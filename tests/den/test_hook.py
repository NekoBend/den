"""Tests for what is left of den hook (den/_hook.py).

den no longer installs hooks. What stays is `den hook run`, a no-op for the
hooks an older den installed, and `den uninstall hook`, which takes those hooks
out again. The workspaces below are written the way the last installer left
them (_installed), so remove is tested against the real shapes.
"""

import copy
import io
import json
import os
import shlex
import stat
import subprocess
import sys
from pathlib import Path

import pytest

from den import _hook
from den._hook import main as hook_main
from den._uninstall import main as uninstall_main

# The shapes every installer wrote, from the last den that installed hooks:
# tool -> {generic event: the tool's own event}.
_CLAUDE_EVENTS = {
    "session-start": "SessionStart",
    "per-turn": "UserPromptSubmit",
    "post-tool": "PostToolUse",
    "stop": "Stop",
}
_COPILOT_EVENTS = {
    "session-start": "sessionStart",
    "per-turn": "userPromptSubmitted",
    "post-tool": "postToolUse",
}
_CLINE_EVENTS = {
    "session-start": "TaskStart",
    "per-turn": "UserPromptSubmit",
    "post-tool": "PostToolUse",
}
_LOCAL = Path(".claude") / "settings.local.json"
_SHARED = Path(".claude") / "settings.json"
_COPILOT = Path(".github") / "hooks" / "den.json"
_CLINE = Path(".clinerules") / "hooks"
_RULES = Path(".clinerules")

# What the cline-cli rule files began with (den/_hook.py and den/_memory.py
# before the removal).
_IMPRINT_RULE = (
    "<!-- den-managed. Edit .den/imprint.md, then re-run "
    "`den install hook --tool cline-cli`. -->\n\n"
    "cline reads den's memory from .clinerules/den-memory.md, a copy of "
    ".den/memory.md. After you edit .den/memory.md directly, run "
    "`den hook memory checkpoint` so the copy is refreshed.\n\n"
    "# Imprint (always-on directives)\n"
)
_MEMORY_RULE = (
    "<!-- den-managed mirror of .den/memory.md. Edit memory with `den hook memory`, "
    "not here; after editing .den/memory.md directly, run "
    "`den hook memory checkpoint` to refresh this copy. -->\n\n- a fact\n"
)


def _cmd(tool, event, den_dir, *, powershell=False):
    """A `den hook run` line as the installer baked it in: --den-dir pins the
    absolute .den, quoted for the shell (or PowerShell) that runs it. With
    den_dir None, as before pinning existed."""
    cmd = f"den hook run --event {event} --tool {tool}"
    if den_dir is None:
        return cmd
    d = str(den_dir)
    quoted = "'" + d.replace("'", "''") + "'" if powershell else shlex.quote(d)
    return f"{cmd} --den-dir {quoted}"


def _dump(data):
    """JSON as the installer wrote it: indent 2, the platform's line ends."""
    return (json.dumps(data, indent=2) + "\n").replace("\n", os.linesep)


def _den_group(tool, event="per-turn", den_dir="/old/proj/.den"):
    """A hook group as an earlier den wrote it into a settings file."""
    return {"hooks": [{"type": "command", "command": _cmd(tool, event, den_dir)}]}


def _claude_hooks(den_dir):
    hooks = {}
    for generic, native in _CLAUDE_EVENTS.items():
        group = _den_group("claude", generic, den_dir)
        if generic == "post-tool":
            group["matcher"] = "Write|Edit|MultiEdit"
        hooks[native] = [group]
    return hooks


def _copilot_entry(event="session-start", den_dir="/old/proj/.den"):
    """A copilot entry as an earlier den wrote it."""
    return {"type": "command", "bash": _cmd("copilot", event, den_dir)}


def _write_cline_script(hooks_dir, native, generic, den_dir, *, windows=False):
    hooks_dir.mkdir(parents=True, exist_ok=True)
    if windows:
        script = hooks_dir / f"{native}.ps1"
        cmd = _cmd("cline", generic, den_dir, powershell=True)
        body = f"# den hook run (den-managed; do not edit)\n{cmd}\n"
        script.write_bytes(body.encode("utf-8-sig"))
    else:
        script = hooks_dir / native
        script.write_bytes(
            (
                "#!/usr/bin/env bash\n"
                "# den hook run (den-managed; do not edit)\n"
                f"exec {_cmd('cline', generic, den_dir)}\n"
            ).encode()
        )
        script.chmod(0o755)
    return script


def _installed(proj, *tools, pinned=True, windows=False):
    """`proj` as `den install hook --tool T` left it for each of `tools`: the
    seeded .den and each tool's hook config. pinned=False writes the commands
    of the dens before --den-dir existed."""
    den_dir = (proj / ".den").resolve() if pinned else None
    (proj / ".den").mkdir(parents=True, exist_ok=True)
    (proj / ".den" / "imprint.md").write_text("# Imprint (always-on directives)\n")
    for tool in tools:
        if tool == "claude":
            cfg = proj / _LOCAL
            cfg.parent.mkdir(parents=True, exist_ok=True)
            cfg.write_bytes(_dump({"hooks": _claude_hooks(den_dir)}).encode())
        elif tool == "copilot":
            cfg = proj / _COPILOT
            cfg.parent.mkdir(parents=True, exist_ok=True)
            hooks = {
                native: [_copilot_entry(generic, den_dir)]
                for generic, native in _COPILOT_EVENTS.items()
            }
            cfg.write_bytes(_dump({"version": 1, "hooks": hooks}).encode())
        elif tool == "cline":
            for generic, native in _CLINE_EVENTS.items():
                _write_cline_script(
                    proj / _CLINE, native, generic, den_dir, windows=windows
                )
        elif tool == "cline-cli":
            rules = proj / _RULES
            rules.mkdir(parents=True, exist_ok=True)
            (rules / "den-imprint.md").write_bytes(_IMPRINT_RULE.encode())
            (rules / "den-memory.md").write_bytes(_MEMORY_RULE.encode())
        else:
            raise AssertionError(tool)
    return proj


def _commands(groups):
    return [h["command"] for g in groups for h in g["hooks"]]


def _names(directory):
    return sorted(p.name for p in directory.iterdir())


# --------------------------------------------------------------------------- #
# den hook run: the no-op the installed hooks still call
# --------------------------------------------------------------------------- #

# What `den hook run` printed with nothing to inject, per tool: claude reads
# empty stdout as nothing, copilot and cline expect JSON on every hook, and
# cline-cli never had a runtime hook.
_NOTHING = {
    "claude": "",
    "copilot": "{}\n",
    "cline": '{"cancel": false}\n',
    "cline-cli": "",
}
_EVENTS = {
    "claude": _CLAUDE_EVENTS,
    "copilot": _COPILOT_EVENTS,
    "cline": _CLINE_EVENTS,
    "cline-cli": {"per-turn": "-"},
}
_FOREIGN_DEN_DIR = "/home/me/proj/.den" if os.name == "nt" else "C:\\Users\\me\\.den"


def _old_argvs():
    """(id, tool, argv) for every argument form an installed hook passes."""
    for tool, events in _EVENTS.items():
        for generic in dict.fromkeys([*events, "stop"]):
            for den_dir in (
                "/w/proj with space/.den",  # shell-quoted on install, one argv
                _FOREIGN_DEN_DIR,  # written on the other OS of a WSL pair
                ".den",  # relative: refused by the old run
                None,  # before pinning existed
            ):
                argv = ["--event", generic, "--tool", tool]
                if den_dir is not None:
                    argv += ["--den-dir", den_dir]
                yield f"{tool}-{generic}-{den_dir}", tool, argv


_OLD_ARGVS = list(_old_argvs())


@pytest.mark.parametrize(
    ("tool", "argv"), [a[1:] for a in _OLD_ARGVS], ids=[a[0] for a in _OLD_ARGVS]
)
def test_run_answers_every_installed_hook_with_its_empty_response(
    tmp_path, monkeypatch, capsys, tool, argv
):
    monkeypatch.chdir(tmp_path)
    assert hook_main(["run", *argv]) == 0
    out = capsys.readouterr()
    assert out.out == _NOTHING[tool]
    assert out.err == "", "silent: a hook's stderr reaches the session"


@pytest.mark.parametrize(
    "argv",
    [
        [],
        ["--event", "per-turn"],
        ["--tool"],
        ["--event", "per-turn", "--tool", "gemini"],
        ["--event", "per-turn", "--tool", "codex"],
        ["--event", "per-turn", "--tool", "nope", "--bogus", "x"],
        ["per-turn", "claude"],
        ["--help"],
    ],
)
def test_run_answers_an_unknown_or_missing_tool_with_nothing(
    tmp_path, monkeypatch, capsys, argv
):
    # gemini (retired) and codex (never installable) are what an older config
    # can still name; the rest is version skew or a hand-written command.
    monkeypatch.chdir(tmp_path)
    assert hook_main(["run", *argv]) == 0
    assert capsys.readouterr() == ("", "")


def test_run_takes_only_the_tool_from_extra_arguments(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    argv = ["run", "--bogus", "--event", "x", "--tool", "cline", "--den-dir"]
    assert hook_main(argv) == 0
    assert capsys.readouterr() == (_NOTHING["cline"], "")


def test_run_does_no_file_or_stdin_io(tmp_path, monkeypatch, capsys):
    """The no-op reads nothing and writes nothing: any filesystem call or stdin
    read on its way through raises here. (A .den with an imprint and a memory
    sits in the workspace, as an older install left it.)"""
    _installed(tmp_path, "claude", "copilot", "cline")
    (tmp_path / ".den" / "memory.md").write_text("- a fact\n")
    monkeypatch.chdir(tmp_path)

    def _no_io(*_a, **_k):
        raise AssertionError("den hook run touched the filesystem")

    class _NoStdin:
        def __getattr__(self, name):
            raise AssertionError(f"den hook run used stdin.{name}")

    with pytest.MonkeyPatch.context() as mp:
        for name in ("open", "stat", "lstat", "scandir", "listdir", "mkdir", "replace"):
            mp.setattr(os, name, _no_io)
        mp.setattr("builtins.open", _no_io)
        mp.setattr(io, "open", _no_io)
        mp.setattr(sys, "stdin", _NoStdin())
        for tool, events in _EVENTS.items():
            for generic in events:
                argv = ["run", "--event", generic, "--tool", tool]
                assert hook_main([*argv, "--den-dir", str(tmp_path / ".den")]) == 0
    assert capsys.readouterr().err == ""


def _tree(root):
    """Every path under root with its bytes (or None for a dir, a FIFO)."""
    found = {}
    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root).as_posix()
        if path.is_file() and not path.is_fifo():
            found[rel] = (path.read_bytes(), path.stat().st_mtime_ns)
        else:
            found[rel] = None
    return found


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="needs POSIX FIFOs")
@pytest.mark.parametrize("tool", sorted(_NOTHING))
def test_run_as_a_hook_reads_and_writes_nothing(tmp_path, tool):
    """Run as the tool runs it: a separate process with stdin left open, in a
    workspace whose .den/imprint.md and .den/memory.md are FIFOs. Opening
    either, or reading stdin, would block until the timeout. Nothing under the
    workspace or the home may change."""
    home = tmp_path / "home"
    home.mkdir()
    ws = _installed(tmp_path / "ws", "claude", "copilot", "cline")
    for name in ("imprint.md", "memory.md"):
        path = ws / ".den" / name
        path.unlink(missing_ok=True)
        os.mkfifo(path)
    before = _tree(tmp_path)
    env = {
        **{k: v for k, v in os.environ.items() if k in {"PATH", "SYSTEMROOT"}},
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_DATA_HOME": str(home / ".local" / "share"),
        "XDG_STATE_HOME": str(home / ".local" / "state"),
        "XDG_CACHE_HOME": str(home / ".cache"),
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONPATH": str(Path(__file__).resolve().parents[2]),
    }
    argv = [sys.executable, "-B", "-m", "den.cli", "hook", "run"]
    argv += ["--event", "per-turn", "--tool", tool, "--den-dir", str(ws / ".den")]
    proc = subprocess.Popen(  # stdin stays open: a read would wait for ever
        argv,
        cwd=ws,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        rc = proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        pytest.fail("den hook run blocked on stdin or on a .den file")
    finally:
        assert proc.stdin is not None
        proc.stdin.close()
    assert proc.stdout is not None and proc.stderr is not None
    out, err = proc.stdout.read(), proc.stderr.read()
    proc.stdout.close()
    proc.stderr.close()
    assert rc == 0
    assert out == _NOTHING[tool].encode()
    assert err == b""
    assert _tree(tmp_path) == before


# --------------------------------------------------------------------------- #
# removed subcommands: one line that names the removal, not a traceback
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize(
    "argv",
    [
        ["install"],
        ["install", "--tool", "claude"],
        ["list"],
        ["imprint"],
        ["memory", "add", "a fact"],
        ["memory"],
        ["remove", "--tool", "claude"],
    ],
)
def test_a_removed_hook_subcommand_says_so_in_one_line(
    tmp_path, monkeypatch, capsys, argv
):
    _installed(tmp_path, "claude")
    monkeypatch.chdir(tmp_path)
    before = _tree(tmp_path)
    assert hook_main(argv) == 1, "not 2: a Claude Code hook exiting 2 blocks"
    out = capsys.readouterr()
    assert out.out == ""
    lines = out.err.splitlines()
    assert len(lines) == 1
    assert lines[0].startswith(f"den hook {argv[0]}: removed from den")
    assert "MIGRATIONS.md" in lines[0]
    assert _tree(tmp_path) == before, "nothing read into or written"


def test_den_hook_remove_points_to_uninstall(capsys):
    assert hook_main(["remove"]) == 1
    assert "use 'den uninstall hook'" in capsys.readouterr().err


def test_den_hook_without_a_subcommand_prints_usage(capsys):
    assert hook_main([]) == 0
    out = capsys.readouterr().out
    assert "den hook run" in out and "den uninstall hook" in out


def test_unknown_subcommand(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    assert hook_main(["frobnicate"]) == 2


# --------------------------------------------------------------------------- #
# den uninstall hook: every shape an older den installed
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize("pinned", [True, False], ids=["pinned", "unpinned"])
def test_uninstall_hook_removes_every_tools_install(tmp_path, monkeypatch, pinned):
    """With no --tool, every tool: what each installer wrote goes. A config
    file itself stays with what is left in it (claude's `{}`, copilot's
    `{"version": 1}`), as remove has always left it."""
    _installed(tmp_path, "claude", "copilot", "cline", pinned=pinned)
    rules = _installed(tmp_path / "cli", "cline-cli") / _RULES
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook"]) == 0
    assert json.loads((tmp_path / _LOCAL).read_text()) == {}
    assert json.loads((tmp_path / _COPILOT).read_text()) == {"version": 1}
    assert _names(tmp_path / _CLINE) == []
    monkeypatch.chdir(tmp_path / "cli")
    assert uninstall_main(["hook", "--tool", "cline-cli"]) == 0
    assert _names(rules) == []


def test_uninstall_hook_leaves_the_den_dir_alone(tmp_path, monkeypatch):
    # .den/imprint.md, memory.md and history/ are the user's to delete
    # (MIGRATIONS.md), and .den/board/ belongs to den board.
    _installed(tmp_path, "claude", "cline-cli")
    den = tmp_path / ".den"
    (den / "memory.md").write_text("- a fact\n")
    (den / "history").mkdir()
    (den / "history" / "memory.20260101T000000000000.md").write_text("old\n")
    (den / "board").mkdir()
    (den / "board" / "reports.jsonl").write_text("{}\n")
    before = _tree(den)
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook"]) == 0
    assert _tree(den) == before


def test_uninstall_hook_creates_no_den_dir(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook"]) == 0
    assert list(tmp_path.iterdir()) == []


def test_remove_strips_den_keeps_foreign(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    cfg = tmp_path / "settings.json"
    foreign = {"hooks": [{"type": "command", "command": "echo foreign"}]}
    hooks = _claude_hooks(tmp_path / ".den")
    hooks["UserPromptSubmit"].insert(0, foreign)
    cfg.write_text(json.dumps({"hooks": hooks}))
    assert uninstall_main(["hook", "--tool", "claude", "--config", str(cfg)]) == 0
    groups = json.loads(cfg.read_text())["hooks"]["UserPromptSubmit"]
    assert _commands(groups) == ["echo foreign"]


# den wrote one hook per group, but a hook added by hand (or by a tool that
# appends to an existing group with the same matcher) can share one of den's.


def _add_to_den_group(settings, event, command):
    data = json.loads(settings.read_text())
    data["hooks"][event][0]["hooks"].append({"type": "command", "command": command})
    settings.write_text(json.dumps(data))


def test_remove_keeps_a_foreign_hook_in_dens_group(tmp_path, monkeypatch):
    _installed(tmp_path, "claude")
    monkeypatch.chdir(tmp_path)
    local = tmp_path / _LOCAL
    _add_to_den_group(local, "Stop", "echo KEEP_FOREIGN_STOP")
    _add_to_den_group(local, "PostToolUse", "echo foreign-policy-check")
    assert uninstall_main(["hook", "--tool", "claude"]) == 0
    stop = {"type": "command", "command": "echo KEEP_FOREIGN_STOP"}
    post = {"type": "command", "command": "echo foreign-policy-check"}
    assert json.loads(local.read_text()) == {
        "hooks": {
            "PostToolUse": [{"hooks": [post], "matcher": "Write|Edit|MultiEdit"}],
            "Stop": [{"hooks": [stop]}],
        }
    }


def test_strip_den_hooks_takes_out_only_dens_hooks():
    den = _den_group("claude")["hooks"][0]
    foreign = {"type": "command", "command": "echo foreign", "timeout": 5}
    hooks = {
        "PostToolUse": [{"matcher": "Write|Edit", "hooks": [den, foreign]}],
        "SessionStart": [{"hooks": [den]}, {"matcher": "startup", "hooks": [foreign]}],
        "Stop": [{"hooks": [den]}],
    }
    before = copy.deepcopy(hooks)
    assert _hook._strip_den_hooks(hooks) == {
        "PostToolUse": [{"matcher": "Write|Edit", "hooks": [foreign]}],
        "SessionStart": [{"matcher": "startup", "hooks": [foreign]}],
    }
    assert hooks == before, "the argument is unchanged: remove compares against it"


@pytest.mark.parametrize(
    "hooks",
    [
        {"Stop": []},
        {"Stop": [{"matcher": "Bash"}]},
        {"Stop": [{"hooks": []}]},
        {"Stop": ["not a group"]},
        {"Stop": [{"hooks": "echo hi"}]},
        {"Stop": [{"hooks": ["echo hi", 5, None]}]},
        {"Stop": [{"hooks": [{"type": "command", "command": 5}]}]},
        {"Stop": {"hooks": [{"type": "command", "command": "echo hi"}]}},
        {"Stop": "echo hi", "PreToolUse": None},
        None,
        ["echo hi"],
    ],
)
def test_strip_den_hooks_returns_what_holds_nothing_of_dens_unchanged(hooks):
    # Anything else made remove rewrite a file it had nothing to take out of,
    # or raised on an entry den never wrote. A shape den never writes (the last
    # four) was dropped. Getting the very object back is remove's cue.
    arg = copy.deepcopy(hooks)
    assert _hook._strip_den_hooks(arg) is arg
    assert arg == hooks


def test_remove_leaves_a_file_with_nothing_of_dens_byte_identical(
    tmp_path, monkeypatch
):
    monkeypatch.chdir(tmp_path)
    local = tmp_path / _LOCAL
    local.parent.mkdir()
    raw = b'{"hooks": {"Stop": [], "PreToolUse": [{"matcher": "Bash", "hooks": []}]}}'
    local.write_bytes(raw)
    assert uninstall_main(["hook", "--tool", "claude"]) == 0
    assert local.read_bytes() == raw


# Shapes den never writes: a `hooks` that is not an object, an event whose value
# is not a list. remove holds nothing of den's in them and leaves them be.
_ODD_HOOKS = {
    "event-object": {"Stop": {"hooks": [{"type": "command", "command": "echo hi"}]}},
    "event-null": {"Stop": None},
    "hooks-null": None,
    "hooks-list": ["echo hi"],
    # json reads NaN, which is not equal to itself: remove has to tell that
    # nothing came out by getting the very object back, not by comparing.
    "hooks-nan": float("nan"),
}


@pytest.mark.parametrize("hooks", list(_ODD_HOOKS.values()), ids=list(_ODD_HOOKS))
def test_remove_leaves_hooks_of_a_shape_den_never_writes_byte_identical(
    tmp_path, monkeypatch, hooks
):
    monkeypatch.chdir(tmp_path)
    local = tmp_path / _LOCAL
    local.parent.mkdir()
    raw = json.dumps({"x": 1, "hooks": hooks}, separators=(",", ":")).encode()
    local.write_bytes(raw)
    assert uninstall_main(["hook", "--tool", "claude"]) == 0
    assert local.read_bytes() == raw


@pytest.mark.parametrize(
    "raw", [b"not json {{{ den hook run", b"[1, 2, 3]\n", b"\xff\xfe not utf-8 \x00"]
)
def test_remove_leaves_a_config_it_cannot_read_as_an_object_alone(
    tmp_path, monkeypatch, raw
):
    monkeypatch.chdir(tmp_path)
    for rel in (_LOCAL, _SHARED, _COPILOT):
        (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / rel).write_bytes(raw)
    assert uninstall_main(["hook", "--tool", "claude", "--tool", "copilot"]) == 0
    for rel in (_LOCAL, _SHARED, _COPILOT):
        assert (tmp_path / rel).read_bytes() == raw
    assert not list((tmp_path / ".claude").glob("*.den.bak*")), "nothing to back up"


# --- copilot --- #

_ODD_BASH = pytest.mark.parametrize("bash", [None, 5], ids=["null", "number"])


def _write_copilot(proj, hooks):
    cfg = proj / _COPILOT
    cfg.parent.mkdir(parents=True)
    cfg.write_text(json.dumps({"version": 1, "hooks": hooks}))
    return cfg


@_ODD_BASH
def test_remove_copilot_keeps_an_entry_whose_bash_is_not_text(
    tmp_path, monkeypatch, bash
):
    monkeypatch.chdir(tmp_path)
    odd = {"type": "command", "bash": bash}
    cfg = _write_copilot(
        tmp_path,
        {
            "sessionStart": [odd, "not an entry", _copilot_entry()],
            "postToolUse": [_copilot_entry("post-tool")],
        },
    )
    assert uninstall_main(["hook", "--tool", "copilot"]) == 0
    assert json.loads(cfg.read_text()) == {
        "version": 1,
        "hooks": {"sessionStart": [odd, "not an entry"]},
    }


def test_remove_copilot_leaves_a_file_with_nothing_of_dens_byte_identical(
    tmp_path, monkeypatch
):
    monkeypatch.chdir(tmp_path)
    cfg = tmp_path / _COPILOT
    cfg.parent.mkdir(parents=True)
    raw = (
        b'{"version":1,"hooks":{"sessionStart":[{"type":"command","bash":"echo hi"},'
        b'"not an entry"],"stop":[],"x":{"bash":"echo y"}}}'
    )
    cfg.write_bytes(raw)
    assert uninstall_main(["hook", "--tool", "copilot"]) == 0
    assert cfg.read_bytes() == raw


_ODD_COPILOT_HOOKS = {
    "event-object": {"sessionStart": {"type": "command", "bash": "echo hi"}},
    "event-null": {"sessionStart": None},
    "hooks-null": None,
    "hooks-list": ["echo hi"],
    "hooks-nan": float("nan"),
}


@pytest.mark.parametrize(
    "hooks", list(_ODD_COPILOT_HOOKS.values()), ids=list(_ODD_COPILOT_HOOKS)
)
def test_remove_copilot_leaves_hooks_of_a_shape_den_never_writes(
    tmp_path, monkeypatch, hooks
):
    monkeypatch.chdir(tmp_path)
    cfg = tmp_path / _COPILOT
    cfg.parent.mkdir(parents=True)
    raw = json.dumps({"version": 1, "hooks": hooks}).encode()
    cfg.write_bytes(raw)
    assert uninstall_main(["hook", "--tool", "copilot"]) == 0
    assert cfg.read_bytes() == raw


# --- cline (the extension): one script per event --- #


@pytest.mark.parametrize("windows", [False, True], ids=["bash", "ps1"])
def test_remove_cline_deletes_den_scripts(tmp_path, monkeypatch, windows):
    # Both names, whichever platform installed: the .ps1 ones begin with a BOM.
    _installed(tmp_path, "cline", windows=windows)
    hooks_dir = tmp_path / _CLINE
    assert len(_names(hooks_dir)) == 3
    if windows:
        assert (hooks_dir / "TaskStart.ps1").read_bytes().startswith(b"\xef\xbb\xbf")
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook", "--tool", "cline"]) == 0
    assert _names(hooks_dir) == []


def test_remove_cline_keeps_a_foreign_script(tmp_path, monkeypatch):
    _installed(tmp_path, "cline")
    hooks_dir = tmp_path / _CLINE
    (hooks_dir / "UserPromptSubmit").write_text("#!/bin/sh\necho mine\n")
    (hooks_dir / "Notification").write_text("# den hook run, not an event den used\n")
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook", "--tool", "cline"]) == 0
    assert _names(hooks_dir) == ["Notification", "UserPromptSubmit"]
    assert (hooks_dir / "UserPromptSubmit").read_text() == "#!/bin/sh\necho mine\n"


def test_remove_cline_with_an_explicit_config(tmp_path, monkeypatch):
    # The earliest dens put the scripts in a user-level dir; --config reaches it.
    hooks_dir = tmp_path / "home" / ".cline" / "hooks"
    for generic, native in _CLINE_EVENTS.items():
        _write_cline_script(hooks_dir, native, generic, None)
    monkeypatch.chdir(tmp_path)
    argv = ["hook", "--tool", "cline", "--config", str(hooks_dir)]
    assert uninstall_main(argv) == 0
    assert _names(hooks_dir) == []


def test_remove_cline_beside_a_single_file_clinerules(tmp_path, monkeypatch):
    (tmp_path / ".clinerules").write_text("Use tabs.\n")
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook", "--tool", "cline"]) == 0
    assert (tmp_path / ".clinerules").read_text() == "Use tabs.\n"


# --- cline-cli: the .clinerules rule files --- #


def test_remove_cline_cli_clears_rule_files(tmp_path, monkeypatch, capsys):
    _installed(tmp_path, "cline-cli")
    rules = tmp_path / _RULES
    (rules / "team-style.md").write_text("Use tabs.\n")
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook", "--tool", "cline-cli"]) == 0
    assert _names(rules) == ["team-style.md"], "the rule files den did not write stay"
    assert "removed den hooks from cline-cli" in capsys.readouterr().err


def test_remove_all_tools_still_covers_cline_cli(tmp_path, monkeypatch):
    _installed(tmp_path, "cline-cli")
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook", "--all-tools"]) == 0
    assert not (tmp_path / _RULES / "den-imprint.md").exists()
    assert not (tmp_path / _RULES / "den-memory.md").exists()


@pytest.mark.parametrize("name", ["den-imprint.md", "den-memory.md"])
def test_remove_cline_cli_keeps_a_rule_file_den_did_not_write(
    tmp_path, monkeypatch, capsys, name
):
    """cline loads every .clinerules/*.md, so den's stale copies have to go,
    but a file there under one of den's names without den's header is someone
    else's and stays byte-identical, with a line saying why."""
    _installed(tmp_path, "cline-cli")
    mine = tmp_path / _RULES / name
    mine.write_bytes(b"# My own rules\r\nkeep me\r\n")
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook", "--tool", "cline-cli"]) == 0
    assert mine.read_bytes() == b"# My own rules\r\nkeep me\r\n"
    assert _names(tmp_path / _RULES) == [name], "den's other file went"
    err = capsys.readouterr().err
    assert f"left {mine.resolve()}" in err and "not a file den wrote" in err


def test_remove_cline_cli_removes_a_memory_copy_without_the_imprint(
    tmp_path, monkeypatch
):
    # The mirror followed den-imprint.md, but a stale copy outlives it when the
    # imprint rule was deleted by hand.
    _installed(tmp_path, "cline-cli")
    (tmp_path / _RULES / "den-imprint.md").unlink()
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook", "--tool", "cline-cli"]) == 0
    assert _names(tmp_path / _RULES) == []


def test_remove_cline_cli_removes_a_rule_an_editor_saved_with_a_bom(
    tmp_path, monkeypatch
):
    _installed(tmp_path, "cline-cli")
    rule = tmp_path / _RULES / "den-imprint.md"
    rule.write_bytes(b"\xef\xbb\xbf" + rule.read_bytes())
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook", "--tool", "cline-cli"]) == 0
    assert _names(tmp_path / _RULES) == []


def test_remove_cline_cli_names_the_ancestor_clinerules_it_cleared(
    tmp_path, monkeypatch, capsys
):
    # cwd has no .den of its own; an ancestor does, and the rule files went
    # beside it. The message names that dir, not a cwd-relative one.
    _installed(tmp_path, "cline-cli")
    sub = tmp_path / "sub"
    sub.mkdir()
    monkeypatch.chdir(sub)
    assert uninstall_main(["hook", "--tool", "cline-cli"]) == 0
    assert _names(tmp_path / _RULES) == []
    err = capsys.readouterr().err
    assert str((tmp_path / ".clinerules").resolve()) in err
    assert str(sub / ".clinerules") not in err


def test_remove_cline_cli_refuses_symlinked_ancestor_clinerules(
    tmp_path, monkeypatch, capsys, symlink
):
    """remove ignores `config` and works beside the nearest ancestor .den, so
    the path _resolve_config vetted (cwd/.clinerules) is not the one it unlinks
    from. An ancestor .clinerules symlink must not become a licence to delete
    real files outside the workspace."""
    outside = tmp_path / "elsewhere"
    outside.mkdir()
    (outside / "den-imprint.md").write_bytes(_IMPRINT_RULE.encode())
    (outside / "den-memory.md").write_bytes(_MEMORY_RULE.encode())
    ws = tmp_path / "workspace"
    (ws / ".den").mkdir(parents=True)
    symlink(outside, ws / ".clinerules")
    nested = ws / "pkg" / "sub"
    nested.mkdir(parents=True)
    monkeypatch.chdir(nested)
    rc = uninstall_main(["hook", "--tool", "cline-cli"])
    # the destruction first: it is the finding, and rc only reports it
    assert (outside / "den-imprint.md").read_bytes() == _IMPRINT_RULE.encode()
    assert (outside / "den-memory.md").read_bytes() == _MEMORY_RULE.encode()
    assert rc == 1
    err = capsys.readouterr().err
    assert "is a symlink" in err
    assert "removed den hooks" not in err


def test_remove_cline_cli_refuses_symlinked_rule_file(tmp_path, monkeypatch, symlink):
    # The .clinerules dir is real; only one rule file is a symlink. unlink would
    # drop just the link, but a file den refuses to read is not one it may clear.
    outside = tmp_path / "notes.md"
    outside.write_bytes(_IMPRINT_RULE.encode())
    proj = _installed(tmp_path / "repo", "cline-cli")
    (proj / _RULES / "den-imprint.md").unlink()
    symlink(outside, proj / _RULES / "den-imprint.md")
    monkeypatch.chdir(proj)
    assert uninstall_main(["hook", "--tool", "cline-cli"]) == 1
    assert outside.read_bytes() == _IMPRINT_RULE.encode()
    assert (proj / _RULES / "den-imprint.md").is_symlink()
    assert (proj / _RULES / "den-memory.md").is_file(), "nothing was touched"


def test_remove_cline_cli_refuses_a_directory_at_a_rule_file(tmp_path, monkeypatch):
    # remove skipped the directory (is_file() is False), unlinked the imprint and
    # reported success, leaving the invalid target behind.
    proj = _installed(tmp_path / "repo", "cline-cli")
    rules = proj / _RULES
    (rules / "den-memory.md").unlink()
    (rules / "den-memory.md").mkdir()
    monkeypatch.chdir(proj)
    assert uninstall_main(["hook", "--tool", "cline-cli"]) == 1
    assert (rules / "den-imprint.md").is_file(), "not removed piecemeal"
    assert (rules / "den-memory.md").is_dir()


def test_remove_treats_a_single_file_clinerules_as_not_installed(
    tmp_path, monkeypatch, capsys
):
    """A regular FILE at .clinerules is cline's classic single-file rules
    format, not something a repo planted: cline-cli was simply never installed
    there, so remove says nothing and succeeds, and the file is left alone."""
    proj = tmp_path / "repo"
    (proj / ".den").mkdir(parents=True)
    (proj / ".clinerules").write_text("Use tabs.\n")
    monkeypatch.chdir(proj)
    assert uninstall_main(["hook", "--tool", "cline-cli"]) == 0
    assert "refusing" not in capsys.readouterr().err
    assert (proj / ".clinerules").read_text() == "Use tabs.\n"


def test_uninstall_hook_succeeds_beside_a_single_file_clinerules(
    tmp_path, monkeypatch, capsys
):
    """`den uninstall hook` (every tool) exited 1 because the never-installed
    cline-cli refused the classic .clinerules file."""
    _installed(tmp_path, "claude")
    (tmp_path / ".clinerules").write_text("Use tabs.\n")
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook"]) == 0
    assert "refusing" not in capsys.readouterr().err
    assert (tmp_path / ".clinerules").read_text() == "Use tabs.\n"


# --- claude: settings.local.json, and the settings.json earlier dens used --- #


def test_remove_reads_both_claude_files(tmp_path, monkeypatch, capsys):
    _installed(tmp_path, "claude")
    shared = tmp_path / _SHARED
    foreign = {"hooks": [{"type": "command", "command": "echo mine"}]}
    shared.write_text(
        json.dumps(
            {
                "theme": "dark",
                "hooks": {
                    "UserPromptSubmit": [_den_group("claude"), foreign],
                    "Stop": [_den_group("claude", "stop")],
                },
            }
        )
    )
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook", "--tool", "claude"]) == 0
    assert json.loads(shared.read_text()) == {
        "theme": "dark",
        "hooks": {"UserPromptSubmit": [foreign]},
    }
    assert json.loads((tmp_path / _LOCAL).read_text()) == {}
    assert f"{shared.resolve()} held den's claude hooks" in capsys.readouterr().err


def test_remove_leaves_a_settings_json_without_den_entries_byte_identical(
    tmp_path, monkeypatch
):
    monkeypatch.chdir(tmp_path)
    shared = tmp_path / _SHARED
    shared.parent.mkdir()
    raw = b'{"theme":"dark",  "hooks": {"Stop": []}}'
    shared.write_bytes(raw)
    assert uninstall_main(["hook", "--tool", "claude"]) == 0
    assert shared.read_bytes() == raw


def test_explicit_config_is_the_only_file_touched(tmp_path, monkeypatch):
    _installed(tmp_path, "claude")
    shared = tmp_path / _SHARED
    raw = json.dumps({"hooks": {"Stop": [_den_group("claude", "stop")]}})
    shared.write_text(raw)
    local = (tmp_path / _LOCAL).read_bytes()
    cfg = tmp_path / "elsewhere.json"
    cfg.write_text(json.dumps({"hooks": {"Stop": [_den_group("claude", "stop")]}}))
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook", "--tool", "claude", "--config", str(cfg)]) == 0
    assert json.loads(cfg.read_text()) == {}
    assert shared.read_text() == raw
    assert (tmp_path / _LOCAL).read_bytes() == local


def test_remove_a_retired_gemini_config_with_an_explicit_config(tmp_path, monkeypatch):
    # gemini (retired) shared claude's settings format; MIGRATIONS.md gives
    # this command for a .gemini/settings.json an older den wrote.
    gemini = tmp_path / ".gemini" / "settings.json"
    gemini.parent.mkdir()
    hooks = {"BeforeAgent": [_den_group("gemini")], "AfterTool": [_den_group("x")]}
    gemini.write_text(json.dumps({"theme": "dark", "hooks": hooks}))
    monkeypatch.chdir(tmp_path)
    argv = ["hook", "--tool", "claude", "--config", ".gemini/settings.json"]
    assert uninstall_main(argv) == 0
    assert json.loads(gemini.read_text()) == {"theme": "dark"}


# --- the workspace config must stay in the workspace --- #


@pytest.mark.parametrize("tool", ["claude", "copilot", "cline"])
def test_uninstall_hook_refuses_a_symlinked_config_dir(
    tmp_path, monkeypatch, capsys, symlink, tool
):
    """A repo-shipped `.claude` (or `.github`, `.clinerules`) -> the user's own
    dir must not let remove rewrite or delete the user's global hooks."""
    outside = _installed(tmp_path / "home", tool)
    before = _tree(outside)
    proj = tmp_path / "repo"
    proj.mkdir()
    top = {"claude": ".claude", "copilot": ".github", "cline": ".clinerules"}[tool]
    symlink(outside / top, proj / top)
    monkeypatch.chdir(proj)
    assert uninstall_main(["hook", "--tool", tool]) == 1
    assert _tree(outside) == before, "target untouched"
    refusals = [
        line
        for line in capsys.readouterr().err.splitlines()
        if "(the workspace config must stay" in line
    ]
    assert len(refusals) == 1
    assert refusals[0].startswith("den uninstall hook: refusing ")


@pytest.mark.parametrize("name", ["settings.local.json", "settings.json"])
def test_uninstall_hook_refuses_a_symlinked_claude_file(
    tmp_path, monkeypatch, symlink, name
):
    # settings.json is the file den moved its old entries out of; stripping
    # through a link would rewrite the target just the same.
    settings = tmp_path / "home" / "settings.json"
    settings.parent.mkdir(parents=True)
    hooks = {"UserPromptSubmit": [_den_group("claude")]}
    settings.write_text(json.dumps({"theme": "dark", "hooks": hooks}))
    before = settings.read_bytes()
    proj = tmp_path / "repo"
    (proj / ".claude").mkdir(parents=True)
    symlink(settings, proj / ".claude" / name)
    monkeypatch.chdir(proj)
    assert uninstall_main(["hook", "--tool", "claude"]) == 1
    assert settings.read_bytes() == before


@pytest.mark.parametrize("dangling", [False, True])
def test_symlinked_settings_json_without_den_entries_is_not_refused(
    tmp_path, monkeypatch, capsys, symlink, dangling
):
    """A repo linking .claude/settings.json to a shared file (or to nothing) is
    none of den's business unless den's old entries are there to take out."""
    shared = tmp_path / "config" / "claude.json"
    shared.parent.mkdir()
    if not dangling:
        shared.write_text(json.dumps({"permissions": {"allow": ["Bash(ls)"]}}))
    proj = tmp_path / "repo"
    (proj / ".claude").mkdir(parents=True)
    symlink(shared, proj / ".claude" / "settings.json")
    monkeypatch.chdir(proj)
    assert uninstall_main(["hook", "--tool", "claude"]) == 0
    assert "refusing" not in capsys.readouterr().err
    if not dangling:
        assert json.loads(shared.read_text()) == {
            "permissions": {"allow": ["Bash(ls)"]}
        }
    else:
        assert not shared.exists()


def test_explicit_config_through_a_symlink_is_followed(tmp_path, monkeypatch, symlink):
    """--config is the user's own choice, not repo-controlled: dotfiles managers
    link ~/.claude, and the target is what gets edited."""
    real = tmp_path / "dotfiles" / "claude" / "settings.json"
    real.parent.mkdir(parents=True)
    real.write_text(json.dumps({"theme": "dark", "hooks": _claude_hooks(None)}))
    home = tmp_path / "home"
    home.mkdir()
    symlink(real.parent, home / ".claude")
    monkeypatch.chdir(tmp_path)
    linked = home / ".claude" / "settings.json"
    assert uninstall_main(["hook", "--tool", "claude", "--config", str(linked)]) == 0
    assert json.loads(real.read_text()) == {"theme": "dark"}
    assert (home / ".claude").is_symlink()


# --- how a config is rewritten: one rename, its owner and mode kept --- #

# A config was truncated and then written in place, so a write that failed
# part-way (a full disk, an I/O error) left the user's settings empty or cut
# short. file_size_limit makes the write fail for real after its first bytes.

_JSON_CONFIGS = pytest.mark.parametrize(
    ("tool", "rel"), [("claude", _LOCAL), ("copilot", _COPILOT)]
)
_BIG = "x" * 6000  # a value of the user's that takes any rewrite past the limit


@_JSON_CONFIGS
def test_uninstall_hook_keeps_the_config_when_the_write_fails_part_way(
    tmp_path, monkeypatch, capsys, file_size_limit, tool, rel
):
    _installed(tmp_path, tool)
    cfg = tmp_path / rel
    data = json.loads(cfg.read_text())
    data["keep"] = _BIG
    cfg.write_text(json.dumps(data))
    installed = cfg.read_bytes()
    monkeypatch.chdir(tmp_path)
    with file_size_limit(1024):
        assert uninstall_main(["hook", "--tool", tool]) == 1
    assert cfg.read_bytes() == installed, "den's hooks included"
    assert _names(cfg.parent) == [cfg.name], "no temporary copy is left"
    assert f"den uninstall hook: left {cfg} as it was: " in capsys.readouterr().err


def test_uninstall_hook_keeps_settings_json_when_the_write_fails_part_way(
    tmp_path, monkeypatch, capsys, file_size_limit
):
    # The committed .claude/settings.json is shared with a team.
    monkeypatch.chdir(tmp_path)
    legacy = tmp_path / _SHARED
    legacy.parent.mkdir()
    hooks = {"Stop": [_den_group("claude", "stop")]}
    original = json.dumps({"keep": "x" * 9000, "hooks": hooks}).encode()
    legacy.write_bytes(original)
    with file_size_limit(4096):
        assert uninstall_main(["hook", "--tool", "claude"]) == 1
    assert legacy.read_bytes() == original
    err = capsys.readouterr().err
    assert f"den uninstall hook: left {legacy} as it was: " in err


def test_uninstall_hook_leaves_a_hard_linked_config_as_it_was(
    tmp_path, monkeypatch, capsys, hard_link
):
    """A config is replaced through a new copy, so one with a second hard link
    (a dotfiles repo) is left as it was, den's hooks included, and named, as
    `den uninstall` leaves such an rc file: the copy would take only this name,
    and the other would keep den's hooks."""
    _installed(tmp_path, "claude")
    cfg = tmp_path / _LOCAL
    installed = cfg.read_bytes()
    other = tmp_path / "dotfiles-settings.json"
    hard_link(cfg, other)
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook", "--tool", "claude"]) == 1
    assert cfg.read_bytes() == installed
    assert other.samefile(cfg)
    err = capsys.readouterr().err
    assert f"den uninstall hook: left {cfg} as it was: it has 2 hard links" in err


@pytest.fixture
def umask_022():
    old = os.umask(0o022)
    yield
    os.umask(old)


@pytest.mark.skipif(os.name == "nt", reason="POSIX permission bits")
@pytest.mark.parametrize("mode", [0o600, 0o640], ids=oct)
def test_uninstall_hook_keeps_the_config_mode(tmp_path, monkeypatch, umask_022, mode):
    # The new copy takes the config's permission bits, as the in-place write
    # kept them.
    _installed(tmp_path, "claude")
    cfg = tmp_path / _LOCAL
    data = json.loads(cfg.read_text())
    data["keep"] = 1
    cfg.write_text(json.dumps(data))
    cfg.chmod(mode)
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook", "--tool", "claude"]) == 0
    assert stat.S_IMODE(cfg.stat().st_mode) == mode
    assert json.loads(cfg.read_text()) == {"keep": 1}


@_JSON_CONFIGS
def test_uninstall_hook_writes_the_config_with_the_platforms_line_ends(
    tmp_path, monkeypatch, tool, rel
):
    # write_text wrote os.linesep (CRLF on Windows); the new copy keeps that.
    _installed(tmp_path, tool)
    cfg = tmp_path / rel
    data = json.loads(cfg.read_text())
    data["keep"] = {"a": 1, "b": [2]}
    cfg.write_text(json.dumps(data))
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook", "--tool", tool]) == 0
    lines = cfg.read_bytes().split(os.linesep.encode())
    assert len(lines) > 2
    assert not [ln for ln in lines if b"\n" in ln or b"\r" in ln]


# --- arguments --- #


def test_uninstall_hook_rejects_an_unknown_tool(tmp_path, monkeypatch, capsys):
    _installed(tmp_path, "claude")
    before = _tree(tmp_path)
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook", "--tool", "gemini"]) == 2
    assert "den uninstall hook: unknown tool 'gemini'" in capsys.readouterr().err
    assert _tree(tmp_path) == before


@pytest.mark.parametrize("flag", ["--help", "-h", "help"])
def test_uninstall_hook_help_prints_usage(tmp_path, monkeypatch, capsys, flag):
    _installed(tmp_path, "claude")
    before = _tree(tmp_path)
    monkeypatch.chdir(tmp_path)
    assert uninstall_main(["hook", flag]) == 0
    assert "usage: den uninstall" in capsys.readouterr().out
    assert _tree(tmp_path) == before, "help removes nothing"


def test_uninstall_hook_runs_without_a_terminal(tmp_path, monkeypatch, capsys):
    # A script needs no flag beyond the tool list, and gets no prompt: the
    # status lines go to stderr.
    _installed(tmp_path, "claude", "copilot")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr("sys.stdin", io.StringIO(""))
    assert uninstall_main(["hook"]) == 0
    out = capsys.readouterr()
    assert out.out == ""
    assert "removed den hooks from claude" in out.err
