#!/usr/bin/env python3
"""Find definitions or usages of a symbol across a source tree.

Usage:
    find-references.py --def <symbol>  [--lang <ext>] [--root <dir>]
    find-references.py --uses <symbol> [--lang <ext>] [--root <dir>]
    find-references.py --in <file>     [--root <dir>]

Modes:
    --def    List every place SYMBOL is defined.
    --uses   List every place SYMBOL is referenced (excluding definitions).
    --in     List every top-level symbol defined in FILE, plus its usages
             elsewhere in the tree.

Languages supported (best-effort via regex):
    .py .ts .tsx .js .jsx .mjs .cjs .go .rs .java .cs .sh .bash

Backend:
    Uses ripgrep (rg) if available for fast search. Falls back to Python
    standard-library os.walk + re otherwise.

Output format:
    <file>:<line>:<kind>:<context>

    <kind> is one of: def, use, use:<owner> (the last form is used by
    --in to indicate the symbol whose external use was found).

Exit codes:
    0  Search completed (results may be empty).
    1  Invalid usage or root not found.

Limitations:
    Regex-based; cannot distinguish symbols by scope, namespace, or
    overload. Matches inside comments and strings are included. Dynamic
    constructs (eval, decorators that rename, generated code) are not
    detected. Treat results as a starting point for review, not a
    complete answer.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

from ._common import DEFINITION_PATTERNS, SKIP_DIRS

Hit = tuple[str, int, str]
Result = tuple[str, int, str, str]


def _ripgrep_available() -> bool:
    """Return True if `rg` is on PATH."""
    return shutil.which("rg") is not None


def _search_with_ripgrep(pattern: str, root: Path, ext: str | None) -> list[Hit]:
    """Search the tree using ripgrep, restricted to one extension if given."""
    cmd = [
        "rg",
        "--no-heading",
        "--line-number",
        "--with-filename",
        "--no-messages",
        # match the Python-walk fallback: search everything except SKIP_DIRS,
        # regardless of .gitignore or hidden-dir status, so results do not
        # depend on whether rg is installed.
        "--no-ignore",
        "--hidden",
        pattern,
        str(root),
    ]
    if ext:
        cmd.extend(["-g", f"*{ext}"])
    for skip in SKIP_DIRS:
        cmd.extend(["-g", f"!{skip}"])
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=False,
            encoding="utf-8",
            errors="replace",
        )
    except FileNotFoundError:
        return []
    hits: list[Hit] = []
    for line in proc.stdout.splitlines():
        # On Windows, paths may start with `C:\`; split from the LEFT only
        # twice so the drive letter survives intact.
        parts = line.split(":", 2)
        if len(parts) != 3:
            continue
        # If parts[0] is a single drive letter, the path includes the next
        # ':'; re-merge.
        if len(parts[0]) == 1 and parts[0].isalpha():
            sub = parts[1].split(":", 1)
            if len(sub) != 2:
                continue
            file = f"{parts[0]}:{sub[0]}"
            try:
                lineno = int(sub[1])
            except ValueError:
                continue
            content = parts[2]
            hits.append((file, lineno, content))
        else:
            try:
                hits.append((parts[0], int(parts[1]), parts[2]))
            except ValueError:
                continue
    return hits


def _search_with_walk(pattern: str, root: Path, ext: str | None) -> list[Hit]:
    """Search by walking the tree with os.walk + re (fallback path)."""
    rx = re.compile(pattern, re.MULTILINE)
    hits: list[Hit] = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        if ext and path.suffix != ext:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for match in rx.finditer(text):
            lineno = text.count("\n", 0, match.start()) + 1
            line_start = text.rfind("\n", 0, match.start()) + 1
            line_end = text.find("\n", match.end())
            if line_end == -1:
                line_end = len(text)
            hits.append((str(path), lineno, text[line_start:line_end]))
    return hits


def _search(pattern: str, root: Path, ext: str | None) -> list[Hit]:
    """Dispatch to ripgrep when available, otherwise the walk fallback."""
    if _ripgrep_available():
        return _search_with_ripgrep(pattern, root, ext)
    return _search_with_walk(pattern, root, ext)


def find_definitions(
    symbol: str,
    root: Path,
    ext_filter: str | None,
) -> list[Result]:
    """Find every definition of `symbol` under `root`.

    Args:
        symbol: Literal symbol name (not regex).
        root: Directory to walk.
        ext_filter: If set, restrict to this extension (e.g. '.py').

    Returns:
        Deduplicated list of (file, lineno, 'def', context) tuples.
    """
    sym_esc = re.escape(symbol)
    raw: list[Result] = []
    for ext, templates in DEFINITION_PATTERNS.items():
        if ext_filter and ext != ext_filter:
            continue
        for template in templates:
            pattern = template.replace("{name}", sym_esc)
            for file, lineno, content in _search(pattern, root, ext):
                raw.append((file, lineno, "def", content.strip()))
    seen: set[tuple[str, int]] = set()
    unique: list[Result] = []
    for r in raw:
        key = (r[0], r[1])
        if key in seen:
            continue
        seen.add(key)
        unique.append(r)
    return unique


def find_usages(
    symbol: str,
    root: Path,
    ext_filter: str | None,
) -> list[Result]:
    """Find every reference to `symbol` (excluding its definitions)."""
    sym_esc = re.escape(symbol)
    word_pattern = rf"\b{sym_esc}\b"
    all_hits = _search(word_pattern, root, ext_filter)
    defs = find_definitions(symbol, root, ext_filter)
    def_keys = {(d[0], d[1]) for d in defs}
    results: list[Result] = []
    for file, lineno, content in all_hits:
        if (file, lineno) in def_keys:
            continue
        results.append((file, lineno, "use", content.strip()))
    return results


def list_in_file(file_path: Path, root: Path) -> list[Result]:
    """List every top-level symbol defined in `file_path`, plus external uses.

    Args:
        file_path: The file whose symbols to enumerate.
        root: Search root for external references.

    Returns:
        List of (file, lineno, kind, context) tuples. `kind` is 'def' for
        definitions in `file_path`, or 'use:<symbol>' for references in
        other files.
    """
    ext = file_path.suffix
    templates = DEFINITION_PATTERNS.get(ext)
    if templates is None:
        print(f"language not supported for --in: {ext}", file=sys.stderr)
        return []

    text = file_path.read_text(encoding="utf-8", errors="ignore")
    local_defs: dict[str, list[tuple[int, str]]] = {}
    for template in templates:
        capturing = template.replace("{name}", r"(\w+)")
        rx = re.compile(capturing, re.MULTILINE)
        for match in rx.finditer(text):
            symbol = match.group(1)
            lineno = text.count("\n", 0, match.start()) + 1
            line_start = text.rfind("\n", 0, match.start()) + 1
            line_end = text.find("\n", match.end())
            if line_end == -1:
                line_end = len(text)
            content = text[line_start:line_end].strip()
            local_defs.setdefault(symbol, []).append((lineno, content))

    file_resolved = file_path.resolve()
    results: list[Result] = []
    for symbol in sorted(local_defs):
        for lineno, content in local_defs[symbol]:
            results.append((str(file_path), lineno, "def", content))
        for u_file, u_line, _, u_content in find_usages(symbol, root, None):
            if Path(u_file).resolve() == file_resolved:
                continue
            results.append((u_file, u_line, f"use:{symbol}", u_content))
    return results


def _normalize_ext(value: str | None) -> str | None:
    if value is None:
        return None
    return value if value.startswith(".") else f".{value}"


def main(argv: list[str] | None = None) -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--def",
        dest="def_sym",
        metavar="SYMBOL",
        help="Find all definitions of SYMBOL.",
    )
    group.add_argument(
        "--uses",
        dest="uses_sym",
        metavar="SYMBOL",
        help="Find all references to SYMBOL (excluding defs).",
    )
    group.add_argument(
        "--in",
        dest="in_file",
        metavar="FILE",
        help="List symbols defined in FILE plus external uses.",
    )
    parser.add_argument(
        "--lang", metavar=".EXT", help="Restrict to one language extension (e.g. .py)."
    )
    parser.add_argument(
        "--root",
        metavar="DIR",
        default=".",
        help="Root directory to search (default: cwd).",
    )
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    if not root.is_dir():
        print(f"root is not a directory: {root}", file=sys.stderr)
        return 1

    ext = _normalize_ext(args.lang)

    if args.def_sym is not None:
        results = find_definitions(args.def_sym, root, ext)
    elif args.uses_sym is not None:
        results = find_usages(args.uses_sym, root, ext)
    else:
        file_path = Path(args.in_file).resolve()
        if not file_path.is_file():
            print(f"file not found: {file_path}", file=sys.stderr)
            return 1
        results = list_in_file(file_path, root)

    for file, lineno, kind, content in results:
        print(f"{file}:{lineno}:{kind}:{content}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
