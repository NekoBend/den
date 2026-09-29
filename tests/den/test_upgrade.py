"""Tests for den upgrade (den/_upgrade.py)."""

from pathlib import Path

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


def _wire(monkeypatch, rcs: dict[int, int] | None = None, have=("uv", "den")):
    """Mock which/run; rcs maps call index -> returncode (default 0).

    `uv tool dir --bin` is answered with _BIN and kept out of `calls`, so the
    indices count the upgrade and the redeploy steps only.
    """
    calls: list[list[str]] = []

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
    assert calls[1] == [str(_BIN / "den"), "install", "skills", "--with-parent"]
    assert calls[2] == [str(_BIN / "den"), "install", "shell"]


def test_refresh_force_is_forwarded_to_both_steps(monkeypatch):
    # After an upgrade every file the new version changed differs from the
    # deployed copy, which `den install` cannot tell from a local edit; without
    # --force a non-interactive refresh keeps them all and deploys nothing.
    calls = _wire(monkeypatch)
    assert upgrade_main(["--refresh", "--force"]) == 0
    assert calls[1] == [
        str(_BIN / "den"),
        "install",
        "skills",
        "--with-parent",
        "--force",
    ]
    assert calls[2] == [str(_BIN / "den"), "install", "shell", "--force"]


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
    assert "den install skills --with-parent --force" in out
    assert "den install shell --force" in out


def test_refresh_step_that_kept_files_reports_it_with_a_force_hint(monkeypatch, capsys):
    # `den install skills` exits non-zero when a non-interactive run kept the
    # files it meant to deploy; the refresh must surface that, not exit 0.
    calls = _wire(monkeypatch, rcs={1: 1})
    assert upgrade_main(["--refresh"]) == 1
    assert len(calls) == 2
    err = capsys.readouterr().err
    # The step deployed everything it was allowed to and kept the rest, and any
    # earlier step fully succeeded, so "nothing was deployed" would be false.
    assert "did not complete" in err
    assert "may already be deployed" in err
    assert "NOT deployed" not in err
    assert "den upgrade --refresh --force" in err


def test_refresh_failure_under_force_omits_the_force_hint(monkeypatch, capsys):
    calls = _wire(monkeypatch, rcs={1: 1})
    assert upgrade_main(["--refresh", "--force"]) == 1
    assert len(calls) == 2
    err = capsys.readouterr().err
    assert "did not complete" in err
    assert "--refresh --force" not in err, "already forced; the hint would be noise"


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
