"""Tests for den upgrade (den/_upgrade.py)."""

from den import _upgrade
from den._upgrade import main as upgrade_main
from den.cli import main as cli_main


class _Proc:
    def __init__(self, rc: int = 0):
        self.returncode = rc


def _wire(monkeypatch, rcs: dict[int, int] | None = None, have=("uv", "den")):
    """Mock which/run; rcs maps call index -> returncode (default 0)."""
    calls: list[list[str]] = []
    monkeypatch.setattr(
        _upgrade.shutil,
        "which",
        lambda name: f"/usr/bin/{name}" if name in have else None,
    )

    def _run(cmd, **k):
        calls.append(cmd)
        return _Proc((rcs or {}).get(len(calls) - 1, 0))

    monkeypatch.setattr(_upgrade.subprocess, "run", _run)
    return calls


def test_upgrade_runs_uv_tool_upgrade(monkeypatch, capsys):
    calls = _wire(monkeypatch)
    assert upgrade_main([]) == 0
    assert calls == [["uv", "tool", "upgrade", "den"]]
    assert "den upgrade --refresh" in capsys.readouterr().out  # redeploy hint


def test_refresh_redeploys_via_new_binary(monkeypatch):
    calls = _wire(monkeypatch)
    assert upgrade_main(["--refresh"]) == 0
    assert calls[0] == ["uv", "tool", "upgrade", "den"]
    # subprocesses of the upgraded binary, never the old in-process code
    assert calls[1] == ["/usr/bin/den", "install", "skills", "--with-parent"]
    assert calls[2] == ["/usr/bin/den", "install", "shell"]


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
    assert calls == [["uv", "tool", "upgrade", "den"]]  # upgrade ran; refresh could not
    assert "manually" in capsys.readouterr().err


def test_windows_lock_hint_on_failed_upgrade(monkeypatch, capsys):
    _wire(monkeypatch, rcs={0: 1})
    monkeypatch.setattr(_upgrade.os, "name", "nt")
    assert upgrade_main([]) == 1
    assert "file-in-use" in capsys.readouterr().err


def test_no_lock_hint_on_posix(monkeypatch, capsys):
    _wire(monkeypatch, rcs={0: 1})
    monkeypatch.setattr(_upgrade.os, "name", "posix")
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
