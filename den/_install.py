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

import re
import shutil
import sys
from pathlib import Path

from ._content import dist_dir, shared_dir, skills_dir

# tool -> (skills_dir, parent_dir, parent_file)
_TOOLS: dict[str, tuple[str, str, str]] = {
    "claude": ("~/.claude/skills", "~/.claude", "CLAUDE.md"),
    "codex": ("~/.agents/skills", "~/.codex", "AGENTS.md"),
    "cline": ("~/.agents/skills", "~/.agents", "AGENTS.md"),
    "copilot": ("~/.copilot/skills", "~/.copilot", "copilot-instructions.md"),
    "gemini": ("~/.gemini/skills", "~/.gemini", "GEMINI.md"),
}

_REF_RE = re.compile(r"shared/reference/([A-Za-z0-9_-]+)\.md")
_REWRITE_RE = re.compile(r"(?:\.\./)*shared/(reference|scripts)/")
_EXCLUDE = {"__pycache__", ".pytest_cache", "tests"}


def _ignore(_dir: str, names: list[str]) -> list[str]:
    return [n for n in names if n in _EXCLUDE or n.endswith(".pyc")]


def _skill_names() -> list[str]:
    root = skills_dir()
    return sorted(d.name for d in root.iterdir() if (d / "SKILL.md").is_file())


def _install_skill(name: str, skills_target: Path) -> str:
    src = skills_dir() / name
    dest = skills_target / name
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(src, dest, ignore=_ignore)

    # Scan the copied skill (before shared/ is added) for which shared resources
    # it references.
    blob = ""
    for p in dest.rglob("*"):
        if p.is_file():
            blob += p.read_text(encoding="utf-8", errors="ignore")
    need_scripts = "shared/scripts/" in blob
    need_all_refs = "shared/reference/<" in blob
    ref_files = sorted(set(_REF_RE.findall(blob)))

    sh = shared_dir()
    ref_dest = dest / "shared" / "reference"
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
        shutil.copytree(sh / "scripts", dest / "shared" / "scripts", ignore=_ignore)

    # Rewrite every shared/... reference to an absolute path under dest/shared/.
    abs_dest = dest.resolve().as_posix()
    rewritten = 0
    for md in dest.rglob("*.md"):
        try:
            orig = md.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue  # not a text .md (binary asset); leave it untouched
        new = _REWRITE_RE.sub(lambda m: f"{abs_dest}/shared/{m.group(1)}/", orig)
        if new != orig:
            md.write_text(new, encoding="utf-8")
            rewritten += 1
    return f"  {name} (rewrote {rewritten} md files)"


def _deploy(
    skills_target: Path,
    parent_dir: Path | None,
    parent_file: str | None,
    with_parent: bool,
    dry_run: bool,
) -> None:
    names = _skill_names()
    if dry_run:
        print(f"[dry-run] skills -> {skills_target}/<name>/")
        print(f"[dry-run]   skills: {' '.join(names)}")
        if with_parent and parent_dir is not None:
            print(f"[dry-run]   parent -> {parent_dir}/{parent_file}")
        return

    skills_target.mkdir(parents=True, exist_ok=True)
    print(f"installing skills -> {skills_target}")
    for name in names:
        print(_install_skill(name, skills_target))

    if with_parent and parent_dir is not None and parent_file is not None:
        src = dist_dir() / ("CLAUDE.md" if parent_file == "CLAUDE.md" else "AGENTS.md")
        if src.is_file():
            parent_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, parent_dir / parent_file)
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
    with_parent = dry_run = codex_config = False
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
        else:
            print(f"den install skills: unexpected arg '{a}'", file=sys.stderr)
            return None
    return tools, targets, with_parent, dry_run, codex_config


def _install_skills(argv: list[str]) -> int:
    parsed = _parse(argv)
    if parsed is None:
        return 2
    tools, targets, with_parent, dry_run, codex_config = parsed

    processed: list[Path] = []
    for tool in tools:
        sk, pd, pf = _TOOLS[tool]
        skt = Path(sk).expanduser()
        _deploy(skt, Path(pd).expanduser(), pf, with_parent, dry_run)
        processed.append(skt)

    for t in targets:
        root = Path(t).expanduser()
        _deploy(root / "skills", root, "AGENTS.md", with_parent, dry_run)
        if with_parent and not dry_run:
            # custom targets get both AGENTS.md and CLAUDE.md at the root
            claude = dist_dir() / "CLAUDE.md"
            if claude.is_file():
                shutil.copy2(claude, root / "CLAUDE.md")
        processed.append(root / "skills")

    if not tools and not targets:
        sk, pd, pf = _TOOLS["claude"]
        _deploy(Path(sk).expanduser(), Path(pd).expanduser(), pf, with_parent, dry_run)
        agents = Path("~/.agents/skills").expanduser()
        _deploy(
            agents, Path("~/.agents").expanduser(), "AGENTS.md", with_parent, dry_run
        )
        processed.append(agents)

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


def _usage() -> None:
    print(
        "usage: den install <target> [args]\n"
        "\n"
        "Targets:\n"
        "  skills [--tool T]... [--all-tools] [--target DIR]...\n"
        "         [--with-parent] [--dry-run] [--codex-config]\n"
        "  shell  [--dry-run] [--no-extras]\n"
        "\n"
        f"Tools: {', '.join(_TOOLS)}.\n"
        "skills with no --tool/--target deploys to ~/.claude and ~/.agents."
    )


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if not args or args[0] in ("-h", "--help", "help"):
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
