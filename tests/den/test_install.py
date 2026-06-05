"""Tests for den install (den/_install.py)."""

from den._install import main as install_main


def test_install_skills_to_target(tmp_path):
    rc = install_main(["skills", "--target", str(tmp_path), "--with-parent"])
    assert rc == 0
    skills = tmp_path / "skills"
    assert (skills / "coding" / "SKILL.md").is_file()
    assert (skills / "code-review" / "SKILL.md").is_file()
    # coding references shared resources -> self-contained shared/ tree
    assert (skills / "coding" / "shared" / "reference").is_dir()
    assert (skills / "coding" / "shared" / "scripts").is_dir()
    # parent prompts at the target root
    assert (tmp_path / "AGENTS.md").is_file()
    assert (tmp_path / "CLAUDE.md").is_file()


def test_install_skills_rewrites_to_absolute(tmp_path):
    install_main(["skills", "--target", str(tmp_path)])
    coding = tmp_path / "skills" / "coding"
    text = (coding / "SKILL.md").read_text()
    assert "../shared/" not in text  # no leftover relative refs
    # rewrite uses forward-slash absolute paths (correct on Windows too)
    assert coding.resolve().as_posix() in text


def test_install_skills_excludes_tests_and_pyc(tmp_path):
    install_main(["skills", "--target", str(tmp_path)])
    scripts = tmp_path / "skills" / "coding" / "shared" / "scripts"
    assert not (scripts / "tests").exists()
    assert not list(scripts.rglob("*.pyc"))


def test_install_skills_dry_run_writes_nothing(tmp_path, capsys):
    rc = install_main(["skills", "--target", str(tmp_path), "--dry-run"])
    assert rc == 0
    assert not (tmp_path / "skills").exists()
    assert "[dry-run]" in capsys.readouterr().out


def test_install_codex_config_prints_blocks(tmp_path, capsys):
    install_main(["skills", "--target", str(tmp_path), "--codex-config"])
    out = capsys.readouterr().out
    assert "[[skills.config]]" in out
    assert "SKILL.md" in out


def test_install_unknown_target(capsys):
    assert install_main(["bogus"]) == 2


def test_install_unknown_tool(capsys):
    assert install_main(["skills", "--tool", "notatool"]) == 2


def test_interactive_dispatches(monkeypatch):
    from den import _install

    # shell?Y extras?N skills?Y claude?Y codex?N cline?N copilot?N gemini?N parent?Y
    answers = iter([True, False, True, True, False, False, False, False, True])
    monkeypatch.setattr(_install, "_confirm", lambda *a: next(answers))
    calls = {}
    monkeypatch.setattr(
        "den._shell.install_shell",
        lambda argv: calls.setdefault("shell", argv) is None and 0 or 0,
    )
    monkeypatch.setattr(
        _install,
        "_install_skills",
        lambda argv: calls.setdefault("skills", argv) is None and 0 or 0,
    )
    assert _install._interactive() == 0
    assert calls["shell"] == ["--no-extras"]
    assert calls["skills"] == ["--tool", "claude", "--with-parent"]


def test_interactive_skips_when_declined(monkeypatch):
    from den import _install

    monkeypatch.setattr(_install, "_confirm", lambda *a: False)  # decline everything
    called = []
    monkeypatch.setattr(
        _install, "_install_skills", lambda argv: called.append("skills") or 0
    )
    assert _install._interactive() == 0
    assert called == []


def test_install_keeps_modified_file_non_tty(tmp_path, monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    install_main(["skills", "--target", str(tmp_path)])
    skill = tmp_path / "skills" / "coding" / "SKILL.md"
    skill.write_text(skill.read_text() + "\nLOCAL EDIT\n")
    install_main(["skills", "--target", str(tmp_path)])  # non-TTY -> skip changed
    assert "LOCAL EDIT" in skill.read_text()


def test_install_force_overwrites_modified(tmp_path, monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    install_main(["skills", "--target", str(tmp_path)])
    skill = tmp_path / "skills" / "coding" / "SKILL.md"
    skill.write_text("CLOBBERED")
    install_main(["skills", "--target", str(tmp_path), "--force"])
    assert "CLOBBERED" not in skill.read_text()


def test_install_interactive_overwrite_on_yes(tmp_path, monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    install_main(["skills", "--target", str(tmp_path)])
    skill = tmp_path / "skills" / "coding" / "SKILL.md"
    skill.write_text("CLOBBERED")
    monkeypatch.setattr("den._install._confirm", lambda *a: True)
    install_main(["skills", "--target", str(tmp_path)])
    assert "CLOBBERED" not in skill.read_text()
