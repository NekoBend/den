"""Tests for den install shell (den/_shell.py)."""

from den import _shell
from den._install import main as install_main


def test_pwsh_dir_honors_queried_profile_on_windows(tmp_path, monkeypatch):
    prof = tmp_path / "OneDrive" / "Documents" / "PowerShell" / _shell._PWSH_PROFILE
    monkeypatch.setattr(_shell, "_windows", lambda: True)
    monkeypatch.setattr(_shell, "_query_pwsh_profile", lambda: prof)
    assert _shell._pwsh_profile_dir() == prof.parent


def test_pwsh_dir_windows_fallback_without_pwsh(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr(_shell, "_windows", lambda: True)
    monkeypatch.setattr(_shell, "_query_pwsh_profile", lambda: None)
    assert _shell._pwsh_profile_dir().as_posix().endswith("Documents/PowerShell")


def test_pwsh_dir_posix_uses_config(monkeypatch):
    monkeypatch.setattr(_shell, "_windows", lambda: False)
    assert _shell._pwsh_profile_dir().as_posix().endswith(".config/powershell")


def test_query_pwsh_profile_takes_last_ps1_line(monkeypatch):
    class _Result:
        returncode = 0
        stdout = (
            "WARNING: a noisy banner line\n"
            "C:\\Users\\x\\Documents\\PowerShell\\Microsoft.PowerShell_profile.ps1\n"
        )

    monkeypatch.setattr(
        _shell.shutil, "which", lambda e: "/x/pwsh" if e == "pwsh" else None
    )
    monkeypatch.setattr(_shell.subprocess, "run", lambda *a, **k: _Result())
    p = _shell._query_pwsh_profile()
    assert p is not None
    assert str(p).endswith(".ps1")
    assert "WARNING" not in str(p)


def test_query_pwsh_profile_rejects_nonzero_returncode(monkeypatch):
    class _Result:
        returncode = 1
        stdout = "garbage that is not a path\n"

    monkeypatch.setattr(
        _shell.shutil, "which", lambda e: "/x/pwsh" if e == "pwsh" else None
    )
    monkeypatch.setattr(_shell.subprocess, "run", lambda *a, **k: _Result())
    assert _shell._query_pwsh_profile() is None


def test_install_shell_deploys_both_families(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("os.name", "posix")
    assert install_main(["shell"]) == 0
    cfg = tmp_path / ".config" / "shell"
    assert (cfg / "init.bash").is_file()
    assert (cfg / "aliases.sh").is_file()
    assert (tmp_path / ".config" / "starship.toml").is_file()
    # pwsh family is deployed too (inert if unused)
    assert (tmp_path / ".config" / "powershell" / "init.ps1").is_file()


def test_install_shell_wires_bashrc(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    install_main(["shell"])
    bashrc = tmp_path / ".bashrc"
    # bash is on PATH in CI, so .bashrc gets the source line
    assert bashrc.is_file()
    assert ".config/shell/init.bash" in bashrc.read_text()


def test_install_shell_wiring_is_idempotent(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    install_main(["shell"])
    install_main(["shell"])
    bashrc = (tmp_path / ".bashrc").read_text()
    assert bashrc.count("# ===== den =====") == 1  # den block added once


def test_install_shell_no_extras_skips_optional(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    install_main(["shell", "--no-extras"])
    cfg = tmp_path / ".config" / "shell"
    assert (cfg / "aliases.sh").is_file()
    assert not (cfg / "ffmpeg.sh").exists()


def test_install_shell_dry_run_writes_nothing(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("HOME", str(tmp_path))
    assert install_main(["shell", "--dry-run"]) == 0
    assert not (tmp_path / ".config" / "shell").exists()
    assert "[dry]" in capsys.readouterr().out


def test_install_shell_cmd_shims_on_windows(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "AppData" / "Local"))
    monkeypatch.setattr("den._shell._windows", lambda: True)
    assert install_main(["shell"]) == 0
    clink = tmp_path / "AppData" / "Local" / "clink"
    assert (clink / "starship.lua").is_file()
    assert (clink / "bin" / "ls.cmd").is_file()


def test_install_shell_no_cmd_shims_off_windows(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("den._shell._windows", lambda: False)
    install_main(["shell"])
    assert not (tmp_path / "AppData" / "Local" / "clink").exists()


def test_install_shell_unexpected_arg(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    assert install_main(["shell", "--bogus"]) == 2


def test_install_shell_keeps_modified_config_non_tty(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    install_main(["shell"])
    al = tmp_path / ".config" / "shell" / "aliases.sh"
    al.write_text(al.read_text() + "\n# my edit\n")
    install_main(["shell"])  # non-TTY -> keep the edited file
    assert "# my edit" in al.read_text()


def test_install_shell_force_overwrites(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    install_main(["shell"])
    al = tmp_path / ".config" / "shell" / "aliases.sh"
    al.write_text("CLOBBERED")
    install_main(["shell", "--force"])
    assert "CLOBBERED" not in al.read_text()


# --------------------------------------------------------------------------- #
# coreutils opt-in (microsoft/coreutils via winget, Windows only)
# --------------------------------------------------------------------------- #


def _calls(monkeypatch):
    """Capture _install_coreutils invocations without running winget."""
    seen = []
    monkeypatch.setattr(
        _shell, "_install_coreutils", lambda dry_run: seen.append(dry_run) or 0
    )
    return seen


def test_coreutils_skipped_with_no_flag(monkeypatch):
    seen = _calls(monkeypatch)
    monkeypatch.setattr(_shell, "_windows", lambda: True)
    _shell._maybe_install_coreutils(want=False, skip=True, dry_run=False)
    assert seen == []


def test_coreutils_flag_off_windows_is_ignored(monkeypatch, capsys):
    seen = _calls(monkeypatch)
    monkeypatch.setattr(_shell, "_windows", lambda: False)
    _shell._maybe_install_coreutils(want=True, skip=False, dry_run=False)
    assert seen == []
    assert "Windows-only" in capsys.readouterr().err


def test_coreutils_flag_installs_on_windows(monkeypatch):
    seen = _calls(monkeypatch)
    monkeypatch.setattr(_shell, "_windows", lambda: True)
    monkeypatch.setattr(_shell.shutil, "which", lambda _: None)  # not already present
    _shell._maybe_install_coreutils(want=True, skip=False, dry_run=False)
    assert seen == [False]


def test_coreutils_already_installed_skips(monkeypatch, capsys):
    seen = _calls(monkeypatch)
    monkeypatch.setattr(_shell, "_windows", lambda: True)
    monkeypatch.setattr(_shell.shutil, "which", lambda _: "C:/x/coreutils.exe")
    _shell._maybe_install_coreutils(want=True, skip=False, dry_run=False)
    assert seen == []
    assert "already installed" in capsys.readouterr().out


def test_coreutils_non_tty_without_flag_skips(monkeypatch):
    seen = _calls(monkeypatch)
    monkeypatch.setattr(_shell, "_windows", lambda: True)
    monkeypatch.setattr(_shell.shutil, "which", lambda _: None)
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    _shell._maybe_install_coreutils(want=False, skip=False, dry_run=False)
    assert seen == []


def test_install_coreutils_dry_run_builds_winget_cmd(monkeypatch, capsys):
    monkeypatch.setattr(_shell.shutil, "which", lambda _: "/x/winget")
    ran = []
    monkeypatch.setattr(_shell.subprocess, "run", lambda *a, **k: ran.append(a) or None)
    assert _shell._install_coreutils(dry_run=True) == 0
    out = capsys.readouterr().out
    assert "winget install -e --id Microsoft.Coreutils -s winget" in out
    assert ran == []  # dry-run does not execute


def test_install_coreutils_without_winget_returns_1(monkeypatch, capsys):
    monkeypatch.setattr(_shell.shutil, "which", lambda _: None)
    assert _shell._install_coreutils(dry_run=False) == 1
    assert "winget not found" in capsys.readouterr().err


def test_install_shell_accepts_coreutils_flags(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setattr(_shell, "_windows", lambda: False)
    # --no-coreutils and --coreutils are accepted (not "unexpected arg")
    assert install_main(["shell", "--no-coreutils"]) == 0
    assert install_main(["shell", "--coreutils"]) == 0


def test_coreutils_interactive_confirm_yes_installs(monkeypatch):
    import den._ui as ui

    seen = _calls(monkeypatch)
    monkeypatch.setattr(_shell, "_windows", lambda: True)
    monkeypatch.setattr(_shell, "_coreutils_present", lambda: False)
    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    monkeypatch.setattr(ui, "confirm", lambda *a, **k: True)
    _shell._maybe_install_coreutils(want=False, skip=False, dry_run=False)
    assert seen == [False]


def test_coreutils_interactive_confirm_no_skips(monkeypatch):
    import den._ui as ui

    seen = _calls(monkeypatch)
    monkeypatch.setattr(_shell, "_windows", lambda: True)
    monkeypatch.setattr(_shell, "_coreutils_present", lambda: False)
    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    monkeypatch.setattr(ui, "confirm", lambda *a, **k: False)
    _shell._maybe_install_coreutils(want=False, skip=False, dry_run=False)
    assert seen == []


def test_coreutils_both_flags_skip_wins(monkeypatch):
    seen = _calls(monkeypatch)
    monkeypatch.setattr(_shell, "_windows", lambda: True)
    _shell._maybe_install_coreutils(want=True, skip=True, dry_run=False)
    assert seen == []


def test_install_shell_propagates_coreutils_failure(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setattr(_shell, "_windows", lambda: True)
    monkeypatch.setattr(_shell, "_coreutils_present", lambda: False)
    monkeypatch.setattr(_shell, "_install_coreutils", lambda dry_run: 1)
    # a flag-driven coreutils install that fails surfaces from install_shell
    assert install_main(["shell", "--coreutils"]) == 1


def test_install_shell_coreutils_dry_run_end_to_end(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    monkeypatch.setattr(_shell, "_windows", lambda: True)
    monkeypatch.setattr(_shell, "_coreutils_present", lambda: False)
    monkeypatch.setattr(_shell, "_query_pwsh_profile", lambda: None)
    monkeypatch.setattr(_shell.shutil, "which", lambda _: None)
    ran = []
    monkeypatch.setattr(_shell.subprocess, "run", lambda *a, **k: ran.append(a) or None)
    # --coreutils --dry-run reaches _install_coreutils, prints the plan, runs nothing
    assert install_main(["shell", "--coreutils", "--dry-run"]) == 0
    assert "winget install -e --id Microsoft.Coreutils" in capsys.readouterr().out
    assert ran == []


def test_coreutils_present_probes_program_files(tmp_path, monkeypatch):
    monkeypatch.setattr(_shell.shutil, "which", lambda _: None)
    monkeypatch.setenv("ProgramFiles", str(tmp_path))
    assert _shell._coreutils_present() is False
    exe = tmp_path / "coreutils" / "coreutils.exe"
    exe.parent.mkdir(parents=True)
    exe.write_text("")
    assert _shell._coreutils_present() is True


# --------------------------------------------------------------------------- #
# disable coreutils' PSConsoleHostReadLine integration (let den's wrappers win)
# --------------------------------------------------------------------------- #

_CU_BLOCK = (
    "# DO NOT MODIFY -- coreutils -- 60b36fc6-2d59-49df-be51-28dd2f4c3c9a\n"
    "# vvvv\n"
    "function PSConsoleHostReadLine { 'rewrite ls -> coreutils' }\n"
    "# ^^^^\n"
    "# DO NOT MODIFY -- coreutils -- 60b36fc6-2d59-49df-be51-28dd2f4c3c9a\n"
)


def test_disable_coreutils_readline_strips_block(tmp_path):
    prof = tmp_path / "Microsoft.PowerShell_profile.ps1"
    prof.write_text('. "$PSScriptRoot\\init.ps1"\n\n' + _CU_BLOCK)
    assert _shell._disable_coreutils_readline(prof) is True
    out = prof.read_text()
    assert "PSConsoleHostReadLine" not in out
    assert "60b36fc6" not in out
    assert '. "$PSScriptRoot\\init.ps1"' in out  # den's wiring is kept


def test_disable_coreutils_readline_idempotent(tmp_path):
    prof = tmp_path / "p.ps1"
    prof.write_text("keep\n\n" + _CU_BLOCK)
    assert _shell._disable_coreutils_readline(prof) is True
    assert _shell._disable_coreutils_readline(prof) is False  # nothing left to strip
    assert prof.read_text().strip() == "keep"


def test_disable_coreutils_readline_noop_without_block(tmp_path):
    prof = tmp_path / "p.ps1"
    prof.write_text('. "$PSScriptRoot\\init.ps1"\n')
    assert _shell._disable_coreutils_readline(prof) is False


def test_disable_coreutils_readline_preserves_crlf(tmp_path):
    prof = tmp_path / "p.ps1"
    prof.write_bytes(("a\r\n\r\n" + _CU_BLOCK.replace("\n", "\r\n") + "b\r\n").encode())
    assert _shell._disable_coreutils_readline(prof) is True
    data = prof.read_bytes()
    assert b"60b36fc6" not in data
    assert b"\r\n" in data
    assert b"\n" not in data.replace(b"\r\n", b"")  # no lone LF; CRLF kept


def test_disable_coreutils_readline_missing_file(tmp_path):
    assert _shell._disable_coreutils_readline(tmp_path / "nope.ps1") is False


def test_disable_coreutils_readline_two_blocks_preserve_between(tmp_path):
    prof = tmp_path / "p.ps1"
    between = "Import-Module MyPreciousModule\n$x = 42\n"
    prof.write_text(_CU_BLOCK + "\n" + between + "\n" + _CU_BLOCK)
    assert _shell._disable_coreutils_readline(prof) is True
    out = prof.read_text()
    assert "MyPreciousModule" in out  # content between two blocks must survive
    assert "$x = 42" in out
    assert "60b36fc6" not in out


def test_disable_coreutils_readline_keeps_dangling_sentinel(tmp_path):
    prof = tmp_path / "p.ps1"
    lone = "# DO NOT MODIFY -- coreutils -- 60b36fc6-2d59-49df-be51-28dd2f4c3c9a\n"
    prof.write_text("keep\n" + _CU_BLOCK + "tail line\n" + lone)
    assert _shell._disable_coreutils_readline(prof) is True
    out = prof.read_text()
    assert "function PSConsoleHostReadLine" not in out  # the paired block is gone
    assert out.count("60b36fc6") == 1  # the unpaired sentinel is left untouched
    assert "tail line" in out


def test_disable_coreutils_readline_backs_up(tmp_path):
    prof = tmp_path / "p.ps1"
    original = "keep\n\n" + _CU_BLOCK
    prof.write_text(original)
    assert _shell._disable_coreutils_readline(prof) is True
    bak = tmp_path / "p.ps1.den.bak"
    assert bak.is_file()
    assert bak.read_text() == original


def test_disable_coreutils_readline_preserves_utf16(tmp_path):
    prof = tmp_path / "p.ps1"
    prof.write_bytes(
        ("keep\r\n\r\n" + _CU_BLOCK.replace("\n", "\r\n")).encode("utf-16")
    )
    assert _shell._disable_coreutils_readline(prof) is True
    data = prof.read_bytes()
    assert data[:2] in (b"\xff\xfe", b"\xfe\xff")  # still UTF-16 with a BOM
    text = data.decode("utf-16")
    assert "60b36fc6" not in text
    assert "keep" in text


def test_disable_coreutils_readline_preserves_utf8_bom(tmp_path):
    prof = tmp_path / "p.ps1"
    prof.write_bytes(b"\xef\xbb\xbf" + ("keep\n\n" + _CU_BLOCK).encode("utf-8"))
    assert _shell._disable_coreutils_readline(prof) is True
    data = prof.read_bytes()
    assert data.startswith(b"\xef\xbb\xbf")  # BOM preserved
    assert b"60b36fc6" not in data


def test_disable_coreutils_readline_aborts_on_undecodable(tmp_path):
    prof = tmp_path / "p.ps1"
    raw = _CU_BLOCK.encode("utf-8") + b"\xc3\x28"  # has sentinels, invalid utf-8 tail
    prof.write_bytes(raw)
    assert (
        _shell._disable_coreutils_readline(prof) is False
    )  # cannot decode -> leave it
    assert prof.read_bytes() == raw  # untouched, no backup-and-rewrite
