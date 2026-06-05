"""Tests for den hook (tools/_hook.py)."""

import json

import _hook
from _hook import main as hook_main


def _den(proj):
    return proj / ".den"


def _seed(proj, imprint=None, memory=None):
    d = _den(proj)
    d.mkdir(parents=True, exist_ok=True)
    if imprint is not None:
        (d / "imprint.md").write_text(imprint)
    if memory is not None:
        (d / "memory.md").write_text(memory)


# --------------------------------------------------------------------------- #
# compose
# --------------------------------------------------------------------------- #


def test_compose_empty_when_nothing(tmp_path):
    assert _hook._compose(_den(tmp_path)) == ""


def test_compose_imprint_only(tmp_path):
    _seed(tmp_path, imprint="do the thing\n")
    out = _hook._compose(_den(tmp_path))
    assert "<den:imprint>" in out and "do the thing" in out
    assert "<den:memory>" not in out


def test_compose_both_in_order(tmp_path):
    _seed(tmp_path, imprint="IMP\n", memory="MEM\n")
    out = _hook._compose(_den(tmp_path))
    assert out.index("<den:imprint>") < out.index("<den:memory>")


# --------------------------------------------------------------------------- #
# run
# --------------------------------------------------------------------------- #


def test_run_per_turn_emits_claude_json(tmp_path, monkeypatch, capsys):
    _seed(tmp_path, imprint="IMP\n", memory="MEM\n")
    monkeypatch.chdir(tmp_path)
    assert hook_main(["run", "--event", "per-turn", "--tool", "claude"]) == 0
    payload = json.loads(capsys.readouterr().out)
    hso = payload["hookSpecificOutput"]
    assert hso["hookEventName"] == "UserPromptSubmit"
    assert "IMP" in hso["additionalContext"]
    assert "MEM" in hso["additionalContext"]


def test_run_emits_nothing_when_empty(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    assert hook_main(["run", "--event", "per-turn", "--tool", "claude"]) == 0
    assert capsys.readouterr().out == ""


def test_run_post_tool_checkpoints_without_output(tmp_path, monkeypatch, capsys):
    _seed(tmp_path, memory="state\n")
    monkeypatch.chdir(tmp_path)
    assert hook_main(["run", "--event", "post-tool", "--tool", "claude"]) == 0
    assert capsys.readouterr().out == ""
    assert (tmp_path / ".den" / "history").is_dir()


def test_run_requires_event_and_tool(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    assert hook_main(["run", "--tool", "claude"]) == 2
    assert hook_main(["run", "--event", "per-turn"]) == 2


def test_run_rejects_unknown_event(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    assert hook_main(["run", "--event", "nope", "--tool", "claude"]) == 2


# --------------------------------------------------------------------------- #
# install / list / remove
# --------------------------------------------------------------------------- #


def test_install_seeds_imprint_and_writes_hooks(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    cfg = tmp_path / "settings.json"
    assert hook_main(["install", "--tool", "claude", "--config", str(cfg)]) == 0
    assert (tmp_path / ".den" / "imprint.md").is_file()
    hooks = json.loads(cfg.read_text())["hooks"]
    assert set(hooks) == {"SessionStart", "UserPromptSubmit", "PostToolUse", "Stop"}
    cmd = hooks["UserPromptSubmit"][0]["hooks"][0]["command"]
    assert cmd == "den hook run --event per-turn --tool claude"
    assert hooks["PostToolUse"][0]["matcher"] == "Write|Edit|MultiEdit"


def test_install_is_idempotent(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    cfg = tmp_path / "settings.json"
    hook_main(["install", "--tool", "claude", "--config", str(cfg)])
    hook_main(["install", "--tool", "claude", "--config", str(cfg)])
    hooks = json.loads(cfg.read_text())["hooks"]
    assert len(hooks["UserPromptSubmit"]) == 1  # not duplicated


def test_install_preserves_foreign_hooks(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    cfg = tmp_path / "settings.json"
    cfg.write_text(
        json.dumps(
            {
                "hooks": {
                    "UserPromptSubmit": [
                        {"hooks": [{"type": "command", "command": "echo foreign"}]}
                    ]
                }
            }
        )
    )
    hook_main(["install", "--tool", "claude", "--config", str(cfg)])
    groups = json.loads(cfg.read_text())["hooks"]["UserPromptSubmit"]
    commands = [h["command"] for g in groups for h in g["hooks"]]
    assert "echo foreign" in commands
    assert "den hook run --event per-turn --tool claude" in commands


def test_install_seeds_default_imprint_content(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    cfg = tmp_path / "settings.json"
    hook_main(["install", "--tool", "claude", "--config", str(cfg)])
    assert (tmp_path / ".den" / "imprint.md").read_text() == _hook._DEFAULT_IMPRINT


def test_install_does_not_overwrite_existing_imprint(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    _seed(tmp_path, imprint="my own imprint\n")
    cfg = tmp_path / "settings.json"
    hook_main(["install", "--tool", "claude", "--config", str(cfg)])
    assert (tmp_path / ".den" / "imprint.md").read_text() == "my own imprint\n"


def test_install_refuses_unverified_tool(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    cfg = tmp_path / "gemini.json"
    assert hook_main(["install", "--tool", "gemini", "--config", str(cfg)]) == 1
    assert not cfg.exists()


def test_remove_strips_den_keeps_foreign(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    cfg = tmp_path / "settings.json"
    cfg.write_text(
        json.dumps(
            {
                "hooks": {
                    "UserPromptSubmit": [
                        {"hooks": [{"type": "command", "command": "echo foreign"}]}
                    ]
                }
            }
        )
    )
    hook_main(["install", "--tool", "claude", "--config", str(cfg)])
    assert hook_main(["remove", "--tool", "claude", "--config", str(cfg)]) == 0
    groups = json.loads(cfg.read_text())["hooks"]["UserPromptSubmit"]
    commands = [h["command"] for g in groups for h in g["hooks"]]
    assert commands == ["echo foreign"]


def test_list_shows_den_managed(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    cfg = tmp_path / "settings.json"
    hook_main(["install", "--tool", "claude", "--config", str(cfg)])
    capsys.readouterr()
    assert hook_main(["list", "--tool", "claude", "--config", str(cfg)]) == 0
    out = capsys.readouterr().out
    assert "den hook run --event per-turn --tool claude" in out


def test_unknown_subcommand(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    assert hook_main(["frobnicate"]) == 2
