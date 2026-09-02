"""den hook memory - workspace-level session memory the agent reads and overwrites.

Memory lives at <project>/.den/memory.md, a single Markdown file the agent
owns: it reads the whole file and rewrites it wholesale. The agent may edit
memory.md directly with its own file tools (not only via `den hook memory save`),
so this module never relies on save being called. Instead a cheap
content-hash `checkpoint` copies memory.md into .den/history/ whenever the
content changes since the last snapshot. Hooks drive `checkpoint` every turn
(and optionally after each write), so direct edits are captured and any bad
overwrite can be recovered with `log` / `restore` / `diff`.

Subcommands:
  show              print memory.md (empty if absent)
  checkpoint        snapshot memory.md into history if it changed
  save [--file F]   overwrite memory.md from stdin or F (snapshots first)
  add <text>        append one fact (from args or stdin), snapshots first
  clear             delete memory.md (snapshots it first)
  log               list history snapshots, newest first
  restore [n]       restore the n-th newest snapshot (default 1)
  diff [n]          diff memory.md against the n-th newest snapshot (default 1)
  path              print the resolved memory.md path
"""

from __future__ import annotations

import os
import sys
from datetime import UTC, datetime
from pathlib import Path

HISTORY_LIMIT = 20

_DEN_DIRNAME = ".den"
_MEMORY_NAME = "memory.md"
_HISTORY_DIRNAME = "history"
_SNAP_PREFIX = "memory."
_SNAP_SUFFIX = ".md"
_STAMP_FORMAT = "%Y%m%dT%H%M%S%f"


def _find_den_dir(start: Path) -> Path:
    """Nearest ancestor .den/ dir, or <start>/.den if none exists yet."""
    start = start.resolve()
    for d in (start, *start.parents):
        cand = d / _DEN_DIRNAME
        if cand.is_dir():
            return cand
    return start / _DEN_DIRNAME


def _memory_path(den_dir: Path) -> Path:
    return den_dir / _MEMORY_NAME


# --------------------------------------------------------------------------- #
# symlink guard
#
# A cloned repository ships the CONTENT and LAYOUT of `.den/`, so a symlink
# there is an attempt to make den read a file from outside the workspace into
# the model's context every turn (memory.md is injected by the hook, and copied
# into .den/history/ by checkpoint) or to overwrite one (save/add/restore/clear
# write memory.md back). den therefore never follows a symlink at `.den` or
# below it. A symlinked component ABOVE `.den` -- the workspace dir itself -- is
# out of scope: the attacker owns repo content, not the local shell. So is the
# TOCTOU window between the check and the open; O_NOFOLLOW narrows it where the
# platform has the flag (Windows does not, and CI runs there too).
# --------------------------------------------------------------------------- #

_ERR = "den hook memory"
_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def _symlink_component(root: Path, path: Path) -> Path | None:
    """First symlinked component at `root` or below on the way to `path`, else None."""
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


def _refuse_symlink(root: Path, path: Path, action: str, prefix: str = _ERR) -> bool:
    """True (after one line on stderr) when `path` must not be read/written."""
    bad = _symlink_component(root, path)
    if bad is None:
        return False
    print(f"{prefix}: refusing to {action} {path}: {bad} is a symlink", file=sys.stderr)
    return True


class _Unreadable:
    """Sentinel type: the file is THERE but den could not read it (a symlink it
    refuses to follow, a permission error, a directory in its place).

    Kept distinct from None ("no memory yet"): a caller that reads the old
    content before rewriting it would otherwise take a failed read for an empty
    file and truncate content it never saw.
    """

    __slots__ = ()


_UNREADABLE = _Unreadable()


def _read_guarded(
    root: Path, path: Path, prefix: str = _ERR
) -> bytes | _Unreadable | None:
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


def _read_guarded_text(
    root: Path, path: Path, prefix: str = _ERR, *, errors: str = "strict"
) -> str | _Unreadable | None:
    data = _read_guarded(root, path, prefix)
    return data.decode("utf-8", errors) if isinstance(data, bytes) else data


def _read_text_or_empty(
    root: Path, path: Path, prefix: str = _ERR, *, errors: str = "strict"
) -> str:
    """Text of `path`, or "" when it is absent or unreadable (already reported).
    For the callers that must not fail: composition and the install notices."""
    text = _read_guarded_text(root, path, prefix, errors=errors)
    return text if isinstance(text, str) else ""


def _write_guarded(root: Path, path: Path, data: bytes, prefix: str = _ERR) -> bool:
    """Create/truncate `path` and write `data`; False when a symlink is in the way.

    Bytes, not text: that is what `newline=""` bought the text writes it replaces
    (LF stays LF on Windows, so snapshots and mirrors are byte-stable).
    """
    if _refuse_symlink(root, path, "write", prefix):
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | _NOFOLLOW, 0o666)
    with os.fdopen(fd, "wb") as fh:
        fh.write(data)
    return True


_CLINERULES_DIRNAME = ".clinerules"
_CLINERULES_IMPRINT = "den-imprint.md"  # also the cline-cli "installed here" marker
_CLINERULES_MEMORY = "den-memory.md"
_CLINERULES_HEADER = (
    "<!-- den-managed mirror of .den/memory.md. Edit memory with `den hook memory`, "
    "not here. -->\n\n"
)


def _clinerules_dir(den_dir: Path) -> Path:
    return den_dir.parent / _CLINERULES_DIRNAME


def mirror_to_clinerules(den_dir: Path) -> bool:
    """Mirror memory.md into the sibling `.clinerules/` dir as `den-memory.md`, but
    only when `den hook install --tool cline-cli` has run here (detected by its
    `den-imprint.md` rule file). cline loads `.clinerules/*.md` as always-on rules
    at session start; the cline CLI cannot inject memory via hooks, so this rule
    file is its memory-delivery channel. Gating on the cline-cli marker (not just
    the dir) is deliberate: the cline EXTENSION creates `.clinerules/hooks/` too,
    and it already injects memory per turn via its hook, so mirroring there as well
    would double-deliver. No-op otherwise. Returns True if it wrote/removed the
    mirror."""
    rules = _clinerules_dir(den_dir)
    if not (rules / _CLINERULES_IMPRINT).is_file():
        return False
    dest = rules / _CLINERULES_MEMORY
    # The mirror is den-managed too, and a repo can ship `.clinerules/` just as
    # easily as `.den/`, so guard it against the same symlink trick.
    if _refuse_symlink(rules, dest, "write"):
        return False
    text = _read_guarded_text(den_dir, _memory_path(den_dir))
    if isinstance(text, _Unreadable):
        return False  # do not mirror, and do not drop the mirror we cannot verify
    text = text or ""
    if text.strip():
        return _write_guarded(rules, dest, (_CLINERULES_HEADER + text).encode("utf-8"))
    if dest.exists():  # memory emptied/cleared -> drop the stale mirror
        dest.unlink()
        return True
    return False


def _history_dir(den_dir: Path) -> Path:
    return den_dir / _HISTORY_DIRNAME


def _snapshots(den_dir: Path) -> list[Path]:
    """History snapshots, newest first (fixed-width timestamps sort by time).

    A symlink is never a snapshot: reading one would leak an outside file into
    memory (log/diff/restore all read the list) and restoring it would write
    memory back through it. Dropped silently rather than reported, because
    checkpoint walks this list every turn and one line per turn is noise; the
    reads a planted symlink actually targets do report.
    """
    hist = _history_dir(den_dir)
    if _symlink_component(den_dir, hist) is not None or not hist.is_dir():
        return []
    snaps = [
        p
        for p in hist.iterdir()
        if p.name.startswith(_SNAP_PREFIX)
        and p.name.endswith(_SNAP_SUFFIX)
        and not p.is_symlink()
    ]
    return sorted(snaps, key=lambda p: p.name, reverse=True)


def _snap_stamp(snap: Path) -> str:
    return snap.name[len(_SNAP_PREFIX) : -len(_SNAP_SUFFIX)]


def _fmt_stamp(stamp: str) -> str:
    try:
        dt = datetime.strptime(stamp, _STAMP_FORMAT).replace(tzinfo=UTC)
    except ValueError:
        return stamp
    return dt.strftime("%Y-%m-%d %H:%M:%S UTC")


def _first_line(path: Path) -> str:
    try:
        with path.open(encoding="utf-8") as fh:
            for line in fh:
                stripped = line.strip()
                if stripped:
                    return stripped[:60]
    except OSError:
        pass
    return ""


def _rotate(den_dir: Path) -> None:
    for old in _snapshots(den_dir)[HISTORY_LIMIT:]:
        old.unlink(missing_ok=True)


def _do_checkpoint(den_dir: Path) -> Path | None:
    """Snapshot memory.md into history if it changed since the newest snapshot.

    Returns the new snapshot path, or None when there is nothing to do
    (no memory.md, or it is identical to the most recent snapshot).
    """
    current = _read_guarded(den_dir, _memory_path(den_dir))
    if not isinstance(current, bytes):  # absent or unreadable -- cannot snapshot
        return None
    hist = _history_dir(den_dir)
    if _refuse_symlink(den_dir, hist, "write"):
        return None
    snaps = _snapshots(den_dir)
    if snaps and snaps[0].read_bytes() == current:
        return None
    hist.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(UTC).strftime(_STAMP_FORMAT)
    dest = hist / f"{_SNAP_PREFIX}{stamp}{_SNAP_SUFFIX}"
    n = 1
    while dest.exists():  # never clobber a same-timestamp snapshot
        dest = hist / f"{_SNAP_PREFIX}{stamp}_{n:03d}{_SNAP_SUFFIX}"
        n += 1
    if not _write_guarded(den_dir, dest, current):
        return None
    _rotate(den_dir)
    return dest


def _parse_index(argv: list[str]) -> int | None:
    if not argv:
        return 1
    try:
        return int(argv[0])
    except ValueError:
        print(
            f"den hook memory: expected a numeric index, got {argv[0]!r}",
            file=sys.stderr,
        )
        return None


def _cmd_show(den_dir: Path, argv: list[str]) -> int:
    text = _read_guarded_text(den_dir, _memory_path(den_dir))
    if isinstance(text, _Unreadable):
        return 1
    if text is not None:
        sys.stdout.write(text)
    return 0


def _cmd_checkpoint(den_dir: Path, argv: list[str]) -> int:
    snap = _do_checkpoint(den_dir)
    if snap is not None:
        print(f"checkpointed: {snap}", file=sys.stderr)
    return 0


def _cmd_save(den_dir: Path, argv: list[str]) -> int:
    if argv and argv[0] in {"--file", "-f"}:
        if len(argv) < 2:
            print("den hook memory save: --file needs a path", file=sys.stderr)
            return 2
        try:
            content = Path(argv[1]).read_text(encoding="utf-8")
        except OSError as exc:
            print(
                f"den hook memory save: cannot read {argv[1]}: {exc}", file=sys.stderr
            )
            return 2
    else:
        content = sys.stdin.read()
    mem = _memory_path(den_dir)
    if _refuse_symlink(den_dir, mem, "write"):
        return 1
    # What cannot be read cannot be checkpointed, and overwriting it would
    # destroy content den never saw. Refuse instead of silently replacing it.
    if isinstance(_read_guarded(den_dir, mem), _Unreadable):
        return 1
    _do_checkpoint(den_dir)
    if not _write_guarded(den_dir, mem, content.encode("utf-8")):
        return 1
    mirror_to_clinerules(den_dir)
    return 0


def _cmd_add(den_dir: Path, argv: list[str]) -> int:
    """Append one fact to memory.md (from args, or stdin if none). Low-friction
    counterpart to save's wholesale overwrite: a weak agent records a single
    line without rewriting the whole file. Snapshots the prior content first."""
    content = " ".join(argv) if argv else sys.stdin.read()
    if not content.strip():
        print(
            "den hook memory add: nothing to add (give text or pipe it on stdin)",
            file=sys.stderr,
        )
        return 2
    mem = _memory_path(den_dir)
    if _refuse_symlink(den_dir, mem, "write"):
        return 1
    existing = _read_guarded_text(den_dir, mem)
    if isinstance(existing, _Unreadable):
        return 1  # appending to what we could not read would truncate it
    _do_checkpoint(den_dir)
    existing = existing or ""
    if existing and not existing.endswith("\n"):
        existing += "\n"
    addition = content if content.endswith("\n") else content + "\n"
    if not _write_guarded(den_dir, mem, (existing + addition).encode("utf-8")):
        return 1
    mirror_to_clinerules(den_dir)
    return 0


def _cmd_clear(den_dir: Path, argv: list[str]) -> int:
    mem = _memory_path(den_dir)
    if _refuse_symlink(den_dir, mem, "remove"):
        return 1
    if isinstance(_read_guarded(den_dir, mem), _Unreadable):
        return 1  # deleting what cannot be snapshotted is not reversible
    _do_checkpoint(den_dir)
    if mem.is_file():
        mem.unlink()
    mirror_to_clinerules(den_dir)
    return 0


def _cmd_log(den_dir: Path, argv: list[str]) -> int:
    snaps = _snapshots(den_dir)
    if not snaps:
        print("(no history)")
        return 0
    for i, snap in enumerate(snaps, start=1):
        print(f"{i:3}  {_fmt_stamp(_snap_stamp(snap))}  {_first_line(snap)}")
    return 0


def _cmd_restore(den_dir: Path, argv: list[str]) -> int:
    n = _parse_index(argv)
    if n is None:
        return 2
    snaps = _snapshots(den_dir)
    if n < 1 or n > len(snaps):
        print(
            f"den hook memory restore: no snapshot #{n} (have {len(snaps)})",
            file=sys.stderr,
        )
        return 1
    target = snaps[n - 1]
    data = target.read_bytes()
    stamp = _snap_stamp(target)
    mem = _memory_path(den_dir)
    if _refuse_symlink(den_dir, mem, "write"):
        return 1
    # Same reason as save/add/clear: _write_guarded opens write-only and
    # truncates, so a memory.md _do_checkpoint could not read would be gone with
    # no snapshot behind it -- and restore is the command whose whole promise is
    # that the state it replaces stays recoverable.
    if isinstance(_read_guarded(den_dir, mem), _Unreadable):
        return 1
    _do_checkpoint(den_dir)  # make the restore itself reversible
    if not _write_guarded(den_dir, mem, data):
        return 1
    mirror_to_clinerules(den_dir)
    print(f"restored #{n} ({_fmt_stamp(stamp)}) -> {mem}", file=sys.stderr)
    return 0


def _cmd_diff(den_dir: Path, argv: list[str]) -> int:
    n = _parse_index(argv)
    if n is None:
        return 2
    snaps = _snapshots(den_dir)
    if n < 1 or n > len(snaps):
        print(
            f"den hook memory diff: no snapshot #{n} (have {len(snaps)})",
            file=sys.stderr,
        )
        return 1
    # difflib is only needed by this subcommand; importing it here keeps it off
    # the den hook run hot path (runs every agent turn).
    import difflib

    old = snaps[n - 1]
    old_lines = old.read_text(encoding="utf-8").splitlines(keepends=True)
    new = _read_guarded_text(den_dir, _memory_path(den_dir))
    if isinstance(new, _Unreadable):
        return 1  # a diff against "" would read as a wholesale deletion
    new_lines = (new or "").splitlines(keepends=True)
    out = "".join(
        difflib.unified_diff(
            old_lines,
            new_lines,
            fromfile=f"#{n} {_fmt_stamp(_snap_stamp(old))}",
            tofile="memory.md",
        )
    )
    if out:
        sys.stdout.write(out if out.endswith("\n") else out + "\n")
    else:
        print("(no differences)", file=sys.stderr)
    return 0


def _cmd_path(den_dir: Path, argv: list[str]) -> int:
    print(_memory_path(den_dir))
    return 0


_HANDLERS = {
    "show": _cmd_show,
    "checkpoint": _cmd_checkpoint,
    "save": _cmd_save,
    "add": _cmd_add,
    "clear": _cmd_clear,
    "log": _cmd_log,
    "restore": _cmd_restore,
    "diff": _cmd_diff,
    "path": _cmd_path,
}


def _usage() -> None:
    print(
        "usage: den hook memory <subcommand> [args]\n"
        "\n"
        "Subcommands:\n"
        "  show              print memory.md (empty if absent)\n"
        "  checkpoint        snapshot memory.md into history if it changed\n"
        "  save [--file F]   overwrite memory.md from stdin or F\n"
        "  add <text>        append one fact (from args or stdin)\n"
        "  clear             delete memory.md (snapshots it first)\n"
        "  log               list history snapshots, newest first\n"
        "  restore [n]       restore the n-th newest snapshot (default 1)\n"
        "  diff [n]          diff memory.md vs the n-th newest snapshot (default 1)\n"
        "  path              print the resolved memory.md path\n"
        "\n"
        f"Memory dir: nearest ancestor .den/ or <cwd>/.den "
        f"(keeps the last {HISTORY_LIMIT} snapshots)."
    )


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]

    if not args or args[0] in {"-h", "--help", "help"}:
        _usage()
        return 0

    cmd, rest = args[0], args[1:]
    handler = _HANDLERS.get(cmd)
    if handler is None:
        print(f"den hook memory: unknown subcommand '{cmd}'", file=sys.stderr)
        _usage()
        return 2

    den_dir = _find_den_dir(Path.cwd())
    return handler(den_dir, rest)


if __name__ == "__main__":
    raise SystemExit(main())
