"""Tests for the den top-level CLI dispatcher (den/cli.py)."""

from den.cli import main as den_main


def test_help_centers_on_install_uninstall(capsys):
    assert den_main(["--help"]) == 0
    out = capsys.readouterr().out
    assert "install" in out and "uninstall" in out
    # the removed dev-tool commands are gone from the surface
    assert "check" not in out and "verify" not in out and "refs" not in out


def test_version(capsys):
    assert den_main(["--version"]) == 0
    assert "den " in capsys.readouterr().out


def test_unknown_command_exits_2(capsys):
    assert den_main(["frobnicate"]) == 2
    assert "unknown command" in capsys.readouterr().err


def test_removed_dev_tool_commands_are_unknown(capsys):
    for cmd in ("check", "verify", "refs", "doc"):
        assert den_main([cmd, "x"]) == 2


def test_hook_memory_and_memory_alias_both_dispatch(tmp_path, monkeypatch, capsys):
    # memory is nested under hook (den hook memory) but the bare `den memory`
    # alias stays for already-deployed imprints; both reach the same store.
    monkeypatch.chdir(tmp_path)
    (tmp_path / ".den").mkdir()
    assert den_main(["hook", "memory", "add", "fact via hook"]) == 0
    assert den_main(["memory", "add", "fact via alias"]) == 0
    assert den_main(["hook", "memory", "show"]) == 0
    out = capsys.readouterr().out
    assert "fact via hook" in out and "fact via alias" in out
