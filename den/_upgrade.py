"""den upgrade - upgrade den itself via uv, then optionally redeploy content.

den is installed as a uv tool, so the upgrade itself is `uv tool upgrade den`.
The wrinkle is that bundled content (skills, shell sources, parent prompts,
cheatsheets) only reaches disk on `den install ...`: after an upgrade the new
wheel's content sits inside the tool venv until it is redeployed. --refresh
does that redeploy immediately - as subprocesses of the freshly upgraded
`den` binary, never in-process, because this running process still has the
OLD package (and its old bundled data) imported.

uv and the upgraded den are resolved through den._exe and run by absolute
path: a checkout that ships uv.exe or den.cmd at its root must not be what
`den upgrade` runs when invoked there on Windows. The redeploy uses the den in
uv's own tool bin dir (`uv tool dir --bin`), the one the upgrade just
replaced, and falls back to PATH (cwd entries dropped) only when uv cannot
name that dir.

What --refresh may replace is decided BEFORE the upgrade, by this process,
which still has the old bundled content (on disk in the tool venv until uv
replaces it): every deployed file in each tool dir -- skills in either
flavor, parent prompts in either profile, the shell files -- is compared byte
for byte with what this version deploys, and the matches are den's own,
unedited. The new den gets that list as a temporary plan file
(`den install skills|shell --refresh-plan FILE`, see _install._install_refresh)
and replaces only those; everything else stays and is listed. A parent prompt
that matches neither profile (hand-written, or edited) is not refreshed at
all, and a tool dir without den's skills is not created. No state is kept
between runs.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from ._exe import find_tool, resolve_tool


def _windows() -> bool:
    # Indirection so tests can flip platform without touching os.name globally
    # (pathlib reads os.name to pick WindowsPath/PosixPath).
    return os.name == "nt"


def _upgraded_den(uv: str) -> str | None:
    """The den `uv tool upgrade` just replaced, by absolute path, or None.

    uv's tool bin dir comes first because PATH can name another den ahead of
    it (a project venv's); PATH, with its cwd entries dropped, is only the
    fallback for a uv that cannot report the dir. A den in the working
    directory is refused either way (reported on stderr).
    """
    bin_dir = None
    try:
        out = subprocess.run(
            [uv, "tool", "dir", "--bin"],
            capture_output=True,
            text=True,
            # uv prints UTF-8; the locale codec would mangle a non-ASCII home
            encoding="utf-8",
            errors="replace",
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        out = None
    if out is not None and out.returncode == 0:
        lines = [ln.strip() for ln in out.stdout.splitlines() if ln.strip()]
        if lines and Path(lines[-1]).is_absolute():
            bin_dir = lines[-1]
    if bin_dir is not None:
        den, refusal = resolve_tool("den", path=bin_dir)
        if refusal:
            print(f"den upgrade: {refusal}", file=sys.stderr)
            return None
        if den:
            return den
    return find_tool("den", "den upgrade")


class _Matcher:
    """A stager (see _install._Stager) that records which staged destinations
    already hold exactly the staged bytes, i.e. are this den's own output."""

    def __init__(self) -> None:
        self.matched: set[Path] = set()

    def stage(self, dest: Path, content: bytes) -> None:
        try:
            if dest.is_file() and dest.read_bytes() == content:
                self.matched.add(dest)
        except OSError:
            pass  # unreadable: not provably den's


def _scan_skills(
    target: Path, names: list[str], den_free: set[str]
) -> tuple[dict, set[Path]] | None:
    """(plan entry, den's unedited files) for one skills dir, or None when no
    deployed file there is byte-identical to this den's: den never deployed
    there (or every file was edited), and the refresh must not create it."""
    from ._install import _install_skill

    present = [n for n in names if (target / n).is_dir()]
    aware, free = _Matcher(), _Matcher()
    for name in present:
        _install_skill(name, target, aware)
        if name in den_free:
            _install_skill(name, target, free, no_den_cli=True)
    owned = aware.matched | free.matched
    if not owned:
        return None
    # Which flavor was deployed: only the --no-den-cli skills differ between
    # the two, so only their files say anything.
    free_dirs = {target / n for n in den_free}
    aware_only = {p for p in aware.matched - free.matched if free_dirs & set(p.parents)}
    no_den_cli = bool(free.matched - aware.matched) and not aware_only
    entry = {"target": str(target), "names": present, "no_den_cli": no_den_cli}
    return entry, owned


def _parent_profile(parent: Path, parent_file: str) -> str | None:
    """The profile whose parent prompt `parent` holds byte for byte, or None."""
    from ._install import _parent_source

    on_disk = parent.read_bytes()
    for profile in ("frontier", "weak"):
        src = _parent_source(parent_file, profile)
        if src.is_file() and src.read_bytes() == on_disk:
            return profile
    return None


def _refresh_plan() -> tuple[dict, list[Path]]:
    """(the refresh plan, parent prompts left alone). Must run before the
    upgrade: it reads THIS version's bundled content. See the module docstring;
    the plan's shape is _install.load_refresh_plan's."""
    from ._install import _PLAN_VERSION, _TOOLS, _skill_names, _tool_paths
    from ._shell import _stage_shell_files
    from ._uninstall import _den_free_skills

    names = _skill_names()
    den_free = _den_free_skills()
    owned: set[Path] = set()
    skills: list[dict] = []
    parents: list[dict] = []
    left_alone: list[Path] = []
    seen: set[Path] = set()
    for tool in _TOOLS:
        target, parent_dir, parent_file = _tool_paths(tool)
        if target not in seen:
            seen.add(target)
            scanned = _scan_skills(target, names, den_free)
            if scanned is not None:
                skills.append(scanned[0])
                owned |= scanned[1]
        parent = parent_dir / parent_file
        if parent in seen or not parent.is_file():
            continue
        seen.add(parent)
        profile = _parent_profile(parent, parent_file)
        if profile is None:
            left_alone.append(parent)
            continue
        parents.append({"path": str(parent), "file": parent_file, "profile": profile})
        owned.add(parent)
    shell = _Matcher()
    _stage_shell_files(
        shell, extras=True, dry_run=False, announce=False, posix_bin=True
    )
    owned |= shell.matched
    plan = {
        "den_refresh_plan": _PLAN_VERSION,
        "known_skills": names,
        "skills": skills,
        "parents": parents,
        "shell": bool(shell.matched),
        "owned": sorted(str(p) for p in owned),
    }
    return plan, left_alone


def _refresh_steps(plan: dict, plan_file: str, *, force: bool) -> list[tuple[str, ...]]:
    """The redeploy commands for the new den: skills (and parents) when den's
    were found anywhere, shell when den's shell files were. --force also
    replaces the files the plan does not prove are den's, each backed up to
    <file>.den.bak first."""
    extra = ("--force",) if force else ()
    steps: list[tuple[str, ...]] = []
    if plan["skills"] or plan["parents"]:
        steps.append(("install", "skills", "--refresh-plan", plan_file, *extra))
    if plan["shell"]:
        steps.append(("install", "shell", "--refresh-plan", plan_file, *extra))
    return steps


def _describe(plan: dict, left_alone: list[Path], prefix: str) -> None:
    """What the refresh will touch, one line each."""
    for entry in plan["skills"]:
        print(f"{prefix}skills in {entry['target']} ({len(entry['names'])} found)")
    for entry in plan["parents"]:
        print(f"{prefix}parent {entry['path']} ({entry['profile']})")
    if plan["shell"]:
        print(f"{prefix}the shell files")
    if not plan["skills"] and not plan["parents"] and not plan["shell"]:
        print(f"{prefix}nothing: no deployed den skills, parent or shell files found")
    for parent in left_alone:
        print(
            f"{prefix}not {parent}: it matches neither parent den deploys"
            " (hand-written or edited), so it is left alone"
        )


def _usage() -> None:
    print(
        "usage: den upgrade [--refresh] [--force] [--dry-run]"
        "   (alias: den update)\n"
        "\n"
        "Upgrade den itself (runs `uv tool upgrade den`).\n"
        "\n"
        "  --refresh  after upgrading, redeploy with the new binary: the skills\n"
        "             in every tool dir that has den's, the parent prompts den\n"
        "             deployed (in the same profile), and the shell files. Only\n"
        "             files still exactly as the old version deployed them are\n"
        "             replaced; edited ones are kept and listed, and a parent\n"
        "             prompt den did not deploy is never touched.\n"
        "  --force    also replace the kept files, copying each to\n"
        "             <file>.den.bak first\n"
        "  --dry-run  print what would be refreshed without running anything"
    )


def main(  # ruff: ignore[too-many-return-statements, too-many-branches]  # flag parse plus one exit per failure mode
    argv: list[str] | None = None,
) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if args and args[0] in {"-h", "--help", "help"}:
        _usage()
        return 0
    refresh = dry_run = force = False
    for a in args:
        if a == "--refresh":
            refresh = True
        elif a == "--force":
            force = True
        elif a == "--dry-run":
            dry_run = True
        else:
            print(f"den upgrade: unknown argument '{a}'", file=sys.stderr)
            return 2
    if force and not refresh:
        print(
            "den upgrade: --force only applies to --refresh; nothing is"
            " redeployed without it.",
            file=sys.stderr,
        )

    uv, refusal = resolve_tool("uv")
    if refusal:
        print(
            f"den upgrade: {refusal}; run den upgrade from another directory.",
            file=sys.stderr,
        )
        return 1
    if uv is None:
        print(
            "den upgrade: uv not found on PATH. den is installed as a uv tool;"
            " install uv (https://docs.astral.sh/uv/) and retry.",
            file=sys.stderr,
        )
        return 1

    # Before the upgrade: only this process can tell which deployed files are
    # its own (it reads the bundled content uv is about to replace).
    plan: dict = {}
    left_alone: list[Path] = []
    if refresh:
        try:
            plan, left_alone = _refresh_plan()
        except (OSError, ValueError) as exc:
            print(f"den upgrade: cannot plan the refresh: {exc}", file=sys.stderr)
            return 1

    upgrade_args = ["tool", "upgrade", "den"]
    if dry_run:
        print(f"[dry-run] would run: uv {' '.join(upgrade_args)}")
        if refresh:
            _describe(plan, left_alone, "[dry-run] would refresh: ")
            for step in _refresh_steps(plan, "<plan>", force=force):
                print(f"[dry-run] would run: den {' '.join(step)}")
        return 0

    proc = subprocess.run([uv, *upgrade_args])
    if proc.returncode != 0:
        if _windows():
            # this process runs from the tool venv uv is replacing; Windows
            # locks running executables, POSIX does not care
            print(
                "hint: if uv reported a file-in-use error, the running den"
                " process was locking its own install; run"
                " `uv tool upgrade den` directly instead.",
                file=sys.stderr,
            )
        return proc.returncode

    if not refresh:
        print(
            "note: bundled content (skills, shell, cheatsheets) is only"
            " redeployed by `den install ...`; run `den upgrade --refresh`"
            " (or the install commands yourself) to deploy the new"
            " version's files."
        )
        return 0

    # The upgraded code and bundled data exist only in the new binary; this
    # process still runs the old package, so redeploy via subprocesses.
    den = _upgraded_den(uv)
    if not den:
        print(
            "den upgrade: `den` not found on PATH after the upgrade; redeploy"
            " manually with `den install skills` and `den install shell`.",
            file=sys.stderr,
        )
        return 1
    return _run_refresh(den, plan, left_alone, force=force)


def _run_refresh(den: str, plan: dict, left_alone: list[Path], *, force: bool) -> int:
    """Hand the plan to the upgraded `den` and run its redeploy steps. Only
    stdlib from here on: the den package on disk is the NEW version now, and an
    import would mix it into this old process."""
    with tempfile.TemporaryDirectory(prefix="den-refresh-") as td:
        plan_file = Path(td) / "plan.json"
        plan_file.write_text(json.dumps(plan), encoding="utf-8")
        steps = _refresh_steps(plan, str(plan_file), force=force)
        if not steps:
            print("den upgrade: nothing to refresh (no deployed den files found)")
        for step in steps:
            proc = subprocess.run([den, *step])
            if proc.returncode != 0:
                # Not "nothing was deployed": a step fails after deploying what
                # it could, and a later step fails only after every earlier one
                # already succeeded.
                print(
                    f"den upgrade: `den {' '.join(step[:2])}` exited"
                    f" {proc.returncode}; the refresh did not complete. Some"
                    " files may already be deployed.",
                    file=sys.stderr,
                )
                return proc.returncode
    for parent in left_alone:
        print(
            f"den upgrade: left {parent} alone: it matches neither parent den"
            " deploys (hand-written or edited)",
            file=sys.stderr,
        )
    return 0
