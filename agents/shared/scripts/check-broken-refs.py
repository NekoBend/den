#!/usr/bin/env python3
"""Detect working-tree references that point to symbols removed since BASE.

Usage:
    check-broken-refs.py [--base <ref>] [--root <dir>] [--lang <ext>]

Default base: HEAD
Default root: .

Strategy:
    1. `git diff --name-only BASE -- ` lists files changed in the working tree.
    2. For each changed file:
       - Extract def symbols at BASE (via `git show <base>:<file>`).
       - Extract def symbols from the current working-tree version.
       - removed_defs = base_defs - current_defs.
    3. For each removed def, search the working tree for usages.
    4. Each usage of a removed def is reported as a broken reference.

Output format:
    <file>:<line>:broken_ref:<symbol>:<context>

Exit codes:
    0  Check completed (results may be empty).
    1  Not a git repository / git unavailable / invalid usage.

Limitations:
    Regex-based, like find-references.py. Renames that move a def to
    another file are reported here as broken because the def left the old
    file; manually verify the new location and ignore false positives.
    Signature changes (same name, different params) are NOT detected.
    Symbols added in the working tree that shadow an external symbol are
    NOT flagged. Dynamic constructs are not analyzed.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

from _common import DEFINITION_PATTERNS, SKIP_DIRS


class GitError(RuntimeError):
    """Raised when a git operation fails or git is unavailable."""


def _run_git(args: list[str], cwd: Path) -> str:
    """Run a git command and return stdout. Raise GitError on failure."""
    if shutil.which("git") is None:
        raise GitError("git is not installed")
    proc = subprocess.run(
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
        encoding="utf-8",
        errors="replace",
    )
    if proc.returncode != 0:
        raise GitError(proc.stderr.strip() or f"git {' '.join(args)} failed")
    return proc.stdout


def _is_git_repo(root: Path) -> bool:
    """Return True if `root` is inside a git working tree."""
    try:
        _run_git(["rev-parse", "--is-inside-work-tree"], root)
        return True
    except GitError:
        return False


def _changed_files(base: str, root: Path, lang_ext: str | None) -> list[Path]:
    """List files changed in the working tree compared to BASE."""
    out = _run_git(["diff", "--name-only", base], root)
    files: list[Path] = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        path = root / line
        if lang_ext and path.suffix != lang_ext:
            continue
        if path.suffix not in DEFINITION_PATTERNS:
            continue
        files.append(path)
    return files


def _extract_defs(text: str, ext: str) -> set[str]:
    """Return the set of top-level symbol names defined in `text`."""
    templates = DEFINITION_PATTERNS.get(ext, [])
    defs: set[str] = set()
    for template in templates:
        pattern = template.replace("{name}", r"(\w+)")
        for match in re.finditer(pattern, text, re.MULTILINE):
            defs.add(match.group(1))
    return defs


def _file_text_at_base(base: str, file: Path, root: Path) -> str | None:
    """Get the text of `file` at `base` ref. Returns None if file did not exist."""
    rel = file.relative_to(root).as_posix()
    try:
        return _run_git(["show", f"{base}:{rel}"], root)
    except GitError:
        return None


def _file_text_now(file: Path) -> str | None:
    """Get the current working-tree text of `file`. Returns None if missing."""
    try:
        return file.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return None


def _ripgrep_available() -> bool:
    return shutil.which("rg") is not None


def _search_for_usages(symbol: str, root: Path) -> list[tuple[str, int, str]]:
    """Find every occurrence of `symbol` as a whole word under `root`."""
    word_pattern = rf"\b{re.escape(symbol)}\b"
    if _ripgrep_available():
        cmd = [
            "rg",
            "--no-heading",
            "--line-number",
            "--with-filename",
            "--no-messages",
            word_pattern,
            str(root),
        ]
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
            proc = None
        hits: list[tuple[str, int, str]] = []
        if proc is not None:
            for line in proc.stdout.splitlines():
                # Same Windows drive-letter handling as find-references.py.
                parts = line.split(":", 2)
                if len(parts) != 3:
                    continue
                if len(parts[0]) == 1 and parts[0].isalpha():
                    sub = parts[1].split(":", 1)
                    if len(sub) != 2:
                        continue
                    file = f"{parts[0]}:{sub[0]}"
                    try:
                        lineno = int(sub[1])
                    except ValueError:
                        continue
                    hits.append((file, lineno, parts[2]))
                else:
                    try:
                        hits.append((parts[0], int(parts[1]), parts[2]))
                    except ValueError:
                        continue
        return hits

    # Fallback: walk the tree manually.
    rx = re.compile(word_pattern)
    hits = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.parts):
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
    parser.add_argument(
        "--base", default="HEAD", help="Git ref to compare against (default: HEAD)."
    )
    parser.add_argument(
        "--root", default=".", help="Working tree root (default: current directory)."
    )
    parser.add_argument(
        "--lang", metavar=".EXT", help="Restrict to one language extension (e.g. .py)."
    )
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    if not root.is_dir():
        print(f"root is not a directory: {root}", file=sys.stderr)
        return 1

    if not _is_git_repo(root):
        print(
            "[check-broken-refs] SKIPPED: not a git repository or git unavailable",
            file=sys.stderr,
        )
        return 0

    ext_filter = _normalize_ext(args.lang)

    try:
        changed = _changed_files(args.base, root, ext_filter)
    except GitError as exc:
        print(f"git error: {exc}", file=sys.stderr)
        return 1

    removed_by_file: dict[Path, set[str]] = {}
    for file in changed:
        base_text = _file_text_at_base(args.base, file, root)
        if base_text is None:
            # File did not exist at base; nothing to remove.
            continue
        current_text = _file_text_now(file)
        if current_text is None:
            # File was deleted; everything in base_text is removed.
            removed_by_file[file] = _extract_defs(base_text, file.suffix)
            continue
        base_defs = _extract_defs(base_text, file.suffix)
        current_defs = _extract_defs(current_text, file.suffix)
        removed = base_defs - current_defs
        if removed:
            removed_by_file[file] = removed

    all_removed = {sym for syms in removed_by_file.values() for sym in syms}
    if not all_removed:
        return 0

    # Map each removed symbol to the resolved path(s) it was removed FROM, so a
    # leftover mention in that same file is not reported as a broken ref: the
    # removal is already part of the diff, and using the name there (a comment,
    # a renamed sibling, a string) is not an external dangling reference.
    removed_from: dict[str, set[Path]] = {}
    for changed_file, syms in removed_by_file.items():
        resolved = changed_file.resolve()
        for sym in syms:
            removed_from.setdefault(sym, set()).add(resolved)

    for symbol in sorted(all_removed):
        for u_file, u_lineno, u_content in _search_for_usages(symbol, root):
            try:
                u_resolved = Path(u_file).resolve()
            except (OSError, ValueError):
                u_resolved = None
            if u_resolved is not None and u_resolved in removed_from.get(symbol, set()):
                continue
            stripped = u_content.strip()
            print(f"{u_file}:{u_lineno}:broken_ref:{symbol}:{stripped}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
