"""den memory - workspace-level session memory the agent reads and overwrites.

Memory lives at <project>/.den/memory.md, a single Markdown file the agent
owns: it reads the whole file and rewrites it wholesale. The agent may edit
memory.md directly with its own file tools (not only via `den memory save`),
so this module never relies on save being called. Instead a cheap
content-hash `checkpoint` copies memory.md into .den/history/ whenever the
content changes since the last snapshot. Hooks drive `checkpoint` every turn
(and optionally after each write), so direct edits are captured and any bad
overwrite can be recovered with `log` / `restore` / `diff`.

Subcommands:
  show              print memory.md (empty if absent)
  checkpoint        snapshot memory.md into history if it changed
  save [--file F]   overwrite memory.md from stdin or F (snapshots first)
  clear             delete memory.md (snapshots it first)
  log               list history snapshots, newest first
  restore [n]       restore the n-th newest snapshot (default 1)
  diff [n]          diff memory.md against the n-th newest snapshot (default 1)
  path              print the resolved memory.md path
"""

from __future__ import annotations

import difflib
import sys
from datetime import datetime, timezone
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


def _history_dir(den_dir: Path) -> Path:
    return den_dir / _HISTORY_DIRNAME


def _snapshots(den_dir: Path) -> list[Path]:
    """History snapshots, newest first (fixed-width timestamps sort by time)."""
    hist = _history_dir(den_dir)
    if not hist.is_dir():
        return []
    snaps = [
        p
        for p in hist.iterdir()
        if p.name.startswith(_SNAP_PREFIX) and p.name.endswith(_SNAP_SUFFIX)
    ]
    return sorted(snaps, key=lambda p: p.name, reverse=True)


def _snap_stamp(snap: Path) -> str:
    return snap.name[len(_SNAP_PREFIX) : -len(_SNAP_SUFFIX)]


def _fmt_stamp(stamp: str) -> str:
    try:
        dt = datetime.strptime(stamp, _STAMP_FORMAT).replace(tzinfo=timezone.utc)
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
    mem = _memory_path(den_dir)
    if not mem.is_file():
        return None
    current = mem.read_bytes()
    snaps = _snapshots(den_dir)
    if snaps and snaps[0].read_bytes() == current:
        return None
    hist = _history_dir(den_dir)
    hist.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime(_STAMP_FORMAT)
    dest = hist / f"{_SNAP_PREFIX}{stamp}{_SNAP_SUFFIX}"
    n = 1
    while dest.exists():  # never clobber a same-timestamp snapshot
        dest = hist / f"{_SNAP_PREFIX}{stamp}_{n:03d}{_SNAP_SUFFIX}"
        n += 1
    dest.write_bytes(current)
    _rotate(den_dir)
    return dest


def _parse_index(argv: list[str]) -> int | None:
    if not argv:
        return 1
    try:
        return int(argv[0])
    except ValueError:
        print(f"den memory: expected a numeric index, got {argv[0]!r}", file=sys.stderr)
        return None


def _cmd_show(den_dir: Path, argv: list[str]) -> int:
    mem = _memory_path(den_dir)
    if mem.is_file():
        sys.stdout.write(mem.read_text(encoding="utf-8"))
    return 0


def _cmd_checkpoint(den_dir: Path, argv: list[str]) -> int:
    snap = _do_checkpoint(den_dir)
    if snap is not None:
        print(f"checkpointed: {snap}", file=sys.stderr)
    return 0


def _cmd_save(den_dir: Path, argv: list[str]) -> int:
    if argv and argv[0] in ("--file", "-f"):
        if len(argv) < 2:
            print("den memory save: --file needs a path", file=sys.stderr)
            return 2
        content = Path(argv[1]).read_text(encoding="utf-8")
    else:
        content = sys.stdin.read()
    _do_checkpoint(den_dir)
    mem = _memory_path(den_dir)
    mem.parent.mkdir(parents=True, exist_ok=True)
    mem.write_text(content, encoding="utf-8")
    return 0


def _cmd_clear(den_dir: Path, argv: list[str]) -> int:
    _do_checkpoint(den_dir)
    mem = _memory_path(den_dir)
    if mem.is_file():
        mem.unlink()
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
            f"den memory restore: no snapshot #{n} (have {len(snaps)})",
            file=sys.stderr,
        )
        return 1
    target = snaps[n - 1]
    data = target.read_bytes()
    stamp = _snap_stamp(target)
    _do_checkpoint(den_dir)  # make the restore itself reversible
    mem = _memory_path(den_dir)
    mem.parent.mkdir(parents=True, exist_ok=True)
    mem.write_bytes(data)
    print(f"restored #{n} ({_fmt_stamp(stamp)}) -> {mem}", file=sys.stderr)
    return 0


def _cmd_diff(den_dir: Path, argv: list[str]) -> int:
    n = _parse_index(argv)
    if n is None:
        return 2
    snaps = _snapshots(den_dir)
    if n < 1 or n > len(snaps):
        print(
            f"den memory diff: no snapshot #{n} (have {len(snaps)})",
            file=sys.stderr,
        )
        return 1
    old = snaps[n - 1]
    mem = _memory_path(den_dir)
    old_lines = old.read_text(encoding="utf-8").splitlines(keepends=True)
    new_lines = (
        mem.read_text(encoding="utf-8").splitlines(keepends=True)
        if mem.is_file()
        else []
    )
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
    "clear": _cmd_clear,
    "log": _cmd_log,
    "restore": _cmd_restore,
    "diff": _cmd_diff,
    "path": _cmd_path,
}


def _usage() -> None:
    print(
        "usage: den memory <subcommand> [args]\n"
        "\n"
        "Subcommands:\n"
        "  show              print memory.md (empty if absent)\n"
        "  checkpoint        snapshot memory.md into history if it changed\n"
        "  save [--file F]   overwrite memory.md from stdin or F\n"
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

    if not args or args[0] in ("-h", "--help", "help"):
        _usage()
        return 0

    cmd, rest = args[0], args[1:]
    handler = _HANDLERS.get(cmd)
    if handler is None:
        print(f"den memory: unknown subcommand '{cmd}'", file=sys.stderr)
        _usage()
        return 2

    den_dir = _find_den_dir(Path.cwd())
    return handler(den_dir, rest)


if __name__ == "__main__":
    raise SystemExit(main())
