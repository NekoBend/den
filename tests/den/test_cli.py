"""Tests for the den top-level CLI dispatcher (den/cli.py)."""

import io

import pytest

from den.cli import main as den_main


def test_help_centers_on_install_uninstall(capsys):
    assert den_main(["--help"]) == 0
    out = capsys.readouterr().out
    assert "install" in out and "uninstall" in out
    # the removed dev-tool commands are gone from the surface; verify came
    # back as runtime plumbing and appears only in the plumbing footer
    assert "check" not in out and "refs" not in out
    assert "verify" not in out.split("Run 'den <command>")[0]
    assert "den verify" in out


def test_version(capsys):
    assert den_main(["--version"]) == 0
    assert "den " in capsys.readouterr().out


def test_unknown_command_exits_2(capsys):
    assert den_main(["frobnicate"]) == 2
    assert "unknown command" in capsys.readouterr().err


def test_removed_dev_tool_commands_are_unknown(capsys):
    # verify is not in this list: it returned as runtime plumbing (task #24)
    for cmd in ("check", "refs", "doc"):
        assert den_main([cmd, "x"]) == 2


# den memory, the per-turn hook and den board were removed (MIGRATIONS.md). A
# stale script, alias or imprint that still runs one of these gets one line
# naming the removal, not a traceback or an argparse error, and exit 1 (not 2,
# which a Claude Code hook reads as "block the prompt"). den board's forms
# neither start a server nor write a file.
_REMOVED = [
    ["memory"],
    ["memory", "--help"],
    *(
        ["memory", sub, *args]
        for sub, args in [
            ("show", []),
            ("checkpoint", []),
            ("save", ["--file", "x.md"]),
            ("add", ["a fact"]),
            ("clear", []),
            ("log", []),
            ("restore", ["1"]),
            ("diff", []),
            ("path", []),
        ]
    ),
    ["hook", "memory", "add", "a fact"],
    ["hook", "imprint"],
    ["hook", "install", "--tool", "claude"],
    ["hook", "list"],
    ["hook", "remove", "--tool", "claude"],
    ["install", "hook"],
    ["install", "hook", "--tool", "cline-cli"],
    ["install", "hook", "--help"],
    ["board"],
    ["board", "--help"],
    ["board", "--open"],
    ["board", "--port", "9000", "--dir", "."],
    ["board", "task", "retest the boss fight after this fix"],
    ["board", "task", "--dir", ".", "retest"],
    ["board", "reply", "r-1", "seen, please retry"],
]


@pytest.mark.parametrize("argv", _REMOVED, ids=[" ".join(a) for a in _REMOVED])
def test_a_removed_command_says_so_in_one_line(tmp_path, monkeypatch, capsys, argv):
    monkeypatch.chdir(tmp_path)
    (tmp_path / ".den").mkdir()
    (tmp_path / ".den" / "memory.md").write_text("- a fact\n")
    monkeypatch.setattr("sys.stdin", io.StringIO("piped text\n"))
    assert den_main(argv) == 1
    out = capsys.readouterr()
    assert out.out == ""
    lines = out.err.splitlines()
    assert len(lines) == 1, lines
    if argv[0] in {"memory", "board"}:
        command = f"den {argv[0]}"
    else:
        command = " ".join(["den", *argv[:2]])
    assert lines[0].startswith(f"{command}: removed from den (2026-11)")
    assert lines[0].endswith(
        "see MIGRATIONS.md, https://github.com/NekoBend/den/blob/main/MIGRATIONS.md"
    )
    assert sorted(p.name for p in tmp_path.rglob("*")) == [".den", "memory.md"]
    assert (tmp_path / ".den" / "memory.md").read_text() == "- a fact\n"


def test_help_names_no_removed_command(capsys):
    assert den_main(["--help"]) == 0
    out = capsys.readouterr().out
    assert "memory" not in out
    assert "board" not in out
    assert "install   [skills|shell|cheatsheets]" in out


def test_ctrl_c_exits_130_without_a_traceback(monkeypatch, capsys):
    """A cancelled prompt raises KeyboardInterrupt (den._ui uses unsafe_ask);
    den ends there with the conventional 130, not a traceback."""
    from den import _install

    def _interrupted(_argv):
        raise KeyboardInterrupt

    monkeypatch.setattr(_install, "main", _interrupted)
    try:
        rc = den_main(["install"])
    except KeyboardInterrupt:
        pytest.fail("KeyboardInterrupt escaped den.cli.main: a traceback")
    assert rc == 130
    assert "cancelled" in capsys.readouterr().err
