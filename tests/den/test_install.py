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
    from den import _install, _ui

    # confirm: shell?Y extras?N skills?Y parent?Y ; select: tools -> [claude]
    answers = iter([True, False, True, True])
    monkeypatch.setattr(_ui, "confirm", lambda *a, **k: next(answers))
    monkeypatch.setattr(_ui, "select", lambda *a, **k: ["claude"])
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
    from den import _install, _ui

    monkeypatch.setattr(_ui, "confirm", lambda *a, **k: False)  # decline everything
    monkeypatch.setattr(_ui, "select", lambda *a, **k: [])
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
    monkeypatch.setattr("den._ui.confirm", lambda *a, **k: True)
    install_main(["skills", "--target", str(tmp_path)])
    assert "CLOBBERED" not in skill.read_text()


def test_install_cline_parent_goes_to_cline_rules_dir(tmp_path, monkeypatch):
    # the VS Code extension reads global rules from <Documents>/Cline/Rules and
    # does NOT read ~/.agents/AGENTS.md; no xdg-user-dir -> ~/Documents fallback
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("den._install.shutil.which", lambda e: None)
    assert install_main(["skills", "--tool", "cline", "--with-parent"]) == 0
    assert (tmp_path / "Documents" / "Cline" / "Rules" / "AGENTS.md").is_file()
    assert not (tmp_path / ".agents" / "AGENTS.md").exists()
    assert (tmp_path / ".agents" / "skills" / "coding" / "SKILL.md").is_file()


def test_install_cline_cli_parent_stays_in_agents(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    assert install_main(["skills", "--tool", "cline-cli", "--with-parent"]) == 0
    assert (tmp_path / ".agents" / "AGENTS.md").is_file()
    assert not (tmp_path / "Documents").exists()


def test_cline_rules_dir_uses_xdg_documents(tmp_path, monkeypatch):
    from den import _install

    monkeypatch.setattr(_install.shutil, "which", lambda e: "/usr/bin/xdg-user-dir")

    class _R:
        returncode = 0
        stdout = str(tmp_path / "MyDocs") + "\n"

    monkeypatch.setattr(_install.subprocess, "run", lambda *a, **k: _R())
    assert _install._cline_rules_dir() == tmp_path / "MyDocs" / "Cline" / "Rules"


def test_cline_rules_dir_windows_queries_powershell(tmp_path, monkeypatch):
    from den import _install

    monkeypatch.setattr(_install, "_windows", lambda: True)
    monkeypatch.setattr(
        _install.shutil, "which", lambda e: "/x/pwsh" if e == "pwsh" else None
    )
    onedrive = "C:\\Users\\x\\OneDrive\\Documents"

    class _R:
        returncode = 0
        stdout = onedrive + "\n"

    monkeypatch.setattr(_install.subprocess, "run", lambda *a, **k: _R())
    got = _install._cline_rules_dir()
    assert str(got).startswith(onedrive)
    assert got.name == "Rules" and got.parent.name == "Cline"
