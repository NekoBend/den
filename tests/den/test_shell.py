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
