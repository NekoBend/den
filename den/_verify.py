#!/usr/bin/env python3
"""Extract and verify import statements in a source file.

Usage:
    verify-imports.py <file>

Output format:
    <file>:<line>:<kind>:<target>:<status>[:<details>]

    kind:    import_module | from_import | require | use | using | source
    status:  OK         imported target verifiably exists
             MISSING    imported target does not exist in this environment
             UNVERIFIED extraction succeeded but verification could not run
                        (tool missing, manifest absent, relative import, etc.)

Per-language verification strategy (best-effort):
    Python:     importlib.util.find_spec on the top-level module name.
    TS/JS:      node_modules/ presence + package.json (deps + devDeps).
    Go:         `go list <pkg>` if `go` is on PATH.
    Rust:       Cargo.toml [dependencies] + std/core/alloc/proc_macro.
    Java:       pom.xml dependencies + build.gradle deps + JDK heuristic.
    C#:         .csproj PackageReference + System.* heuristic.
    Shell:      file existence for `source FILE` / `. FILE`.

Exit codes:
    0  Analysis ran (results listed, may include MISSING).
    1  Bad usage / file not found / unrecognized extension.

Limitations:
    Regex-based for non-Python languages; handles common cases, not all
    syntax. Dynamic imports, generated paths, and runtime resolution are
    NOT analyzed. Treat results as a starting point, not a complete map.
"""

from __future__ import annotations

import argparse
import ast
import importlib.util
import json
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

Import = tuple[int, str, str, str, str]  # (line, kind, target, status, details)


# ---------- Python ----------


def analyze_python(path: Path, text: str) -> list[Import]:
    """Extract and verify Python imports via the ast module + importlib."""
    results: list[Import] = []
    try:
        tree = ast.parse(text, filename=str(path))
    except SyntaxError as exc:
        return [
            (
                getattr(exc, "lineno", 0) or 0,
                "parse_error",
                str(exc).split("\n", 1)[0],
                "UNVERIFIED",
                "python ast parse failed",
            )
        ]
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                results.append(
                    _check_python_module(node.lineno, "import_module", alias.name)
                )
        elif isinstance(node, ast.ImportFrom):
            if node.level and node.level > 0:
                target = "." * node.level + (node.module or "")
                results.append(
                    (
                        node.lineno,
                        "from_import",
                        target,
                        "UNVERIFIED",
                        "relative import (package context unknown)",
                    )
                )
                continue
            mod = node.module or ""
            results.append(_check_python_module(node.lineno, "from_import", mod))
    return results


def _check_python_module(lineno: int, kind: str, target: str) -> Import:
    top = target.split(".")[0]
    if not top:
        return (lineno, kind, target, "UNVERIFIED", "empty module name")
    try:
        spec = importlib.util.find_spec(top)
    except (ImportError, ValueError):
        spec = None
    if spec is not None:
        return (lineno, kind, target, "OK", "")
    return (
        lineno,
        kind,
        target,
        "MISSING",
        f"module '{top}' not found in current Python environment",
    )


# ---------- TypeScript / JavaScript ----------

# Node.js built-in modules (sample; not exhaustive but covers most common).
_NODE_BUILTINS: frozenset[str] = frozenset(
    {
        "assert",
        "buffer",
        "child_process",
        "cluster",
        "console",
        "crypto",
        "dgram",
        "dns",
        "events",
        "fs",
        "http",
        "http2",
        "https",
        "net",
        "os",
        "path",
        "perf_hooks",
        "process",
        "punycode",
        "querystring",
        "readline",
        "repl",
        "stream",
        "string_decoder",
        "tls",
        "tty",
        "url",
        "util",
        "v8",
        "vm",
        "worker_threads",
        "zlib",
        "module",
        "timers",
        "node:test",
    }
)

_TS_IMPORT_RE = re.compile(
    r"""import\s+(?:type\s+)?(?:[^'"]*?\s+from\s+)?['"]([^'"]+)['"]""",
    re.MULTILINE,
)
_TS_REQUIRE_RE = re.compile(
    r"""\brequire\(\s*['"]([^'"]+)['"]\s*\)""",
    re.MULTILINE,
)


def analyze_ts(path: Path, text: str) -> list[Import]:
    """Extract TS/JS imports via regex, verify against node_modules + package.json."""
    pkg_json_deps = _load_package_json_deps(path)
    project_root = _find_ancestor(path, "package.json") or path.parent
    node_modules = project_root / "node_modules"
    results: list[Import] = []

    for match in _TS_IMPORT_RE.finditer(text):
        target = match.group(1)
        lineno = text.count("\n", 0, match.start()) + 1
        results.append(
            _check_node_target(
                lineno, "import_module", target, node_modules, pkg_json_deps, path
            )
        )
    for match in _TS_REQUIRE_RE.finditer(text):
        target = match.group(1)
        lineno = text.count("\n", 0, match.start()) + 1
        results.append(
            _check_node_target(
                lineno, "require", target, node_modules, pkg_json_deps, path
            )
        )
    return results


def _check_node_target(
    lineno: int,
    kind: str,
    target: str,
    node_modules: Path,
    pkg_deps: set[str],
    source: Path,
) -> Import:
    if target.startswith(("./", "../", "/")):
        # Local file import. Resolve relative to source file.
        candidate = (source.parent / target).resolve()
        for suffix in (
            "",
            ".ts",
            ".tsx",
            ".js",
            ".jsx",
            ".mjs",
            ".cjs",
            "/index.ts",
            "/index.js",
        ):
            if Path(str(candidate) + suffix).exists():
                return (lineno, kind, target, "OK", "")
        return (lineno, kind, target, "MISSING", "local file not found")

    # Strip subpath: '@scope/pkg/sub' → '@scope/pkg'; 'pkg/sub' → 'pkg'.
    if target.startswith("@"):
        pkg = "/".join(target.split("/")[:2])
    else:
        pkg = target.split("/")[0]

    if pkg in _NODE_BUILTINS or pkg.startswith("node:"):
        return (lineno, kind, target, "OK", "node builtin")
    if pkg in pkg_deps:
        # Declared dependency; check installation.
        if (node_modules / pkg).exists():
            return (lineno, kind, target, "OK", "")
        return (
            lineno,
            kind,
            target,
            "UNVERIFIED",
            f"declared in package.json but not installed (no node_modules/{pkg})",
        )
    if node_modules.exists() and (node_modules / pkg).exists():
        return (lineno, kind, target, "OK", "installed but not in package.json")
    if not node_modules.exists():
        return (
            lineno,
            kind,
            target,
            "UNVERIFIED",
            "no node_modules and no package.json deps to consult",
        )
    return (
        lineno,
        kind,
        target,
        "MISSING",
        f"package '{pkg}' not found in package.json deps or node_modules",
    )


def _load_package_json_deps(source: Path) -> set[str]:
    pkg_json = _find_ancestor(source, "package.json")
    if pkg_json is None:
        return set()
    try:
        with pkg_json.open("r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return set()
    deps: set[str] = set()
    for key in (
        "dependencies",
        "devDependencies",
        "peerDependencies",
        "optionalDependencies",
    ):
        section = data.get(key) or {}
        if isinstance(section, dict):
            deps.update(section.keys())
    return deps


# ---------- Go ----------

_GO_IMPORT_BLOCK_RE = re.compile(r"import\s*\(([^)]*)\)", re.DOTALL)
_GO_IMPORT_LINE_RE = re.compile(r'import\s+(?:\w+\s+)?"([^"]+)"')


def analyze_go(path: Path, text: str) -> list[Import]:
    """Extract Go imports and verify via `go list` if available."""
    paths_with_lines: list[tuple[int, str]] = []
    for match in _GO_IMPORT_BLOCK_RE.finditer(text):
        block = match.group(1)
        base_line = text.count("\n", 0, match.start()) + 1
        for line_offset, raw in enumerate(block.splitlines()):
            stripped = raw.strip()
            if not stripped or stripped.startswith("//"):
                continue
            m = re.match(r'(?:\w+\s+)?"([^"]+)"', stripped)
            if m:
                paths_with_lines.append((base_line + line_offset, m.group(1)))
    for match in _GO_IMPORT_LINE_RE.finditer(text):
        target = match.group(1)
        lineno = text.count("\n", 0, match.start()) + 1
        paths_with_lines.append((lineno, target))

    has_go = shutil.which("go") is not None
    results: list[Import] = []
    for lineno, target in paths_with_lines:
        if not has_go:
            results.append(
                (
                    lineno,
                    "import_module",
                    target,
                    "UNVERIFIED",
                    "`go` not installed; cannot verify with `go list`",
                )
            )
            continue
        if target.startswith("-"):
            # never let an import path lifted from the analyzed file reach `go
            # list` as a leading-dash argument (it would parse as a build flag).
            results.append(
                (
                    lineno,
                    "import_module",
                    target,
                    "UNVERIFIED",
                    "refusing a leading-dash import path",
                )
            )
            continue
        proc = subprocess.run(
            ["go", "list", target],
            capture_output=True,
            text=True,
            check=False,
            encoding="utf-8",
            errors="replace",
        )
        if proc.returncode == 0:
            results.append((lineno, "import_module", target, "OK", ""))
        else:
            err = (
                proc.stderr.strip().splitlines()[-1]
                if proc.stderr
                else "go list failed"
            )
            results.append((lineno, "import_module", target, "MISSING", err))
    return results


# ---------- Rust ----------

_RUST_USE_RE = re.compile(
    r"^\s*(?:pub\s+)?use\s+([\w:]+)(?:::\{|\s*;|\s+as)", re.MULTILINE
)
_RUST_STD_CRATES: frozenset[str] = frozenset(
    {
        "std",
        "core",
        "alloc",
        "proc_macro",
        "test",
        "crate",
        "super",
        "self",  # path keywords, not external
    }
)


def analyze_rust(path: Path, text: str) -> list[Import]:
    """Extract Rust `use` declarations; verify against Cargo.toml [dependencies]."""
    deps = _load_cargo_deps(path)
    results: list[Import] = []
    for match in _RUST_USE_RE.finditer(text):
        path_expr = match.group(1)
        top = path_expr.split("::", 1)[0]
        lineno = text.count("\n", 0, match.start()) + 1
        if top in _RUST_STD_CRATES:
            results.append((lineno, "use", path_expr, "OK", f"{top} (std/path)"))
        elif deps is None:
            results.append(
                (
                    lineno,
                    "use",
                    path_expr,
                    "UNVERIFIED",
                    "no Cargo.toml found in ancestors",
                )
            )
        elif top in deps:
            results.append(
                (lineno, "use", path_expr, "OK", f"{top} declared in Cargo.toml")
            )
        else:
            results.append(
                (
                    lineno,
                    "use",
                    path_expr,
                    "MISSING",
                    f"crate '{top}' not in Cargo.toml [dependencies]",
                )
            )
    return results


def _load_cargo_deps(source: Path) -> set[str] | None:
    cargo = _find_ancestor(source, "Cargo.toml")
    if cargo is None:
        return None
    try:
        text = cargo.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return None
    deps: set[str] = set()
    in_deps = False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            in_deps = line in {
                "[dependencies]",
                "[dev-dependencies]",
                "[build-dependencies]",
            }
            continue
        if not in_deps or not line or line.startswith("#"):
            continue
        m = re.match(r"([\w-]+)\s*=", line)
        if m:
            # Rust crates are referenced with underscores in code even when
            # the toml key is hyphenated. Normalize both ways.
            name = m.group(1)
            deps.add(name)
            deps.add(name.replace("-", "_"))
    return deps


# ---------- Java ----------

_JAVA_IMPORT_RE = re.compile(r"^\s*import\s+(?:static\s+)?([\w.]+)\s*;", re.MULTILINE)
_JAVA_JDK_PREFIXES: tuple[str, ...] = (
    "java.",
    "javax.",
    "jdk.",
    "com.sun.",
    "sun.",
    "org.w3c.dom",
    "org.xml.sax",
    "org.ietf.jgss",
)


def analyze_java(path: Path, text: str) -> list[Import]:
    """Extract Java imports; verify against pom.xml / build.gradle + JDK heuristic."""
    deps = _load_java_deps(path)
    results: list[Import] = []
    for match in _JAVA_IMPORT_RE.finditer(text):
        target = match.group(1)
        lineno = text.count("\n", 0, match.start()) + 1
        if any(target.startswith(prefix) for prefix in _JAVA_JDK_PREFIXES):
            results.append((lineno, "import_module", target, "OK", "JDK package"))
            continue
        if deps is None:
            results.append(
                (
                    lineno,
                    "import_module",
                    target,
                    "UNVERIFIED",
                    "no pom.xml or build.gradle found in ancestors",
                )
            )
            continue
        # Match against any dep group:artifact prefix.
        top_two = ".".join(target.split(".")[:2])
        top_three = ".".join(target.split(".")[:3])
        if any(
            target.startswith(d) or top_two.startswith(d) or top_three.startswith(d)
            for d in deps
        ):
            results.append(
                (
                    lineno,
                    "import_module",
                    target,
                    "OK",
                    "matches declared dependency prefix",
                )
            )
        else:
            results.append(
                (
                    lineno,
                    "import_module",
                    target,
                    "UNVERIFIED",
                    "package not matched to any declared dependency "
                    "(prefix match heuristic)",
                )
            )
    return results


def _load_java_deps(source: Path) -> set[str] | None:
    pom = _find_ancestor(source, "pom.xml")
    gradle = _find_ancestor(source, "build.gradle") or _find_ancestor(
        source, "build.gradle.kts"
    )
    deps: set[str] = set()
    if pom is not None:
        try:
            tree = ET.parse(pom)
            ns_match = re.match(r"\{([^}]+)\}", tree.getroot().tag)
            ns = {"m": ns_match.group(1)} if ns_match else {}
            for dep in tree.findall(".//m:dependency" if ns else ".//dependency", ns):
                group = dep.find("m:groupId" if ns else "groupId", ns)
                if group is not None and group.text:
                    deps.add(group.text.strip())
        except (OSError, ET.ParseError):
            pass
    if gradle is not None:
        try:
            text = gradle.read_text(encoding="utf-8", errors="ignore")
            for match in re.finditer(r"""['"]([\w.-]+):[\w.-]+:[\w.+-]+['"]""", text):
                deps.add(match.group(1))
        except OSError:
            pass
    if not deps and pom is None and gradle is None:
        return None
    return deps


# ---------- C# ----------

_CS_USING_RE = re.compile(r"^\s*using\s+(?:static\s+)?([\w.]+)\s*;", re.MULTILINE)


def analyze_csharp(path: Path, text: str) -> list[Import]:
    """Extract C# usings; verify against .csproj PackageReference + System.* heuristic."""
    deps = _load_csproj_deps(path)
    results: list[Import] = []
    for match in _CS_USING_RE.finditer(text):
        target = match.group(1)
        lineno = text.count("\n", 0, match.start()) + 1
        if target.startswith("System.") or target == "System":
            results.append((lineno, "using", target, "OK", "BCL"))
            continue
        if deps is None:
            results.append(
                (lineno, "using", target, "UNVERIFIED", "no .csproj found in ancestors")
            )
            continue
        # Match against PackageReference Include attributes.
        top_one = target.split(".", 1)[0]
        if any(target.startswith(d) or top_one == d for d in deps):
            results.append(
                (
                    lineno,
                    "using",
                    target,
                    "OK",
                    "matches declared PackageReference prefix",
                )
            )
        else:
            results.append(
                (
                    lineno,
                    "using",
                    target,
                    "UNVERIFIED",
                    "namespace not matched to any PackageReference "
                    "(prefix match heuristic)",
                )
            )
    return results


def _load_csproj_deps(source: Path) -> set[str] | None:
    proj = _find_ancestor_glob(source, "*.csproj")
    if proj is None:
        return None
    try:
        tree = ET.parse(proj)
        deps: set[str] = set()
        for pr in tree.getroot().iter("PackageReference"):
            include = pr.attrib.get("Include")
            if include:
                deps.add(include)
        return deps
    except (OSError, ET.ParseError):
        return None


# ---------- Shell ----------

_SHELL_SOURCE_RE = re.compile(r"^\s*(?:source|\.)\s+([^\s;#]+)", re.MULTILINE)


def analyze_shell(path: Path, text: str) -> list[Import]:
    """Extract shell `source` and `.` directives; verify file existence."""
    results: list[Import] = []
    for match in _SHELL_SOURCE_RE.finditer(text):
        target = match.group(1)
        lineno = text.count("\n", 0, match.start()) + 1
        # Strip shell quotes if any.
        clean = target.strip("\"'")
        candidate = (
            (path.parent / clean).resolve()
            if not clean.startswith("/")
            else Path(clean)
        )
        if candidate.exists():
            results.append((lineno, "source", clean, "OK", ""))
        else:
            results.append(
                (lineno, "source", clean, "MISSING", f"file not found at {candidate}")
            )
    return results


# ---------- Common helpers ----------


def _find_ancestor(start: Path, name: str) -> Path | None:
    """Walk up from `start.parent` looking for a file named `name`."""
    for ancestor in [start.parent, *start.parents]:
        candidate = ancestor / name
        if candidate.is_file():
            return candidate
    return None


def _find_ancestor_glob(start: Path, pattern: str) -> Path | None:
    """Walk up from `start.parent` looking for any file matching glob `pattern`."""
    for ancestor in [start.parent, *start.parents]:
        matches = list(ancestor.glob(pattern))
        if matches:
            return matches[0]
    return None


LANGUAGE_HANDLERS = {
    ".py": analyze_python,
    ".ts": analyze_ts,
    ".tsx": analyze_ts,
    ".js": analyze_ts,
    ".jsx": analyze_ts,
    ".mjs": analyze_ts,
    ".cjs": analyze_ts,
    ".go": analyze_go,
    ".rs": analyze_rust,
    ".java": analyze_java,
    ".cs": analyze_csharp,
    ".sh": analyze_shell,
    ".bash": analyze_shell,
}


def main(argv: list[str] | None = None) -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("file", help="Source file to analyze.")
    args = parser.parse_args(argv)

    path = Path(args.file)
    if not path.is_file():
        print(f"file not found: {path}", file=sys.stderr)
        return 1

    handler = LANGUAGE_HANDLERS.get(path.suffix)
    if handler is None:
        print(f"unrecognized extension: {path.suffix}", file=sys.stderr)
        return 1

    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError as exc:
        print(f"cannot read {path}: {exc}", file=sys.stderr)
        return 1

    results = handler(path, text)
    for lineno, kind, target, status, details in results:
        suffix = f":{details}" if details else ""
        print(f"{path}:{lineno}:{kind}:{target}:{status}{suffix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
