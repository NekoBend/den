"""Tests for den verify (den/_verify.py)."""

import os
from pathlib import Path

from den import _verify
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


def _capture_cmds(monkeypatch, rc: int = 0, out: str = ""):
    cmds: list[list[str]] = []
    monkeypatch.setattr(_verify.shutil, "which", _fake_which)
    monkeypatch.setattr(
        _verify.subprocess,
        "run",
        lambda cmd, **k: cmds.append(cmd) or _Proc(rc, out),
    )
    return cmds


def _capture_calls(monkeypatch, rc: int = 0, out: str = ""):
    """Every subprocess.run call as a dict: its kwargs plus "cmd"."""
    calls: list[dict] = []
    monkeypatch.setattr(_verify.shutil, "which", _fake_which)
    monkeypatch.setattr(
        _verify.subprocess,
        "run",
        lambda cmd, **k: calls.append({"cmd": cmd, **k}) or _Proc(rc, out),
    )
    return calls


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
    monkeypatch.setattr(_verify.shutil, "which", lambda name, path=None: None)
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
    assert _verify._search_path() == str(tmp_path)


def test_tool_inside_the_workspace_is_refused(tmp_path, monkeypatch, capsys):
    """A repo-supplied ruff/ty is refused (SKIP), not executed."""
    f = _py(tmp_path)
    monkeypatch.chdir(tmp_path)  # the workspace `den verify` is invoked from
    cmds = _capture_cmds(monkeypatch)
    monkeypatch.setattr(
        _verify.shutil, "which", lambda name, path=None: str(tmp_path / name)
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
    assert [c[-1] for c in formats] == [str(a), str(b)]
    out = capsys.readouterr().out
    assert f"== {a}" in out and f"== {b}" in out
    assert "across 2 files" in out


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
    monkeypatch.setattr(_verify.shutil, "which", lambda name, path=None: None)
    assert cli_main(["verify", str(f)]) == 0
    assert "config: ruff" in capsys.readouterr().out


def test_cli_usage_mentions_verify_as_plumbing(capsys):
    cli_main(["--help"])
    assert "den verify" in capsys.readouterr().out
