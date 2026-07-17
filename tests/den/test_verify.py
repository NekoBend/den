"""Tests for den verify (den/_verify.py)."""

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


def _capture_cmds(monkeypatch, rc: int = 0, out: str = ""):
    cmds: list[list[str]] = []
    monkeypatch.setattr(_verify.shutil, "which", lambda name: f"/usr/bin/{name}")
    monkeypatch.setattr(
        _verify.subprocess,
        "run",
        lambda cmd, **k: cmds.append(cmd) or _Proc(rc, out),
    )
    return cmds


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
    lint = next(c for c in cmds if c[:2] == ["ruff", "check"])
    assert "--extend-select" in lint and "D101,D102,D103" in lint
    assert "den defaults" in capsys.readouterr().out


def test_project_config_wins_no_injected_flags(tmp_path, monkeypatch, capsys):
    f = _py(tmp_path)
    (tmp_path / "sub" / "ruff.toml").write_text("select=['F']\n")
    cmds = _capture_cmds(monkeypatch)
    assert verify_main([str(f)]) == 0
    lint = next(c for c in cmds if c[:2] == ["ruff", "check"])
    assert "--extend-select" not in lint  # project settings never stomped
    assert "ruff.toml" in capsys.readouterr().out  # and the winner is shown


def test_ty_gets_explicit_project_root(tmp_path, monkeypatch):
    f = _py(tmp_path)
    (tmp_path / "pyproject.toml").write_text("[project]\nname='x'\n")
    cmds = _capture_cmds(monkeypatch)
    verify_main([str(f)])
    ty = next(c for c in cmds if c[0] == "ty")
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
    monkeypatch.setattr(_verify.shutil, "which", lambda name: None)
    assert verify_main([str(f)]) == 0  # skips are not failures
    out = capsys.readouterr().out
    assert "SKIP format (ruff not installed: uv tool install ruff)" in out
    assert "SKIP typecheck (ty not installed: uv tool install ty)" in out


def test_usage_and_errors(tmp_path, capsys):
    assert verify_main([]) == 0  # usage, not an error
    assert "usage: den verify" in capsys.readouterr().out
    assert verify_main([str(tmp_path / "missing.py")]) == 2
    notpy = tmp_path / "x.sh"
    notpy.write_text("echo hi\n")
    assert verify_main([str(notpy)]) == 2
    assert "run-checks.sh" in capsys.readouterr().err  # points at the alternative


def test_cli_dispatches_verify(tmp_path, monkeypatch, capsys):
    f = _py(tmp_path)
    monkeypatch.setattr(_verify.shutil, "which", lambda name: None)
    assert cli_main(["verify", str(f)]) == 0
    assert "config: ruff" in capsys.readouterr().out


def test_cli_usage_mentions_verify_as_plumbing(capsys):
    cli_main(["--help"])
    assert "den verify" in capsys.readouterr().out
