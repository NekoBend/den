"""Tests for den uninstall (den/_uninstall.py)."""

from pathlib import Path

from den._install import main as install_main
from den._uninstall import _has_block, _strip_block
from den._uninstall import main as uninstall_main


def _install(tmp_path, *extra):
    assert install_main(["skills", "--target", str(tmp_path), *extra]) == 0


def test_uninstall_removes_unmodified_keeps_modified(tmp_path, monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    _install(tmp_path)
    coding = tmp_path / "skills" / "coding" / "SKILL.md"
    review = tmp_path / "skills" / "code-review" / "SKILL.md"
    coding.write_text(coding.read_text() + "\nMINE\n")  # user edit -> keep
    assert uninstall_main(["skills", "--target", str(tmp_path), "--yes"]) == 0
    assert coding.is_file() and "MINE" in coding.read_text()  # kept
    assert not review.is_file()  # den's, removed


def test_uninstall_prunes_emptied_dirs(tmp_path, monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    _install(tmp_path)
    assert (tmp_path / "skills" / "code-review").is_dir()
    assert uninstall_main(["skills", "--target", str(tmp_path), "--yes"]) == 0
    # every skill was den's -> whole skills tree gone, but the target root stays
    assert not (tmp_path / "skills").exists()
    assert tmp_path.is_dir()


def test_uninstall_dry_run_changes_nothing(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    _install(tmp_path)
    n_before = sum(1 for _ in (tmp_path / "skills").rglob("*"))
    assert uninstall_main(["skills", "--target", str(tmp_path), "--dry-run"]) == 0
    assert "dry-run" in capsys.readouterr().out
    assert sum(1 for _ in (tmp_path / "skills").rglob("*")) == n_before


def test_uninstall_non_tty_refuses_without_yes(tmp_path, monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    _install(tmp_path)
    skill = tmp_path / "skills" / "coding" / "SKILL.md"
    assert uninstall_main(["skills", "--target", str(tmp_path)]) == 1
    assert skill.is_file()  # nothing deleted


def test_uninstall_interactive_confirm_yes_deletes(tmp_path, monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    _install(tmp_path)
    skill = tmp_path / "skills" / "coding" / "SKILL.md"
    monkeypatch.setattr("den._ui.confirm", lambda *a, **k: True)
    assert uninstall_main(["skills", "--target", str(tmp_path)]) == 0
    assert not skill.is_file()


def test_uninstall_interactive_confirm_no_keeps(tmp_path, monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    _install(tmp_path)
    skill = tmp_path / "skills" / "coding" / "SKILL.md"
    monkeypatch.setattr("den._ui.confirm", lambda *a, **k: False)
    assert uninstall_main(["skills", "--target", str(tmp_path)]) == 0
    assert skill.is_file()  # declined -> kept


def test_uninstall_parent_only_with_flag(tmp_path, monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    _install(tmp_path, "--with-parent")
    agents = tmp_path / "AGENTS.md"
    assert agents.is_file()
    # without --with-parent the parent prompt is left in place
    uninstall_main(["skills", "--target", str(tmp_path), "--yes"])
    assert agents.is_file()
    # with --with-parent it is removed (it is unchanged den content)
    _install(tmp_path, "--with-parent")
    uninstall_main(["skills", "--target", str(tmp_path), "--with-parent", "--yes"])
    assert not agents.is_file()


def test_uninstall_unknown_target(capsys):
    assert uninstall_main(["bogus"]) == 2


def test_uninstall_unknown_tool(capsys):
    assert uninstall_main(["skills", "--tool", "notatool"]) == 2


# --------------------------------------------------------------------------- #
# rc block strip (used by shell uninstall)
# --------------------------------------------------------------------------- #


def test_strip_block_removes_marker_and_line(tmp_path):
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / ".bashrc"
    rc.write_text(f"export FOO=1\n\n# ===== den =====\n{line}\n")
    assert _has_block(rc, line)
    _strip_block(rc, line)
    assert rc.read_text() == "export FOO=1\n"
    assert not _has_block(rc, line)


def test_strip_block_keeps_foreign_content(tmp_path):
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / ".bashrc"
    rc.write_text(f"# ===== den =====\n{line}\nalias x=y\n")
    _strip_block(rc, line)
    assert "alias x=y" in rc.read_text()
    assert "den" not in rc.read_text()


def test_has_block_false_when_absent(tmp_path):
    rc = tmp_path / ".bashrc"
    rc.write_text("just my stuff\n")
    assert not _has_block(rc, "anything")
    assert not _has_block(Path(tmp_path / "nope"), "x")  # missing file


def test_has_block_ignores_marker_inside_user_comment(tmp_path):
    rc = tmp_path / ".bashrc"
    rc.write_text("echo hi  # ===== den ===== (just my note)\n")
    # the marker appears only as a substring of a user comment -> not den's block
    assert not _has_block(rc, "anything")


def test_has_block_requires_marker_followed_by_den_line(tmp_path):
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / ".bashrc"
    # standalone marker, but the next line is the user's own, not den's wire line
    rc.write_text("# ===== den =====\nmy own note here\n")
    assert not _has_block(rc, line)


def test_strip_block_leaves_stray_marker_untouched(tmp_path):
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / ".bashrc"
    original = "export FOO=1\n\n# ===== den =====\nmy own note here\n"
    rc.write_text(original)
    _strip_block(rc, line)
    # marker not followed by den's line -> nothing removed (incl. preceding blank)
    assert rc.read_text() == original


def test_strip_block_keeps_whitespace_only_user_content(tmp_path):
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / ".bashrc"
    rc.write_text(f"   \n\n# ===== den =====\n{line}\n")  # user had whitespace lines
    _strip_block(rc, line)
    assert rc.exists()  # not exactly den's created form -> kept
    assert "den" not in rc.read_text()


def test_strip_block_preserves_crlf(tmp_path):
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / "profile.ps1"
    rc.write_bytes(f"Set-Foo 1\r\n\r\n# ===== den =====\r\n{line}\r\n".encode())
    _strip_block(rc, line)
    assert rc.read_bytes() == b"Set-Foo 1\r\n"  # CRLF kept, not flipped to LF


def test_strip_block_removes_den_created_empty_file(tmp_path):
    line = '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
    rc = tmp_path / "profile.ps1"  # created form: only den's block
    rc.write_text(f"# ===== den =====\n{line}\n")
    _strip_block(rc, line)
    assert not rc.exists()  # den created it -> removed, no empty leftover


# --------------------------------------------------------------------------- #
# shell install -> uninstall round-trip (temp HOME)
# --------------------------------------------------------------------------- #


def test_uninstall_shell_round_trip(tmp_path, monkeypatch):
    from den._shell import install_shell
    from den._uninstall import _uninstall_shell

    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setenv("HOME", str(tmp_path))  # Path.home() + expanduser() on posix
    (tmp_path / ".bashrc").write_text("export FOO=1\n")

    assert install_shell(["--no-extras"]) == 0
    shell_dir = tmp_path / ".config" / "shell"
    assert (shell_dir / "_helpers.sh").is_file()
    assert "# ===== den =====" in (tmp_path / ".bashrc").read_text()

    (shell_dir / "aliases.sh").write_text("# mine\n")  # user edit -> must survive
    assert _uninstall_shell(["--yes"]) == 0
    assert (shell_dir / "aliases.sh").read_text() == "# mine\n"  # kept
    assert not (shell_dir / "_helpers.sh").exists()  # den's, removed
    assert (tmp_path / ".bashrc").read_text() == "export FOO=1\n"  # block stripped
    assert (tmp_path / ".config").is_dir()  # boundary never removed


def test_uninstall_shell_non_tty_refuses_without_yes(tmp_path, monkeypatch):
    from den._shell import install_shell
    from den._uninstall import _uninstall_shell

    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setenv("HOME", str(tmp_path))
    assert install_shell(["--no-extras"]) == 0
    assert _uninstall_shell([]) == 1  # no --yes, non-TTY -> refuse
    assert (tmp_path / ".config" / "shell" / "_helpers.sh").is_file()  # untouched


def test_uninstall_shell_removes_posix_bin_keeps_local_bin(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setattr("den._shell._windows", lambda: False)
    assert install_main(["shell", "--bin"]) == 0
    local_bin = tmp_path / ".local" / "bin"
    installed = sorted(p.name for p in local_bin.iterdir())
    assert installed, "expected at least one helper executable installed"
    assert uninstall_main(["shell", "--yes"]) == 0
    for name in installed:
        assert not (local_bin / name).exists()  # den's helpers removed
    assert local_bin.is_dir()  # boundary keeps the (now-empty) user dir


def test_uninstall_shell_keeps_user_file_in_local_bin(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setattr("den._shell._windows", lambda: False)
    assert install_main(["shell", "--bin"]) == 0
    local_bin = tmp_path / ".local" / "bin"
    mine = local_bin / "myscript"
    mine.write_text("#!/bin/sh\necho hi\n")
    assert uninstall_main(["shell", "--yes"]) == 0
    assert mine.is_file()  # a file den did not place is never removed


def test_uninstall_cline_removes_rules_parent(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setattr("den._install.shutil.which", lambda e: None)
    assert install_main(["skills", "--tool", "cline", "--with-parent"]) == 0
    rules_parent = tmp_path / "Documents" / "Cline" / "Rules" / "AGENTS.md"
    assert rules_parent.is_file()
    assert uninstall_main(["skills", "--tool", "cline", "--with-parent", "--yes"]) == 0
    assert not rules_parent.exists()
