"""Tests for den install (den/_install.py)."""

import os
from pathlib import Path

import pytest

from den import _install
from den._install import main as install_main


def test_install_skills_to_target(tmp_path):
    rc = install_main(["skills", "--target", str(tmp_path), "--with-parent"])
    assert rc == 0
    skills = tmp_path / "skills"
    assert (skills / "coding" / "SKILL.md").is_file()
    assert (skills / "code-audit" / "SKILL.md").is_file()
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
    assert f"{coding.resolve().as_posix()}/examples/testing.md" in text
    for md in coding.rglob("*.md"):
        left = [
            m.group(0)
            for m in _install._PATH_RE.finditer(md.read_text(encoding="utf-8"))
            if m.group("local")
        ]
        assert not left, f"{md.relative_to(coding)}: relative {left}"


def test_install_profile_weak_deploys_router_parent(tmp_path):
    rc = install_main(
        ["skills", "--target", str(tmp_path), "--with-parent", "--profile", "weak"]
    )
    assert rc == 0
    agents = (tmp_path / "AGENTS.md").read_text()
    claude = (tmp_path / "CLAUDE.md").read_text()
    assert "<skill_catalog>" in agents  # the router IS the weak parent
    assert agents == claude  # one weak content, whatever the file name


def test_install_default_profile_is_frontier(tmp_path):
    install_main(["skills", "--target", str(tmp_path), "--with-parent"])
    text = (tmp_path / "AGENTS.md").read_text()
    assert "<precedence>" in text
    assert "<skill_catalog>" not in text


def test_install_unknown_profile_exits_2(tmp_path):
    assert install_main(["skills", "--target", str(tmp_path), "--profile", "mid"]) == 2


def test_uninstall_removes_weak_parent(tmp_path):
    from den._uninstall import main as uninstall_main

    install_main(
        ["skills", "--target", str(tmp_path), "--with-parent", "--profile", "weak"]
    )
    assert "<skill_catalog>" in (tmp_path / "AGENTS.md").read_text()
    rc = uninstall_main(["skills", "--target", str(tmp_path), "--with-parent", "--yes"])
    assert rc == 0
    assert not (tmp_path / "AGENTS.md").exists()
    assert not (tmp_path / "CLAUDE.md").exists()


@pytest.mark.skipif(os.name == "nt", reason="Windows has no execute bit")
def test_install_skills_keeps_scripts_executable(tmp_path):
    # the skills invoke these by absolute path; a 0644 copy dies on permission
    # denied at every call site
    install_main(["skills", "--target", str(tmp_path)])
    scripts = tmp_path / "skills" / "coding" / "shared" / "scripts"
    assert (scripts / "run-checks.sh").stat().st_mode & 0o111
    assert (scripts / "find-references.py").stat().st_mode & 0o111
    # content files are not marked executable
    skill = tmp_path / "skills" / "coding" / "SKILL.md"
    assert not skill.stat().st_mode & 0o111


@pytest.mark.skipif(os.name == "nt", reason="Windows has no execute bit")
def test_install_repairs_a_lost_executable_bit(tmp_path):
    # A deployed script can lose +x without its bytes changing (backup restore,
    # dotfiles sync, a copy made on Windows). The byte-identical fast path used
    # to `continue` before the chmod, so the re-install reported success and
    # left every call site dying on permission denied.
    install_main(["skills", "--target", str(tmp_path)])
    scripts = tmp_path / "skills" / "coding" / "shared" / "scripts"
    script = scripts / "find-references.py"
    script.chmod(0o644)
    assert install_main(["skills", "--target", str(tmp_path)]) == 0
    assert script.stat().st_mode & 0o111


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


def test_install_dry_run_names_every_root_file_the_real_run_writes(tmp_path, capsys):
    # A preview that omits a destination the real run overwrites is worse than
    # no preview: --target --with-parent also writes CLAUDE.md at the root, and
    # only AGENTS.md was ever announced.
    args = ["skills", "--target", str(tmp_path), "--with-parent"]
    assert install_main([*args, "--dry-run"]) == 0
    out = capsys.readouterr().out
    assert not (tmp_path / "skills").exists()
    assert install_main(args) == 0
    written = sorted(p.name for p in tmp_path.iterdir() if p.is_file())
    assert written == ["AGENTS.md", "CLAUDE.md"]
    for name in written:
        assert f"{tmp_path}/{name}" in out


def test_install_codex_config_prints_blocks(tmp_path, capsys):
    install_main(["skills", "--target", str(tmp_path), "--codex-config"])
    out = capsys.readouterr().out
    assert "[[skills.config]]" in out
    assert "SKILL.md" in out


def test_install_unknown_target(capsys):
    assert install_main(["bogus"]) == 2


def test_install_unknown_tool(capsys):
    assert install_main(["skills", "--tool", "notatool"]) == 2


def test_install_gemini_tool_is_retired(capsys):
    # retired with gemini-cli's upstream EOL; Antigravity reads the
    # cross-tool ~/.agents/skills + AGENTS.md that den already deploys
    assert install_main(["skills", "--tool", "gemini"]) == 2


def test_uninstall_sweeps_legacy_gemini_skills(tmp_path, monkeypatch):
    from den._uninstall import main as uninstall_main

    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("USERPROFILE", str(tmp_path))  # windows expanduser
    # simulate an old den deploy into ~/.gemini/skills by installing there
    install_main(["skills", "--target", str(tmp_path / ".gemini")])
    legacy = tmp_path / ".gemini" / "skills" / "coding" / "SKILL.md"
    assert legacy.is_file()
    assert uninstall_main(["skills", "--yes"]) == 0
    assert not legacy.exists()  # den-identical legacy copies are removed
    assert (tmp_path / ".gemini").is_dir()  # the tool dir itself is kept


def test_install_cheatsheets_deploys(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path))
    assert install_main(["cheatsheets"]) == 0
    dest = tmp_path / "den" / "cheatsheets"
    assert (dest / "shell" / "one-liners.md").is_file()
    assert list(dest.rglob("*.py"))  # python cheatsheets too


def test_install_cheatsheets_dry_run_writes_nothing(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path))
    assert install_main(["cheatsheets", "--dry-run"]) == 0
    assert not (tmp_path / "den").exists()
    assert "[dry-run]" in capsys.readouterr().out


def test_uninstall_cheatsheets_removes_identical(tmp_path, monkeypatch):
    from den._uninstall import main as uninstall_main

    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path))
    install_main(["cheatsheets"])
    sheet = tmp_path / "den" / "cheatsheets" / "shell" / "one-liners.md"
    assert sheet.is_file()
    assert uninstall_main(["cheatsheets", "--yes"]) == 0
    assert not sheet.exists()


def test_install_hook_routes_to_cmd_install(tmp_path, monkeypatch):
    # `den install hook` is a thin alias for `den hook install`.
    monkeypatch.chdir(tmp_path)  # seed imprint.md under tmp, not the repo
    cfg = tmp_path / "settings.json"
    assert install_main(["hook", "--tool", "claude", "--config", str(cfg)]) == 0
    assert cfg.is_file()
    assert "den hook run" in cfg.read_text()


def test_uninstall_hook_routes_to_cmd_remove(tmp_path, monkeypatch):
    from den._uninstall import main as uninstall_main

    monkeypatch.chdir(tmp_path)  # seed imprint.md under tmp, not the repo
    cfg = tmp_path / "settings.json"
    install_main(["hook", "--tool", "claude", "--config", str(cfg)])
    assert "den hook run" in cfg.read_text()
    assert uninstall_main(["hook", "--tool", "claude", "--config", str(cfg)]) == 0
    remaining = cfg.read_text() if cfg.is_file() else ""
    assert "den hook run" not in remaining


def test_cheatsheets_unknown_arg_exits_2(tmp_path, monkeypatch):
    from den._uninstall import main as uninstall_main

    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path))
    assert install_main(["cheatsheets", "--bogus"]) == 2
    assert uninstall_main(["cheatsheets", "--bogus"]) == 2


def test_cheatsheets_missing_bundle_errors(tmp_path, monkeypatch):
    # install and uninstall both refuse (rc 1) when no bundle is present, instead
    # of a misleading silent success. _install imports cheatsheets_dir at module
    # level; _uninstall imports it lazily from _content -- patch both bindings.
    from den import _content, _install
    from den._uninstall import main as uninstall_main

    def _no_bundle():
        return tmp_path / "nope"

    monkeypatch.setattr(_install, "cheatsheets_dir", _no_bundle)
    monkeypatch.setattr(_content, "cheatsheets_dir", _no_bundle)
    assert install_main(["cheatsheets"]) == 1
    assert uninstall_main(["cheatsheets", "--yes"]) == 1


def test_interactive_dispatches(monkeypatch):
    from den import _install, _ui

    monkeypatch.setattr(_install, "_windows", lambda: False)  # plugins Q is POSIX-only
    # confirm: shell?Y extras?N zsh-plugins?N skills?Y parent?Y cheatsheets?N
    # ; select -> [claude]
    answers = iter([True, False, False, True, True, False])
    monkeypatch.setattr(_ui, "confirm", lambda *a, **k: next(answers))
    monkeypatch.setattr(_ui, "select", lambda *a, **k: ["claude"])
    calls = {}
    monkeypatch.setattr(
        "den._shell.install_shell",
        lambda argv: (calls.setdefault("shell", argv) is None and 0) or 0,
    )
    monkeypatch.setattr(
        _install,
        "_install_skills",
        lambda argv: (calls.setdefault("skills", argv) is None and 0) or 0,
    )
    assert _install._interactive() == 0
    assert calls["shell"] == ["--no-extras"]
    assert calls["skills"] == ["--tool", "claude", "--with-parent"]


def test_interactive_opts_into_zsh_plugins(monkeypatch):
    from den import _install, _ui

    monkeypatch.setattr(_install, "_windows", lambda: False)
    # confirm: shell?Y extras?Y zsh-plugins?Y skills?N cheatsheets?N
    answers = iter([True, True, True, False, False])
    monkeypatch.setattr(_ui, "confirm", lambda *a, **k: next(answers))
    calls = {}
    monkeypatch.setattr(
        "den._shell.install_shell",
        lambda argv: (calls.setdefault("shell", argv) is None and 0) or 0,
    )
    assert _install._interactive() == 0
    assert calls["shell"] == ["--zsh-plugins"]


def test_interactive_weak_profile_question_for_mixed_tools(monkeypatch):
    from den import _install, _ui

    monkeypatch.setattr(_install, "_windows", lambda: False)
    # shell?N skills?Y -> select [cline] -> parent?Y weak-profile?Y cheatsheets?N
    answers = iter([False, True, True, True, False])
    monkeypatch.setattr(_ui, "confirm", lambda *a, **k: next(answers))
    monkeypatch.setattr(_ui, "select", lambda *a, **k: ["cline"])
    calls = {}
    monkeypatch.setattr(
        _install,
        "_install_skills",
        lambda argv: (calls.setdefault("skills", argv) is None and 0) or 0,
    )
    assert _install._interactive() == 0
    assert calls["skills"] == ["--tool", "cline", "--with-parent", "--profile", "weak"]


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
    # non-TTY -> the changed file is skipped, and the run says so with its exit
    # code: a script (or an older den's refresh, which runs this command) must
    # not read a run that deployed none of the new version's files as success.
    assert install_main(["skills", "--target", str(tmp_path)]) == 1
    assert "LOCAL EDIT" in skill.read_text()
    # --force is the way through, and it succeeds
    assert install_main(["skills", "--target", str(tmp_path), "--force"]) == 0
    assert "LOCAL EDIT" not in skill.read_text()


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


def test_install_interactive_decline_is_not_a_failure(tmp_path, monkeypatch):
    # keeping a file because the user said "no" is their choice, not a failed
    # deploy; only the unattended skip is reported as one
    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    install_main(["skills", "--target", str(tmp_path)])
    skill = tmp_path / "skills" / "coding" / "SKILL.md"
    skill.write_text("MINE")
    monkeypatch.setattr("den._ui.confirm", lambda *a, **k: False)
    assert install_main(["skills", "--target", str(tmp_path)]) == 0
    assert skill.read_text() == "MINE"


@pytest.mark.real_path_probes
def test_install_cline_parent_goes_to_cline_rules_dir(tmp_path, monkeypatch):
    # the VS Code extension reads global rules from <Documents>/Cline/Rules and
    # does NOT read ~/.agents/AGENTS.md; no xdg-user-dir -> ~/Documents fallback
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("den._install.shutil.which", lambda e, path=None: None)
    assert install_main(["skills", "--tool", "cline", "--with-parent"]) == 0
    assert (tmp_path / "Documents" / "Cline" / "Rules" / "AGENTS.md").is_file()
    assert not (tmp_path / ".agents" / "AGENTS.md").exists()
    assert (tmp_path / ".agents" / "skills" / "coding" / "SKILL.md").is_file()


def test_install_cline_cli_parent_stays_in_agents(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    assert install_main(["skills", "--tool", "cline-cli", "--with-parent"]) == 0
    assert (tmp_path / ".agents" / "AGENTS.md").is_file()
    assert not (tmp_path / "Documents").exists()


@pytest.mark.real_path_probes
def test_cline_rules_dir_uses_xdg_documents(tmp_path, monkeypatch):
    from den import _install

    monkeypatch.setattr(
        _install.shutil, "which", lambda e, path=None: "/usr/bin/xdg-user-dir"
    )

    class _R:
        returncode = 0
        stdout = str(tmp_path / "MyDocs") + "\n"

    monkeypatch.setattr(_install.subprocess, "run", lambda *a, **k: _R())
    assert _install._cline_rules_dir() == tmp_path / "MyDocs" / "Cline" / "Rules"


@pytest.mark.real_path_probes
def test_cline_rules_dir_runs_xdg_user_dir_by_absolute_path(tmp_path, monkeypatch):
    from den import _install

    tool = str(Path(Path.cwd().anchor) / "den-tools" / "xdg-user-dir")
    monkeypatch.setattr(_install, "_windows", lambda: False)
    monkeypatch.setattr(_install.sys, "platform", "linux")
    monkeypatch.setattr(_install.shutil, "which", lambda e, path=None: tool)

    class _R:
        returncode = 0
        stdout = str(tmp_path / "MyDocs") + "\n"

    ran = []
    monkeypatch.setattr(
        _install.subprocess, "run", lambda cmd, **k: ran.append(cmd) or _R()
    )
    assert _install._cline_rules_dir() == tmp_path / "MyDocs" / "Cline" / "Rules"
    assert ran == [[tool, "DOCUMENTS"]]


@pytest.mark.real_path_probes
def test_cline_rules_dir_refuses_powershell_in_the_working_directory(
    tmp_path, monkeypatch, capsys
):
    """Windows: a pwsh.exe/powershell.exe in the directory `den install skills
    --tool cline` runs from is refused, never run; ~/Documents is the fallback."""
    from den import _install

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(_install, "_windows", lambda: True)
    # Windows: the OS whose which() and CreateProcess search the cwd
    monkeypatch.setattr("den._exe._windows", lambda: True)
    monkeypatch.setattr(
        _install.shutil, "which", lambda e, path=None: str(tmp_path / e)
    )
    ran = []
    monkeypatch.setattr(_install.subprocess, "run", lambda cmd, **k: ran.append(cmd))
    assert _install._cline_rules_dir() == Path.home() / "Documents" / "Cline" / "Rules"
    assert ran == []
    err = capsys.readouterr().err
    assert "refusing pwsh resolved inside the workspace" in err
    assert "refusing powershell resolved inside the workspace" in err


@pytest.mark.real_path_probes
def test_cline_rules_dir_windows_queries_powershell(tmp_path, monkeypatch):
    from den import _install

    monkeypatch.setattr(_install, "_windows", lambda: True)
    monkeypatch.setattr(
        _install.shutil,
        "which",
        lambda e, path=None: "/x/pwsh" if e == "pwsh" else None,
    )
    onedrive = "C:\\Users\\x\\OneDrive\\Documents"

    class _R:
        returncode = 0
        stdout = onedrive + "\n"

    monkeypatch.setattr(_install.subprocess, "run", lambda *a, **k: _R())
    got = _install._cline_rules_dir()
    assert str(got).startswith(onedrive)
    assert got.name == "Rules" and got.parent.name == "Cline"


def test_leaf_help_prints_usage(capsys):
    # `den install <target> --help` should print usage and exit 0, not error 2.
    for target in ("skills", "shell", "cheatsheets"):
        for flag in ("--help", "-h", "help"):
            assert install_main([target, flag]) == 0
            assert "usage: den install" in capsys.readouterr().out


@pytest.mark.skipif(os.name == "nt", reason="Windows has no execute bit")
def test_install_does_not_chmod_through_a_symlinked_destination(
    tmp_path, monkeypatch, symlink
):
    """chmod follows a symlink, so the mode repair used to hand a symlinked
    destination's OUTSIDE target 0o755 -- on the byte-identical path, with
    nothing deployed at all. A tool dir (not a --target, which refuses any
    link outright) is where den still meets such a link."""
    monkeypatch.setenv("HOME", str(tmp_path))
    install_main(["skills", "--tool", "claude"])
    scripts = tmp_path / ".claude" / "skills" / "coding" / "shared" / "scripts"
    script = scripts / "find-references.py"
    outside = tmp_path / "outside.py"
    outside.write_bytes(script.read_bytes())  # byte-identical, so nothing deploys
    outside.chmod(0o600)
    script.unlink()
    symlink(outside, script)

    assert install_main(["skills", "--tool", "claude"]) == 0
    assert outside.stat().st_mode & 0o777 == 0o600, "the link's target is untouched"
    assert script.is_symlink(), "and the link itself is left as the user made it"


# ---- --target workspaces never write through a symlink (a cloned repo's layout) ----


def _workspace(tmp_path):
    ws = tmp_path / "src" / "repo"
    ws.mkdir(parents=True)
    return ws


def test_install_target_never_creates_through_a_dangling_symlink(
    tmp_path, monkeypatch, symlink, capsys
):
    """A repo shipping CLAUDE.md -> ../../.bash_profile, which does not exist
    yet: den used to create that outside file, with no prompt at all."""
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    ws = _workspace(tmp_path)
    outside = tmp_path / ".bash_profile"
    symlink(outside, ws / "CLAUDE.md")
    rc = install_main(
        ["skills", "--target", str(ws), "--with-parent", "--profile", "weak"]
    )
    assert rc == 1, "a refused destination is a failed deploy"
    assert not outside.exists()
    assert (ws / "CLAUDE.md").is_symlink(), "the link is left alone"
    assert (ws / "AGENTS.md").is_file(), "everything else still deploys"
    assert (ws / "skills" / "coding" / "SKILL.md").is_file()
    err = capsys.readouterr().err
    assert "refusing to write" in err and "CLAUDE.md is a symlink" in err


def test_install_target_force_never_overwrites_through_a_symlink(
    tmp_path, monkeypatch, symlink
):
    """AGENTS.md -> ~/.bashrc: with --force (or a 'yes' at the overwrite
    prompt) den used to replace the user's .bashrc with the parent prompt."""
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    ws = _workspace(tmp_path)
    outside = tmp_path / ".bashrc"
    outside.write_text("MY BASHRC\n")
    symlink(outside, ws / "AGENTS.md")
    rc = install_main(["skills", "--target", str(ws), "--with-parent", "--force"])
    assert rc == 1
    assert outside.read_text() == "MY BASHRC\n"
    assert (ws / "CLAUDE.md").is_file()


def test_install_target_never_lists_a_symlink_for_the_overwrite_prompt(
    tmp_path, monkeypatch, symlink, capsys
):
    """The 'exist and differ' list named the link ('AGENTS.md') with no hint
    of where the write would land; a user who answered yes lost the file."""
    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    monkeypatch.setattr("den._ui.confirm", lambda *a, **k: True)
    ws = _workspace(tmp_path)
    outside = tmp_path / ".bashrc"
    outside.write_text("MY BASHRC\n")
    symlink(outside, ws / "AGENTS.md")
    assert install_main(["skills", "--target", str(ws), "--with-parent"]) == 1
    assert outside.read_text() == "MY BASHRC\n"
    assert "exist and differ" not in capsys.readouterr().out


def test_install_target_refuses_a_symlinked_skills_dir(tmp_path, monkeypatch, symlink):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    ws = _workspace(tmp_path)
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    symlink(elsewhere, ws / "skills")
    assert install_main(["skills", "--target", str(ws)]) == 1
    assert list(elsewhere.iterdir()) == []


def test_install_target_through_a_symlinked_root_is_the_users_choice(
    tmp_path, monkeypatch, symlink
):
    """Only links BELOW the target are the repo's; the target path itself (a
    ~/work -> /data/work arrangement) is the user's own and still works."""
    real = tmp_path / "data" / "repo"
    real.mkdir(parents=True)
    symlink(real, tmp_path / "repo")
    assert install_main(["skills", "--target", str(tmp_path / "repo")]) == 0
    assert (real / "skills" / "coding" / "SKILL.md").is_file()


def test_install_tool_dir_still_follows_a_dotfiles_symlink(
    tmp_path, monkeypatch, symlink
):
    """~/.claude symlinked into a dotfiles repo is the user's own arrangement:
    the default tool dirs keep writing through it."""
    home = tmp_path / "home"
    home.mkdir()
    dotfiles = tmp_path / "dotfiles" / "claude"
    dotfiles.mkdir(parents=True)
    symlink(dotfiles, home / ".claude")
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("USERPROFILE", str(home))
    assert install_main(["skills", "--tool", "claude", "--with-parent"]) == 0
    assert (dotfiles / "CLAUDE.md").is_file()
    assert (dotfiles / "skills" / "coding" / "SKILL.md").is_file()


# ---- skill-local paths and shared references ----


def _fake_content(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    skill_md: str | bytes,
    shared: dict[str, str] | None = None,
    local: dict[str, str] | None = None,
) -> Path:
    """Point den._install at a content tree holding one skill, `demo`: its
    SKILL.md, its other files (`local`, by path under the skill) and the
    shared/reference files (`shared`, by file name). Every file is written as
    bytes, so its line endings are exactly the ones given."""
    content = tmp_path / "content"
    files = {"SKILL.md": skill_md, **(local or {})}
    for rel, text in files.items():
        path = content / "skills" / "demo" / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text if isinstance(text, bytes) else text.encode("utf-8"))
    ref = content / "shared" / "reference"
    ref.mkdir(parents=True)
    for name, text in (shared or {}).items():
        (ref / name).write_bytes(text.encode("utf-8"))
    monkeypatch.setattr(_install, "skills_dir", lambda: content / "skills")
    monkeypatch.setattr(_install, "shared_dir", lambda: content / "shared")
    return content


def test_install_rewrites_skill_local_refs_to_absolute(tmp_path, monkeypatch):
    _fake_content(
        tmp_path,
        monkeypatch,
        "Read reference/rubric.md, then compare against examples/<language>.md.\n",
        local={"reference/rubric.md": "r\n", "examples/python.md": "p\n"},
    )
    target = tmp_path / "target"
    assert install_main(["skills", "--target", str(target)]) == 0
    demo = target / "skills" / "demo"
    text = (demo / "SKILL.md").read_text(encoding="utf-8")
    root = demo.resolve().as_posix()
    assert text == (
        f"Read {root}/reference/rubric.md, then compare against"
        f" {root}/examples/<language>.md.\n"
    )


@pytest.mark.parametrize(
    ("before", "after"),
    [
        ("Read reference/severity-rubric.md:", "Read /R/reference/severity-rubric.md:"),
        ("`examples/testing.md`", "`/R/examples/testing.md`"),
        ("examples/<language>.md", "/R/examples/<language>.md"),
        (
            "reference/dimensions/<dimension>.md.",
            "/R/reference/dimensions/<dimension>.md.",
        ),
        ("(./examples/a.md)", "(/R/examples/a.md)"),
        ("[link](examples/a.md)", "[link](/R/examples/a.md)"),
        ("はreference/x.mdを読む", "は/R/reference/x.mdを読む"),
        ("../../shared/reference/python.md", "/R/shared/reference/python.md"),
        ("shared/scripts/run-checks.sh", "/R/shared/scripts/run-checks.sh"),
        # left alone: not a skill-local path, or not written from the skill root
        ("docs/reference/api.md", "docs/reference/api.md"),
        ("the reference/guide split", "the reference/guide split"),
        ("examples/a.mdx", "examples/a.mdx"),
        ("my-examples/a.md", "my-examples/a.md"),
        ("../examples/a.md", "../examples/a.md"),
    ],
)
def test_local_ref_rewrite_edge_cases(before, after):
    assert _install._rewrite(before, "/R/") == after
    # A relative copy keeps every local path as written; shared/ loses its ../
    relative = _install._rewrite(before, "")
    if "shared/" in before:
        assert relative == after.replace("/R/", "")
    else:
        assert relative == before


def test_materialize_follows_shared_refs_transitively(tmp_path, monkeypatch):
    _fake_content(
        tmp_path,
        monkeypatch,
        "Read ../../shared/reference/a.md.\n",
        shared={
            "a.md": "Then read shared/reference/b.md.\n",
            "b.md": "Back to shared/reference/a.md.\n",  # a cycle ends
            "unused.md": "nobody names this\n",
        },
    )
    work = tmp_path / "work"
    _install._materialize("demo", work, "/R/demo/")
    bundled = sorted(p.name for p in (work / "shared" / "reference").iterdir())
    assert bundled == ["a.md", "b.md"]
    a = (work / "shared" / "reference" / "a.md").read_text(encoding="utf-8")
    assert a == "Then read /R/demo/shared/reference/b.md.\n"


def test_materialize_fails_on_a_missing_shared_file(tmp_path, monkeypatch):
    _fake_content(
        tmp_path,
        monkeypatch,
        "Read shared/reference/a.md.\n",
        shared={"a.md": "Then read shared/reference/gone.md.\n"},
    )
    with pytest.raises(
        ValueError, match=r"^demo: shared/reference/gone\.md does not exist$"
    ):
        _install._materialize("demo", tmp_path / "work", "/R/demo/")


@pytest.mark.parametrize(
    ("skill_md", "broken"),
    [
        # _REF_RE never matched a nested name, so it was dropped in silence
        ("Read shared/reference/sub/x.md.\n", "SKILL.md: shared/reference/sub/x.md"),
        ("Read shared/scripts/gone.py.\n", "SKILL.md: shared/scripts/gone.py"),
        ("Compare against examples/nope.md.\n", "SKILL.md: examples/nope.md"),
        ("Read reference/<topic>.md.\n", "SKILL.md: reference/<topic>.md"),
    ],
    ids=["nested-shared", "missing-script", "missing-local", "placeholder-no-dir"],
)
def test_materialize_fails_on_a_reference_to_nothing(
    tmp_path, monkeypatch, skill_md, broken
):
    _fake_content(tmp_path, monkeypatch, skill_md)
    (tmp_path / "content" / "shared" / "scripts").mkdir()
    with pytest.raises(ValueError, match="name nothing the skill ships") as exc:
        _install._materialize("demo", tmp_path / "work", "/R/demo/")
    assert str(exc.value).splitlines()[1:] == [f"  {broken}"]


def test_materialize_fails_on_a_parent_relative_local_ref(tmp_path, monkeypatch):
    _fake_content(
        tmp_path,
        monkeypatch,
        "Read examples/a.md.\n",
        local={"examples/a.md": "See ../examples/b.md.\n", "examples/b.md": "b\n"},
    )
    with pytest.raises(ValueError, match="name nothing the skill ships") as exc:
        _install._materialize("demo", tmp_path / "work", "/R/demo/")
    assert str(exc.value).splitlines()[1:] == [
        "  examples/a.md: ../examples/ - write skill-local paths from the skill root"
    ]


def test_install_reports_a_broken_reference_and_writes_nothing(
    tmp_path, monkeypatch, capsys
):
    _fake_content(tmp_path, monkeypatch, "Compare against examples/nope.md.\n")
    target = tmp_path / "target"
    assert install_main(["skills", "--target", str(target), "--with-parent"]) == 2
    assert not target.exists()
    err = capsys.readouterr().err
    assert err.startswith("den install skills: demo: references that name nothing")
    assert "SKILL.md: examples/nope.md" in err


@pytest.mark.parametrize("eol", [b"\n", b"\r\n"], ids=["lf", "crlf"])
def test_rewrite_keeps_the_source_line_endings(tmp_path, monkeypatch, eol):
    """write_text turned every LF into CRLF on Windows; bytes in, bytes out
    keeps what the source has on every platform."""
    lines = [b"Read examples/a.md.", b"Then shared/reference/b.md.", b""]
    _fake_content(
        tmp_path,
        monkeypatch,
        eol.join(lines),
        shared={"b.md": "b\n"},
        local={"examples/a.md": "a\n"},
    )
    work = tmp_path / "work"
    assert _install._materialize("demo", work, "/R/demo/") == 1
    out = (work / "SKILL.md").read_bytes()
    assert out == eol.join(
        [b"Read /R/demo/examples/a.md.", b"Then /R/demo/shared/reference/b.md.", b""]
    )
