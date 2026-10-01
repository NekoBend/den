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

    Each mode reads the tree once: the lines holding the symbol (for --in,
    any of the file's symbols) as a whole word are found, then each is
    classified as a definition or a use in-process. With ripgrep that is one
    run per case group (PowerShell files are searched apart, ignoring case),
    and more only when the file list outgrows the command-line limit.

    --in lists top-level names: in Python, a def or class at module level
    (column 0, or inside a module-level if/try/with/for/while block) and an
    assignment at column 0, never a method, a nested function or a local.
    A Go method (a func with a receiver) is not one either. In Rust, Java
    and C# a name counts outside every type and function body only (a Rust
    `mod` or `extern` block and a C# namespace count as outside), so an impl
    method, a nested type and a function inside a function are left out.

Languages supported (best-effort via regex):
    .py .ts .tsx .js .jsx .mjs .cjs .go .rs .java .cs .sh .bash .ps1 .psm1

    In PowerShell files (.ps1 .psm1 .psd1) matching ignores case, as
    PowerShell does.

Backend:
    Uses ripgrep (rg) if available for fast search. Falls back to reading
    the files in-process otherwise, one line at a time.

Search scope:
    Inside a git work tree, the files git tracks plus the untracked ones it
    does not ignore (`git ls-files --cached --others --exclude-standard`), so
    virtual environments, build output and anything else listed in a
    .gitignore are not searched; hidden files such as .github/ are. Nested
    repositories and submodules are separate work trees and are not searched.
    A root that is itself gitignored, and any root outside a work tree, is
    searched whole, except directories below it holding a pyvenv.cfg (a
    virtual environment, whatever it is called); so is a work tree git fails
    to list (an unreadable index, a repository owned by another user), with
    a note on stderr. Either way the skipped directories (.git, node_modules,
    .venv, build, ...) are left out and symlinks are not followed, not even a
    tracked directory that became one. These rules apply below the root
    only: a root you name is searched even when it is ignored, holds a
    pyvenv.cfg or is called .venv/ or build/. Both backends search that
    same file list, and binary files as text (ripgrep is passed --text), so
    the result does not change when ripgrep is installed or removed, nor
    with the ripgrep configuration on the machine (RIPGREP_CONFIG_PATH is
    not read).
    A matching line is printed verbatim, so a tree holding untracked secrets
    that are not ignored has them searched too, and a hit inside a binary
    file prints that file's bytes: run this only on a tree whose contents you
    would read yourself.

    git and rg are run by absolute path, found in the absolute PATH entries
    only. One found in the working directory is refused on Windows, which
    would otherwise run a git.exe or rg.exe shipped at the root of the
    checkout, and on any system when it was reached through a relative PATH
    entry. git runs with core.fsmonitor=false, so a .git/config that came
    with the tree cannot make it start the fsmonitor program it names.

Output format:
    <file>:<line>:<kind>:<context>

    <kind> is one of: def, use, use:<owner> (the last form is used by
    --in to indicate the symbol whose external use was found).

    <context> is the matching line, clamped to 300 characters with
    ` [...+N chars]` appended when it was longer, so one hit inside a
    minified bundle or a binary blob cannot flood the output.

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
import sys
from pathlib import Path

from _common import (
    TOP_LEVEL_PATTERNS,
    allow_undecodable_paths_on_stdout,
    format_hit,
    is_definition_line,
    iter_searchable_lines,
    list_search_files,
    mentions,
    search_words,
    top_level_definitions,
)

Result = tuple[str, int, str, str]


def _files(root: Path, ext_filter: str | None) -> list[Path]:
    files = list_search_files(root)
    if ext_filter:
        files = [f for f in files if f.suffix == ext_filter]
    return files


def _split(
    symbol: str, root: Path, ext_filter: str | None
) -> tuple[list[Result], list[Result]]:
    """(definitions, uses) of `symbol`, from one whole-word search.

    Every definition pattern holds the symbol as a whole word, so the
    definition lines are a subset of the word hits: each hit is classified by
    the patterns of its own file's extension instead of searching the tree
    once more per (extension, pattern) pair.
    """
    defs: list[Result] = []
    uses: list[Result] = []
    for file, lineno, content in search_words([symbol], _files(root, ext_filter)):
        if is_definition_line(content, Path(file).suffix, symbol):
            defs.append((file, lineno, "def", content.strip()))
        else:
            uses.append((file, lineno, "use", content.strip()))
    return defs, uses


def find_definitions(
    symbol: str,
    root: Path,
    ext_filter: str | None,
) -> list[Result]:
    """Find every definition of `symbol` under `root`.

    Args:
        symbol: Literal symbol name (not regex).
        root: Directory to search.
        ext_filter: If set, restrict to this extension (e.g. '.py').

    Returns:
        List of (file, lineno, 'def', context) tuples, one per line.
    """
    return _split(symbol, root, ext_filter)[0]


def find_usages(
    symbol: str,
    root: Path,
    ext_filter: str | None,
) -> list[Result]:
    """Find every reference to `symbol` (excluding its definitions)."""
    return _split(symbol, root, ext_filter)[1]


def list_in_file(file_path: Path, root: Path) -> list[Result]:
    """List every top-level symbol defined in `file_path`, plus external uses.

    One search finds every line naming any of the file's symbols; each line
    is then attributed to the symbols it names.

    Args:
        file_path: The file whose symbols to enumerate.
        root: Search root for external references.

    Returns:
        List of (file, lineno, kind, context) tuples. `kind` is 'def' for
        definitions in `file_path`, or 'use:<symbol>' for references in
        other files.
    """
    ext = file_path.suffix
    if ext not in TOP_LEVEL_PATTERNS:
        print(f"language not supported for --in: {ext}", file=sys.stderr)
        return []

    text = "\n".join(line for _lineno, line in iter_searchable_lines(file_path))
    local_defs: dict[str, list[tuple[int, str]]] = {}
    for lineno, symbol, line in top_level_definitions(text, ext):
        local_defs.setdefault(symbol, []).append((lineno, line.strip()))

    # Hits come from a handful of files; resolve each one once.
    resolved: dict[str, Path] = {}
    file_resolved = file_path.resolve()
    hits = [
        (u_file, u_line, u_content, Path(u_file).suffix)
        for u_file, u_line, u_content in search_words(
            local_defs, list_search_files(root)
        )
    ]
    results: list[Result] = []
    for symbol in sorted(local_defs):
        for lineno, content in local_defs[symbol]:
            results.append((str(file_path), lineno, "def", content))
        for u_file, u_line, u_content, u_ext in hits:
            if not mentions(u_content, u_ext, symbol):
                continue
            if is_definition_line(u_content, u_ext, symbol):
                continue
            if u_file not in resolved:
                resolved[u_file] = Path(u_file).resolve()
            if resolved[u_file] == file_resolved:
                continue
            results.append((u_file, u_line, f"use:{symbol}", u_content.strip()))
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
    allow_undecodable_paths_on_stdout()

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
        print(format_hit(file, lineno, kind, content))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
