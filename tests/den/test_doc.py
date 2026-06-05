"""Tests for den doc (den/_doc.py)."""

from den._doc import main as doc_main


def test_doc_blank_line_breaks_association(tmp_path, capsys):
    # a doc comment separated from the declaration by a blank line is NOT its doc
    f = tmp_path / "a.ts"
    f.write_text("/** orphan doc */\n\nexport function lonely() {}\n")
    assert doc_main([str(f)]) == 0
    out = capsys.readouterr().out
    assert "lonely:NO_DOC" in out
    assert ":3:" in out  # reported at the declaration line, not the blank line


def test_doc_adjacent_comment_is_documented(tmp_path, capsys):
    f = tmp_path / "b.ts"
    f.write_text("/** doc */\nexport function ok() {}\n")
    assert doc_main([str(f)]) == 0
    assert "ok:HAS_DOC" in capsys.readouterr().out
