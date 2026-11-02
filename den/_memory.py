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

import contextlib
import re
import sys
from datetime import UTC, datetime
from pathlib import Path

from ._fsafe import (
    _UNREADABLE,
    _find_den_dir,
    _read_guarded,
    _refuse_symlink,
    _symlink_component,
    _Unreadable,
    _write_guarded,
)

HISTORY_LIMIT = 20

_MEMORY_NAME = "memory.md"
_HISTORY_DIRNAME = "history"
_SNAP_PREFIX = "memory."
_SNAP_SUFFIX = ".md"
_STAMP_FORMAT = "%Y%m%dT%H%M%S%f"
# Exactly what _do_checkpoint names a snapshot: the UTC stamp, plus a _NNN
# counter when two land on the same microsecond.
_SNAP_NAME = re.compile(r"memory\.(\d{8}T\d{12})(?:_\d{3,})?\.md")


def _memory_path(den_dir: Path) -> Path:
    return den_dir / _MEMORY_NAME


_ERR = "den hook memory"


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


_CLINERULES_DIRNAME = ".clinerules"
_CLINERULES_IMPRINT = "den-imprint.md"  # also the cline-cli "installed here" marker
_CLINERULES_MEMORY = "den-memory.md"
_CLINERULES_HEADER = (
    "<!-- den-managed mirror of .den/memory.md. Edit memory with `den hook memory`, "
    "not here; after editing .den/memory.md directly, run "
    "`den hook memory checkpoint` to refresh this copy. -->\n\n"
)


def _clinerules_dir(den_dir: Path) -> Path:
    return den_dir.parent / _CLINERULES_DIRNAME


def _holds(path: Path, data: bytes) -> bool:
    """True when `path` is a regular file holding exactly `data`."""
    try:
        return path.is_file() and path.read_bytes() == data
    except OSError:
        return False


def mirror_to_clinerules(den_dir: Path) -> bool:
    """Mirror memory.md into the sibling `.clinerules/` dir as `den-memory.md`, but
    only when `den hook install --tool cline-cli` has run here (detected by its
    `den-imprint.md` rule file). cline loads `.clinerules/*.md` as always-on rules
    at session start; the cline CLI cannot inject memory via hooks, so this rule
    file is its memory-delivery channel. Gating on the cline-cli marker (not just
    the dir) is deliberate: the cline EXTENSION creates `.clinerules/hooks/` too,
    and it already injects memory per turn via its hook, so mirroring there as well
    would double-deliver. No-op otherwise, and a copy that is already current is
    not rewritten (checkpoint and every `den hook run` call this). Returns True
    if it wrote/removed the mirror."""
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
    if _refuse_symlink(rules, dest, "write", _ERR):
        return False
    text = _read_guarded_text(den_dir, _memory_path(den_dir))
    if isinstance(text, _Unreadable):
        return False  # do not mirror, and do not drop the mirror we cannot verify
    text = text or ""
    if text.strip():
        data = (_CLINERULES_HEADER + text).encode("utf-8")
        return not _holds(dest, data) and _write_guarded(rules, dest, data, _ERR)
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


def _is_snapshot_name(name: str, now: datetime) -> bool:
    """True for a name den's checkpoint could have written: the exact stamp
    format, a stamp that parses, and not later than now. A cloned repo ships
    `.den/history/` too, and a name that merely starts with `memory.` -- say
    `memory.zzz.md` -- sorted ahead of every real snapshot for good: `restore`
    (newest first, the documented recovery) brought its text into memory.md,
    and checkpoint deduplicated against it, writing a copy every hook event
    until rotation had deleted the real history. A future stamp would do the
    same until that date."""
    match = _SNAP_NAME.fullmatch(name)
    if match is None:
        return False
    try:
        stamp = datetime.strptime(match.group(1), _STAMP_FORMAT).replace(tzinfo=UTC)
    except ValueError:
        return False
    return stamp <= now


def _snapshots(den_dir: Path) -> list[Path]:
    """History snapshots, newest first (fixed-width timestamps sort by time).

    Only regular files with den's own snapshot name count (_is_snapshot_name).
    A symlink would leak an outside file into memory (log/diff/restore all read
    the list) and restoring it would write memory back through it; a DIRECTORY
    named `memory.*.md` -- equally shippable in a repo -- passed the name test
    and then crashed checkpoint/restore/diff on read_bytes(). Anything else in
    history/ is never read, rotated or deleted. Dropped silently rather than
    reported, because checkpoint walks this list every turn and one line per
    turn is noise; install names them once (_foreign_history).
    """
    hist = _history_dir(den_dir)
    if _symlink_component(den_dir, hist) is not None or not hist.is_dir():
        return []
    now = datetime.now(UTC)
    snaps = [
        p
        for p in hist.iterdir()
        if _is_snapshot_name(p.name, now) and not p.is_symlink() and p.is_file()
    ]
    return sorted(snaps, key=lambda p: p.name, reverse=True)


def _foreign_history(den_dir: Path) -> list[str]:
    """Names in history/ that are not snapshots den would use, sorted."""
    hist = _history_dir(den_dir)
    if _symlink_component(den_dir, hist) is not None or not hist.is_dir():
        return []
    ours = {p.name for p in _snapshots(den_dir)}
    return sorted(p.name for p in hist.iterdir() if p.name not in ours)


def _snap_stamp(snap: Path) -> str:
    return snap.name[len(_SNAP_PREFIX) : -len(_SNAP_SUFFIX)]


def _fmt_stamp(stamp: str) -> str:
    try:
        dt = datetime.strptime(stamp, _STAMP_FORMAT).replace(tzinfo=UTC)
    except ValueError:
        return stamp
    return dt.strftime("%Y-%m-%d %H:%M:%S UTC")


_NOT_TEXT = "(not UTF-8 text)"


def _first_line(path: Path) -> str:
    """First non-blank line of a snapshot, truncated, for the `log` listing.

    A snapshot can hold bytes that are not UTF-8: save/clear/restore checkpoint
    memory.md as BYTES on purpose, so undecodable content is preserved intact.
    `log` has to list such a snapshot -- with a placeholder, since there is no
    line to show -- rather than raise on the way past it.
    """
    try:
        data = path.read_bytes()
    except OSError:
        return ""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return _NOT_TEXT
    for line in text.splitlines():
        stripped = line.strip()
        if stripped:
            return stripped[:60]
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
    if _refuse_symlink(den_dir, hist, "write", _ERR):
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
    current = _read_guarded(den_dir, _memory_path(den_dir), _ERR)
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
        if not _write_guarded(den_dir, dest, current, _ERR):
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
    if _refuse_symlink(den_dir, mem, action, _ERR):
        return False
    return not isinstance(_read_guarded(den_dir, mem, _ERR), _Unreadable)


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


def utf8_stdout() -> None:
    """Write stdout as UTF-8, whatever the locale. Memory and the imprint are
    UTF-8 and so is what reads den's output; a Windows den whose stdout is
    redirected (an agent running it) got the ANSI code page instead, with
    strict errors, so an em dash or an emoji in memory -- or the seeded
    imprint's own Japanese -- crashed `show` and `den hook imprint`."""
    reconfigure = getattr(sys.stdout, "reconfigure", None)
    if callable(reconfigure):
        # a stream that cannot switch keeps its own encoding
        with contextlib.suppress(OSError, ValueError):
            reconfigure(encoding="utf-8")


def _read_stdin(prefix: str) -> str | None:
    """stdin as UTF-8 text (a leading BOM dropped), whatever the locale; None
    (one line on stderr) when it is not UTF-8. The locale codec turned piped
    UTF-8 into mojibake on cp1252 -- written to memory.md and injected every
    turn -- and raised on cp932."""
    stream = sys.stdin
    if stream is None:
        return ""
    buffer = getattr(stream, "buffer", None)
    if buffer is None:  # already text (an embedding host, a test's StringIO)
        return stream.read()
    try:
        return buffer.read().decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        print(
            f"{prefix}: stdin is not UTF-8 text ({exc}); nothing written",
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
    # Also the refresh for cline-cli's copy after a direct edit to memory.md,
    # even when another hook already snapshotted that edit.
    mirror_to_clinerules(den_dir)
    if isinstance(snap, _Refused):
        return 1  # asked for a checkpoint, could not make one
    if snap is not None:
        print(f"checkpointed: {snap}", file=sys.stderr)
    return 0


def _save_content(argv: list[str]) -> str | int:
    """The text `save` will write: stdin, or the file named by --file. An int is
    the exit code to return instead (the message is already out)."""
    if not (argv and argv[0] in {"--file", "-f"}):
        text = _read_stdin("den hook memory save")
        return 2 if text is None else text
    if len(argv) < 2:
        print("den hook memory save: --file needs a path", file=sys.stderr)
        return 2
    try:
        # utf-8-sig: a leading BOM is dropped, as for stdin (_read_stdin)
        return Path(argv[1]).read_text(encoding="utf-8-sig")
    except OSError as exc:
        print(f"den hook memory save: cannot read {argv[1]}: {exc}", file=sys.stderr)
        return 2
    except UnicodeDecodeError as exc:
        print(
            f"den hook memory save: {argv[1]} is not UTF-8 text ({exc})",
            file=sys.stderr,
        )
        return 2


def _cmd_save(den_dir: Path, argv: list[str]) -> int:
    content = _save_content(argv)
    if isinstance(content, int):
        return content
    mem = _memory_path(den_dir)
    if not _writable_memory(den_dir, mem) or not _checkpointed(den_dir):
        return 1
    if not _write_guarded(den_dir, mem, content.encode("utf-8"), _ERR):
        return 1
    mirror_to_clinerules(den_dir)
    return 0


def _cmd_add(den_dir: Path, argv: list[str]) -> int:
    """Append one fact to memory.md (from args, or stdin if none). Low-friction
    counterpart to save's wholesale overwrite: a weak agent records a single
    line without rewriting the whole file. Snapshots the prior content first."""
    content = " ".join(argv) if argv else _read_stdin("den hook memory add")
    if content is not None and not content.strip():
        print(
            "den hook memory add: nothing to add (give text or pipe it on stdin)",
            file=sys.stderr,
        )
    if content is None or not content.strip():
        return 2  # (an undecodable stdin already said why)
    mem = _memory_path(den_dir)
    if _refuse_symlink(den_dir, mem, "write", _ERR):
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
    if not _write_guarded(den_dir, mem, (existing + addition).encode("utf-8"), _ERR):
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
    if not _write_guarded(den_dir, mem, data, _ERR):
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
    # Guarded, like every other read: a snapshot may hold non-UTF-8 bytes (see
    # _first_line), and a strict decode raised straight out of `diff`.
    old_text = _read_guarded_text(den_dir, old)
    if not isinstance(old_text, str):
        return 1  # unreadable or undecodable snapshot; the read said why
    old_lines = old_text.splitlines(keepends=True)
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

    utf8_stdout()
    den_dir = _find_den_dir(Path.cwd())
    return handler(den_dir, rest)


if __name__ == "__main__":
    raise SystemExit(main())
