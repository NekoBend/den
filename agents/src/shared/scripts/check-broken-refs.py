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

Search scope:
    Usages are searched with ripgrep when available, otherwise by walking the
    tree; both backends read every file under the root except the skipped
    directories (.git, node_modules, .venv, build, ...) and neither follows
    symlinks. Git-ignored and hidden files ARE searched, deliberately (a
    dangling reference in .github/, .claude/ or an untracked file is still a
    dangling reference), and so are binary ones (ripgrep is passed --text), so
    the result does not change when ripgrep is installed or removed, nor with
    the ripgrep configuration on the machine (RIPGREP_CONFIG_PATH is not
    read). Matching lines are printed verbatim, so a tree holding untracked
    secrets has them searched too, and a hit inside a binary file prints that
    file's bytes: run this only on a tree whose contents you would read
    yourself.

Output format:
    <file>:<line>:broken_ref:<symbol>:<context>

    <context> is the matching line, clamped to 300 characters with
    ` [...+N chars]` appended when it was longer, so one hit inside a
    minified bundle or a binary blob cannot flood the output.

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
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

from _common import (
    DEFAULT_CAPTURE,
    DEFINITION_CAPTURE,
    DEFINITION_PATTERNS,
    RG_SEARCH_FLAGS,
    format_hit,
    iter_search_files,
    parse_rg_output,
    read_searchable_text,
    rg_skip_globs,
)


class GitError(RuntimeError):
    """Raised when a git operation fails or git is unavailable."""


def _run_git_bytes(args: list[str], cwd: Path) -> bytes:
    """Run a git command and return raw stdout. Raise GitError on failure.

    A path is bytes, not text: POSIX file names may hold sequences that are
    not valid UTF-8, and decoding one with errors="replace" renames it to a
    file that exists nowhere. Every command whose output is a PATH reads it
    from here and converts with os.fsdecode, whose surrogateescape round-trips
    back to the original bytes when the path is opened or handed to git again.
    """
    if shutil.which("git") is None:
        raise GitError("git is not installed")
    proc = subprocess.run(
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        message = proc.stderr.decode("utf-8", errors="replace").strip()
        raise GitError(message or f"git {' '.join(args)} failed")
    return proc.stdout


def _run_git(args: list[str], cwd: Path) -> str:
    """Run a git command and return stdout decoded as text (file CONTENT)."""
    return _run_git_bytes(args, cwd).decode("utf-8", errors="replace")


def _is_git_repo(root: Path) -> bool:
    """Return True if `root` is inside a git working tree."""
    try:
        _run_git(["rev-parse", "--is-inside-work-tree"], root)
        return True
    except GitError:
        return False


def _repo_root(root: Path) -> Path:
    """Absolute top-level of the git working tree that contains `root`.

    Only the newline git appends is removed. .strip() would also eat a space
    that is part of the directory name, and the top-level would then resolve
    somewhere else: every changed file fails the is_relative_to(root) test
    below and the whole check silently reports nothing.
    """
    out = os.fsdecode(_run_git_bytes(["rev-parse", "--show-toplevel"], root))
    return Path(out.removesuffix("\n")).resolve()


def _changed_files(
    base: str, root: Path, repo_root: Path, lang_ext: str | None
) -> list[Path]:
    """List files changed in the working tree compared to BASE.

    `git diff --name-only` prints paths relative to the REPOSITORY top-level
    whatever the cwd is, so they are joined onto `repo_root` and then narrowed
    to the ones that live under `root` (which may be any subdirectory).

    `-z` is what makes the paths usable: without it git QUOTES anything
    non-ASCII (`café.py` arrives as `"caf\303\251.py"`, escapes and quotes
    included) and the resulting path exists nowhere, while stripping
    whitespace to clean up the line ending would eat a leading or trailing
    space that is part of the name. Either way the file looked deleted, and
    every symbol it defined at BASE was reported as a broken reference.

    The stream is read as BYTES and converted with os.fsdecode for the same
    reason: a file name that is not valid UTF-8 is legal on POSIX, and
    decoding it with errors="replace" would point every later step at a file
    that does not exist.
    """
    out = _run_git_bytes(["diff", "--name-only", "-z", base], root)
    files: list[Path] = []
    for raw in out.split(b"\x00"):
        if not raw:
            continue
        path = repo_root / os.fsdecode(raw)
        if not path.is_relative_to(root):
            continue
        if lang_ext and path.suffix != lang_ext:
            continue
        if path.suffix not in DEFINITION_PATTERNS:
            continue
        files.append(path)
    return files


def _extract_defs(text: str, ext: str) -> set[str]:
    """Return the set of top-level symbol names defined in `text`."""
    templates = DEFINITION_PATTERNS.get(ext, [])
    capture = DEFINITION_CAPTURE.get(ext, DEFAULT_CAPTURE)
    defs: set[str] = set()
    for template in templates:
        pattern = template.replace("{name}", capture)
        defs.update(
            match.group(1) for match in re.finditer(pattern, text, re.MULTILINE)
        )
    return defs


def _file_text_at_base(base: str, file: Path, repo_root: Path) -> str | None:
    """Get the text of `file` at `base` ref. Returns None if file did not exist.

    `<rev>:<path>` is resolved from the repository top-level, so `file` is made
    relative to that and git is run from there. A name that is not valid UTF-8
    carries surrogate escapes here; subprocess re-encodes them with os.fsencode
    on POSIX, so git receives the original bytes.
    """
    rel = file.relative_to(repo_root).as_posix()
    try:
        return _run_git(["show", f"{base}:{rel}"], repo_root)
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
            # same flags as find-references.py: search everything except
            # SKIP_DIRS, ignored and hidden files included, so a dangling
            # reference is reported whether or not rg is installed.
            *RG_SEARCH_FLAGS,
            word_pattern,
            str(root),
        ]
        cmd.extend(rg_skip_globs())
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
        return parse_rg_output(proc.stdout)

    # Fallback: walk the tree manually.
    rx = re.compile(word_pattern)
    hits: list[tuple[str, int, str]] = []
    for path in iter_search_files(root):
        text = read_searchable_text(path)
        if text is None:
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


def main(  # ruff: ignore[too-many-branches, too-many-locals]  # flag dispatch
    argv: list[str] | None = None,
) -> int:
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
        repo_root = _repo_root(root)
        changed = _changed_files(args.base, root, repo_root, ext_filter)
    except GitError as exc:
        print(f"git error: {exc}", file=sys.stderr)
        return 1

    removed_by_file: dict[Path, set[str]] = {}
    for file in changed:
        base_text = _file_text_at_base(args.base, file, repo_root)
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
            print(format_hit(u_file, u_lineno, f"broken_ref:{symbol}", stripped))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
