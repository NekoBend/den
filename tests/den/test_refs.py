"""Tests for den refs (den/_refs.py)."""

from den._refs import main as refs_main


def test_refs_def_empty_string_does_not_crash(tmp_path):
    # an empty --def used to mis-route to --in and crash on Path(None)
    assert refs_main(["--def", "", "--root", str(tmp_path)]) == 0


def test_refs_def_finds_symbol(tmp_path, capsys):
    (tmp_path / "m.py").write_text("def hello():\n    pass\n")
    assert refs_main(["--def", "hello", "--root", str(tmp_path)]) == 0
    assert "hello" in capsys.readouterr().out
