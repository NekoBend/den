"""Put the repo root on sys.path so tests can import the `den` package, keep
every test out of the real home (see isolate_user_dirs), and skip the
POSIX-deployment tests on a native Windows runner.

The Windows CI job runs this suite to exercise den's real Windows code paths.
Some tests, though, exercise POSIX behavior specifically: they mock
`_shell._windows` to False to deploy the bash/zsh config to `~/.config/shell` and
`~/.local/bin`, instantiate `PosixPath`, or assume a hermetic `~/Documents`
(the cline extension's rules dir). Those cannot run meaningfully on Windows and
stay fully covered by the ubuntu jobs, so they are skipped here (only on win32).
"""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

# After the sys.path entry above, which it needs.
from den import _install, _shell

# POSIX-only tests (see the module docstring). Fixed via PYTHONUTF8 (encoding) and
# den's newline="" writes (CRLF), the memory/imprint tests are NOT here -- they run
# on Windows too.
_WINDOWS_SKIP = {
    # shell: POSIX config/bin deployment (mock _windows=False) + PosixPath
    "test_install_shell_bin_does_not_chmod_through_a_symlink",
    "test_install_shell_bin_flag_installs_executables",
    "test_install_shell_bin_prompt_yes_installs",
    "test_install_shell_deploys_both_families",
    "test_install_shell_force_overwrites",
    "test_install_shell_keeps_modified_config_non_tty",
    "test_install_shell_no_extras_skips_optional",
    "test_install_shell_wires_bashrc",
    "test_install_shell_wires_the_profile_pwsh_reads_under_xdg",
    "test_install_shell_wiring_is_idempotent",
    "test_uninstall_shell_keeps_user_file_in_local_bin",
    "test_uninstall_shell_non_tty_refuses_without_yes",
    "test_uninstall_shell_removes_posix_bin_keeps_local_bin",
    "test_uninstall_shell_round_trip",
    # cline: workspace-local executable scripts (POSIX name/bit) + Documents rules dir
    "test_install_cline_is_workspace_local",
    "test_install_cline_writes_executable_scripts",
    "test_install_cline_parent_goes_to_cline_rules_dir",
    "test_install_cline_cli_parent_stays_in_agents",
    "test_uninstall_cline_removes_rules_parent",
}


# Every variable den (or a PowerShell it starts) reads to find the user's home
# and config, and where each one points during a test, relative to tmp_path.
# Path.home() reads USERPROFILE on Windows and HOME elsewhere; LOCALAPPDATA holds
# the Clink shims; pwsh on Linux builds $PROFILE from XDG_CONFIG_HOME.
_USER_DIRS = {
    "HOME": (),
    "USERPROFILE": (),
    "LOCALAPPDATA": ("AppData", "Local"),
    "APPDATA": ("AppData", "Roaming"),
    "XDG_CONFIG_HOME": (".config",),
    "XDG_DATA_HOME": (".local", "share"),
    "XDG_CACHE_HOME": (".cache",),
    "XDG_STATE_HOME": (".local", "state"),
}


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "real_path_probes: run den's own PowerShell and xdg-user-dir path "
        "queries instead of the isolate_user_dirs stand-ins",
    )


@pytest.fixture(autouse=True)
def isolate_user_dirs(request, tmp_path, monkeypatch):
    """Point every user directory at tmp_path, for every test.

    A test that set only HOME still wrote the real profile. On Windows
    Path.home() reads USERPROFILE and Clink's dir is LOCALAPPDATA. And den asks
    the real PowerShell for $PROFILE (on Windows once _windows() says so, which
    tests mock on Linux too): on Windows that is the Documents folder whatever
    HOME or USERPROFILE say, on Linux it follows XDG_CONFIG_HOME. So
    `pytest tests/den` put the branch's shell files into the developer's live
    PowerShell startup. The variables above now point under tmp_path, and the
    two probes that start a program to find a directory (_query_pwsh_profile,
    _cline_rules_dir) answer with their no-probe fallback under the home
    instead. A test that sets one of these itself still wins, and a test of a
    probe itself takes the real one with @pytest.mark.real_path_probes.
    """
    for var, parts in _USER_DIRS.items():
        monkeypatch.setenv(var, str(tmp_path.joinpath(*parts)))
    if request.node.get_closest_marker("real_path_probes") is None:
        monkeypatch.setattr(
            _shell,
            "_query_pwsh_profile",
            lambda: Path.home() / "Documents" / "PowerShell" / _shell._PWSH_PROFILE,
        )
        monkeypatch.setattr(
            _install,
            "_cline_rules_dir",
            lambda: Path.home() / "Documents" / "Cline" / "Rules",
        )


@pytest.fixture
def symlink(tmp_path):
    """`link(target, path)`, or skip when this platform/session cannot symlink.

    The symlink-hardening tests need a real symlink; on Windows that takes the
    create-symbolic-link privilege (or developer mode), which a runner may not
    have. Probe once and skip rather than fail there. `target_is_directory` is
    ignored on POSIX and required on Windows for a dir target.
    """

    def _link(target, path):
        Path(path).symlink_to(target, target_is_directory=Path(target).is_dir())

    target = tmp_path / "_symlink_probe_target"
    target.write_text("probe")
    probe = tmp_path / "_symlink_probe"
    try:
        _link(target, probe)
    except (OSError, NotImplementedError):
        pytest.skip("creating symlinks is not permitted here")
    probe.unlink()
    target.unlink()
    return _link


@pytest.fixture(autouse=True)
def _no_ambient_xdg_config_home(monkeypatch):
    """den places the pwsh profile and the zsh plugins under $XDG_CONFIG_HOME
    when it is set, as those shells read them there. Tests fake HOME and expect
    ~/.config; an XDG_CONFIG_HOME from the runner's environment would send
    their writes into the real one. A test that wants it sets it itself."""
    monkeypatch.delenv("XDG_CONFIG_HOME", raising=False)


def pytest_collection_modifyitems(config, items):
    if sys.platform != "win32":
        return
    skip = pytest.mark.skip(reason="POSIX/hermetic test; covered on the ubuntu jobs")
    for item in items:
        if item.name in _WINDOWS_SKIP:
            item.add_marker(skip)
