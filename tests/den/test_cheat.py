"""Tests for den cheat (den/_cheat.py)."""

from den._cheat import main as cheat_main


def test_cheat_lists_available(capsys):
    assert cheat_main([]) == 0
    out = capsys.readouterr().out
    assert "shell/one-liners.md" in out


def test_cheat_views_one(capsys):
    assert cheat_main(["shell/one-liners"]) == 0
    assert capsys.readouterr().out.strip() != ""


def test_cheat_unknown_returns_error(capsys):
    assert cheat_main(["no-such-sheet-xyz"]) == 1


def test_cheat_ambiguous_lists_candidates(capsys):
    # "regex" matches several files under python/regex/
    assert cheat_main(["regex"]) == 1
    err = capsys.readouterr().err
    assert "ambiguous" in err
