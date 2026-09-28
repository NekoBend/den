"""Tests for den verify (den/_verify.py)."""

import os
import shutil
from pathlib import Path

import pytest

from den import _exe, _verify
from den._verify import main as verify_main
from den.cli import main as cli_main


def _py(tmp_path: Path, rel: str = "sub/mod.py") -> Path:
    f = tmp_path / rel
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text("class T:\n    def m(self):\n        return 1\n")
    return f


class _Proc:
    def __init__(self, rc: int = 0, out: str = ""):
        self.returncode = rc
        self.stdout = out
        self.stderr = ""


def _tool(name: str) -> str:
    """Where the fake which() finds a tool: absolute, and outside any cwd.

    Built from the cwd's anchor so it is a real absolute path on POSIX and on
    Windows alike (a "/usr/bin/x" literal is drive-relative on Windows).
    """
    return str(Path(Path.cwd().anchor) / "den-tools" / name)


def _fake_which(name, path=None):
    return _tool(name)


def _show_settings(settings_path: str | None) -> str:
    """What `ruff check --show-settings FILE` prints first; ruff Debug-quotes
    the path (a Windows one has its backslashes doubled)."""
    head = 'Resolved settings for: "/w/f.py"\n'
    if settings_path is not None:
        quoted = settings_path.replace("\\", "\\\\").replace('"', '\\"')
        head += f'Settings path: "{quoted}"\n'
    return head + '\n# General Settings\ncache_dir = "/w/.ruff_cache"\n'


class _Runs:
    """What the fake subprocess.run saw: each stage call as its kwargs plus
    "cmd" (calls), the same as bare argv (cmds), and every `ruff check
    --show-settings` query (queries), which is config discovery for a file
    with no config above it rather than a stage."""

    def __init__(self) -> None:
        self.calls: list[dict] = []
        self.cmds: list[list[str]] = []
        self.queries: list[list[str]] = []


def _capture(
    monkeypatch, rc: int = 0, out: str = "", settings_path: str | None = None
) -> _Runs:
    """Fake which() and run(); the settings query is answered with
    `settings_path` (None: ruff names no config file)."""
    runs = _Runs()
    monkeypatch.setattr(_exe.shutil, "which", _fake_which)

    def _run(cmd, **k):
        if "--show-settings" in cmd:
            runs.queries.append(cmd)
            return _Proc(0, _show_settings(settings_path))
        runs.calls.append({"cmd": cmd, **k})
        runs.cmds.append(cmd)
        return _Proc(rc, out)

    monkeypatch.setattr(_verify.subprocess, "run", _run)
    return runs


def _capture_cmds(monkeypatch, rc: int = 0, out: str = ""):
    return _capture(monkeypatch, rc, out).cmds


def _capture_calls(monkeypatch, rc: int = 0, out: str = ""):
    """Every stage's subprocess.run call as a dict: its kwargs plus "cmd"."""
    return _capture(monkeypatch, rc, out).calls


# ---- config discovery (real filesystem, mirrors ruff's nearest-wins) ----


def test_ruff_config_nearest_shadows_root(tmp_path):
    f = _py(tmp_path)
    (tmp_path / "pyproject.toml").write_text("[tool.ruff]\nselect=['F']\n")
    (tmp_path / "sub" / "ruff.toml").write_text("select=['E']\n")
    cfg = _verify._ruff_config(f)
    assert cfg is not None
    path, kind = cfg
    assert path == tmp_path / "sub" / "ruff.toml"  # nearest wins outright
    assert kind == "ruff.toml"


def test_ruff_config_pyproject_without_section_does_not_stop_walk(tmp_path):
    f = _py(tmp_path)
    (tmp_path / "sub" / "pyproject.toml").write_text("[project]\nname='x'\n")
    (tmp_path / ".ruff.toml").write_text("select=['F']\n")
    cfg = _verify._ruff_config(f)
    assert cfg is not None
    assert cfg[0] == tmp_path / ".ruff.toml"  # walked past the sectionless one


def test_ruff_config_none(tmp_path, monkeypatch):
    # anchor the walk in an isolated tree with nothing above tmp_path either
    f = _py(tmp_path)
    cfg = _verify._ruff_config(f)
    # tmp_path trees have no ruff config; the walk may only find one if the
    # host has one at / - treat both "None" and "outside tmp_path" as pass.
    assert cfg is None or tmp_path not in cfg[0].parents


# ---- no config above the file: ruff falls back (cwd project, user config) ----


def test_ruff_fallback_config_is_reported_and_no_defaults_added(
    tmp_path, monkeypatch, capsys
):
    """With nothing above the file, ruff uses the cwd's project config (or
    the user-level one). den used to print 'ruff <- none' and add D101-D103
    on top of whatever ruff really used."""
    f = _py(tmp_path)
    monkeypatch.setattr(_verify, "_ruff_config", lambda _f: None)
    cfg = Path(Path.cwd().anchor) / "proj" / "pyproject.toml"
    runs = _capture(monkeypatch, settings_path=str(cfg))
    assert verify_main([str(f)]) == 0
    cmds, queries = runs.cmds, runs.queries
    lint = next(c for c in cmds if Path(c[0]).name == "ruff" and c[1] == "check")
    assert "--extend-select" not in lint
    out = capsys.readouterr().out
    assert f"config: ruff <- pyproject.toml [tool.ruff] ({cfg.parent}" in out
    assert "den defaults" not in out
    assert len(queries) == 1
    assert Path(queries[0][0]).is_absolute(), "asked by absolute path too"


def test_den_defaults_when_ruff_names_no_settings_file(tmp_path, monkeypatch, capsys):
    f = _py(tmp_path)
    monkeypatch.setattr(_verify, "_ruff_config", lambda _f: None)
    cmds = _capture_cmds(monkeypatch)
    assert verify_main([str(f)]) == 0
    lint = next(c for c in cmds if Path(c[0]).name == "ruff" and c[1] == "check")
    assert "D101,D102,D103" in lint
    assert "config: ruff <- none -> den defaults" in capsys.readouterr().out


def test_fallback_is_asked_once_per_run(tmp_path, monkeypatch):
    a = _py(tmp_path, "a.py")
    b = _py(tmp_path, "b.py")
    monkeypatch.setattr(_verify, "_ruff_config", lambda _f: None)
    runs = _capture(monkeypatch)
    verify_main([str(a), str(b)])
    assert len(runs.queries) == 1, "the fallback depends on the cwd, not the file"


def test_settings_path_parses_ruffs_debug_quoting():
    """ruff prints the path Debug-quoted: backslashes doubled on Windows."""
    win = 'Settings path: "C:\\\\Users\\\\u\\\\ruff.toml"'
    assert _verify._settings_path(win) == "C:\\Users\\u\\ruff.toml"
    assert _verify._settings_path('Settings path: "/h/.config/ruff/ruff.toml"') == (
        "/h/.config/ruff/ruff.toml"
    )
    assert _verify._settings_path("Resolved settings for: x\n") is None


@pytest.mark.skipif(shutil.which("ruff") is None, reason="needs a real ruff")
def test_real_ruff_cwd_project_config_is_named(tmp_path, monkeypatch, capsys):
    """The finding's probe with the real ruff: cwd proj/ has a config, the
    file lives outside it with none above."""
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "pyproject.toml").write_text('[tool.ruff.lint]\nselect = ["E", "F"]\n')
    other = tmp_path / "o"
    other.mkdir()
    f = other / "f.py"
    f.write_text("def f():\n    return 1\n")
    for var in ("HOME", "USERPROFILE", "XDG_CONFIG_HOME", "APPDATA"):
        monkeypatch.setenv(var, str(tmp_path / "home"))  # no user-level config
    monkeypatch.chdir(proj)
    monkeypatch.setattr(_verify, "_ruff_config", lambda _f: None)  # none above
    verify_main([str(f)])
    out = capsys.readouterr().out
    assert f"config: ruff <- pyproject.toml [tool.ruff] ({proj.resolve()}" in out
    assert "D103" not in out


def test_project_root_prefers_pyproject_ancestor(tmp_path):
    f = _py(tmp_path)
    (tmp_path / "pyproject.toml").write_text("[project]\nname='x'\n")
    assert _verify._project_root(f) == tmp_path


def test_project_root_falls_back_to_file_dir(tmp_path):
    f = _py(tmp_path)
    root = _verify._project_root(f)
    assert root == f.parent or (root / "pyproject.toml").is_file()


# ---- behavior (subprocess mocked) ----


def test_den_defaults_only_without_config(tmp_path, monkeypatch, capsys):
    f = _py(tmp_path)
    cmds = _capture_cmds(monkeypatch)
    monkeypatch.setattr(_verify, "_ruff_config", lambda _f: None)
    assert verify_main([str(f)]) == 0
    lint = next(c for c in cmds if Path(c[0]).name == "ruff" and c[1] == "check")
    assert "--extend-select" in lint and "D101,D102,D103" in lint
    assert "den defaults" in capsys.readouterr().out


def test_project_config_wins_no_injected_flags(tmp_path, monkeypatch, capsys):
    f = _py(tmp_path)
    (tmp_path / "sub" / "ruff.toml").write_text("select=['F']\n")
    cmds = _capture_cmds(monkeypatch)
    assert verify_main([str(f)]) == 0
    lint = next(c for c in cmds if Path(c[0]).name == "ruff" and c[1] == "check")
    assert "--extend-select" not in lint  # project settings never stomped
    assert "ruff.toml" in capsys.readouterr().out  # and the winner is shown


def test_ty_gets_explicit_project_root(tmp_path, monkeypatch):
    f = _py(tmp_path)
    (tmp_path / "pyproject.toml").write_text("[project]\nname='x'\n")
    cmds = _capture_cmds(monkeypatch)
    verify_main([str(f)])
    ty = next(c for c in cmds if Path(c[0]).name == "ty")
    assert "--project" in ty
    assert str(tmp_path) == ty[ty.index("--project") + 1]


def test_venv_line_reports_virtual_env(tmp_path, monkeypatch, capsys):
    f = _py(tmp_path)
    _capture_cmds(monkeypatch)
    monkeypatch.setenv("VIRTUAL_ENV", "/some/venv")
    verify_main([str(f)])
    assert "venv: /some/venv (VIRTUAL_ENV)" in capsys.readouterr().out


def test_venv_line_actionable_when_missing(tmp_path, monkeypatch, capsys):
    f = _py(tmp_path)
    _capture_cmds(monkeypatch)
    monkeypatch.delenv("VIRTUAL_ENV", raising=False)
    verify_main([str(f)])
    assert "uv sync" in capsys.readouterr().out


def test_fail_detail_is_capped(tmp_path, monkeypatch, capsys):
    f = _py(tmp_path)
    noise = "\n".join(f"line {i}" for i in range(80))
    _capture_cmds(monkeypatch, rc=1, out=noise)
    assert verify_main([str(f)]) == 1
    out = capsys.readouterr().out
    assert "more lines)" in out
    assert "line 79" not in out  # beyond the cap


def test_skip_names_next_action(tmp_path, monkeypatch, capsys):
    f = _py(tmp_path)
    monkeypatch.setattr(_exe.shutil, "which", lambda name, path=None: None)
    assert verify_main([str(f)]) == 0  # skips are not failures
    out = capsys.readouterr().out
    assert "SKIP format (ruff not installed: uv tool install ruff)" in out
    assert "SKIP typecheck (ty not installed: uv tool install ty)" in out


# ---- tool resolution (never from the workspace, never by bare name) ----


def test_tools_run_by_absolute_path(tmp_path, monkeypatch):
    """cmd[0] is which()'s absolute result: no PATH/cwd search by the OS."""
    f = _py(tmp_path)
    cmds = _capture_cmds(monkeypatch)
    assert verify_main([str(f)]) == 0
    assert [Path(c[0]).name for c in cmds] == ["ruff", "ruff", "ty"]
    assert all(Path(c[0]).is_absolute() for c in cmds)
    assert all(c[0] == _tool(Path(c[0]).name) for c in cmds)


def test_search_path_drops_current_directory_entries(tmp_path, monkeypatch):
    """An empty entry, "." and a relative dir all mean the workspace: dropped."""
    monkeypatch.setenv(
        "PATH", os.pathsep.join([str(tmp_path), "", os.curdir, "rel/bin"])
    )
    assert _exe.search_path() == str(tmp_path)


def test_tool_in_the_working_directory_is_refused(tmp_path, monkeypatch, capsys):
    """A ruff/ty sitting in the cwd - all the curdir search can reach - is
    refused (SKIP), not executed."""
    f = _py(tmp_path)
    monkeypatch.chdir(tmp_path)  # the workspace `den verify` is invoked from
    cmds = _capture_cmds(monkeypatch)
    monkeypatch.setattr(  # a repo shipping ./ruff, next to the checked file
        _exe.shutil, "which", lambda name, path=None: str(tmp_path / name)
    )
    assert verify_main([str(f)]) == 0  # a refusal is a skip, not a failure
    out = capsys.readouterr().out
    planted = tmp_path / "ruff"
    assert f"den verify: refusing ruff resolved inside the workspace ({planted})" in out
    assert "SKIP format (ruff not run:" in out
    assert "SKIP lint (ruff not run:" in out
    assert "SKIP typecheck (ty not run:" in out
    assert "3 skipped" in out
    assert cmds == []  # nothing was run


def test_tool_in_a_project_venv_is_allowed(tmp_path, monkeypatch, capsys):
    """The project's own .venv/bin/ruff is under the cwd but not in it: the
    curdir search cannot reach a subdirectory, and it is the wanted tool."""
    f = _py(tmp_path)
    monkeypatch.chdir(tmp_path)
    venv_bin = tmp_path / ".venv" / "bin"
    cmds = _capture_cmds(monkeypatch)
    monkeypatch.setattr(
        _exe.shutil, "which", lambda name, path=None: str(venv_bin / name)
    )
    assert verify_main([str(f)]) == 0
    assert [c[0] for c in cmds] == [
        str(venv_bin / "ruff"),
        str(venv_bin / "ruff"),
        str(venv_bin / "ty"),
    ]
    out = capsys.readouterr().out
    assert "refusing" not in out
    assert "PASS format" in out


def test_tool_output_is_decoded_as_utf8(tmp_path, monkeypatch):
    """ruff/ty emit UTF-8 snippets; the locale codec raises on cp932/cp1252."""
    f = _py(tmp_path)
    calls = _capture_calls(monkeypatch)
    assert verify_main([str(f)]) == 0
    assert len(calls) == 3
    for call in calls:
        assert call["encoding"] == "utf-8"
        assert call["errors"] == "replace"
        assert call["capture_output"] is True


def test_usage_and_errors(tmp_path, capsys):
    assert verify_main([]) == 0  # usage, not an error
    assert "usage: den verify" in capsys.readouterr().out
    assert verify_main([str(tmp_path / "missing.py")]) == 2
    notpy = tmp_path / "x.sh"
    notpy.write_text("echo hi\n")
    assert verify_main([str(notpy)]) == 2
    assert "standard tools" in capsys.readouterr().err  # points at the alternative


def test_several_files_each_verified(tmp_path, monkeypatch, capsys):
    a = _py(tmp_path, "a.py")
    b = _py(tmp_path, "b.py")
    cmds = _capture_cmds(monkeypatch)
    assert verify_main([str(a), str(b)]) == 0
    formats = [
        c for c in cmds if Path(c[0]).name == "ruff" and c[1:3] == ["format", "--check"]
    ]
    assert [c[3:] for c in formats] == [[str(a), str(b)]]  # one run for both
    out = capsys.readouterr().out
    assert f"== {a}" in out and f"== {b}" in out
    assert out.count("PASS format") == out.count("PASS typecheck") == 2
    assert "6 passed, 0 failed, 0 skipped across 2 files" in out


# ---- one process per stage per (config, project), per-file results kept ----


def _respond(monkeypatch, answer):
    """Fake run(): `answer(argv)` -> (rc, output) per stage call; the settings
    query says ruff uses no config file. Returns the stage argvs."""
    cmds: list[list[str]] = []
    monkeypatch.setattr(_exe.shutil, "which", _fake_which)

    def _run(cmd, **k):
        if "--show-settings" in cmd:
            return _Proc(0, _show_settings(None))
        cmds.append(cmd)
        rc, out = answer(cmd)
        return _Proc(rc, out)

    monkeypatch.setattr(_verify.subprocess, "run", _run)
    return cmds


def test_files_of_one_project_share_one_process_per_stage(tmp_path, monkeypatch):
    """den verify started 3 processes per file, and ty re-resolved the same
    project in every one of them."""
    files = [_py(tmp_path, f"m{i}.py") for i in range(4)]
    (tmp_path / "pyproject.toml").write_text("[project]\nname='x'\n")
    cmds = _respond(monkeypatch, lambda cmd: (0, ""))
    assert verify_main([str(f) for f in files]) == 0
    assert len(cmds) == 3
    for cmd in cmds:
        assert cmd[-4:] == [str(f) for f in files]
    assert cmds[2][1:4] == ["check", "--project", str(tmp_path)]


def test_a_failing_batch_reports_each_file_as_a_solo_run_would(
    tmp_path, monkeypatch, capsys
):
    """Only the file the batch output names is re-run alone, for its exact
    PASS/FAIL and FAIL detail; the others pass without another process."""
    a, b, c = (_py(tmp_path, f"{n}.py") for n in "abc")

    def answer(cmd):
        if cmd[1:3] == ["format", "--check"] and str(b) in cmd:
            return 1, f"Would reformat: {b}\n1 file would be reformatted"
        return 0, ""

    cmds = _respond(monkeypatch, answer)
    assert verify_main([str(a), str(b), str(c)]) == 1
    formats = [x[3:] for x in cmds if x[1:3] == ["format", "--check"]]
    assert formats == [[str(a), str(b), str(c)], [str(b)]]
    out = capsys.readouterr().out
    per_file = out.split("== ")[1:]
    assert "PASS format" in per_file[0]
    assert f"FAIL format\n  Would reformat: {b}" in per_file[1]
    assert "PASS format" in per_file[2]
    assert "8 passed, 1 failed, 0 skipped across 3 files" in out


def test_a_batch_that_errors_reruns_every_file_alone(tmp_path, monkeypatch, capsys):
    """Exit 2 is ruff's (and ty's) own error, not a diagnostic: nothing ties it
    to one file, so each file gets its own run."""
    a, b = _py(tmp_path, "a.py"), _py(tmp_path, "b.py")

    def answer(cmd):
        if Path(cmd[0]).name == "ty" and len(cmd) > 5:
            return 2, "error: something about the batch"
        if Path(cmd[0]).name == "ty" and str(b) in cmd:
            return 1, f"error[x] {b}:1:1 broken"
        return 0, ""

    cmds = _respond(monkeypatch, answer)
    assert verify_main([str(a), str(b)]) == 1
    tys = [x[4:] for x in cmds if Path(x[0]).name == "ty"]
    assert tys == [[str(a), str(b)], [str(a)], [str(b)]]
    out = capsys.readouterr().out
    assert "PASS typecheck" in out.split("== ")[1]
    assert "FAIL typecheck" in out.split("== ")[2]


def test_files_in_different_projects_are_grouped_apart(tmp_path, monkeypatch):
    one = _py(tmp_path / "one", "x.py")
    two = _py(tmp_path / "two", "y.py")
    for root in ("one", "two"):
        (tmp_path / root / "pyproject.toml").write_text("[project]\nname='x'\n")
    cmds = _respond(monkeypatch, lambda cmd: (0, ""))
    assert verify_main([str(one), str(two)]) == 0
    tys = [x for x in cmds if Path(x[0]).name == "ty"]
    assert [x[3] for x in tys] == [str(tmp_path / "one"), str(tmp_path / "two")]
    assert [x[4:] for x in tys] == [[str(one)], [str(two)]]


def test_several_files_one_unusable_still_runs_the_rest(tmp_path, monkeypatch, capsys):
    a = _py(tmp_path, "a.py")
    cmds = _capture_cmds(monkeypatch)
    assert verify_main([str(a), str(tmp_path / "missing.py")]) == 1
    assert any(
        Path(c[0]).name == "ruff" and c[1:3] == ["format", "--check"] for c in cmds
    ), "good file ran"
    captured = capsys.readouterr()
    assert "file not found" in captured.err
    assert "1 failed" in captured.out


def test_all_files_unusable_is_a_usage_error(tmp_path, capsys):
    assert verify_main([str(tmp_path / "x.py"), str(tmp_path / "y.py")]) == 2
    assert capsys.readouterr().err.count("file not found") == 2


def test_cli_dispatches_verify(tmp_path, monkeypatch, capsys):
    f = _py(tmp_path)
    monkeypatch.setattr(_exe.shutil, "which", lambda name, path=None: None)
    assert cli_main(["verify", str(f)]) == 0
    assert "config: ruff" in capsys.readouterr().out


def test_cli_usage_mentions_verify_as_plumbing(capsys):
    cli_main(["--help"])
    assert "den verify" in capsys.readouterr().out
