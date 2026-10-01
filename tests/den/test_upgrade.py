"""Tests for den upgrade (den/_upgrade.py)."""

import os
from collections.abc import Callable
from pathlib import Path

import pytest

from den import _upgrade
from den._upgrade import main as upgrade_main
from den.cli import main as cli_main


class _Proc:
    def __init__(self, rc: int = 0, out: str = ""):
        self.returncode = rc
        self.stdout = out


def _tool(name: str) -> str:
    """Where the fake which() finds a tool on PATH: absolute, outside any cwd.

    Built from the cwd's anchor so it is a real absolute path on POSIX and on
    Windows alike (a "/usr/bin/x" literal is drive-relative on Windows).
    """
    return str(Path(Path.cwd().anchor) / "den-tools" / name)


# What `uv tool dir --bin` reports: where `uv tool upgrade` put the new den.
_BIN = Path(Path.cwd().anchor) / "uv-tool-bin"


# A plan that finds den's skills, a parent and the shell files, so both redeploy
# steps run; the plan builder itself is exercised by the end-to-end tests below.
_PLAN = {
    "den_refresh_plan": 1,
    "known_skills": ["coding"],
    "skills": [{"target": "/x/skills", "names": ["coding"], "no_den_cli": False}],
    "parents": [],
    "shell": True,
    "shell_extras": True,
    "shell_bin": False,
    "owned": {},
    "absent": [],
}


def _step(call: list[str], what: str, *, force: bool = False) -> bool:
    """True when `call` is the new den's `install <what> --refresh-plan FILE`."""
    tail = ["--force"] if force else []
    return (
        call[0] == str(_BIN / "den")
        and call[1:4] == ["install", what, "--refresh-plan"]
        and call[4].endswith("plan.json")
        and call[5:] == tail
    )


def _wire(monkeypatch, rcs: dict[int, int] | None = None, have=("uv", "den")):
    """Mock which/run; rcs maps call index -> returncode (default 0).

    `uv tool dir --bin` is answered with _BIN and kept out of `calls`, so the
    indices count the upgrade and the redeploy steps only.
    """
    calls: list[list[str]] = []
    monkeypatch.setattr(_upgrade, "_refresh_plan", lambda: (dict(_PLAN), []))

    def _which(name, path=None):
        if name not in have:
            return None
        return str(_BIN / name) if path == str(_BIN) else _tool(name)

    monkeypatch.setattr("den._exe.shutil.which", _which)

    def _run(cmd, **k):
        if cmd[1:] == ["tool", "dir", "--bin"]:
            return _Proc(0, f"{_BIN}\n")
        calls.append(cmd)
        return _Proc((rcs or {}).get(len(calls) - 1, 0))

    monkeypatch.setattr(_upgrade.subprocess, "run", _run)
    return calls


def test_upgrade_runs_uv_tool_upgrade(monkeypatch, capsys):
    calls = _wire(monkeypatch)
    assert upgrade_main([]) == 0
    assert calls == [[_tool("uv"), "tool", "upgrade", "den"]]
    assert "den upgrade --refresh" in capsys.readouterr().out  # redeploy hint


def test_refresh_redeploys_via_new_binary(monkeypatch):
    calls = _wire(monkeypatch)
    assert upgrade_main(["--refresh"]) == 0
    assert calls[0] == [_tool("uv"), "tool", "upgrade", "den"]
    # subprocesses of the upgraded binary, never the old in-process code
    assert _step(calls[1], "skills")
    assert _step(calls[2], "shell")


def test_refresh_force_is_forwarded_to_both_steps(monkeypatch):
    calls = _wire(monkeypatch)
    assert upgrade_main(["--refresh", "--force"]) == 0
    assert _step(calls[1], "skills", force=True)
    assert _step(calls[2], "shell", force=True)


def test_refresh_plan_is_made_before_the_upgrade(monkeypatch):
    # It reads THIS den's bundled content, which `uv tool upgrade` replaces.
    calls = _wire(monkeypatch)
    order: list[str] = []
    monkeypatch.setattr(
        _upgrade, "_refresh_plan", lambda: order.append("plan") or (dict(_PLAN), [])
    )
    real_run = _upgrade.subprocess.run

    def _run(cmd, **k):
        if cmd[1:] == ["tool", "upgrade", "den"]:
            order.append("upgrade")
        return real_run(cmd, **k)

    monkeypatch.setattr(_upgrade.subprocess, "run", _run)
    assert upgrade_main(["--refresh"]) == 0
    assert order == ["plan", "upgrade"]
    assert len(calls) == 3


def test_refresh_skips_what_den_never_deployed(monkeypatch, capsys):
    calls = _wire(monkeypatch)
    empty = dict(_PLAN, skills=[], shell=False)
    monkeypatch.setattr(_upgrade, "_refresh_plan", lambda: (empty, []))
    assert upgrade_main(["--refresh"]) == 0
    assert calls == [[_tool("uv"), "tool", "upgrade", "den"]]
    assert "nothing to refresh" in capsys.readouterr().out


def test_force_without_refresh_says_it_does_nothing(monkeypatch, capsys):
    calls = _wire(monkeypatch)
    assert upgrade_main(["--force"]) == 0
    assert calls == [[_tool("uv"), "tool", "upgrade", "den"]]  # nothing redeployed
    assert "--force only applies to --refresh" in capsys.readouterr().err


def test_dry_run_shows_the_forced_steps(monkeypatch, capsys):
    calls = _wire(monkeypatch)
    assert upgrade_main(["--dry-run", "--refresh", "--force"]) == 0
    assert calls == []
    out = capsys.readouterr().out
    assert "den install skills --refresh-plan <plan> --force" in out
    assert "den install shell --refresh-plan <plan> --force" in out
    assert "would refresh skills in /x/skills" in out
    assert "shell files (with the extras, without the ~/.local/bin helpers)" in out


def test_refresh_step_failure_is_reported(monkeypatch, capsys):
    calls = _wire(monkeypatch, rcs={1: 1})
    assert upgrade_main(["--refresh"]) == 1
    assert len(calls) == 2
    err = capsys.readouterr().err
    # The step deployed what it could, and any earlier step fully succeeded, so
    # "nothing was deployed" would be false.
    assert "did not complete" in err
    assert "may already be deployed" in err
    assert "NOT deployed" not in err


def test_failed_upgrade_skips_refresh_and_propagates(monkeypatch):
    calls = _wire(monkeypatch, rcs={0: 3})
    assert upgrade_main(["--refresh"]) == 3
    assert len(calls) == 1


def test_failed_refresh_step_stops_and_propagates(monkeypatch):
    calls = _wire(monkeypatch, rcs={1: 2})
    assert upgrade_main(["--refresh"]) == 2
    assert len(calls) == 2  # shell step not attempted after skills failed


def test_no_uv_errors_with_hint(monkeypatch, capsys):
    calls = _wire(monkeypatch, have=())
    assert upgrade_main([]) == 1
    assert calls == []
    assert "uv not found" in capsys.readouterr().err


def test_den_missing_after_upgrade_errors(monkeypatch, capsys):
    calls = _wire(monkeypatch, have=("uv",))
    assert upgrade_main(["--refresh"]) == 1
    assert calls == [
        [_tool("uv"), "tool", "upgrade", "den"]
    ]  # upgrade ran; refresh could not
    assert "manually" in capsys.readouterr().err


# ---- tool resolution (never from the working directory, never by bare name) ----


def test_uv_and_den_run_by_absolute_path(monkeypatch):
    """argv[0] is always a resolved absolute path, so CreateProcess does no
    search of its own (it would look in the current directory first)."""
    calls = _wire(monkeypatch)
    assert upgrade_main(["--refresh"]) == 0
    assert [Path(c[0]).is_absolute() for c in calls] == [True, True, True]


def test_uv_in_the_working_directory_is_refused(tmp_path, monkeypatch, capsys):
    """A checkout shipping uv(.exe) at its root: what Windows' which() and
    CreateProcess find first. It is refused, never run."""
    monkeypatch.chdir(tmp_path)
    # Windows: the OS whose which() and CreateProcess search the cwd
    monkeypatch.setattr("den._exe._windows", lambda: True)
    calls = _wire(monkeypatch)
    monkeypatch.setattr(
        "den._exe.shutil.which", lambda name, path=None: str(tmp_path / name)
    )
    assert upgrade_main(["--refresh"]) == 1
    assert calls == []
    err = capsys.readouterr().err
    assert f"refusing uv resolved inside the workspace ({tmp_path / 'uv'})" in err


def test_refresh_runs_the_den_uv_just_upgraded(monkeypatch):
    """The redeploy runs the den in uv's tool bin dir, not whichever den PATH
    happens to name first (a project venv's, or a planted one)."""
    calls = _wire(monkeypatch)
    assert upgrade_main(["--refresh"]) == 0
    assert calls[1][0] == str(_BIN / "den")
    assert calls[1][0] != _tool("den")


def test_uv_in_the_working_directory_runs_on_posix(tmp_path, monkeypatch):
    """POSIX never searches the cwd, so a uv there came from an absolute PATH
    entry (den upgrade run from ~/.local/bin): it is the uv PATH names and it
    runs. Refusing it broke den upgrade there for no gain."""
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr("den._exe._windows", lambda: False)
    calls = _wire(monkeypatch)
    monkeypatch.setattr(
        "den._exe.shutil.which", lambda name, path=None: str(tmp_path / name)
    )
    assert upgrade_main([]) == 0
    assert calls == [[str(tmp_path / "uv"), "tool", "upgrade", "den"]]


def test_refresh_refuses_a_den_in_the_working_directory(tmp_path, monkeypatch, capsys):
    """A den.cmd committed at the repo root (plain text, trivially shipped) is
    what a cwd-first which("den") used to hand the redeploy."""
    monkeypatch.chdir(tmp_path)
    # Windows: the OS whose which() and CreateProcess search the cwd
    monkeypatch.setattr("den._exe._windows", lambda: True)
    calls = _wire(monkeypatch)

    def _which(name, path=None):
        return str(tmp_path / name) if name == "den" else _tool(name)

    monkeypatch.setattr("den._exe.shutil.which", _which)
    assert upgrade_main(["--refresh"]) == 1
    assert calls == [[_tool("uv"), "tool", "upgrade", "den"]]  # no den was run
    err = capsys.readouterr().err
    assert "refusing den resolved inside the workspace" in err
    assert "manually" in err


def test_refresh_falls_back_to_path_when_uv_cannot_name_its_bin_dir(monkeypatch):
    calls = _wire(monkeypatch)
    real_run = _upgrade.subprocess.run

    def _run(cmd, **k):
        if cmd[1:] == ["tool", "dir", "--bin"]:
            return _Proc(2, "")  # an old uv without --bin
        return real_run(cmd, **k)

    monkeypatch.setattr(_upgrade.subprocess, "run", _run)
    assert upgrade_main(["--refresh"]) == 0
    assert calls[1][0] == _tool("den")


def test_windows_lock_hint_on_failed_upgrade(monkeypatch, capsys):
    _wire(monkeypatch, rcs={0: 1})
    monkeypatch.setattr(_upgrade, "_windows", lambda: True)
    assert upgrade_main([]) == 1
    assert "file-in-use" in capsys.readouterr().err


def test_no_lock_hint_on_posix(monkeypatch, capsys):
    _wire(monkeypatch, rcs={0: 1})
    monkeypatch.setattr(_upgrade, "_windows", lambda: False)
    assert upgrade_main([]) == 1
    assert "file-in-use" not in capsys.readouterr().err


def test_dry_run_runs_nothing(monkeypatch, capsys):
    calls = _wire(monkeypatch)
    assert upgrade_main(["--dry-run", "--refresh"]) == 0
    assert calls == []
    out = capsys.readouterr().out
    assert "uv tool upgrade den" in out and "install skills" in out


def test_usage_and_unknown_arg(capsys):
    assert upgrade_main(["--help"]) == 0
    assert "usage: den upgrade" in capsys.readouterr().out
    assert upgrade_main(["--bogus"]) == 2
    assert "unknown argument" in capsys.readouterr().err


def test_cli_dispatches_upgrade_and_update_alias(monkeypatch):
    seen: list[list[str]] = []
    monkeypatch.setattr(_upgrade, "main", lambda argv: seen.append(argv) or 0)
    assert cli_main(["upgrade", "--dry-run"]) == 0
    assert cli_main(["update", "--dry-run"]) == 0
    assert seen == [["--dry-run"], ["--dry-run"]]


def test_cli_help_lists_upgrade(capsys):
    cli_main(["--help"])
    assert "upgrade" in capsys.readouterr().out


# ---- end to end: what a refresh may replace (decided by the den before the
# upgrade) and what it must leave alone ----

_REPO = Path(__file__).resolve().parents[2]
_HAND_WRITTEN = "# my own global rules\n"


def _new_version(tmp_path: Path, *, with_shell: bool = False) -> Path:
    """A bundled-content root for "the next den version": a copy of this one
    with a changed skill file, changed parents and, optionally, shell files."""
    import shutil

    root = tmp_path / "next-den"
    skip = shutil.ignore_patterns("__pycache__", "*.pyc")
    shutil.copytree(_REPO / "agents" / "src", root / "agents" / "src", ignore=skip)
    shutil.copytree(
        _REPO / "agents" / "dist" / "parents", root / "agents" / "dist" / "parents"
    )
    for rel in (
        "agents/src/skills/coding/SKILL.md",
        "agents/src/skills/grounding/SKILL.md",
        "agents/dist/parents/CLAUDE.md",
        "agents/dist/parents/AGENTS.md",
        "agents/dist/parents/weak/AGENTS.md",
    ):
        with (root / rel).open("a", encoding="utf-8") as fh:
            fh.write("\nNEXT VERSION\n")
    new_skill = root / "agents" / "src" / "skills" / "brand-new"
    new_skill.mkdir()
    (new_skill / "SKILL.md").write_text("---\nname: brand-new\n---\nNEW SKILL\n")
    if with_shell:
        shutil.copytree(_REPO / "shell", root / "shell", ignore=skip)
        for rel in (
            "shell/posix/aliases.sh",
            "shell/posix/functions.sh",
            "shell/posix/bin/fixids",
        ):
            with (root / rel).open("a", encoding="utf-8") as fh:
                fh.write("\n# NEXT VERSION\n")
    return root


def _upgrade_to(
    monkeypatch, new_root: Path, during: Callable[[], None] | None = None
) -> list[list[str]]:
    """Run den upgrade with uv faked: `uv tool upgrade den` swaps the bundled
    content for `new_root` (after calling `during`, what the user does while uv
    runs), and the upgraded den runs in-process on it."""
    from den import _content

    calls: list[list[str]] = []

    def _which(name, path=None):
        return str(_BIN / name) if path == str(_BIN) else _tool(name)

    monkeypatch.setattr("den._exe.shutil.which", _which)

    def _run(cmd, **k):
        if cmd[1:] == ["tool", "dir", "--bin"]:
            return _Proc(0, f"{_BIN}\n")
        calls.append(cmd)
        if cmd[1:] == ["tool", "upgrade", "den"]:
            if during is not None:
                during()
            monkeypatch.setattr(_content, "content_root", lambda: new_root)
            return _Proc(0)
        return _Proc(cli_main(cmd[1:]))

    monkeypatch.setattr(_upgrade.subprocess, "run", _run)
    return calls


def _deploy_like_a_user(monkeypatch) -> Path:
    """Skills for claude (no parent: a hand-written CLAUDE.md instead), and
    skills plus the weak parent for copilot, one of whose files the user
    edited. Nothing in ~/.agents."""
    from den._install import main as install_main

    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    home = Path.home()
    assert install_main(["skills", "--tool", "claude"]) == 0
    (home / ".claude" / "CLAUDE.md").write_text(_HAND_WRITTEN)
    flags = ["skills", "--tool", "copilot", "--with-parent", "--profile", "weak"]
    assert install_main(flags) == 0
    edited = home / ".copilot" / "skills" / "coding" / "SKILL.md"
    edited.write_text(edited.read_text() + "\nMY LOCAL EDIT\n")
    return edited


def test_refresh_replaces_only_what_den_wrote(tmp_path, monkeypatch, capsys):
    """The finding: `den upgrade --refresh` always ran `install skills
    --with-parent` into ~/.claude and ~/.agents with the frontier profile."""
    edited = _deploy_like_a_user(monkeypatch)
    home = Path.home()
    calls = _upgrade_to(monkeypatch, _new_version(tmp_path))
    assert upgrade_main(["--refresh"]) == 0
    assert len(calls) == 2, "no shell step: den's shell was never deployed"

    assert (home / ".claude" / "CLAUDE.md").read_text() == _HAND_WRITTEN
    for target in (home / ".claude" / "skills", home / ".copilot" / "skills"):
        assert "NEXT VERSION" in (target / "grounding" / "SKILL.md").read_text()
        assert "NEW SKILL" in (target / "brand-new" / "SKILL.md").read_text()
    parent = (home / ".copilot" / "copilot-instructions.md").read_text()
    assert "<skill_catalog>" in parent and "NEXT VERSION" in parent, "still weak"
    assert "MY LOCAL EDIT" in edited.read_text()
    assert "NEXT VERSION" not in edited.read_text()
    assert not (home / ".agents").exists(), "no skills were ever deployed there"
    assert not list(home.rglob("*.den.bak"))
    out = capsys.readouterr()
    listing = (out.out + out.err).replace("\n", "")  # rich wraps long paths
    assert str(edited) in listing, "the kept file is listed"
    assert "CLAUDE.md alone" in out.err


def test_refresh_force_backs_up_what_it_replaces(tmp_path, monkeypatch):
    edited = _deploy_like_a_user(monkeypatch)
    home = Path.home()
    _upgrade_to(monkeypatch, _new_version(tmp_path))
    assert upgrade_main(["--refresh", "--force"]) == 0
    assert "NEXT VERSION" in edited.read_text()
    backup = edited.with_name("SKILL.md.den.bak")
    assert "MY LOCAL EDIT" in backup.read_text()
    # a parent den cannot prove it wrote is not touched, not even by --force
    assert (home / ".claude" / "CLAUDE.md").read_text() == _HAND_WRITTEN
    backups = sorted(p.relative_to(home) for p in home.rglob("*.den.bak"))
    assert backups == [backup.relative_to(home)], "den's own files need no backup"


def test_refresh_force_leaves_an_edited_den_parent_alone(tmp_path, monkeypatch, capsys):
    """--force replaces kept skill and shell files, never a parent prompt: an
    edited one matches neither profile, so the plan does not name it."""
    _deploy_like_a_user(monkeypatch)
    parent = Path.home() / ".copilot" / "copilot-instructions.md"
    parent.write_text(parent.read_text() + "\nMY EDIT TO THE DEN PARENT\n")
    before = parent.read_bytes()
    _upgrade_to(monkeypatch, _new_version(tmp_path))
    assert upgrade_main(["--refresh", "--force"]) == 0
    assert parent.read_bytes() == before
    assert not parent.with_name(parent.name + ".den.bak").exists()
    assert "copilot-instructions.md alone" in capsys.readouterr().err.replace("\n", "")
    capsys.readouterr()
    assert upgrade_main(["--help"]) == 0
    usage = " ".join(capsys.readouterr().out.split())
    assert "--force also replace the kept skill and shell files" in usage
    assert "never a parent prompt" in usage


def _edit_while_uv_runs() -> tuple[Path, Path, Callable[[], None]]:
    """(a skill file, the parent prompt, what edits both): files the plan
    proves are den's when it is made, edited before the new den writes."""
    home = Path.home()
    skill = home / ".claude" / "skills" / "grounding" / "SKILL.md"
    parent = home / ".copilot" / "copilot-instructions.md"

    def edit() -> None:
        for path in (skill, parent):
            path.write_text(path.read_text() + "\nEDITED DURING THE UPGRADE\n")

    return skill, parent, edit


def test_refresh_keeps_an_edit_made_while_uv_runs(tmp_path, monkeypatch, capsys):
    """The plan named den's files by path only: one edited while `uv tool
    upgrade` ran was replaced as den's, and the edit was lost without a backup."""
    _deploy_like_a_user(monkeypatch)
    skill, parent, edit = _edit_while_uv_runs()
    _upgrade_to(monkeypatch, _new_version(tmp_path), during=edit)
    assert upgrade_main(["--refresh"]) == 0
    for path in (skill, parent):
        assert "EDITED DURING THE UPGRADE" in path.read_text()
        assert "NEXT VERSION" not in path.read_text()
    out = capsys.readouterr()
    listing = (out.out + out.err).replace("\n", "")  # rich wraps long paths
    assert str(skill) in listing and str(parent) in listing


def test_refresh_force_backs_up_an_edit_made_while_uv_runs(
    tmp_path, monkeypatch, capsys
):
    _deploy_like_a_user(monkeypatch)
    skill, parent, edit = _edit_while_uv_runs()
    _upgrade_to(monkeypatch, _new_version(tmp_path), during=edit)
    assert upgrade_main(["--refresh", "--force"]) == 0
    assert "NEXT VERSION" in skill.read_text()
    backup = skill.with_name("SKILL.md.den.bak")
    assert "EDITED DURING THE UPGRADE" in backup.read_text()
    # still never a parent prompt: --force does not replace an edited one
    assert "EDITED DURING THE UPGRADE" in parent.read_text()
    assert "NEXT VERSION" not in parent.read_text()
    assert not parent.with_name(parent.name + ".den.bak").exists()
    out = capsys.readouterr()
    listing = " ".join((out.out + out.err).split())
    assert "never replaced, not even with --force" in listing


def test_refresh_keeps_the_no_den_cli_flavor_and_deleted_skills(tmp_path, monkeypatch):
    import shutil

    from den._install import main as install_main
    from den._portable import table

    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    assert install_main(["skills", "--tool", "claude", "--no-den-cli"]) == 0
    skills = Path.home() / ".claude" / "skills"
    shutil.rmtree(skills / "compressor")  # the user does not want this one
    _upgrade_to(monkeypatch, _new_version(tmp_path))
    assert upgrade_main(["--refresh"]) == 0
    assert not (skills / "compressor").exists(), "a deleted skill stays deleted"
    assert (skills / "brand-new" / "SKILL.md").is_file(), "a new skill arrives"
    den_free = sorted(table())
    coding = (skills / "coding" / "SKILL.md").read_text()
    assert "coding" in den_free and "den verify" not in coding
    assert "NEXT VERSION" in coding


def _next_with_a_new_example(tmp_path: Path) -> Path:
    """The next version, with a file added to a skill that already exists."""
    root = _new_version(tmp_path)
    examples = root / "agents" / "src" / "skills" / "coding" / "examples"
    (examples / "zig.md").write_text("NEW EXAMPLE\n")
    return root


def test_refresh_leaves_a_deleted_skill_file_deleted(tmp_path, monkeypatch, capsys):
    """The refresh restaged every file of each skill it kept, so one file the
    user deleted (not the whole skill) came back."""
    _deploy_like_a_user(monkeypatch)
    examples = Path.home() / ".claude" / "skills" / "coding" / "examples"
    (examples / "rust.md").unlink()
    meanwhile = (examples / "python.md").unlink  # den's when the plan was made
    _upgrade_to(monkeypatch, _next_with_a_new_example(tmp_path), during=meanwhile)
    assert upgrade_main(["--refresh"]) == 0
    assert not (examples / "rust.md").exists()
    assert not (examples / "python.md").exists()
    assert (examples / "zig.md").read_text() == "NEW EXAMPLE\n", "a new file arrives"
    assert "NEXT VERSION" in (examples.parent / "SKILL.md").read_text()
    out = capsys.readouterr()
    assert str(examples / "rust.md") in (out.out + out.err).replace("\n", "")


def test_refresh_force_recreates_a_deleted_skill_file(tmp_path, monkeypatch):
    _deploy_like_a_user(monkeypatch)
    rust = Path.home() / ".claude" / "skills" / "coding" / "examples" / "rust.md"
    rust.unlink()
    _upgrade_to(monkeypatch, _next_with_a_new_example(tmp_path))
    assert upgrade_main(["--refresh", "--force"]) == 0
    assert rust.is_file()
    assert not list(rust.parent.glob("*.den.bak*")), "nothing there to back up"


@pytest.mark.skipif(os.name == "nt", reason="deploys the POSIX shell files")
def test_refresh_leaves_a_deleted_shell_file_deleted(tmp_path, monkeypatch, capsys):
    from den._install import main as install_main

    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setattr("den._shell._windows", lambda: False)
    assert install_main(["shell"]) == 0
    shell = Path.home() / ".config" / "shell"
    (shell / "proxy.sh").unlink()  # one of the extras, not wanted
    _upgrade_to(monkeypatch, _new_version(tmp_path, with_shell=True))
    assert upgrade_main(["--refresh"]) == 0
    assert "# NEXT VERSION" in (shell / "functions.sh").read_text()
    assert (shell / "python.sh").is_file(), "the other extras are refreshed"
    assert not (shell / "proxy.sh").exists()
    out = capsys.readouterr()
    assert str(shell / "proxy.sh") in (out.out + out.err).replace("\n", "")


@pytest.mark.skipif(os.name == "nt", reason="deploys the POSIX shell files")
def test_refresh_replaces_unedited_shell_files_only(tmp_path, monkeypatch):
    from den._install import main as install_main

    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setattr("den._shell._windows", lambda: False)
    assert install_main(["shell"]) == 0
    shell = Path.home() / ".config" / "shell"
    (shell / "aliases.sh").write_text("# my aliases\n")
    calls = _upgrade_to(monkeypatch, _new_version(tmp_path, with_shell=True))
    assert upgrade_main(["--refresh"]) == 0
    assert [c[1:3] for c in calls[1:]] == [["install", "shell"]], "no skills step"
    assert "# NEXT VERSION" in (shell / "functions.sh").read_text()
    assert (shell / "aliases.sh").read_text() == "# my aliases\n"


@pytest.mark.skipif(os.name == "nt", reason="deploys the POSIX shell files")
def test_refresh_keeps_a_no_extras_shell_install_as_it_was(tmp_path, monkeypatch):
    """The refresh ran a plain `install shell`, which created every extras file
    a --no-extras install had left out."""
    from den._install import main as install_main

    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setattr("den._shell._windows", lambda: False)
    assert install_main(["shell", "--no-extras", "--no-bin"]) == 0
    home = Path.home()
    shell = home / ".config" / "shell"
    before = sorted(p.name for p in shell.iterdir())
    assert "python.sh" not in before
    _upgrade_to(monkeypatch, _new_version(tmp_path, with_shell=True))
    assert upgrade_main(["--refresh"]) == 0
    assert "# NEXT VERSION" in (shell / "functions.sh").read_text()
    assert sorted(p.name for p in shell.iterdir()) == before
    assert not (home / ".local" / "bin" / "fixids").exists()


@pytest.mark.skipif(os.name == "nt", reason="deploys the POSIX shell files")
def test_refresh_refreshes_the_posix_helpers_den_deployed(tmp_path, monkeypatch):
    """The refresh never passed --bin, and without a terminal that meant no
    ~/.local/bin helpers: den's own copies stayed on the old version."""
    from den._install import main as install_main

    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setattr("den._shell._windows", lambda: False)
    assert install_main(["shell", "--bin"]) == 0
    fixids = Path.home() / ".local" / "bin" / "fixids"
    assert fixids.is_file()
    _upgrade_to(monkeypatch, _new_version(tmp_path, with_shell=True))
    assert upgrade_main(["--refresh"]) == 0
    assert "# NEXT VERSION" in fixids.read_text()
    assert fixids.stat().st_mode & 0o111
    assert (Path.home() / ".config" / "shell" / "python.sh").is_file()


@pytest.mark.parametrize("refresh", [True, False], ids=["refresh", "install"])
def test_a_file_edited_after_the_check_is_kept(tmp_path, monkeypatch, capsys, refresh):
    """Only what was checked (den's, or listed and approved) is replaced: an
    edit landing between the check and the write is kept, not overwritten."""
    import hashlib

    from den import _install

    # Bytes, not text: write_text writes "\r\n" on Windows, which the
    # byte-for-byte check rightly calls an edit.
    ours, edited = tmp_path / "ours.md", tmp_path / "edited.md"
    for path in (ours, edited):
        path.write_bytes(b"OLD\n")
    digest = hashlib.sha256(b"OLD\n").hexdigest()
    owned = {ours: digest, edited: digest} if refresh else None
    writer = _install._Writer(force=False, owned=owned)
    writer.stage(ours, b"NEW\n")
    writer.stage(edited, b"NEW\n")
    if not refresh:  # an install over identical files lists nothing
        ours.write_bytes(b"NEW\n")
        edited.write_bytes(b"NEW\n")
    real_ask = _install._Writer._ask

    def ask_then_edit(self, changed):
        answer = real_ask(self, changed)
        edited.write_bytes(b"MINE\n")
        return answer

    monkeypatch.setattr(_install._Writer, "_ask", ask_then_edit)
    assert writer.commit() == (0 if refresh else 1)
    assert ours.read_text() == "NEW\n"
    assert edited.read_text() == "MINE\n"
    assert f"kept {edited}: it changed after den checked it" in capsys.readouterr().err


def test_install_force_backs_up_a_file_it_overwrites(tmp_path, monkeypatch):
    from den._install import main as install_main

    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    assert install_main(["skills", "--target", str(tmp_path)]) == 0
    skill = tmp_path / "skills" / "coding" / "SKILL.md"
    skill.write_text("MINE\n")
    assert install_main(["skills", "--target", str(tmp_path), "--force"]) == 0
    assert skill.read_text() != "MINE\n"
    assert skill.with_name("SKILL.md.den.bak").read_text() == "MINE\n"


def _skill_install(where: str, tmp_path: Path) -> tuple[list[str], Path]:
    """(install skills args, the coding SKILL.md they deploy) for a confined
    --target workspace or for a tool dir under the home."""
    if where == "target":
        return ["skills", "--target", str(tmp_path)], tmp_path / "skills"
    return ["skills", "--tool", "claude"], Path.home() / ".claude" / "skills"


@pytest.mark.parametrize("where", ["target", "tool"])
def test_install_force_never_replaces_an_earlier_backup(
    tmp_path, monkeypatch, capsys, where
):
    """The first --force saved the user's edit; a later one (after an upgrade,
    the file holds den's previous content) must not back that up over it."""
    from den._install import main as install_main

    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    args, skills = _skill_install(where, tmp_path)
    assert install_main(args) == 0
    skill = skills / "coding" / "SKILL.md"
    deployed = skill.read_text()
    skill.write_text("MINE\n")
    assert install_main([*args, "--force"]) == 0
    skill.write_text("den's content from an older version\n")
    capsys.readouterr()
    assert install_main([*args, "--force"]) == 0
    assert skill.read_text() == deployed
    assert skill.with_name("SKILL.md.den.bak").read_text() == "MINE\n"
    second = skill.with_name("SKILL.md.den.bak.1")
    assert second.read_text() == "den's content from an older version\n"
    assert "SKILL.md.den.bak.1" in capsys.readouterr().err
    # the same content again reuses the backup that already holds it
    skill.write_text("MINE\n")
    assert install_main([*args, "--force"]) == 0
    assert not skill.with_name("SKILL.md.den.bak.2").exists()


@pytest.mark.skipif(os.name == "nt", reason="POSIX permission bits")
@pytest.mark.parametrize("where", ["target", "tool"])
@pytest.mark.parametrize(
    ("mode", "want"), [(0o600, 0o600), (0o755, 0o644)], ids=["private", "script"]
)
def test_install_force_backup_keeps_the_files_permissions(
    tmp_path, monkeypatch, mode, want, where
):
    """A private file's backup must not be world-readable, and a backed-up
    script must not stay executable."""
    from den._install import main as install_main

    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    args, skills = _skill_install(where, tmp_path)
    assert install_main(args) == 0
    skill = skills / "coding" / "SKILL.md"
    skill.write_text("MINE\n")
    skill.chmod(mode)
    assert install_main([*args, "--force"]) == 0
    backup = skill.with_name("SKILL.md.den.bak")
    assert backup.read_text() == "MINE\n"
    assert backup.stat().st_mode & 0o777 == want


def test_install_force_refuses_to_back_up_through_a_symlink(
    tmp_path, monkeypatch, symlink, capsys
):
    from den._install import main as install_main

    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    ws = tmp_path / "ws"
    assert install_main(["skills", "--target", str(ws)]) == 0
    skill = ws / "skills" / "coding" / "SKILL.md"
    skill.write_text("MINE\n")
    outside = tmp_path / "outside.txt"
    outside.write_text("not den's\n")
    symlink(outside, skill.with_name("SKILL.md.den.bak"))
    assert install_main(["skills", "--target", str(ws), "--force"]) == 1
    assert outside.read_text() == "not den's\n"
    assert skill.read_text() == "MINE\n", "not replaced without a backup"
    assert "symlink" in capsys.readouterr().err


@pytest.mark.parametrize("flag", ["--no-extras", "--bin", "--no-bin"])
def test_shell_refresh_plan_decides_extras_and_bin_itself(tmp_path, flag, capsys):
    import json

    from den._install import main as install_main

    path = tmp_path / "plan.json"
    path.write_text(json.dumps(_PLAN))
    assert install_main(["shell", "--refresh-plan", str(path), flag]) == 2
    assert f"decides {flag} itself" in capsys.readouterr().err


@pytest.mark.parametrize(
    "plan",
    [
        "not json",
        '{"den_refresh_plan": 2}',
        '{"den_refresh_plan": 1, "owned": "x"}',
        {**_PLAN, "owned": [str(Path(_BIN.anchor) / "x")]},  # paths, no digests
        {**_PLAN, "owned": {str(Path(_BIN.anchor) / "x"): "not a digest"}},
        {**_PLAN, "absent": "x"},
    ],
)
def test_a_broken_refresh_plan_is_refused(tmp_path, plan, capsys):
    import json

    from den._install import main as install_main

    path = tmp_path / "plan.json"
    path.write_text(plan if isinstance(plan, str) else json.dumps(plan))
    assert install_main(["skills", "--refresh-plan", str(path)]) == 2
    assert install_main(["shell", "--refresh-plan", str(path)]) == 2
    assert "cannot use the refresh plan" in capsys.readouterr().err
