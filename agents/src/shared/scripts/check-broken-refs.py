#!/usr/bin/env python3
"""Detect working-tree references that point to symbols removed since BASE.

Usage:
    check-broken-refs.py [--base <ref>] [--root <dir>] [--lang <ext>]

Default base: HEAD, which covers uncommitted changes only. To check changes
that are already committed (a branch, a pull request), pass the commit they
started from: --base "$(git merge-base <base-branch> HEAD)".
Default root: .

Strategy:
    1. `git diff --name-status -M BASE` lists files changed in the working
       tree, a renamed file under both its old and its new path.
    2. For each changed file:
       - Extract its top-level definitions and its methods at BASE (via
         `git show <base>:<old path>`) and in the working tree (new path).
       - removed = base - current.
    3. All removed names are searched for in ONE pass over the tree: a
       top-level name as a whole word, a member (a method, or a type nested
       in a Java or C# type) only as `.name` attribute access, or in a Rust
       file also as `Type::name` (dunder methods are not searched).
    4. Each such mention outside the file(s) the name was removed from is
       reported as a broken reference.

    The base and the number of changed files examined are printed to stderr,
    so an empty report on an empty diff is not mistaken for a clean one.

Search scope:
    Inside a git work tree, the files git tracks plus the untracked ones it
    does not ignore (`git ls-files --cached --others --exclude-standard`), so
    virtual environments, build output and anything else listed in a
    .gitignore are not searched; hidden files such as .github/ are. Nested
    repositories and submodules are separate work trees and are not searched.
    A root that is itself gitignored is searched whole, except directories
    holding a pyvenv.cfg (a virtual environment, whatever it is called).
    Either way the skipped directories (.git, node_modules, .venv, build,
    ...) are left out and symlinks are not followed, not even a tracked
    directory that became one. Ripgrep, when installed, searches that
    same file list, otherwise the files are read in-process, and binary files
    are searched as text by both (ripgrep is passed --text), so the result
    does not change when ripgrep is installed or removed, nor with the
    ripgrep configuration on the machine (RIPGREP_CONFIG_PATH is not read).
    Matching lines are printed verbatim, so a tree holding untracked secrets
    that are not ignored has them searched too, and a hit inside a binary
    file prints that file's bytes: run this only on a tree whose contents you
    would read yourself.

    git and rg are run by absolute path, found in the absolute PATH entries
    only. One found in the working directory is refused on Windows, which
    would otherwise run a git.exe or rg.exe shipped at the root of the
    checkout, and on any system when it was reached through a relative PATH
    entry. git runs with core.fsmonitor=false, so a .git/config that came
    with the tree cannot make it start the fsmonitor program it names. A
    clean filter that config defines still runs when `git diff` rehashes a
    changed file, as it does for any git command run in that tree.

Output format:
    <file>:<line>:broken_ref:<symbol>:<context>

    <context> is the matching line, clamped to 300 characters with
    ` [...+N chars]` appended when it was longer, so one hit inside a
    minified bundle or a binary blob cannot flood the output.

Exit codes:
    0  Check completed (results may be empty).
    1  Not a git repository / git unavailable / invalid usage.

Limitations:
    Regex-based, like find-references.py. A def moved to ANOTHER file (not
    a rename of the whole file) is reported here as broken because it left
    the old file; manually verify the new location and ignore false
    positives.

    What counts as a definition: in Python, a def or class at module level
    (column 0, or inside a module-level if/try/with/for/while block) and an
    assignment at column 0; a def in a class body is a method. Local
    variables, keyword arguments, nested functions, class attributes and
    assignments inside a block are not definitions. A Go func with a
    receiver is a method. In Rust, Java and C# the braces decide: a
    definition outside every type and function body (a Rust `mod` or
    `extern` block and a C# namespace count as outside) is top-level, a fn
    or const in a Rust impl or trait and a type nested in a Java or C# type
    is a member, anything in a function body is neither. Shell and PowerShell
    functions count at any depth; a shell variable does not, a PowerShell
    `$x =` at column 0 (or a `$script:`/`$global:` one) does. In PowerShell
    files (.ps1 .psm1 .psd1) names are compared and matched ignoring case,
    as PowerShell does: renaming Get-Widget to get-widget removes nothing,
    and a removed Get-Widget is found where it is called as get-widget.

    Signature changes (same name, different params) are NOT detected.
    Symbols added in the working tree that shadow an external symbol are NOT
    flagged. Dynamic constructs are not analyzed.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from _common import (
    CASE_INSENSITIVE_EXTS,
    DEFINITION_PATTERNS,
    allow_undecodable_paths_on_stdout,
    find_tool,
    format_hit,
    git_command,
    list_search_files,
    member_definitions,
    mentions,
    search_words,
    top_level_definitions,
)

PROG = "[check-broken-refs]"


class GitError(RuntimeError):
    """Raised when a git operation fails or git is unavailable."""


def _run_git_bytes(args: list[str], cwd: Path) -> bytes:
    """Run a git command and return raw stdout. Raise GitError on failure.

    A path is bytes, not text: POSIX file names may hold sequences that are
    not valid UTF-8, and decoding one with errors="replace" renames it to a
    file that exists nowhere. Every command whose output is a PATH reads it
    from here and converts with os.fsdecode, whose surrogateescape round-trips
    back to the original bytes when the path is opened or handed to git again.

    git runs by absolute path (find_tool): never one shipped in the workspace,
    and with GIT_SAFE_CONFIG, so the repository's own config cannot make it
    start an fsmonitor program.
    """
    git = find_tool("git")
    if git is None:
        raise GitError("git is not installed")
    proc = subprocess.run(
        git_command(git, *args),
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
) -> list[tuple[Path, Path]]:
    """(path at BASE, path now) for each file changed in the working tree.

    `--name-status -M` is what keeps a renamed file: `--name-only` names it
    by its NEW path alone, where nothing existed at BASE, so the file was
    skipped and every definition removed from it went unchecked. A rename
    arrives as `R<score> NUL old NUL new`; every other change as
    `<status> NUL path`. A copy (C, when diff.renames=copies) leaves its
    source in place, so only its new path is kept, as an added file.

    git prints paths relative to the REPOSITORY top-level whatever the cwd
    is, so they are joined onto `repo_root` and then narrowed to the ones that
    live under `root` (which may be any subdirectory).

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
    out = _run_git_bytes(["diff", "--name-status", "-z", "-M", base], root)
    fields = out.split(b"\x00")
    changed: list[tuple[Path, Path]] = []
    i = 0
    while i < len(fields):
        status = fields[i]
        if not status:
            i += 1
            continue
        if status[:1] in {b"R", b"C"}:
            old, new = fields[i + 1 : i + 3]
            i += 3
            if status[:1] == b"C":
                old = new
        else:
            old = new = fields[i + 1]
            i += 2
        old_path = repo_root / os.fsdecode(old)
        new_path = repo_root / os.fsdecode(new)
        if not (old_path.is_relative_to(root) or new_path.is_relative_to(root)):
            continue
        if lang_ext and old_path.suffix != lang_ext:
            continue
        if old_path.suffix not in DEFINITION_PATTERNS:
            continue
        changed.append((old_path, new_path))
    return changed


def _names(found: list[tuple[int, str, str]]) -> set[str]:
    return {name for _lineno, name, _line in found}


def _removed(base: set[str], current: set[str], ext: str) -> set[str]:
    """Names in `base` that `current` no longer has.

    PowerShell names are case-insensitive, so renaming Get-Widget to
    get-widget removes nothing there.
    """
    if ext not in CASE_INSENSITIVE_EXTS:
        return base - current
    kept = {name.casefold() for name in current}
    return {name for name in base if name.casefold() not in kept}


def _is_dunder(name: str) -> bool:
    return name.startswith("__") and name.endswith("__")


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


def _normalize_ext(value: str | None) -> str | None:
    if value is None:
        return None
    return value if value.startswith(".") else f".{value}"


def _removed_symbols(
    changed: list[tuple[Path, Path]], base: str, repo_root: Path
) -> tuple[set[str], set[str], dict[str, set[Path]]]:
    """(top-level names, method names, where each was removed from).

    Top-level names are searched as whole words, methods only as `.name`.
    Each removed symbol maps to the resolved path(s) it was removed FROM
    (both paths of a renamed file), so a leftover mention in that same file
    is not reported as a broken ref: the removal is already part of the diff,
    and using the name there (a comment, a renamed sibling, a string) is not
    an external dangling reference.
    """
    words: set[str] = set()
    members: set[str] = set()
    removed_from: dict[str, set[Path]] = {}
    for old, new in changed:
        base_text = _file_text_at_base(base, old, repo_root)
        if base_text is None:
            # File did not exist at base; nothing to remove.
            continue
        current_text = _file_text_now(new) or ""  # deleted: everything removed
        base_top = _names(top_level_definitions(base_text, old.suffix))
        now_top = _names(top_level_definitions(current_text, new.suffix))
        base_members = _names(member_definitions(base_text, old.suffix))
        now_members = _names(member_definitions(current_text, new.suffix))
        gone_top = _removed(base_top, now_top, old.suffix)
        gone_members = {
            name
            for name in _removed(base_members, now_members | now_top, old.suffix)
            if not _is_dunder(name)
        }
        if not gone_top and not gone_members:
            continue
        words |= gone_top
        members |= gone_members
        sources = {old.resolve()} if old == new else {old.resolve(), new.resolve()}
        for sym in gone_top | gone_members:
            removed_from.setdefault(sym, set()).update(sources)
    members -= words  # removed at top level somewhere: any bare mention counts
    return words, members, removed_from


def _report(
    words: set[str], members: set[str], removed_from: dict[str, set[Path]], root: Path
) -> None:
    """Print every mention of a removed symbol outside the file it left."""
    # The hits come from a handful of files: resolve each one once, not once
    # per hit (realpath costs an lstat per path component, which was 85% of
    # the run time on a slow mount).
    resolved: dict[str, Path | None] = {}

    def resolve(file: str) -> Path | None:
        if file not in resolved:
            try:
                resolved[file] = Path(file).resolve()
            except (OSError, ValueError):
                resolved[file] = None
        return resolved[file]

    hits = [
        (u_file, u_lineno, u_content, Path(u_file).suffix)
        for u_file, u_lineno, u_content in search_words(
            words | members, list_search_files(root)
        )
    ]
    for symbol in sorted(words | members):
        member = symbol in members
        for u_file, u_lineno, u_content, u_ext in hits:
            if not mentions(u_content, u_ext, symbol, member=member):
                continue
            if resolve(u_file) in removed_from[symbol]:
                continue
            stripped = u_content.strip()
            print(format_hit(u_file, u_lineno, f"broken_ref:{symbol}", stripped))


def main(argv: list[str] | None = None) -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--base",
        default="HEAD",
        help=(
            "Git ref to compare against (default: HEAD, i.e. uncommitted changes "
            'only; for a branch pass "$(git merge-base <base-branch> HEAD)").'
        ),
    )
    parser.add_argument(
        "--root", default=".", help="Working tree root (default: current directory)."
    )
    parser.add_argument(
        "--lang", metavar=".EXT", help="Restrict to one language extension (e.g. .py)."
    )
    args = parser.parse_args(argv)
    allow_undecodable_paths_on_stdout()

    root = Path(args.root).resolve()
    if not root.is_dir():
        print(f"root is not a directory: {root}", file=sys.stderr)
        return 1

    if not _is_git_repo(root):
        print(
            f"{PROG} SKIPPED: not a git repository or git unavailable",
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

    # Said every time: an empty report on an empty diff is not a clean one.
    count = f"{len(changed)} changed file{'' if len(changed) == 1 else 's'}"
    hint = ""
    if not changed and args.base == "HEAD":
        hint = (
            " (HEAD covers uncommitted changes only; for committed ones pass"
            ' --base "$(git merge-base <base-branch> HEAD)")'
        )
    print(f"{PROG} base={args.base}: {count} examined{hint}", file=sys.stderr)

    words, members, removed_from = _removed_symbols(changed, args.base, repo_root)
    if removed_from:
        _report(words, members, removed_from, root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
