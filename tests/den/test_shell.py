"""Tests for den install shell (den/_shell.py)."""

from den._install import main as install_main


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
