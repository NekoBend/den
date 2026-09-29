"""conftest.isolate_user_dirs: no test in tests/den reaches the real home."""

import os
from pathlib import Path

from den import _install, _shell
from den._install import main as install_main

_VARS = (
    "HOME",
    "USERPROFILE",
    "LOCALAPPDATA",
    "APPDATA",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_CACHE_HOME",
    "XDG_STATE_HOME",
)


def test_user_dirs_point_into_tmp_path(tmp_path):
    for var in _VARS:
        assert Path(os.environ[var]).is_relative_to(tmp_path), var
    assert Path.home() == tmp_path
    assert Path("~").expanduser() == tmp_path


def test_path_probes_answer_under_the_test_home(tmp_path):
    # Neither starts a program: the real ones ask PowerShell (and xdg-user-dir)
    # for directories outside the test's home.
    docs = tmp_path / "Documents"
    assert _shell._query_pwsh_profile() == docs / "PowerShell" / _shell._PWSH_PROFILE
    assert _install._cline_rules_dir() == docs / "Cline" / "Rules"


def test_windows_shell_install_writes_only_under_tmp_path(tmp_path, monkeypatch):
    # The Windows branch with nothing set but the fixture: pwsh files, profile
    # line, Clink shims and the POSIX files all land in the test's home.
    monkeypatch.setattr(_shell, "_windows", lambda: True)
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    assert install_main(["shell"]) == 0
    pwsh = tmp_path / "Documents" / "PowerShell"
    assert _shell._PWSH_LINE in (pwsh / _shell._PWSH_PROFILE).read_text()
    assert (tmp_path / "AppData" / "Local" / "clink" / "starship.lua").is_file()
    assert (tmp_path / ".config" / "shell" / "init.bash").is_file()
