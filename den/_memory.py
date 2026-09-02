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
    """Text of `path`. Bytes that are not UTF-8 are an unreadable file, not an
    exception: den's text artifacts are UTF-8, a repo can put any byte in one,
    and _compose reads memory.md and imprint.md on EVERY hook invocation -- so a
    raised UnicodeDecodeError would crash the per-turn hook. Callers already know
    what to do with the sentinel. (`errors="replace"` never reaches the except.)
    """
    data = _read_guarded(root, path, prefix)
    if not isinstance(data, bytes):
        return data
    try:
        return data.decode("utf-8", errors)
    except UnicodeDecodeError as exc:
        print(f"{prefix}: cannot read {path}: {exc}", file=sys.stderr)
        return _UNREADABLE


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
    if path.exists() and not path.is_file():
        # A repo can ship `.den/imprint.md/` (or any other target) as a DIRECTORY.
        # os.open would raise IsADirectoryError straight out of den install; and
        # the callers that check `is_file()` first read that as "absent" and write.
        # (A symlink cannot reach here: _refuse_symlink covers the final component.)
        print(
            f"{prefix}: refusing to write {path}: not a regular file", file=sys.stderr
        )
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
    marker = rules / _CLINERULES_IMPRINT
    # The marker is PROOF that `den install hook --tool cline-cli` ran here, so it
    # has to be a real file den wrote. is_file() follows a link, so a repo-planted
    # symlink to ANY outside regular file used to switch the mirror on for a
    # workspace that never installed cline-cli -- publishing memory.md into a
    # .clinerules the user never asked den to write to. Silent, like every other
    # "not installed here" answer: this is a gate, and it runs on every save/add.
    if _symlink_component(rules, marker) is not None or not marker.is_file():
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
    if dest.is_file():  # memory emptied/cleared -> drop the stale mirror
        dest.unlink()
        return True
    if dest.exists():
        # Symmetric with the write branch above: a repo can ship
        # `.clinerules/den-memory.md/` as a DIRECTORY, and unlink() on it raises
        # -- after `clear` has already deleted memory.md, so den would die
        # half-done. (A symlink cannot reach here; _refuse_symlink ran first.)
        print(
            f"{_ERR}: refusing to remove {dest}: not a regular file",
            file=sys.stderr,
        )
    return False


def _history_dir(den_dir: Path) -> Path:
    return den_dir / _HISTORY_DIRNAME


def _snapshots(den_dir: Path) -> list[Path]:
    """History snapshots, newest first (fixed-width timestamps sort by time).

    Only regular files count. A symlink would leak an outside file into memory
    (log/diff/restore all read the list) and restoring it would write memory back
    through it; a DIRECTORY named `memory.*.md` -- equally shippable in a repo --
    passed the name test and then crashed checkpoint/restore/diff on read_bytes().
    Dropped silently rather than reported, because checkpoint walks this list
    every turn and one line per turn is noise; the reads a planted entry actually
    targets do report.
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
        and p.is_file()
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


class _Refused:
    """Sentinel type: a checkpoint den declined or failed to make, when there WAS
    content to snapshot -- a symlinked or non-directory `history/`, a refused
    snapshot write, an OSError on the way.

    Kept distinct from None, which means there was simply nothing to do (memory.md
    absent, or already identical to the newest snapshot). Folding the two together
    is what let save/add/clear/restore carry on after the safety net was refused
    and leave an overwrite -- or, for clear, a deletion -- with no snapshot behind
    it.
    """

    __slots__ = ()


_REFUSED = _Refused()


def _unusable_history(den_dir: Path, hist: Path) -> bool:
    """True (one line on stderr) when `.den/history` cannot hold a snapshot: a
    symlink den will not follow, or a non-directory a repo planted there -- which
    would otherwise make `mkdir(exist_ok=True)` raise FileExistsError."""
    if _refuse_symlink(den_dir, hist, "write"):
        return True
    if hist.exists() and not hist.is_dir():
        print(
            f"{_ERR}: refusing to snapshot into {hist}: not a directory",
            file=sys.stderr,
        )
        return True
    return False


def _do_checkpoint(den_dir: Path) -> Path | _Refused | None:
    """Snapshot memory.md into history if it changed since the newest snapshot.

    Returns the new snapshot path; None when there is nothing to do (no memory.md,
    or it already matches the newest snapshot); `_REFUSED` when there was content
    to snapshot and den could not store it. Callers that are about to overwrite or
    delete memory.md must treat `_REFUSED` as a stop -- see _checkpointed.
    """
    current = _read_guarded(den_dir, _memory_path(den_dir))
    if not isinstance(current, bytes):  # absent or unreadable -- nothing to store
        return None
    hist = _history_dir(den_dir)
    if _unusable_history(den_dir, hist):
        return _REFUSED
    try:
        snaps = _snapshots(den_dir)
        if snaps and snaps[0].read_bytes() == current:
            return None  # unchanged: nothing to do, and that is not a refusal
        hist.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(UTC).strftime(_STAMP_FORMAT)
        dest = hist / f"{_SNAP_PREFIX}{stamp}{_SNAP_SUFFIX}"
        n = 1
        while dest.exists():  # never clobber a same-timestamp snapshot
            dest = hist / f"{_SNAP_PREFIX}{stamp}_{n:03d}{_SNAP_SUFFIX}"
            n += 1
        if not _write_guarded(den_dir, dest, current):
            return _REFUSED
        _rotate(den_dir)
        return dest
    except OSError as exc:  # read-only workspace, full disk, vanished dir
        print(f"{_ERR}: cannot snapshot into {hist}: {exc}", file=sys.stderr)
        return _REFUSED


def _writable_memory(den_dir: Path, mem: Path, action: str = "write") -> bool:
    """False (already reported) when memory.md must not be written or removed: a
    symlink den will not follow, or a file it exists but could not read --
    replacing content den never saw would destroy it, and it cannot be
    snapshotted either. One place, so no command can check only half of it."""
    if _refuse_symlink(den_dir, mem, action):
        return False
    return not isinstance(_read_guarded(den_dir, mem), _Unreadable)


def _checkpointed(den_dir: Path) -> bool:
    """Run the pre-write checkpoint. False (already reported) when it was refused,
    and the caller must then write nothing: without a snapshot behind it the
    overwrite -- or the delete -- cannot be undone."""
    return not isinstance(_do_checkpoint(den_dir), _Refused)


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
    if isinstance(snap, _Refused):
        return 1  # asked for a checkpoint, could not make one
    if snap is not None:
        print(f"checkpointed: {snap}", file=sys.stderr)
    return 0


def _save_content(argv: list[str]) -> str | int:
    """The text `save` will write: stdin, or the file named by --file. An int is
    the exit code to return instead (the message is already out)."""
    if not (argv and argv[0] in {"--file", "-f"}):
        return sys.stdin.read()
    if len(argv) < 2:
        print("den hook memory save: --file needs a path", file=sys.stderr)
        return 2
    try:
        return Path(argv[1]).read_text(encoding="utf-8")
    except OSError as exc:
        print(f"den hook memory save: cannot read {argv[1]}: {exc}", file=sys.stderr)
        return 2


def _cmd_save(den_dir: Path, argv: list[str]) -> int:
    content = _save_content(argv)
    if isinstance(content, int):
        return content
    mem = _memory_path(den_dir)
    if not _writable_memory(den_dir, mem) or not _checkpointed(den_dir):
        return 1
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
    if not _checkpointed(den_dir):
        return 1
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
    # Deleting what cannot be snapshotted is not reversible.
    if not _writable_memory(den_dir, mem, "remove") or not _checkpointed(den_dir):
        return 1
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
    # restore is the command whose whole promise is that the state it replaces
    # stays recoverable, so both preconditions and the checkpoint must hold.
    if not _writable_memory(den_dir, mem) or not _checkpointed(den_dir):
        return 1
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
