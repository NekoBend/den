"""den uninstall - reverse den install, statelessly.

Re-derives what `den install` would deploy (from the bundled content) and, for
each target file, removes it ONLY if it is byte-identical to den's version; a
file the user changed is kept and reported (package-manager semantics). The
rc-file `# ===== den =====` block is stripped, and dirs den created that become
empty are pruned. With no component (in a terminal) it asks per component,
mirroring `den install`.

  den uninstall [skills|shell] [--yes] [--dry-run]
  den uninstall skills [--tool T]... [--all-tools] [--target DIR]... [--with-parent]
"""

from __future__ import annotations

import sys
from pathlib import Path

from . import _ui
from ._content import dist_dir


def _has_block(rc: Path, line: str) -> bool:
    from ._shell import _COMMENT

    if not rc.is_file():
        return False
    try:
        text = rc.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return False
    # den-managed only when the marker line is immediately followed by den's
    # exact wire line (what _wire writes, and what _strip_block removes). A
    # stray marker in the user's own content is neither reported nor touched.
    lines = text.splitlines()
    return any(
        ln.strip() == _COMMENT and i + 1 < len(lines) and lines[i + 1] == line
        for i, ln in enumerate(lines)
    )


def _strip_block(rc: Path, line: str) -> None:
    """Remove den's rc block: the `# ===== den =====` marker, the source line
    that follows it, and one preceding blank line (the append form). Preserves
    the file's CRLF/LF line ending. If the file is EXACTLY what den created
    (only the block, nothing else), den owns it, so it is removed."""
    from ._shell import _COMMENT

    text = rc.read_bytes().decode("utf-8", errors="ignore")
    crlf = "\r\n" in text
    norm = text.replace("\r\n", "\n")
    if norm == f"{_COMMENT}\n{line}\n":
        try:
            rc.unlink()
        except OSError:
            pass
        return
    lines = norm.split("\n")
    out: list[str] = []
    i = 0
    while i < len(lines):
        # Only den's block: marker immediately followed by den's wire line.
        # A stray marker (or a user-edited wire line) is left untouched.
        if lines[i].strip() == _COMMENT and i + 1 < len(lines) and lines[i + 1] == line:
            if out and out[-1] == "":
                out.pop()
            i += 2
            continue
        out.append(lines[i])
        i += 1
    new = "\n".join(out)
    if crlf:
        new = new.replace("\n", "\r\n")
    rc.write_text(new, encoding="utf-8", newline="")


class _Remover:
    """Collects the same (dest, content) stages a _Writer would, but on commit
    deletes only the files byte-identical to den's version and keeps the ones
    the user changed. Also strips rc blocks and prunes emptied dirs."""

    def __init__(self) -> None:
        self._files: list[tuple[Path, bytes]] = []
        self._unwire: list[tuple[Path, str]] = []
        self._boundaries: set[Path] = set()

    # same signature as _Writer.stage so install's staging code can drive us
    def stage(self, dest: Path, content: bytes) -> None:
        self._files.append((Path(dest), content))

    def unwire(self, rc: Path, line: str) -> None:
        self._unwire.append((Path(rc), line))

    def boundary(self, *dirs: Path) -> None:
        # dirs den did NOT create; pruning stops at (and never removes) them.
        for d in dirs:
            self._boundaries.add(Path(d))

    def _plan(self):
        delete: list[Path] = []
        keep: list[Path] = []
        seen: set[Path] = set()
        for dest, content in self._files:
            if dest in seen:
                continue
            seen.add(dest)
            if not dest.is_file():
                continue
            try:
                same = dest.read_bytes() == content
            except OSError:
                continue
            (delete if same else keep).append(dest)
        unwire = [(rc, line) for rc, line in self._unwire if _has_block(rc, line)]
        return delete, keep, unwire

    def commit(self, assume_yes: bool, dry_run: bool) -> int:
        delete, keep, unwire = self._plan()
        if keep:
            _ui.say("Keeping files you changed (no longer den's):", style="yellow")
            for d in keep:
                _ui.say(f"  {d}", style="yellow")
        if not delete and not unwire:
            _ui.say("Nothing else to remove." if keep else "Nothing to remove.")
            return 0
        _ui.say("To be removed:")
        for d in delete:
            _ui.say(f"  rm {d}")
        for rc, _line in unwire:
            _ui.say(f"  unwire {rc}")
        if dry_run:
            _ui.say("(dry-run; nothing changed)")
            return 0
        if not assume_yes:
            if not sys.stdin.isatty():
                print(
                    "den uninstall: refusing to delete without --yes (non-interactive)",
                    file=sys.stderr,
                )
                return 1
            if not _ui.confirm("Remove them?", False):
                _ui.say("aborted; nothing removed.")
                return 0
        for d in delete:
            try:
                d.unlink()
            except OSError as e:
                print(f"  warning: {d}: {e}", file=sys.stderr)
        for rc, line in unwire:
            _strip_block(rc, line)
        self._prune(delete)
        _ui.say(f"removed {len(delete)} file(s); unwired {len(unwire)} rc file(s).")
        return 0

    def _prune(self, deleted: list[Path]) -> None:
        home = Path.home()
        # deepest first, so a dir is only checked after its children were emptied
        for f in sorted(deleted, key=lambda p: len(p.parts), reverse=True):
            cur = f.parent
            while cur not in self._boundaries and cur != home and cur != cur.parent:
                try:
                    next(cur.iterdir())
                    break  # not empty
                except StopIteration:
                    pass  # empty -> remove
                except OSError:
                    break
                parent = cur.parent
                try:
                    cur.rmdir()
                except OSError:
                    break
                cur = parent


def _stage_skills(remover: _Remover, tools, targets, with_parent) -> None:
    from ._install import _TOOLS, _install_skill, _skill_names, _tool_paths

    names = _skill_names()

    def do(skills_target: Path, parent_dir: Path, parent_file: str | None) -> None:
        for name in names:
            _install_skill(name, skills_target, remover)
        remover.boundary(parent_dir)
        if with_parent and parent_file:
            src = dist_dir() / (
                "CLAUDE.md" if parent_file == "CLAUDE.md" else "AGENTS.md"
            )
            if src.is_file():
                remover.stage(parent_dir / parent_file, src.read_bytes())

    if not tools and not targets:
        sk, pd, pf = _TOOLS["claude"]
        do(Path(sk).expanduser(), Path(pd).expanduser(), pf)
        do(
            Path("~/.agents/skills").expanduser(),
            Path("~/.agents").expanduser(),
            "AGENTS.md",
        )
        return
    for tool in tools:
        do(*_tool_paths(tool))
    for t in targets:
        root = Path(t).expanduser()
        do(root / "skills", root, "AGENTS.md")
        if with_parent:
            claude = dist_dir() / "CLAUDE.md"
            if claude.is_file():
                remover.stage(root / "CLAUDE.md", claude.read_bytes())


def _parse_skills(argv: list[str]):
    from ._install import _TOOLS

    tools: list[str] = []
    targets: list[str] = []
    with_parent = assume_yes = dry_run = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--tool" and i + 1 < len(argv):
            if argv[i + 1] not in _TOOLS:
                print(f"den uninstall: unknown tool '{argv[i + 1]}'", file=sys.stderr)
                return None
            tools.append(argv[i + 1])
            i += 2
        elif a == "--all-tools":
            tools = list(_TOOLS)
            i += 1
        elif a == "--target" and i + 1 < len(argv):
            targets.append(argv[i + 1])
            i += 2
        elif a == "--with-parent":
            with_parent = True
            i += 1
        elif a == "--yes":
            assume_yes = True
            i += 1
        elif a == "--dry-run":
            dry_run = True
            i += 1
        else:
            print(f"den uninstall skills: unexpected arg '{a}'", file=sys.stderr)
            return None
    return tools, targets, with_parent, assume_yes, dry_run


def _uninstall_skills(argv: list[str]) -> int:
    parsed = _parse_skills(argv)
    if parsed is None:
        return 2
    tools, targets, with_parent, assume_yes, dry_run = parsed
    remover = _Remover()
    _stage_skills(remover, tools, targets, with_parent)
    return remover.commit(assume_yes, dry_run)


def _uninstall_shell(argv: list[str]) -> int:
    assume_yes = "--yes" in argv
    dry_run = "--dry-run" in argv
    for a in argv:
        if a not in ("--yes", "--dry-run"):
            print(f"den uninstall shell: unexpected arg '{a}'", file=sys.stderr)
            return 2

    from ._shell import (
        _BASH_LINE,
        _PWSH_LINE,
        _PWSH_PROFILE,
        _ZSH_LINE,
        _localappdata,
        _stage_shell_files,
        _windows,
    )

    remover = _Remover()
    # extras=True, posix_bin=True: stage every file den could have placed (including
    # the optional shell/posix/bin/* executables in ~/.local/bin); absent ones are
    # skipped.
    posix_dir, pwsh_dir = _stage_shell_files(
        remover, extras=True, dry_run=False, announce=False, posix_bin=True
    )
    home = Path.home()
    # ~/.local/bin is the user's own dir (den only drops its helper executables in),
    # so never prune it even when removing them empties it.
    remover.boundary(home / ".config", pwsh_dir.parent, home / ".local" / "bin")
    if _windows():
        remover.boundary(_localappdata())
    remover.unwire(home / ".bashrc", _BASH_LINE)
    remover.unwire(home / ".zshrc", _ZSH_LINE)
    remover.unwire(pwsh_dir / _PWSH_PROFILE, _PWSH_LINE)
    return remover.commit(assume_yes, dry_run)


def _interactive() -> int:
    from ._install import _TOOLS

    _ui.say(
        "den uninstall -- interactive (nothing is removed without confirmation)",
        style="bold cyan",
    )
    rc = 0
    _ui.say("\n# shell environment")
    rc |= _uninstall_shell([])
    _ui.say("\n# LLM agent skills")
    chosen = _ui.select(
        "Remove skills from which tools? (space to toggle, enter to confirm)",
        [(tool, False) for tool in _TOOLS],
    )
    if chosen:
        flags: list[str] = []
        for tool in chosen:
            flags += ["--tool", tool]
        rc |= _uninstall_skills(flags)
    else:
        _ui.say("  (no tools selected)")
    _ui.say(
        "\nHooks are per-workspace: run 'den hook remove' inside a project to "
        "remove them there."
    )
    return rc


def _usage() -> None:
    print(
        "usage: den uninstall [<target>] [args]\n"
        "\n"
        "With no target (in a terminal), den uninstall asks per component.\n"
        "\n"
        "Targets:\n"
        "  skills [--tool T]... [--all-tools] [--target DIR]... [--with-parent]\n"
        "  shell\n"
        "\n"
        "Common: [--yes] skip the confirm, [--dry-run] show the plan only.\n"
        "\n"
        "Only files identical to den's version are removed; files you changed are\n"
        "kept. The rc-file '# ===== den =====' block is stripped. Hooks are\n"
        "per-workspace: use 'den hook remove'."
    )


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if args and args[0] in ("-h", "--help", "help"):
        _usage()
        return 0
    if not args:
        if sys.stdin.isatty():
            return _interactive()
        _usage()
        return 0
    target, rest = args[0], args[1:]
    if target == "skills":
        return _uninstall_skills(rest)
    if target == "shell":
        return _uninstall_shell(rest)
    print(
        f"den uninstall: unknown target '{target}' (try: skills, shell)",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
