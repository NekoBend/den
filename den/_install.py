"""den install - deploy skills (and parent prompts) into agent tool dirs.

Installs each skill as a SELF-CONTAINED unit: the skill's files plus the shared
resources it references (shared/reference/*.md and, if any script is used, the
whole shared/scripts/ set) are copied under <target>/skills/<name>/shared/, and
every shared/... reference is rewritten to an ABSOLUTE path under that skill's
own shared/.

  den install skills [--tool TOOL]... [--all-tools] [--target DIR]...
                     [--with-parent] [--dry-run] [--codex-config]
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from . import _ui
from ._content import dist_dir, shared_dir, skills_dir

# tool -> (skills_dir, parent_dir, parent_file). The cline (VS Code extension)
# parent_dir is dynamic -- see _tool_paths/_cline_rules_dir; the value here is
# only the fallback shape.
_TOOLS: dict[str, tuple[str, str, str]] = {
    "claude": ("~/.claude/skills", "~/.claude", "CLAUDE.md"),
    "codex": ("~/.agents/skills", "~/.codex", "AGENTS.md"),
    "cline": ("~/.agents/skills", "~/Documents/Cline/Rules", "AGENTS.md"),
    "cline-cli": ("~/.agents/skills", "~/.agents", "AGENTS.md"),
    "copilot": ("~/.copilot/skills", "~/.copilot", "copilot-instructions.md"),
    "gemini": ("~/.gemini/skills", "~/.gemini", "GEMINI.md"),
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
    together never double-deliver."""
    if _windows():
        for exe in ("pwsh", "powershell"):
            if not shutil.which(exe):
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
    if sys.platform == "linux" and shutil.which("xdg-user-dir"):
        try:
            out = subprocess.run(
                ["xdg-user-dir", "DOCUMENTS"],
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


_REF_RE = re.compile(r"shared/reference/([A-Za-z0-9_-]+)\.md")
_REWRITE_RE = re.compile(r"(?:\.\./)*shared/(reference|scripts)/")
_EXCLUDE = {"__pycache__", ".pytest_cache", "tests"}


def _ignore(_dir: str, names: list[str]) -> list[str]:
    return [n for n in names if n in _EXCLUDE or n.endswith(".pyc")]


def _skill_names() -> list[str]:
    root = skills_dir()
    return sorted(d.name for d in root.iterdir() if (d / "SKILL.md").is_file())


class _Writer:
    """Collect (dest, content) writes, then commit them. New and byte-identical
    files are written silently; files that already exist and DIFFER are listed
    and, unless --force, the user is asked once before overwriting (default no,
    so local edits are kept). Non-interactive: differing files are skipped."""

    def __init__(self, force: bool):
        self.force = force
        self._items: list[tuple[Path, bytes]] = []

    def stage(self, dest: Path, content: bytes) -> None:
        self._items.append((dest, content))

    def commit(self) -> None:
        changed = [d for d, c in self._items if d.is_file() and d.read_bytes() != c]
        overwrite = True
        if changed and not self.force:
            _ui.say(
                "These files exist and differ from the bundled version:", style="yellow"
            )
            for d in changed:
                _ui.say(f"  {d}", style="yellow")
            if sys.stdin.isatty():
                overwrite = _ui.confirm("Overwrite them?", False)
            else:
                print("  skipped (re-run with --force to overwrite)", file=sys.stderr)
                overwrite = False
        kept = 0
        for dest, content in self._items:
            if dest.is_file():
                if dest.read_bytes() == content:
                    continue
                if not overwrite:
                    kept += 1
                    continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(content)
        if kept:
            print(f"  kept {kept} modified file(s) as-is", file=sys.stderr)


def _install_skill(name: str, skills_target: Path, writer: _Writer) -> str:
    """Build the self-contained skill in a temp dir (rewriting shared/ refs to
    its FINAL location), then stage every file for the writer to commit."""
    src = skills_dir() / name
    final = skills_target / name
    abs_final = final.resolve().as_posix()
    rewritten = 0

    with tempfile.TemporaryDirectory() as td:
        work = Path(td) / name
        shutil.copytree(src, work, ignore=_ignore)

        # Scan the copied skill (before shared/ is added) for what it references.
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

        # Rewrite shared/... refs to an absolute path under the skill's FINAL dir.
        for md in work.rglob("*.md"):
            try:
                orig = md.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue  # not a text .md (binary asset); leave it untouched
            new = _REWRITE_RE.sub(lambda m: f"{abs_final}/shared/{m.group(1)}/", orig)
            if new != orig:
                md.write_text(new, encoding="utf-8")
                rewritten += 1

        for f in sorted(work.rglob("*")):
            if f.is_file():
                writer.stage(final / f.relative_to(work), f.read_bytes())

    return f"  {name} (rewrote {rewritten} md files)"


def _deploy(
    skills_target: Path,
    parent_dir: Path | None,
    parent_file: str | None,
    with_parent: bool,
    dry_run: bool,
    writer: _Writer,
) -> None:
    names = _skill_names()
    if dry_run:
        print(f"[dry-run] skills -> {skills_target}/<name>/")
        print(f"[dry-run]   skills: {' '.join(names)}")
        if with_parent and parent_dir is not None:
            print(f"[dry-run]   parent -> {parent_dir}/{parent_file}")
        return

    print(f"installing skills -> {skills_target}")
    for name in names:
        print(_install_skill(name, skills_target, writer))

    if with_parent and parent_dir is not None and parent_file is not None:
        src = dist_dir() / ("CLAUDE.md" if parent_file == "CLAUDE.md" else "AGENTS.md")
        if src.is_file():
            writer.stage(parent_dir / parent_file, src.read_bytes())
            print(f"  parent -> {parent_dir}/{parent_file}")
        else:
            print(f"  warning: {src} not found", file=sys.stderr)


def _codex_config(skills_target: Path) -> None:
    print("\n# --- paste into ~/.codex/config.toml ---")
    for name in _skill_names():
        print("[[skills.config]]")
        print(f'path = "{(skills_target / name).as_posix()}/SKILL.md"')
        print("enabled = true\n")


def _parse(argv: list[str]):
    tools: list[str] = []
    targets: list[str] = []
    with_parent = dry_run = codex_config = force = False
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
        elif a == "--with-parent":
            with_parent = True
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
    return tools, targets, with_parent, dry_run, codex_config, force


def _install_skills(argv: list[str]) -> int:
    parsed = _parse(argv)
    if parsed is None:
        return 2
    tools, targets, with_parent, dry_run, codex_config, force = parsed
    writer = _Writer(force)

    processed: list[Path] = []
    for tool in tools:
        skt, parent_dir, pf = _tool_paths(tool)
        _deploy(skt, parent_dir, pf, with_parent, dry_run, writer)
        processed.append(skt)

    for t in targets:
        root = Path(t).expanduser()
        _deploy(root / "skills", root, "AGENTS.md", with_parent, dry_run, writer)
        if with_parent and not dry_run:
            # custom targets get both AGENTS.md and CLAUDE.md at the root
            claude = dist_dir() / "CLAUDE.md"
            if claude.is_file():
                writer.stage(root / "CLAUDE.md", claude.read_bytes())
        processed.append(root / "skills")

    if not tools and not targets:
        sk, pd, pf = _TOOLS["claude"]
        _deploy(
            Path(sk).expanduser(),
            Path(pd).expanduser(),
            pf,
            with_parent,
            dry_run,
            writer,
        )
        agents = Path("~/.agents/skills").expanduser()
        _deploy(
            agents,
            Path("~/.agents").expanduser(),
            "AGENTS.md",
            with_parent,
            dry_run,
            writer,
        )
        processed.append(agents)

    if not dry_run:
        writer.commit()

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
    return 0


def _interactive() -> int:
    """`den install` with no target: ask per component, like the old installer."""
    _ui.say("den install -- interactive setup", style="bold cyan")
    rc = 0
    if _ui.confirm(
        "Install the shell environment (bash/zsh + PowerShell, starship)?", True
    ):
        from ._shell import install_shell

        extras = _ui.confirm(
            "  Include optional helpers (python/ffmpeg/parallel)?", True
        )
        rc |= install_shell([] if extras else ["--no-extras"])

    if _ui.confirm("Install the LLM agent skills?", False):
        chosen = _ui.select(
            "Which tools do you use? (space to toggle, enter to confirm)",
            [(tool, tool == "claude") for tool in _TOOLS],
        )
        flags: list[str] = []
        for tool in chosen:
            flags += ["--tool", tool]
        if flags and _ui.confirm(
            "Install the parent prompt (AGENTS.md/CLAUDE.md) too?", True
        ):
            flags.append("--with-parent")
        if flags:
            rc |= _install_skills(flags)

    _ui.say(
        "\nHooks install per workspace: run 'den hook install' inside a project "
        "to imprint context every turn there."
    )
    return rc


def _usage() -> None:
    print(
        "usage: den install [<target>] [args]\n"
        "\n"
        "With no target (in a terminal), den install asks per component.\n"
        "\n"
        "Targets:\n"
        "  skills [--tool T]... [--all-tools] [--target DIR]...\n"
        "         [--with-parent] [--dry-run] [--codex-config] [--force]\n"
        "  shell  [--dry-run] [--no-extras] [--force]\n"
        "         [--coreutils|--no-coreutils] [--bin|--no-bin]\n"
        "\n"
        "Existing files that differ are kept unless you confirm (or pass --force).\n"
        "\n"
        f"Tools: {', '.join(_TOOLS)}.\n"
        "skills with no --tool/--target deploys to ~/.claude and ~/.agents."
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
        return _install_skills(rest)
    if target == "shell":
        from ._shell import install_shell

        return install_shell(rest)
    print(
        f"den install: unknown target '{target}' (try: skills, shell)",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
