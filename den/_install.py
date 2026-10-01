"""den install - deploy skills (and parent prompts) into agent tool dirs.

Installs each skill as a SELF-CONTAINED unit: the skill's files plus the shared
resources it references (shared/reference/*.md and, if any script is used, the
whole shared/scripts/ set) are copied under <target>/skills/<name>/shared/, and
every shared/... reference is rewritten to an ABSOLUTE path under that skill's
own shared/.

  den install skills [--tool TOOL]... [--all-tools] [--target DIR]...
                     [--with-parent] [--no-den-cli] [--profile weak|frontier]
                     [--dry-run] [--codex-config]

The parent prompt comes in two profiles: frontier (the default; invariants
for models that follow instructions natively and auto-fire skills) and weak
(the skill router, maximal scaffolding). The profile picks WHICH parent
content is deployed; the file name each tool reads stays the tool's own.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Protocol

from . import _ui
from ._content import cheatsheets_dir, dist_dir, shared_dir, skills_dir
from ._exe import find_tool
from ._memory import _refuse_symlink, _write_guarded

# tool -> (skills_dir, parent_dir, parent_file). The cline (VS Code extension)
# parent_dir is dynamic -- see _tool_paths/_cline_rules_dir; the value here is
# only the fallback shape.
_TOOLS: dict[str, tuple[str, str, str]] = {
    "claude": ("~/.claude/skills", "~/.claude", "CLAUDE.md"),
    "codex": ("~/.agents/skills", "~/.codex", "AGENTS.md"),
    "cline": ("~/.agents/skills", "~/Documents/Cline/Rules", "AGENTS.md"),
    "cline-cli": ("~/.agents/skills", "~/.agents", "AGENTS.md"),
    "copilot": ("~/.copilot/skills", "~/.copilot", "copilot-instructions.md"),
    # gemini: RETIRED (2026-07). gemini-cli hit upstream EOL for individual
    # accounts; its successor Antigravity reads ~/.agents/skills + AGENTS.md,
    # which den already deploys for codex/cline. den uninstall sweeps the
    # legacy ~/.gemini/skills copies (see _uninstall._stage_skills).
}


def _windows() -> bool:
    # Indirection so tests can flip platform without touching os.name globally
    # (pathlib reads os.name at instantiation to pick WindowsPath/PosixPath).
    return os.name == "nt"


def _cline_rules_dir() -> Path:
    """The cline VS Code EXTENSION's global always-on rules dir,
    <Documents>/Cline/Rules. The extension does NOT read ~/.agents/AGENTS.md
    (its AGENTS.md support resolves against the workspace cwd only, see
    getLocalAgentsRules in cline's source), so the parent prompt must go where
    getGlobalClineRules reads. Resolve Documents the same way cline's own
    getDocumentsPath does, so den lands exactly where the extension looks:
    Windows asks PowerShell for MyDocuments (OneDrive-redirect aware), Linux
    asks xdg-user-dir, anything else uses ~/Documents. The cline CLI does not
    read this dir (it reads ~/.agents/AGENTS.md), so cline + cline-cli
    together never double-deliver. Every helper runs by absolute path and
    never from the working directory (den._exe)."""
    if _windows():
        for name in ("pwsh", "powershell"):
            exe = find_tool(name, "den")
            if exe is None:
                continue
            try:
                out = subprocess.run(
                    [
                        exe,
                        "-NoProfile",
                        "-Command",
                        "[Environment]::GetFolderPath('MyDocuments')",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
            except (OSError, subprocess.SubprocessError):
                continue
            lines = [ln.strip() for ln in out.stdout.splitlines() if ln.strip()]
            if out.returncode == 0 and lines:
                return Path(lines[-1]) / "Cline" / "Rules"
        return Path.home() / "Documents" / "Cline" / "Rules"
    xdg = find_tool("xdg-user-dir", "den") if sys.platform == "linux" else None
    if xdg is not None:
        try:
            out = subprocess.run(
                [xdg, "DOCUMENTS"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if out.returncode == 0 and out.stdout.strip():
                return Path(out.stdout.strip()) / "Cline" / "Rules"
        except (OSError, subprocess.SubprocessError):
            pass
    return Path.home() / "Documents" / "Cline" / "Rules"


def _tool_paths(tool: str) -> tuple[Path, Path, str]:
    """Resolve a tool's (skills_target, parent_dir, parent_file) to real paths.
    Single source for install AND uninstall, so removal always mirrors what
    install wrote."""
    sk, pd, pf = _TOOLS[tool]
    parent = _cline_rules_dir() if tool == "cline" else Path(pd).expanduser()
    return Path(sk).expanduser(), parent, pf


# Tools whose model varies per session (local/weak models are plausible), so
# the interactive flow asks which parent profile to deploy. claude/codex
# only run frontier-class models and are not asked.
_MIXED_MODEL_TOOLS = {"cline", "cline-cli", "copilot"}


def _parent_source(parent_file: str, profile: str) -> Path:
    """The dist file a parent deploy copies for this profile. The weak profile
    has ONE parent content (the skill router); parent_file only names the file
    the tool reads, never the content."""
    if profile == "weak":
        return dist_dir() / "weak" / "AGENTS.md"
    return dist_dir() / ("CLAUDE.md" if parent_file == "CLAUDE.md" else "AGENTS.md")


_REF_RE = re.compile(r"shared/reference/([A-Za-z0-9_-]+)\.md")
_REWRITE_RE = re.compile(r"(?:\.\./)*shared/(reference|scripts)/")
_EXCLUDE = {"__pycache__", ".pytest_cache", "tests"}


def _ignore(_dir: str, names: list[str]) -> list[str]:
    return [n for n in names if n in _EXCLUDE or n.endswith(".pyc")]


def _skill_names() -> list[str]:
    root = skills_dir()
    return sorted(d.name for d in root.iterdir() if (d / "SKILL.md").is_file())


class _Stager(Protocol):
    """The staging surface _install_skill needs. Both _Writer (install) and
    _uninstall._Remover satisfy it structurally, so skill staging drives either."""

    def stage(self, dest: Path, content: bytes) -> None: ...


def _chmod_no_follow(path: Path, mode: int) -> None:
    """chmod, but never through a symlink.

    chmod FOLLOWS a link, so a symlinked destination would hand its outside
    target the mode -- and every caller reaches here on the byte-identical
    repair path, where den deployed nothing at all. A 0o600 file elsewhere must
    not become world-executable because den decided nothing needed doing. The
    link is the user's own arrangement; den leaves it and its target alone.

    One helper, shared by the staged writes and _shell.py's ~/.local/bin repair,
    so the rule cannot drift between the two.
    """
    if path.is_symlink():
        return
    path.chmod(mode)


_ERR = "den install"


class _Writer:
    """Collect (dest, content) writes, then commit them. New and byte-identical
    files are written silently; files that already exist and DIFFER are listed
    and, unless --force, the user is asked once before overwriting (default no,
    so local edits are kept). Non-interactive: differing files are skipped.
    --force copies each differing file to <file>.den.bak before replacing it.

    With `owned` (`den upgrade --refresh`, see _install_refresh) nothing is
    asked: a differing file in `owned` -- one the den that ran before the
    upgrade proved it had written and nobody has edited since -- is replaced,
    and every other differing file is kept and listed (or, with --force, backed
    up and replaced).

    A root passed to confine() is a workspace den does not control (--target,
    typically a cloned repo), so a symlink anywhere below it - CLAUDE.md ->
    ~/.bashrc, a dangling one included - is refused and reported instead of
    written through, and the write itself does not follow a link (O_NOFOLLOW).
    The default tool dirs are not confined: a ~/.claude symlinked into a
    dotfiles repo is the user's own arrangement and keeps working."""

    def __init__(self, *, force: bool, owned: set[Path] | None = None) -> None:
        self.force = force
        self.owned = owned
        self._items: list[tuple[Path, bytes]] = []
        self._roots: list[Path] = []

    def stage(self, dest: Path, content: bytes) -> None:
        self._items.append((dest, content))

    def confine(self, root: Path) -> None:
        """Refuse every staged path below `root` that reaches a symlink."""
        self._roots.append(root)

    def _confined(self, dest: Path) -> tuple[Path, Path] | None:
        """(resolved root, dest under it) when `dest` lies in a confined root.

        The root is resolved first: a symlink in the root's OWN path is the
        user's choice of where the workspace lives, only links below it are
        the workspace's."""
        for root in self._roots:
            try:
                rel = dest.relative_to(root)
            except ValueError:
                continue
            real = root.resolve()
            return real, real / rel
        return None

    @staticmethod
    def _ensure_mode(dest: Path) -> None:
        """The skills tell the model to run these by absolute path, so the
        deployed copy has to keep the source's executable bit; a plain
        write_bytes lands 0644 and every invocation dies on permission denied.
        Only scripts are marked; content files stay 0644.

        Applied to byte-identical files too, so a deployed script that lost +x
        (a backup restore, a dotfiles sync, a copy made on Windows, a write by
        a den old enough to predate this rule) is repaired by a re-install
        instead of staying broken forever -- the same repair _shell.py makes
        for ~/.local/bin.

        Never through a symlink -- see _chmod_no_follow."""
        if dest.suffix in {".sh", ".py"} and "/scripts/" in dest.as_posix():
            _chmod_no_follow(dest, 0o755)

    def _ask(self, changed: list[Path]) -> tuple[bool, bool]:
        """(overwrite, silently_skipped) for the files that exist and differ."""
        if not changed or self.force:
            return True, False
        if self.owned is not None:
            # A refresh asks nothing: what it may replace was decided before the
            # upgrade. The rest is the user's (or a version whose update was
            # skipped), kept and listed.
            _ui.say(
                "Left alone (edited, or not as den last deployed them; "
                "--force backs each up to <file>.den.bak and replaces it):",
                style="yellow",
            )
            for d in changed:
                _ui.say(f"  {d}", style="yellow")
            return False, False
        _ui.say(
            "These files exist and differ from the bundled version:", style="yellow"
        )
        for d in changed:
            _ui.say(f"  {d}", style="yellow")
        if sys.stdin.isatty():
            return _ui.confirm("Overwrite them?", default=False), False
        print("  skipped (re-run with --force to overwrite)", file=sys.stderr)
        return False, True

    @staticmethod
    def _backup(dest: Path, guard: tuple[Path, Path] | None) -> bool:
        """Copy `dest` to <dest>.den.bak before --force replaces it. False (one
        line on stderr) when no backup could be made; the caller then leaves
        `dest` alone, since replacing what could not be kept is the loss the
        backup exists to prevent. An earlier backup is replaced: the file about
        to be overwritten is the newer state. The copy is a plain 0644 file, so
        a backed-up ~/.local/bin helper is not left executable on PATH."""
        try:
            data = dest.read_bytes()
            if guard is not None:  # a confined root: never through a link below it
                root, real = guard
                return _write_guarded(
                    root, real.with_name(real.name + ".den.bak"), data, _ERR
                )
            bak = dest.with_name(dest.name + ".den.bak")
            if bak.is_symlink() or (bak.exists() and not bak.is_file()):
                print(
                    f"{_ERR}: not replacing {dest}: {bak} is not a regular file",
                    file=sys.stderr,
                )
                return False
            bak.write_bytes(data)
        except OSError as exc:
            print(
                f"{_ERR}: not replacing {dest}: cannot back it up: {exc}",
                file=sys.stderr,
            )
            return False
        return True

    def commit(self) -> int:  # ruff: ignore[too-many-branches]  # one per outcome
        """Write the staged files. Returns the number of files that were NOT
        deployed without the user choosing so: differing files kept by the
        non-interactive skip plus destinations refused under a confined root,
        so a scripted caller can exit non-zero instead of reporting a deploy
        that never happened; an interactive "no" is the user's own choice and
        counts 0, as does a file a refresh leaves alone (not den's to replace)."""
        refused = 0
        items: list[tuple[Path, bytes, tuple[Path, Path] | None]] = []
        for dest, content in self._items:
            guard = self._confined(dest)
            if guard is not None and _refuse_symlink(*guard, "write", _ERR):
                refused += 1
                continue
            items.append((dest, content, guard))
        changed = [d for d, c, _g in items if d.is_file() and d.read_bytes() != c]
        owned = self.owned if self.owned is not None else set()
        overwrite, silently_skipped = self._ask([d for d in changed if d not in owned])
        kept = 0
        backed_up: list[Path] = []
        for dest, content, guard in items:
            if dest.is_file():
                if dest.read_bytes() == content:
                    self._ensure_mode(dest)
                    continue
                if dest not in owned:
                    if not overwrite:
                        kept += 1
                        continue
                    if self.force:
                        if not self._backup(dest, guard):
                            refused += 1
                            continue
                        backed_up.append(dest)
            if guard is None:
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(content)
            elif not _write_guarded(*guard, content, _ERR):
                refused += 1
                continue
            self._ensure_mode(dest)
        for d in backed_up:
            print(f"  backed up {d} -> {d.name}.den.bak", file=sys.stderr)
        if kept:
            print(f"  kept {kept} modified file(s) as-is", file=sys.stderr)
        if refused:
            print(
                f"  refused {refused} path(s) listed above; nothing was written there",
                file=sys.stderr,
            )
        return refused + (kept if silently_skipped else 0)


def _materialize(  # ruff: ignore[too-many-branches]  # one branch per shared-resource kind
    name: str, work: Path, ref_prefix: str, *, no_den_cli: bool = False
) -> int:
    """Copy skill `name` to `work` as a self-contained unit: the shared/
    resources it references are copied inside it and every shared/ reference
    is rewritten to `ref_prefix` + kind + '/'. With no_den_cli the substitution
    table (agents/src/no-den-cli.toml) is applied to SKILL.md and to the
    bundled shared/ files it names before any reference is rewritten,
    removing every mention of den's own CLI and cheatsheets. Returns the
    number of rewritten .md files."""
    src = skills_dir() / name
    rewritten = 0
    shutil.copytree(src, work, ignore=_ignore)
    if no_den_cli:
        from ._portable import strip_den_cli

        skill_md = work / "SKILL.md"
        skill_md.write_text(
            strip_den_cli(name, skill_md.read_text(encoding="utf-8")),
            encoding="utf-8",
        )

    if True:  # scan the copied skill (before shared/ is added) for what it references
        blob = ""
        for p in work.rglob("*"):
            if p.is_file():
                blob += p.read_text(encoding="utf-8", errors="ignore")
        need_scripts = "shared/scripts/" in blob
        need_all_refs = "shared/reference/<" in blob
        ref_files = sorted(set(_REF_RE.findall(blob)))

        sh = shared_dir()
        ref_dest = work / "shared" / "reference"
        if need_all_refs:
            ref_dest.mkdir(parents=True, exist_ok=True)
            for md in (sh / "reference").glob("*.md"):
                shutil.copy2(md, ref_dest / md.name)
        elif ref_files:
            ref_dest.mkdir(parents=True, exist_ok=True)
            for rf in ref_files:
                srcf = sh / "reference" / f"{rf}.md"
                if srcf.is_file():
                    shutil.copy2(srcf, ref_dest / f"{rf}.md")
        if need_scripts:
            shutil.copytree(sh / "scripts", work / "shared" / "scripts", ignore=_ignore)
        if no_den_cli:  # before the rewrite below, so anchors match the source text
            from ._portable import strip_shared

            strip_shared(work)

        # Rewrite shared/... refs to their destination under the skill itself.
        for md in work.rglob("*.md"):
            try:
                orig = md.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue  # not a text .md (binary asset); leave it untouched
            new = _REWRITE_RE.sub(lambda m: f"{ref_prefix}{m.group(1)}/", orig)
            if new != orig:
                md.write_text(new, encoding="utf-8")
                rewritten += 1
    return rewritten


def _install_skill(
    name: str, skills_target: Path, writer: _Stager, *, no_den_cli: bool = False
) -> str:
    """Build the self-contained skill in a temp dir (rewriting shared/ refs to
    its FINAL absolute location), then stage every file for the writer."""
    final = skills_target / name
    abs_final = final.resolve().as_posix()
    with tempfile.TemporaryDirectory() as td:
        work = Path(td) / name
        rewritten = _materialize(
            name, work, f"{abs_final}/shared/", no_den_cli=no_den_cli
        )
        for f in sorted(work.rglob("*")):
            if f.is_file():
                writer.stage(final / f.relative_to(work), f.read_bytes())
    return f"  {name} (rewrote {rewritten} md files)"


def _deploy(
    skills_target: Path,
    parent_dir: Path | None,
    parent_file: str | None,
    writer: _Writer,
    *,
    with_parent: bool,
    dry_run: bool,
    profile: str = "frontier",
    no_den_cli: bool = False,
) -> None:
    names = _skill_names()
    if dry_run:
        print(f"[dry-run] skills -> {skills_target}/<name>/")
        print(f"[dry-run]   skills: {' '.join(names)}")
        if with_parent and parent_dir is not None:
            print(f"[dry-run]   parent ({profile}) -> {parent_dir}/{parent_file}")
        return

    print(f"installing skills -> {skills_target}")
    for name in names:
        print(_install_skill(name, skills_target, writer, no_den_cli=no_den_cli))

    if with_parent and parent_dir is not None and parent_file is not None:
        src = _parent_source(parent_file, profile)
        if src.is_file():
            writer.stage(parent_dir / parent_file, src.read_bytes())
            print(f"  parent ({profile}) -> {parent_dir}/{parent_file}")
        else:
            print(f"  warning: {src} not found", file=sys.stderr)


# --- den upgrade --refresh: replace only what the previous version wrote --- #
#
# The den running `den upgrade` still has the OLD bundled content, so before
# `uv tool upgrade` it compares every deployed file in each tool dir with that
# content and writes down what matched: the plan below (den/_upgrade.py builds
# it). The new den then reads it via `den install skills|shell --refresh-plan
# FILE` and replaces only those files. The plan is a temporary file for that one
# hand-over, not a record of what den deployed: README's "no manifest" design
# stands. Its shape is an interface between two den versions, so a later den
# must keep accepting version 1.

_PLAN_VERSION = 1
_PARENT_FILES = frozenset(pf for _sk, _pd, pf in _TOOLS.values())


def load_refresh_plan(path: str) -> dict:
    """The refresh plan at `path`, checked for shape. ValueError says what is
    wrong (OSError when it cannot be read)."""
    plan = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(plan, dict) or plan.get("den_refresh_plan") != _PLAN_VERSION:
        raise ValueError(f"not a version {_PLAN_VERSION} den refresh plan")

    def absolute(value: object) -> str:
        if not isinstance(value, str) or not Path(value).is_absolute():
            raise ValueError(f"not an absolute path: {value!r}")
        return value

    def strings(value: object) -> list[str]:
        if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
            raise ValueError(f"not a list of strings: {value!r}")
        return [v for v in value if isinstance(v, str)]

    for p in strings(plan.get("owned")):
        absolute(p)
    strings(plan.get("known_skills"))
    skills = plan.get("skills")
    parents = plan.get("parents")
    if not isinstance(skills, list) or not isinstance(parents, list):
        raise ValueError("skills and parents must be lists")
    for entry in skills:
        if not isinstance(entry, dict) or not isinstance(entry.get("no_den_cli"), bool):
            raise ValueError(f"bad skills entry: {entry!r}")
        absolute(entry.get("target"))
        strings(entry.get("names"))
    for entry in parents:
        if (
            not isinstance(entry, dict)
            or entry.get("file") not in _PARENT_FILES
            or entry.get("profile") not in {"frontier", "weak"}
        ):
            raise ValueError(f"bad parent entry: {entry!r}")
        absolute(entry.get("path"))
    if not isinstance(plan.get("shell"), bool):
        raise ValueError("shell must be true or false")
    return plan


def read_refresh_plan(path: str, prefix: str) -> dict | None:
    """load_refresh_plan, or None after one line on stderr."""
    try:
        return load_refresh_plan(path)
    except (OSError, ValueError) as exc:
        print(f"{prefix}: cannot use the refresh plan {path}: {exc}", file=sys.stderr)
        return None


def _install_refresh(plan_path: str, *, force: bool, dry_run: bool) -> int:
    """`den install skills --refresh-plan FILE`: redeploy the skills into each
    tool dir the plan names (the skill dirs present there, plus skills this
    version added) and each parent prompt in its recorded profile. A differing
    file is replaced only when the plan lists it as den's own unedited copy;
    any other one is kept and listed, or with --force backed up and replaced.
    A parent the old den did not recognize is not in the plan at all, so a
    hand-written CLAUDE.md is never touched, not even with --force."""
    plan = read_refresh_plan(plan_path, "den install skills")
    if plan is None:
        return 2
    names = _skill_names()
    known = set(plan["known_skills"])
    writer = _Writer(force=force, owned={Path(p) for p in plan["owned"]})
    for entry in plan["skills"]:
        target = Path(entry["target"])
        present = set(entry["names"])
        wanted = [n for n in names if n in present or n not in known]
        if dry_run:
            print(f"[dry-run] refresh skills -> {target}/: {' '.join(wanted)}")
            continue
        print(f"refreshing skills -> {target}")
        for name in wanted:
            print(_install_skill(name, target, writer, no_den_cli=entry["no_den_cli"]))
    for entry in plan["parents"]:
        src = _parent_source(entry["file"], entry["profile"])
        if dry_run:
            print(f"[dry-run] refresh parent ({entry['profile']}) -> {entry['path']}")
        elif src.is_file():
            writer.stage(Path(entry["path"]), src.read_bytes())
            print(f"  parent ({entry['profile']}) -> {entry['path']}")
        else:
            print(f"  warning: {src} not found", file=sys.stderr)
    return 0 if dry_run or not writer.commit() else 1


def _codex_config(skills_target: Path) -> None:
    print("\n# --- paste into ~/.codex/config.toml ---")
    for name in _skill_names():
        print("[[skills.config]]")
        print(f'path = "{(skills_target / name).as_posix()}/SKILL.md"')
        print("enabled = true\n")


def _parse(  # ruff: ignore[too-many-branches]  # one branch per flag
    argv: list[str],
) -> tuple[list[str], list[str], bool, bool, bool, bool, str, bool] | None:
    tools: list[str] = []
    targets: list[str] = []
    with_parent = dry_run = codex_config = force = no_den_cli = False
    profile = "frontier"
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--tool" and i + 1 < len(argv):
            if argv[i + 1] not in _TOOLS:
                print(f"den install: unknown tool '{argv[i + 1]}'", file=sys.stderr)
                return None
            tools.append(argv[i + 1])
            i += 2
        elif a == "--all-tools":
            tools = list(_TOOLS)
            i += 1
        elif a == "--target" and i + 1 < len(argv):
            targets.append(argv[i + 1])
            i += 2
        elif a == "--profile" and i + 1 < len(argv):
            if argv[i + 1] not in {"weak", "frontier"}:
                print(
                    f"den install: unknown profile '{argv[i + 1]}' (weak or frontier)",
                    file=sys.stderr,
                )
                return None
            profile = argv[i + 1]
            i += 2
        elif a == "--with-parent":
            with_parent = True
            i += 1
        elif a == "--no-den-cli":
            no_den_cli = True
            i += 1
        elif a == "--dry-run":
            dry_run = True
            i += 1
        elif a == "--codex-config":
            codex_config = True
            i += 1
        elif a == "--force":
            force = True
            i += 1
        else:
            print(f"den install skills: unexpected arg '{a}'", file=sys.stderr)
            return None
    return (
        tools,
        targets,
        with_parent,
        dry_run,
        codex_config,
        force,
        profile,
        no_den_cli,
    )


def _refresh_plan_arg(
    argv: list[str], prefix: str
) -> tuple[str | None, list[str]] | None:
    """(the --refresh-plan FILE, the other args), or None (one line on stderr)
    when the flag has no value."""
    if "--refresh-plan" not in argv:
        return None, argv
    i = argv.index("--refresh-plan")
    if i + 1 >= len(argv):
        print(f"{prefix}: --refresh-plan needs a file", file=sys.stderr)
        return None
    return argv[i + 1], argv[:i] + argv[i + 2 :]


def _install_skills_cmd(argv: list[str]) -> int:
    """`den install skills`: the refresh hand-over, or an ordinary install."""
    split = _refresh_plan_arg(argv, "den install skills")
    if split is None:
        return 2
    plan_path, argv = split
    if plan_path is None:
        return _install_skills(argv)
    extra = [a for a in argv if a not in {"--force", "--dry-run"}]
    if extra:
        print(
            "den install skills: --refresh-plan takes only --force and"
            f" --dry-run, not {' '.join(extra)}",
            file=sys.stderr,
        )
        return 2
    return _install_refresh(
        plan_path, force="--force" in argv, dry_run="--dry-run" in argv
    )


def _install_skills(argv: list[str]) -> int:  # ruff: ignore[too-many-locals]  # per-target staging
    parsed = _parse(argv)
    if parsed is None:
        return 2
    tools, targets, with_parent, dry_run, codex_config, force, profile, no_den_cli = (
        parsed
    )
    writer = _Writer(force=force)

    processed: list[Path] = []
    for tool in tools:
        skt, parent_dir, pf = _tool_paths(tool)
        _deploy(
            skt,
            parent_dir,
            pf,
            writer,
            with_parent=with_parent,
            dry_run=dry_run,
            profile=profile,
            no_den_cli=no_den_cli,
        )
        processed.append(skt)

    for t in targets:
        # absolute (not resolved): the staged paths must sit under the root
        # confine() compares them with, and the rewritten references resolve
        # on their own (_install_skill)
        root = Path(t).expanduser().absolute()
        writer.confine(root)
        _deploy(
            root / "skills",
            root,
            "AGENTS.md",
            writer,
            with_parent=with_parent,
            dry_run=dry_run,
            profile=profile,
            no_den_cli=no_den_cli,
        )
        if with_parent:
            # custom targets get both AGENTS.md and CLAUDE.md at the root, so
            # the dry-run has to name CLAUDE.md too -- a preview that omits a
            # destination the real run overwrites is worse than no preview.
            claude = _parent_source("CLAUDE.md", profile)
            if not claude.is_file():
                print(f"  warning: {claude} not found", file=sys.stderr)
            elif dry_run:
                print(f"[dry-run]   parent ({profile}) -> {root}/CLAUDE.md")
            else:
                writer.stage(root / "CLAUDE.md", claude.read_bytes())
        processed.append(root / "skills")

    if not tools and not targets:
        sk, pd, pf = _TOOLS["claude"]
        _deploy(
            Path(sk).expanduser(),
            Path(pd).expanduser(),
            pf,
            writer,
            with_parent=with_parent,
            dry_run=dry_run,
            profile=profile,
            no_den_cli=no_den_cli,
        )
        agents = Path("~/.agents/skills").expanduser()
        _deploy(
            agents,
            Path("~/.agents").expanduser(),
            "AGENTS.md",
            writer,
            with_parent=with_parent,
            dry_run=dry_run,
            profile=profile,
            no_den_cli=no_den_cli,
        )
        processed.append(agents)

    skipped = writer.commit() if not dry_run else 0

    if codex_config:
        target = processed[0] if processed else Path("~/.agents/skills").expanduser()
        if not dry_run:
            target.mkdir(parents=True, exist_ok=True)
        _codex_config(target)

    if not dry_run and not with_parent and processed:
        print(
            "\nNote: skills reference a parent prompt (<honesty_contract>, "
            "<language_policy>, <work_discipline>). Re-run with --with-parent "
            "to install it into each tool's location."
        )
    # A non-interactive run that kept differing files deployed nothing for them.
    # Say so with the exit code: `den upgrade --refresh` (and any script) would
    # otherwise read "success" from a run that left the old version in place.
    return 1 if skipped else 0


def _interactive() -> int:
    """`den install` with no target: ask per component, like the old installer."""
    _ui.say("den install -- interactive setup", style="bold cyan")
    rc = 0
    if _ui.confirm(
        "Install the shell environment (bash/zsh + PowerShell, starship)?", default=True
    ):
        from ._shell import install_shell

        extras = _ui.confirm(
            "  Include optional helpers (python/ffmpeg/parallel)?", default=True
        )
        shell_flags = [] if extras else ["--no-extras"]
        # zsh plugins are POSIX-only; do not ask a question that no-ops.
        if not _windows() and _ui.confirm(
            "  Clone the pinned zsh plugins (autosuggestions + highlighting)?",
            default=False,
        ):
            shell_flags.append("--zsh-plugins")
        rc |= install_shell(shell_flags)

    if _ui.confirm("Install the LLM agent skills?", default=False):
        chosen = _ui.select(
            "Which tools do you use? (space to toggle, enter to confirm)",
            [(tool, tool == "claude") for tool in _TOOLS],
        )
        flags: list[str] = []
        for tool in chosen:
            flags += ["--tool", tool]
        if flags and _ui.confirm(
            "Install the parent prompt (AGENTS.md/CLAUDE.md) too?", default=True
        ):
            flags.append("--with-parent")
        # Only tools that plausibly run weak/local models get the question;
        # the answer applies to this whole install (split runs to mix).
        if (
            flags
            and any(t in _MIXED_MODEL_TOOLS for t in chosen)
            and _ui.confirm(
                "  Deploy the weak-model parent (the skill router) instead of"
                " the frontier parent?",
                default=False,
            )
        ):
            flags += ["--profile", "weak"]
        if flags:
            rc |= _install_skills(flags)

    if _ui.confirm("Install the offline cheatsheets?", default=False):
        rc |= _install_cheatsheets([])

    _ui.say(
        "\nHooks install per workspace: run 'den install hook' inside a project "
        "to imprint context every turn there."
    )
    return rc


def _cheatsheets_target() -> Path:
    base = os.environ.get("XDG_DATA_HOME")
    root = Path(base) if base else Path.home() / ".local" / "share"
    return root / "den" / "cheatsheets"


def _install_cheatsheets(argv: list[str]) -> int:
    """Deploy the bundled cheatsheets to the XDG data dir. Browsing is the shell
    `cheat` function's job (den install shell); this only stages the files."""
    dry_run = force = False
    for a in argv:
        if a == "--dry-run":
            dry_run = True
        elif a == "--force":
            force = True
        else:
            print(f"den install cheatsheets: unexpected arg '{a}'", file=sys.stderr)
            return 2

    src = cheatsheets_dir()
    if not src.is_dir():
        print("den install cheatsheets: no cheatsheets are bundled", file=sys.stderr)
        return 1
    dest_root = _cheatsheets_target()
    files = [
        p
        for p in sorted(src.rglob("*"))
        if p.is_file() and "__pycache__" not in p.parts and p.suffix != ".pyc"
    ]
    if dry_run:
        print(f"[dry-run] cheatsheets -> {dest_root}/ ({len(files)} files)")
        return 0
    writer = _Writer(force=force)
    for f in files:
        writer.stage(dest_root / f.relative_to(src), f.read_bytes())
    print(f"installing cheatsheets -> {dest_root}")
    return 1 if writer.commit() else 0


def _usage() -> None:
    print(
        "usage: den install [<target>] [args]\n"
        "\n"
        "With no target (in a terminal), den install asks per component.\n"
        "\n"
        "Targets:\n"
        "  skills [--tool T]... [--all-tools] [--target DIR]...\n"
        "         [--with-parent] [--no-den-cli] [--profile weak|frontier]\n"
        "         [--dry-run] [--codex-config] [--force]\n"
        "  shell  [--dry-run] [--no-extras] [--force]\n"
        "         [--coreutils|--no-coreutils] [--bin|--no-bin] [--zsh-plugins]\n"
        "  hook   [--tool T]... [--all-tools] [--config PATH]"
        "  per-workspace imprint hooks\n"
        "  cheatsheets [--dry-run] [--force]                  "
        " bundled sheets -> data dir\n"
        "\n"
        "Existing files that differ are kept unless you confirm (or pass --force,\n"
        "which first copies each one it overwrites to <file>.den.bak).\n"
        "\n"
        f"Tools: {', '.join(_TOOLS)}.\n"
        "skills with no --tool/--target deploys to ~/.claude and ~/.agents.\n"
        "--profile frontier (default) deploys the frontier parent; weak deploys\n"
        "the skill router (for weak/local models; typically with --target)."
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
    # Leaf-level help: `den install skills --help` etc. should print usage, not
    # error. hook owns its own arg handling in _hook, so it is excluded here.
    if target in {"skills", "shell", "cheatsheets"} and any(
        a in {"-h", "--help", "help"} for a in rest
    ):
        _usage()
        return 0
    if target == "skills":
        return _install_skills_cmd(rest)
    if target == "shell":
        from ._shell import install_shell

        return install_shell(rest)
    if target == "hook":
        from ._hook import _cmd_install

        return _cmd_install(rest)
    if target == "cheatsheets":
        return _install_cheatsheets(rest)
    print(
        f"den install: unknown target '{target}' "
        "(try: skills, shell, hook, cheatsheets)",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
