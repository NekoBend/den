"""File-safety helpers shared by den's commands.

A cloned repository ships the CONTENT and LAYOUT of the workspace files den
reads and writes (what `den install skills --target` deploys, `.clinerules/`,
a hook config), so a symlink there is an attempt to make den read a file from
outside the workspace or to overwrite one. These helpers never follow a
symlink at a root or below it. A symlinked component ABOVE the root (the
workspace dir itself) is out of scope: the attacker owns repo content, not
the local shell. So is the TOCTOU window between the check and the open;
O_NOFOLLOW narrows it where the platform has the flag (Windows does not, and
CI runs there too).

Every message starts with `prefix`, the command the caller runs for the user.
"""

from __future__ import annotations

import os
import sys
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pathlib import Path

_DEN_DIRNAME = ".den"
_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def _find_den_dir(start: Path) -> Path:
    """Nearest ancestor .den/ dir, or <start>/.den if none exists yet."""
    start = start.resolve()
    for d in (start, *start.parents):
        cand = d / _DEN_DIRNAME
        if cand.is_dir():
            return cand
    return start / _DEN_DIRNAME


def _symlink_component(root: Path, path: Path) -> Path | None:
    """First symlinked component at `root` or below on the way to `path`, else None.

    None for a `path` that is not under `root` means "not checked", not "safe":
    the guard owns only what lies below its root, and a caller that takes a
    path from outside (git's answer, an explicit --config) checks it itself."""
    if root.is_symlink():
        return root
    try:
        rel = path.relative_to(root)
    except ValueError:  # not under root: nothing this guard owns
        return None
    cur = root
    for part in rel.parts:
        cur /= part
        if cur.is_symlink():
            return cur
    return None


def _refuse_symlink(root: Path, path: Path, action: str, prefix: str) -> bool:
    """True (after one line on stderr) when `path` must not be read/written."""
    bad = _symlink_component(root, path)
    if bad is None:
        return False
    print(f"{prefix}: refusing to {action} {path}: {bad} is a symlink", file=sys.stderr)
    return True


class _Unreadable:
    """Sentinel type: the file is THERE but den could not read it (a symlink it
    refuses to follow, a permission error, a directory in its place).

    Kept distinct from None ("absent"): a caller that reads the old content
    before rewriting it would otherwise take a failed read for an empty file
    and truncate content it never saw.
    """

    __slots__ = ()


_UNREADABLE = _Unreadable()


def _read_guarded(root: Path, path: Path, prefix: str) -> bytes | _Unreadable | None:
    """Bytes of `path`; None when it is ABSENT; `_UNREADABLE` (one line on
    stderr) when it exists but cannot be read."""
    if _refuse_symlink(root, path, "read", prefix):
        return _UNREADABLE
    try:
        fd = os.open(path, os.O_RDONLY | _NOFOLLOW)
    except FileNotFoundError:
        return None
    except OSError as exc:
        print(f"{prefix}: cannot read {path}: {exc}", file=sys.stderr)
        return _UNREADABLE
    try:
        with os.fdopen(fd, "rb") as fh:
            return fh.read()
    except OSError as exc:
        print(f"{prefix}: cannot read {path}: {exc}", file=sys.stderr)
        return _UNREADABLE


def _write_guarded(root: Path, path: Path, data: bytes, prefix: str) -> bool:
    """Create/truncate `path` and write `data`; False when a symlink is in the way.

    Bytes, not text: that is what `newline=""` bought the text writes it replaces
    (LF stays LF on Windows, so what den writes is byte-stable).
    """
    if _refuse_symlink(root, path, "write", prefix):
        return False
    if path.exists() and not path.is_file():
        # A repo can ship any target (say a skill's `SKILL.md/`) as a
        # DIRECTORY. os.open would raise IsADirectoryError straight out of den;
        # and the callers that check `is_file()` first read that as "absent"
        # and write. (A symlink cannot reach here: _refuse_symlink covers the
        # final component.)
        print(
            f"{prefix}: refusing to write {path}: not a regular file", file=sys.stderr
        )
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | _NOFOLLOW, 0o666)
    with os.fdopen(fd, "wb") as fh:
        fh.write(data)
    return True
