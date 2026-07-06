"""Tests for den/_content.py (bundled-vs-checkout content resolution)."""

from den import _content


def test_content_root_prefers_bundled_data(monkeypatch, tmp_path):
    # A wheel install has den/_data/ next to _content.py -> that is the root.
    data = tmp_path / "_data"
    data.mkdir()
    monkeypatch.setattr(_content, "__file__", str(tmp_path / "_content.py"))
    assert _content.content_root() == data


def test_content_root_falls_back_to_repo_root(monkeypatch, tmp_path):
    # A source checkout has no den/_data/, so the repo root (the package's parent)
    # is used instead.
    pkg = tmp_path / "den"
    pkg.mkdir()
    monkeypatch.setattr(_content, "__file__", str(pkg / "_content.py"))
    assert _content.content_root() == tmp_path


def test_content_dirs_are_under_the_root(monkeypatch, tmp_path):
    monkeypatch.setattr(_content, "content_root", lambda: tmp_path)
    assert _content.cheatsheets_dir() == tmp_path / "cheatsheets"
    assert _content.skills_dir() == tmp_path / "agents" / "skills"
    assert _content.shared_dir() == tmp_path / "agents" / "shared"
    assert _content.dist_dir() == tmp_path / "agents" / "dist"
    assert _content.shell_dir() == tmp_path / "shell"
