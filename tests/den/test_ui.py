"""Tests for den/_ui.py (interactive prompts that degrade to plain stdin)."""

from den import _ui


def test_confirm_fallback_yes(monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)  # skip questionary
    monkeypatch.setattr("builtins.input", lambda _prompt: "yes")
    assert _ui.confirm("ok?", default=False) is True


def test_confirm_fallback_no(monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setattr("builtins.input", lambda _prompt: "n")
    assert _ui.confirm("ok?", default=True) is False


def test_confirm_empty_answer_uses_default(monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setattr("builtins.input", lambda _prompt: "")
    assert _ui.confirm("ok?", default=True) is True
    assert _ui.confirm("ok?", default=False) is False


def test_confirm_eof_uses_default(monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)

    def _raise(_prompt):
        raise EOFError

    monkeypatch.setattr("builtins.input", _raise)
    assert _ui.confirm("ok?", default=True) is True
    assert _ui.confirm("ok?", default=False) is False


def test_select_fallback_asks_per_item(monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    answers = {"  a": True, "  b": False, "  c": True}
    monkeypatch.setattr(_ui, "confirm", lambda prompt, default: answers[prompt])
    monkeypatch.setattr(_ui, "say", lambda *a, **k: None)
    assert _ui.select("pick", [("a", True), ("b", False), ("c", True)]) == ["a", "c"]


def test_say_without_rich_uses_print(monkeypatch, capsys):
    monkeypatch.setattr(_ui, "_console", lambda: None)
    _ui.say("hello world")
    assert "hello world" in capsys.readouterr().out
