#!/usr/bin/env python3
"""Check documentation coverage for public APIs in a source file.

Usage:
    doc-coverage.py <file>

Output format:
    <file>:<line>:<kind>:<name>:<status>[:<details>]

    kind:   function | class | interface | type | struct | enum | trait
            | record | method
    status: HAS_DOC | NO_DOC

Per-language visibility rules:
    Python:     names not starting with '_' (module level and class methods)
    TS/JS:      `export`ed top-level declarations + non-private class members
    Go:         identifiers starting with uppercase
    Rust:       `pub` prefix
    Java:       `public` modifier
    C#:         `public` modifier
    Shell:      all top-level functions (no visibility concept)

Per-language doc detection:
    Python:     ast.get_docstring on functions/classes/methods
    TS/JS:      `/** ... */` JSDoc block on the lines immediately above
    Go:         contiguous `// X ...` lines immediately above (X = name)
    Rust:       contiguous `/// ...` or `//! ...` lines immediately above
    Java:       `/** ... */` Javadoc block immediately above
    C#:         contiguous `/// <summary>` lines immediately above
    Shell:      contiguous `# ` lines immediately above

Exit codes:
    0  Analysis ran (results listed, may include NO_DOC entries).
    1  Bad usage / file not found / unrecognized extension.

Limitations:
    Regex-based for non-Python languages. Class-method detection uses
    balanced-brace scanning that ignores strings and comments. Doc
    detection looks at contiguous comment lines immediately above; doc
    blocks separated by blank lines from the declaration are not
    associated. Treat results as a starting point.
"""

from __future__ import annotations

import argparse
import ast
import re
import sys
from pathlib import Path

DocItem = tuple[int, str, str, str, str]  # (line, kind, name, status, details)


# ---------- Helpers ----------


def _extract_brace_block(text: str, start_pos: int) -> tuple[int, int] | None:
    """Return (body_start, body_end) for the balanced brace block beginning at
    or after `start_pos`. Returns None if no balanced block is found.
    Does not account for braces inside strings or comments; best-effort."""
    open_pos = text.find("{", start_pos)
    if open_pos < 0:
        return None
    depth = 1
    pos = open_pos + 1
    while pos < len(text) and depth > 0:
        c = text[pos]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        pos += 1
    if depth != 0:
        return None
    return (open_pos + 1, pos - 1)


def _lineno_of(text: str, pos: int) -> int:
    return text.count("\n", 0, pos) + 1


def _has_block_comment_above(
    text: str, decl_start: int, open_marker: str = "/**", close_marker: str = "*/"
) -> bool:
    """Return True if a /** ... */ doc block ends on the line immediately
    above the line containing position `decl_start`.

    The block must be adjacent (no blank line in between), matching the
    JSDoc / Javadoc convention of placing the doc comment directly above
    the declaration. Trailing whitespace after the closing marker is
    tolerated; a blank line between comment and declaration is not."""
    line_start = text.rfind("\n", 0, decl_start) + 1
    if line_start == 0:
        # Declaration is on the first line; nothing can be above it.
        return False
    # Content of the line immediately above the declaration line.
    prev_line_end = line_start - 1  # index of the newline ending that line
    prev_line_start = text.rfind("\n", 0, prev_line_end) + 1
    prev_line = text[prev_line_start:prev_line_end].rstrip()
    if not prev_line.endswith(close_marker):
        # The adjacent line does not close a block comment.
        return False
    # A matching opening marker must exist at or before this close marker.
    close_pos = prev_line_start + len(prev_line) - len(close_marker)
    open_pos = text.rfind(open_marker, 0, close_pos + len(close_marker))
    return 0 <= open_pos <= close_pos


def _has_line_comment_above(text: str, decl_start: int, prefix: str) -> bool:
    """Return True if at least one comment line starting with `prefix` exists
    on the line immediately above `decl_start` (no blank line between)."""
    line_start = text.rfind("\n", 0, decl_start) + 1
    if line_start == 0:
        return False
    prev_line_end = line_start - 1
    prev_line_start = text.rfind("\n", 0, prev_line_end) + 1
    prev_line = text[prev_line_start:prev_line_end]
    return prev_line.lstrip().startswith(prefix)


# ---------- Python ----------


def analyze_python(path: Path, text: str) -> list[DocItem]:
    """Use ast to find public functions/classes/methods and check docstrings."""
    results: list[DocItem] = []
    try:
        tree = ast.parse(text, filename=str(path))
    except SyntaxError as exc:
        return [
            (
                getattr(exc, "lineno", 0) or 0,
                "parse_error",
                "<file>",
                "NO_DOC",
                f"ast parse failed: {exc.msg}",
            )
        ]

    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if node.name.startswith("_"):
                continue
            status = "HAS_DOC" if ast.get_docstring(node) else "NO_DOC"
            results.append((node.lineno, "function", node.name, status, ""))
        elif isinstance(node, ast.ClassDef):
            if node.name.startswith("_"):
                continue
            class_status = "HAS_DOC" if ast.get_docstring(node) else "NO_DOC"
            results.append((node.lineno, "class", node.name, class_status, ""))
            for member in node.body:
                if isinstance(member, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    name = member.name
                    # Treat dunder methods as public (they ARE part of the
                    # contract: __init__, __eq__, etc.). Skip single-underscore.
                    if name.startswith("_") and not name.startswith("__"):
                        continue
                    m_status = "HAS_DOC" if ast.get_docstring(member) else "NO_DOC"
                    results.append(
                        (member.lineno, "method", f"{node.name}.{name}", m_status, "")
                    )
    return results


# ---------- TypeScript / JavaScript ----------

_TS_TOP_LEVEL_RE = re.compile(
    r"""^[ \t]*export\s+
        (?:default\s+)?
        (?:async\s+)?
        (?P<kind>function|class|interface|type|enum)
        \s+
        (?P<name>\w+)
    """,
    re.MULTILINE | re.VERBOSE,
)
_TS_METHOD_RE = re.compile(
    r"""^(?P<indent>[ \t]+)
        (?!private\b|protected\b|//|/\*)
        (?:public\s+|static\s+|async\s+|readonly\s+|get\s+|set\s+)*
        (?P<name>\w+)
        \s*\(
    """,
    re.MULTILINE | re.VERBOSE,
)


def analyze_ts(path: Path, text: str) -> list[DocItem]:
    """Find top-level exports and class methods, check JSDoc."""
    results: list[DocItem] = []

    for match in _TS_TOP_LEVEL_RE.finditer(text):
        kind = match.group("kind")
        name = match.group("name")
        lineno = _lineno_of(text, match.start())
        has_doc = _has_block_comment_above(text, match.start())
        results.append((lineno, kind, name, "HAS_DOC" if has_doc else "NO_DOC", ""))

    # Class methods: find each `class X` body and scan inside.
    for class_match in re.finditer(r"\bclass\s+(\w+)", text):
        class_name = class_match.group(1)
        body = _extract_brace_block(text, class_match.end())
        if body is None:
            continue
        body_text = text[body[0] : body[1]]
        for m in _TS_METHOD_RE.finditer(body_text):
            method_name = m.group("name")
            if method_name in {
                "if",
                "for",
                "while",
                "switch",
                "catch",
                "return",
                "function",
            }:
                continue  # control-flow keyword, not a method
            if method_name.startswith("#"):
                continue  # ECMAScript private field
            absolute_pos = body[0] + m.start()
            lineno = _lineno_of(text, absolute_pos)
            has_doc = _has_block_comment_above(text, absolute_pos)
            results.append(
                (
                    lineno,
                    "method",
                    f"{class_name}.{method_name}",
                    "HAS_DOC" if has_doc else "NO_DOC",
                    "",
                )
            )
    return results


# ---------- Go ----------

_GO_DECL_RE = re.compile(
    r"""^(?P<kind>func|type)\s+
        (?:\(\s*\w+\s+\*?(?P<receiver>\w+)\s*\)\s+)?
        (?P<name>\w+)
    """,
    re.MULTILINE | re.VERBOSE,
)


def analyze_go(path: Path, text: str) -> list[DocItem]:
    """Find exported (uppercase-first) top-level declarations and methods."""
    results: list[DocItem] = []
    for match in _GO_DECL_RE.finditer(text):
        kind = match.group("kind")
        receiver = match.group("receiver")
        name = match.group("name")
        if not name or not name[0].isupper():
            continue  # unexported
        lineno = _lineno_of(text, match.start())
        # Go doc convention: contiguous `// X ...` lines starting with the name.
        has_doc = _has_line_comment_above(text, match.start(), "//")
        kind_label = (
            "method" if receiver else ("function" if kind == "func" else "type")
        )
        display = f"{receiver}.{name}" if receiver else name
        results.append(
            (lineno, kind_label, display, "HAS_DOC" if has_doc else "NO_DOC", "")
        )
    return results


# ---------- Rust ----------

_RUST_DECL_RE = re.compile(
    r"""^[ \t]*pub\s+
        (?:\([^)]*\)\s+)?
        (?P<kind>fn|struct|enum|trait|type|mod|const|static)
        \s+
        (?P<name>\w+)
    """,
    re.MULTILINE | re.VERBOSE,
)


def analyze_rust(path: Path, text: str) -> list[DocItem]:
    """Find pub top-level declarations and pub methods inside impl blocks."""
    results: list[DocItem] = []
    for match in _RUST_DECL_RE.finditer(text):
        kind = match.group("kind")
        name = match.group("name")
        lineno = _lineno_of(text, match.start())
        # Rust doc convention: contiguous `/// ...` lines.
        has_doc = _has_line_comment_above(
            text, match.start(), "///"
        ) or _has_line_comment_above(text, match.start(), "//!")
        kind_label = {
            "fn": "function",
            "struct": "struct",
            "enum": "enum",
            "trait": "trait",
            "type": "type",
            "mod": "module",
            "const": "constant",
            "static": "static",
        }.get(kind, kind)
        results.append(
            (lineno, kind_label, name, "HAS_DOC" if has_doc else "NO_DOC", "")
        )

    # pub methods inside impl blocks.
    for impl_match in re.finditer(r"\bimpl\b[^{]*?(?:for\s+(\w+)|(\w+))\s*\{", text):
        type_name = impl_match.group(1) or impl_match.group(2) or "<impl>"
        body = _extract_brace_block(text, impl_match.end())
        if body is None:
            continue
        body_text = text[body[0] : body[1]]
        for m in re.finditer(r"^[ \t]*pub\s+fn\s+(\w+)", body_text, re.MULTILINE):
            method_name = m.group(1)
            absolute_pos = body[0] + m.start()
            lineno = _lineno_of(text, absolute_pos)
            has_doc = _has_line_comment_above(
                text, absolute_pos, "///"
            ) or _has_line_comment_above(text, absolute_pos, "//!")
            results.append(
                (
                    lineno,
                    "method",
                    f"{type_name}.{method_name}",
                    "HAS_DOC" if has_doc else "NO_DOC",
                    "",
                )
            )
    return results


# ---------- Java ----------

_JAVA_TOP_RE = re.compile(
    r"""^[ \t]*public\s+
        (?:abstract\s+|final\s+|static\s+|sealed\s+|non-sealed\s+)*
        (?P<kind>class|interface|enum|record)
        \s+
        (?P<name>\w+)
    """,
    re.MULTILINE | re.VERBOSE,
)
_JAVA_METHOD_RE = re.compile(
    r"""^(?P<indent>[ \t]+)public\s+
        (?:static\s+|final\s+|abstract\s+|synchronized\s+|default\s+)*
        (?:[\w<>\[\],\s.?]+?\s+)?
        (?P<name>\w+)
        \s*\(
    """,
    re.MULTILINE | re.VERBOSE,
)


def analyze_java(path: Path, text: str) -> list[DocItem]:
    """Find public top-level types and public methods inside them."""
    results: list[DocItem] = []
    for match in _JAVA_TOP_RE.finditer(text):
        kind = match.group("kind")
        name = match.group("name")
        lineno = _lineno_of(text, match.start())
        has_doc = _has_block_comment_above(text, match.start())
        results.append((lineno, kind, name, "HAS_DOC" if has_doc else "NO_DOC", ""))

        body = _extract_brace_block(text, match.end())
        if body is None:
            continue
        body_text = text[body[0] : body[1]]
        for m in _JAVA_METHOD_RE.finditer(body_text):
            method_name = m.group("name")
            if method_name in {
                "if",
                "for",
                "while",
                "switch",
                "return",
                "throw",
                "new",
                "this",
                "super",
            }:
                continue
            absolute_pos = body[0] + m.start()
            lineno = _lineno_of(text, absolute_pos)
            has_doc = _has_block_comment_above(text, absolute_pos)
            results.append(
                (
                    lineno,
                    "method",
                    f"{name}.{method_name}",
                    "HAS_DOC" if has_doc else "NO_DOC",
                    "",
                )
            )
    return results


# ---------- C# ----------

_CS_TOP_RE = re.compile(
    r"""^[ \t]*public\s+
        (?:abstract\s+|sealed\s+|static\s+|partial\s+)*
        (?P<kind>class|interface|struct|record|enum)
        \s+
        (?P<name>\w+)
    """,
    re.MULTILINE | re.VERBOSE,
)
_CS_METHOD_RE = re.compile(
    r"""^(?P<indent>[ \t]+)public\s+
        (?:static\s+|virtual\s+|override\s+|async\s+|abstract\s+|sealed\s+)*
        (?:[\w<>\[\],\s.?]+?\s+)?
        (?P<name>\w+)
        \s*\(
    """,
    re.MULTILINE | re.VERBOSE,
)


def analyze_csharp(path: Path, text: str) -> list[DocItem]:
    """Find public top-level types and public methods inside them."""
    results: list[DocItem] = []
    for match in _CS_TOP_RE.finditer(text):
        kind = match.group("kind")
        name = match.group("name")
        lineno = _lineno_of(text, match.start())
        has_doc = _has_line_comment_above(text, match.start(), "///")
        results.append((lineno, kind, name, "HAS_DOC" if has_doc else "NO_DOC", ""))

        body = _extract_brace_block(text, match.end())
        if body is None:
            continue
        body_text = text[body[0] : body[1]]
        for m in _CS_METHOD_RE.finditer(body_text):
            method_name = m.group("name")
            if method_name in {
                "if",
                "for",
                "while",
                "switch",
                "return",
                "throw",
                "new",
                "this",
                "base",
            }:
                continue
            absolute_pos = body[0] + m.start()
            lineno = _lineno_of(text, absolute_pos)
            has_doc = _has_line_comment_above(text, absolute_pos, "///")
            results.append(
                (
                    lineno,
                    "method",
                    f"{name}.{method_name}",
                    "HAS_DOC" if has_doc else "NO_DOC",
                    "",
                )
            )
    return results


# ---------- Shell ----------

_SHELL_FUNC_RE = re.compile(
    r"^[ \t]*(?:function\s+)?(?P<name>\w[\w-]*)\s*\(\s*\)\s*\{",
    re.MULTILINE,
)


def analyze_shell(path: Path, text: str) -> list[DocItem]:
    """All top-level shell functions; check `#` comment block above."""
    results: list[DocItem] = []
    for match in _SHELL_FUNC_RE.finditer(text):
        name = match.group("name")
        lineno = _lineno_of(text, match.start())
        has_doc = _has_line_comment_above(text, match.start(), "#")
        results.append(
            (lineno, "function", name, "HAS_DOC" if has_doc else "NO_DOC", "")
        )
    return results


# ---------- Dispatcher ----------

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
    for lineno, kind, name, status, details in results:
        suffix = f":{details}" if details else ""
        print(f"{path}:{lineno}:{kind}:{name}:{status}{suffix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
