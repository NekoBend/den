"""Tests for den/_ui.py (interactive prompts that degrade to plain stdin)."""

import sys
import types

import pytest

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


def test_say_prints_paths_literally_through_rich(capsys):
    """say() lists file paths before the overwrite and removal prompts. Rich
    markup parsing dropped a '[client]' directory, ate the backslash before a
    Windows '\\[Client]' one, and raised MarkupError on 'notes[/old]'."""
    pytest.importorskip("rich")
    msgs = [
        "  rm /w/[client] app/skills/x.md",
        "  rm C:\\w\\[Client] app\\x.md",
        "  rm /w/notes[/old]/x.md",
        "  /w/:smile:/[bold]x[/bold]",
    ]
    for m in msgs:
        _ui.say(m, style="yellow")
    assert capsys.readouterr().out.splitlines() == msgs


class _Question:
    """A questionary question: ask() swallows Ctrl-C (prints 'Cancelled by
    user' and returns None, questionary/question.py), unsafe_ask() raises."""

    def __init__(self, answer=None, *, interrupt=False):
        self.answer = answer
        self.interrupt = interrupt

    def ask(self):
        return None if self.interrupt else self.answer

    def unsafe_ask(self):
        if self.interrupt:
            raise KeyboardInterrupt
        return self.answer


def _questionary(monkeypatch, question):
    fake = types.SimpleNamespace(
        confirm=lambda *a, **k: question,
        checkbox=lambda *a, **k: question,
        Choice=lambda name, checked: name,
    )
    monkeypatch.setitem(sys.modules, "questionary", fake)
    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    asked: list[str] = []
    monkeypatch.setattr("builtins.input", lambda prompt: asked.append(prompt) or "")
    return asked


def test_confirm_ctrl_c_cancels_instead_of_asking_again(monkeypatch):
    """Ctrl-C used to print 'Cancelled by user' and then ask the same question
    on a plain prompt, where the next Enter took the default (yes, for the
    shell install)."""
    asked = _questionary(monkeypatch, _Question(interrupt=True))
    with pytest.raises(KeyboardInterrupt):
        _ui.confirm("Install the shell environment?", default=True)
    assert asked == [], "the plain fallback prompt must not be reached"


def test_select_ctrl_c_cancels(monkeypatch):
    asked = _questionary(monkeypatch, _Question(interrupt=True))
    with pytest.raises(KeyboardInterrupt):
        _ui.select("Which tools?", [("claude", True)])
    assert asked == []


def test_confirm_and_select_return_the_answer(monkeypatch):
    _questionary(monkeypatch, _Question(answer=False))
    assert _ui.confirm("ok?", default=True) is False
    _questionary(monkeypatch, _Question(answer=["claude"]))
    assert _ui.select("Which tools?", [("claude", True)]) == ["claude"]
