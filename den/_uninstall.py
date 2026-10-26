"""den uninstall - reverse den install, statelessly.

Re-derives what `den install` would deploy (from the bundled content) and, for
each target file, removes it ONLY if it is byte-identical to den's version,
checked again right before the delete; a file the user changed (before the
prompt or while it was open) is kept and reported (package-manager semantics).
The rc-file `# ===== den =====` block is stripped, and dirs den created that
become empty are pruned. With no component (in a terminal) it asks per
component, mirroring `den install`.

  den uninstall [skills|shell] [--yes] [--dry-run]
  den uninstall skills [--tool T]... [--all-tools] [--target DIR]... [--with-parent]
"""

from __future__ import annotations

import shutil
import stat
import sys
from pathlib import Path

from . import _ui

_ERR = "den uninstall"


def _read_file(path: Path) -> bytes | None:
    """The bytes of the regular file at `path`; None when there is none there
    (absent, a dangling link, a directory). OSError when den cannot tell or
    cannot read it (a permission error, a directory it may not search): the
    file may well be den's, so the caller reports it instead of passing it
    over as absent."""
    try:
        if not stat.S_ISREG(path.stat().st_mode):
            return None
        return path.read_bytes()
    except (FileNotFoundError, NotADirectoryError):
        return None


def _has_block(rc: Path, line: str) -> bool:
    """Whether `rc` holds den's block. False when there is no regular file
    there, or one that does not decode; OSError when one is there but cannot
    be read (see _read_file)."""
    from ._shell import _COMMENT, _decode_rc

    raw = _read_file(rc)
    if raw is None:
        return False
    try:
        # In the file's own encoding (a UTF-16 PowerShell profile gets den's
        # block in UTF-16, see _shell._wire); UTF-8 is lossless, and
        # `errors="ignore"` would DROP every byte that is not valid UTF-8.
        text, _codec = _decode_rc(raw)
    except UnicodeDecodeError:
        return False
    # den-managed only when the marker line is immediately followed by den's
    # exact wire line (what _wire writes, and what _strip_block removes). A
    # stray marker in the user's own content is neither reported nor touched.
    lines = text.splitlines()
    return any(
        ln.strip() == _COMMENT and i + 1 < len(lines) and lines[i + 1] == line
        for i, ln in enumerate(lines)
    )


def _strip_block(rc: Path, line: str) -> bool:
    """Remove den's rc block: the `# ===== den =====` marker, the source line
    that follows it, and one preceding blank line (the append form). If nothing
    but den's block was in the file, den created it, so the file goes too,
    unless it is a symlink (the user's own arrangement, a dotfiles repo): its
    target is emptied instead, and the link stays. The new content replaces
    the file through a temporary copy (_shell._replace_bytes), never by
    truncating it. True when a block was removed; False when there was none
    to remove (the file is then not rewritten). OSError when the file cannot
    be read, rewritten or removed: the file is as it was, block included, and
    the caller says so.

    Works on BYTES, keeping each surviving line with its own terminator. The
    previous version set one `crlf` flag if the file contained a single CRLF
    anywhere and then rewrote every ending to match, so a file mixing LF and
    CRLF (a Windows editor touching a POSIX rc file, a merge) came back with
    every LF line converted -- the opposite of the byte-exact promise. Lines den
    did not write are now copied through verbatim, endings and non-UTF-8 bytes
    alike, and no decode happens at all.

    A UTF-16 file (a PowerShell 5.1 profile) is the one exception: it is
    transcoded to UTF-8, stripped the same way, and written back in its own
    encoding behind its own BOM. Strict decoding makes that exact; a file
    that does not decode is left alone (_has_block never reports one).
    """
    from ._shell import _bom_codec, _replace_bytes

    raw = _read_file(rc)
    if raw is None:
        return False  # removed since den looked: no block left in it
    bom, codec = _bom_codec(raw)
    if codec == "utf-8":
        kept, stripped = _strip_lines(raw, line)
    else:
        try:
            text = raw[len(bom) :].decode(codec)
        except UnicodeDecodeError:
            return False
        kept, stripped = _strip_lines(text.encode("utf-8"), line)
        kept = bom + kept.decode("utf-8").encode(codec)
    if not stripped:
        return False
    if kept.removeprefix(bom) or rc.is_symlink():
        _replace_bytes(rc, kept)
    else:  # only den's block was there
        rc.unlink(missing_ok=True)
    return True


def _strip_lines(data: bytes, line: str) -> tuple[bytes, bool]:
    """(data without den's block, whether a block was removed); see _strip_block."""
    from ._shell import _COMMENT

    marker = _COMMENT.encode("utf-8")
    wire = line.encode("utf-8")
    lines = data.splitlines(keepends=True)

    def content(raw: bytes) -> bytes:
        """The line without its terminator (\n, \r\n or a bare \r)."""
        return raw.rstrip(b"\r\n")

    kept: list[bytes] = []
    stripped = False
    i = 0
    while i < len(lines):
        # Only den's block: marker immediately followed by den's wire line.
        # A stray marker (or a user-edited wire line) is left untouched.
        if (
            content(lines[i]).strip() == marker
            and i + 1 < len(lines)
            and content(lines[i + 1]) == wire
        ):
            if kept and content(kept[-1]) == b"":
                kept.pop()  # the blank line the append form inserted
            stripped = True
            i += 2
            continue
        kept.append(lines[i])
        i += 1
    return b"".join(kept), stripped


class _Remover:
    """Collects the same (dest, content) stages a _Writer would, but on commit
    deletes only the files byte-identical to den's version and keeps the ones
    the user changed. Also strips rc blocks and prunes emptied dirs. The bytes
    are compared when the plan is listed and again right before each delete,
    so a file saved again while the prompt was open is kept.

    A root passed to confine() is a workspace den does not control (--target,
    typically a cloned repo), as for _Writer: a path below it that reaches a
    symlink - a symlinked skills/, a CLAUDE.md linked elsewhere, a dangling
    link - is refused, never removed through, and the symlink is named once
    on stderr, however many of den's paths lie below it and whether or not
    anything is behind it. The default tool dirs are not confined, as for
    _Writer.

    commit returns 1 when part of the plan did not happen without the user
    choosing so: a path refused, a file kept because it changed after den
    checked it, or a file or rc file den failed to read, remove or rewrite
    (each named on stderr and left out of the closing count)."""

    def __init__(self) -> None:
        self._files: list[tuple[Path, bytes]] = []
        self._unwire: list[tuple[Path, str]] = []
        self._boundaries: set[Path] = set()
        self._roots: list[Path] = []

    # same signature as _Writer.stage so install's staging code can drive us
    def stage(self, dest: Path, content: bytes) -> None:
        self._files.append((Path(dest), content))

    def confine(self, root: Path) -> None:
        """Refuse every staged path below `root` that reaches a symlink."""
        self._roots.append(root)

    def unwire(self, rc: Path, line: str) -> None:
        self._unwire.append((Path(rc), line))

    def boundary(self, *dirs: Path) -> None:
        # dirs den did NOT create; pruning stops at (and never removes) them.
        for d in dirs:
            self._boundaries.add(Path(d))

    def _candidates(self) -> dict[Path, list[bytes]]:
        """Every content staged for each dest, dests in staging order.

        A dest can be staged more than once, because `den install` can write
        more than one content there (the --no-den-cli SKILL.md variants, the
        frontier/weak parents). A file is den's when its bytes match ANY of
        them -- first-wins would report den's own output as a file the user
        changed."""
        candidates: dict[Path, list[bytes]] = {}
        for dest, content in self._files:
            candidates.setdefault(dest, []).append(content)
        return candidates

    def _refused(self, dest: Path, named: set[Path]) -> bool:
        """Whether `dest` lies below a confined root and reaches a symlink
        there. The symlink is named on stderr the first time (and added to
        `named`); every other path below it is refused without another line.
        OSError when a component cannot be inspected."""
        from ._install import _confined
        from ._memory import _symlink_component

        guard = _confined(self._roots, dest)
        if guard is None:
            return False
        bad = _symlink_component(*guard)
        if bad is None:
            return False
        if bad not in named:
            named.add(bad)
            what = bad if bad == guard[1] else f"anything below {bad}"
            print(
                f"{_ERR}: refusing to remove {what}: it is a symlink", file=sys.stderr
            )
        return True

    def _plan(
        self,
    ) -> tuple[list[Path], list[Path], list[tuple[Path, str]], int, int]:
        """(files to delete, files to keep, rc files to unwire, the number of
        symlinks refused under a confined root, the number of files and rc
        files den could not read). Each refusal and each read error is named
        on stderr: a file den cannot inspect may well be den's, or hold its
        block, so it is not passed over as absent."""
        delete: list[Path] = []
        keep: list[Path] = []
        named: set[Path] = set()
        unreadable = 0
        candidates = self._candidates()
        for dest in candidates:
            try:
                if self._refused(dest, named):
                    continue  # left alone, never removed through the link
                on_disk = _read_file(dest)
            except OSError as e:
                print(f"{_ERR}: cannot read {dest}: {e}", file=sys.stderr)
                unreadable += 1
                continue
            if on_disk is None:
                continue
            same = any(on_disk == c for c in candidates[dest])
            (delete if same else keep).append(dest)
        unwire: list[tuple[Path, str]] = []
        for rc, line in self._unwire:
            try:
                if _has_block(rc, line):
                    unwire.append((rc, line))
            except OSError as e:
                print(f"{_ERR}: cannot read {rc}: {e}", file=sys.stderr)
                unreadable += 1
        return delete, keep, unwire, len(named), unreadable

    @staticmethod
    def _show(
        delete: list[Path],
        keep: list[Path],
        unwire: list[tuple[Path, str]],
        refused: int,
        unreadable: int,
    ) -> bool:
        """Print the plan; False when there is nothing to remove."""
        if refused:
            print(
                f"  refused {refused} path(s) listed above; nothing was removed there",
                file=sys.stderr,
            )
        if unreadable:
            print(
                f"  could not read {unreadable} file(s) listed above;"
                " they are left as they are",
                file=sys.stderr,
            )
        if keep:
            _ui.say("Keeping files you changed (no longer den's):", style="yellow")
            for d in keep:
                _ui.say(f"  {d}", style="yellow")
        if not delete and not unwire:
            _ui.say(
                "Nothing else to remove."
                if keep or refused or unreadable
                else "Nothing to remove."
            )
            return False
        _ui.say("To be removed:")
        for d in delete:
            _ui.say(f"  rm {d}")
        for rc, _line in unwire:
            _ui.say(f"  unwire {rc}")
        return True

    def _remove(self, delete: list[Path]) -> tuple[list[Path], int, int]:
        """Delete the planned files: (the files removed, the number kept
        because they changed after den checked them, the number den failed
        to read or remove, each named on stderr). Each one is checked again
        right before it goes, so what decides the delete is what the file
        holds now, not what it held when the plan was listed: an edit saved
        while the prompt was open is kept, and a path below a confined root
        that reaches a symlink by now is refused."""
        candidates = self._candidates()
        removed: list[Path] = []
        late = failed = 0
        named: set[Path] = set()
        for d in delete:
            try:
                if self._refused(d, named):
                    late += 1
                    continue
                data = _read_file(d)
            except OSError as e:
                print(f"  warning: {d}: {e}", file=sys.stderr)
                failed += 1
                continue
            if data is None:
                continue  # gone since the plan was listed: nothing to remove
            if not any(data == c for c in candidates[d]):
                late += 1
                print(f"  kept {d}: it changed after den checked it", file=sys.stderr)
                continue
            try:
                d.unlink()
            except OSError as e:
                print(f"  warning: {d}: {e}", file=sys.stderr)
                failed += 1
                continue
            removed.append(d)
        return removed, late, failed

    @staticmethod
    def _unwire_all(unwire: list[tuple[Path, str]]) -> tuple[int, int]:
        """Strip den's block from each rc file: (the number unwired, the
        number den failed to read, rewrite or remove, each named on stderr)."""
        unwired = failed = 0
        for rc, line in unwire:
            try:
                if _strip_block(rc, line):
                    unwired += 1
            except OSError as e:
                print(f"  warning: {rc}: {e}", file=sys.stderr)
                failed += 1
        return unwired, failed

    def commit(self, *, assume_yes: bool, dry_run: bool) -> int:
        """Delete what _plan found, after one confirmation. 1 when part of the
        plan did not happen (see the class docstring) or a non-interactive
        run lacks --yes, else 0."""
        delete, keep, unwire, refused, unreadable = self._plan()
        status = 1 if refused or unreadable else 0
        if not self._show(delete, keep, unwire, refused, unreadable):
            return status
        if dry_run:
            _ui.say("(dry-run; nothing changed)")
            return status
        if not assume_yes:
            if not sys.stdin.isatty():
                print(
                    "den uninstall: refusing to delete without --yes (non-interactive)",
                    file=sys.stderr,
                )
                return 1
            if not _ui.confirm("Remove them?", default=False):
                _ui.say("aborted; nothing removed.")
                return status
        removed, late, failed = self._remove(delete)
        unwired, unwire_failed = self._unwire_all(unwire)
        self._prune(removed)
        _ui.say(f"removed {len(removed)} file(s); unwired {unwired} rc file(s).")
        not_done = [f"{failed} file(s) not removed"] if failed else []
        if unwire_failed:
            not_done.append(f"{unwire_failed} rc file(s) not unwired")
        if not_done:
            print(f"  {', '.join(not_done)}; see the warnings above", file=sys.stderr)
        return 1 if status or late or failed or unwire_failed else 0

    @staticmethod
    def _drop_pycache(cur: Path) -> None:
        """Remove `cur/__pycache__` when it is all that is left of `cur`.

        The skills tell the model to run den's deployed shared/scripts/*.py by
        absolute path, and those import `_common`, so CPython writes a
        `__pycache__/` next to them. It is residue of den's own files, never
        staged and never the user's, but it would block the prune and leave a
        gutted skill directory behind. Only compiled bytecode is dropped."""
        try:
            rest = list(cur.iterdir())
            if len(rest) != 1 or rest[0].name != "__pycache__" or not rest[0].is_dir():
                return
            if any(p.suffix != ".pyc" or not p.is_file() for p in rest[0].iterdir()):
                return  # something other than bytecode lives there; leave it
        except OSError:
            return
        shutil.rmtree(rest[0], ignore_errors=True)

    def _prune(self, deleted: list[Path]) -> None:
        home = Path.home()
        # deepest first, so a dir is only checked after its children were emptied
        for f in sorted(deleted, key=lambda p: len(p.parts), reverse=True):
            cur = f.parent
            while cur not in self._boundaries and cur not in {home, cur.parent}:
                self._drop_pycache(cur)
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


def _den_free_skills() -> set[str]:
    """Skills whose `--no-den-cli` copy differs from the den-aware one: exactly
    the keys of the substitution table (a skill with no entry is copied
    unchanged). Uninstall stages the second variant only for these, so it
    recognizes either flavor without materializing every skill twice. A missing
    or broken table costs the extra candidate, never the uninstall itself."""
    try:
        from ._portable import table

        return set(table())
    except (OSError, ValueError):
        return set()


def _stage_skills(
    remover: _Remover,
    tools: list[str],
    targets: list[str],
    *,
    with_parent: bool,
) -> None:
    from ._install import (
        _TOOLS,
        _install_skill,
        _parent_source,
        _skill_names,
        _tool_paths,
    )

    names = _skill_names()
    den_free = _den_free_skills()

    def stage_parent(dest: Path) -> None:
        """Stage both contents `den install` may have written to the parent
        file `dest`, the frontier and the weak profile: _plan removes it when
        it matches either, and keeps and reports it otherwise. dest itself
        is not read here. _plan reads it after the symlink rule, and names a
        file it cannot read."""
        for profile in ("frontier", "weak"):
            src = _parent_source(dest.name, profile)
            if src.is_file():
                remover.stage(dest, src.read_bytes())

    def do(skills_target: Path, parent_dir: Path, parent_file: str | None) -> None:
        for name in names:
            # `den install skills` writes either the den-aware skill or the
            # --no-den-cli one, and nothing on disk records which. Stage both
            # so either is recognized as den's own output; _plan accepts a dest
            # whose bytes match any staged candidate.
            _install_skill(name, skills_target, remover)
            if name in den_free:
                _install_skill(name, skills_target, remover, no_den_cli=True)
        remover.boundary(parent_dir)
        if with_parent and parent_file:
            stage_parent(parent_dir / parent_file)

    if not tools and not targets:
        sk, pd, pf = _TOOLS["claude"]
        do(Path(sk).expanduser(), Path(pd).expanduser(), pf)
        do(
            Path("~/.agents/skills").expanduser(),
            Path("~/.agents").expanduser(),
            "AGENTS.md",
        )
        # Legacy sweep: den used to deploy gemini skills to ~/.gemini/skills;
        # gemini-cli is EOL upstream and its successor (Antigravity) reads
        # ~/.agents/skills, so stage the old copies for removal too. Only
        # den-identical files are ever deleted, so user edits survive.
        legacy = Path("~/.gemini/skills").expanduser()
        if legacy.is_dir():
            for name in names:
                _install_skill(name, legacy, remover)
                if name in den_free:
                    _install_skill(name, legacy, remover, no_den_cli=True)
            remover.boundary(legacy.parent)
        return
    for tool in tools:
        do(*_tool_paths(tool))
    for t in targets:
        root = Path(t).expanduser()
        # a workspace den does not control, as `den install --target` treats
        # it: nothing below it is removed through a symlink
        remover.confine(root)
        do(root / "skills", root, "AGENTS.md")
        if with_parent:
            stage_parent(root / "CLAUDE.md")


def _parse_skills(
    argv: list[str],
) -> tuple[list[str], list[str], bool, bool, bool] | None:
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
    _stage_skills(remover, tools, targets, with_parent=with_parent)
    return remover.commit(assume_yes=assume_yes, dry_run=dry_run)


def _uninstall_shell(argv: list[str]) -> int:
    assume_yes = "--yes" in argv
    dry_run = "--dry-run" in argv
    for a in argv:
        if a not in {"--yes", "--dry-run"}:
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
    _posix_dir, pwsh_dir = _stage_shell_files(
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
    return remover.commit(assume_yes=assume_yes, dry_run=dry_run)


def _uninstall_cheatsheets(argv: list[str]) -> int:
    assume_yes = "--yes" in argv
    dry_run = "--dry-run" in argv
    for a in argv:
        if a not in {"--yes", "--dry-run"}:
            print(f"den uninstall cheatsheets: unexpected arg '{a}'", file=sys.stderr)
            return 2

    from ._content import cheatsheets_dir
    from ._install import _cheatsheets_target

    src = cheatsheets_dir()
    if not src.is_dir():
        # Mirror `den install cheatsheets`: without the bundle we cannot derive
        # what to remove, so say so instead of reporting a misleading success.
        print("den uninstall cheatsheets: no cheatsheets are bundled", file=sys.stderr)
        return 1
    dest_root = _cheatsheets_target()
    remover = _Remover()
    for f in sorted(src.rglob("*")):
        if f.is_file() and "__pycache__" not in f.parts and f.suffix != ".pyc":
            remover.stage(dest_root / f.relative_to(src), f.read_bytes())
    # den owns den/cheatsheets/ (and its den/ parent); stop pruning at the XDG
    # data root, which is the user's.
    remover.boundary(dest_root.parent.parent)
    return remover.commit(assume_yes=assume_yes, dry_run=dry_run)


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
        # Mirror `den install`, which deploys the parent by default; only a
        # den-identical parent is removed, so an edited one is kept.
        if _ui.confirm(
            "Remove the parent prompt (AGENTS.md/CLAUDE.md) too?", default=True
        ):
            flags.append("--with-parent")
        rc |= _uninstall_skills(flags)
    else:
        _ui.say("  (no tools selected)")
    # Mirror `den install`, which offers cheatsheets here. Called unconditionally
    # like _uninstall_shell above: commit() supplies the per-component confirm and
    # prints "Nothing to remove." when the user never installed them.
    _ui.say("\n# offline cheatsheets")
    rc |= _uninstall_cheatsheets([])
    _ui.say(
        "\nHooks are per-workspace: run 'den uninstall hook' inside a project to "
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
        "  hook   [--tool T]... [--all-tools] [--config PATH]\n"
        "  cheatsheets\n"
        "\n"
        "Common (skills/shell/cheatsheets): [--yes] skip the confirm, "
        "[--dry-run] show the plan only.\n"
        "\n"
        "Only files identical to den's version are removed; files you changed are\n"
        "kept. The rc-file '# ===== den =====' block is stripped. Hooks are\n"
        "per-workspace: 'den uninstall hook' unregisters them in the current one."
    )


def main(argv: list[str] | None = None) -> int:  # ruff: ignore[too-many-return-statements]  # target dispatch
    args = argv if argv is not None else sys.argv[1:]
    if args and args[0] in {"-h", "--help", "help"}:
        _usage()
        return 0
    if not args:
        if sys.stdin.isatty():
            return _interactive()
        _usage()
        return 0
    target, rest = args[0], args[1:]
    # Leaf-level help: `den uninstall skills --help` etc. should print usage, not
    # error. hook owns its own arg handling in _hook, so it is excluded here.
    if target in {"skills", "shell", "cheatsheets"} and any(
        a in {"-h", "--help", "help"} for a in rest
    ):
        _usage()
        return 0
    if target == "skills":
        return _uninstall_skills(rest)
    if target == "shell":
        return _uninstall_shell(rest)
    if target == "hook":
        from ._hook import _cmd_remove

        return _cmd_remove(rest)
    if target == "cheatsheets":
        return _uninstall_cheatsheets(rest)
    print(
        f"den uninstall: unknown target '{target}' "
        "(try: skills, shell, hook, cheatsheets)",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
