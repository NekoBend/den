"""Put the repo root on sys.path so tests can import the `den` package, and skip
the POSIX-deployment tests on a native Windows runner.

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

# POSIX-only tests (see the module docstring). Fixed via PYTHONUTF8 (encoding) and
# den's newline="" writes (CRLF), the memory/imprint tests are NOT here -- they run
# on Windows too.
_WINDOWS_SKIP = {
    # shell: POSIX config/bin deployment (mock _windows=False) + PosixPath
    "test_install_shell_bin_flag_installs_executables",
    "test_install_shell_bin_prompt_yes_installs",
    "test_install_shell_deploys_both_families",
    "test_install_shell_force_overwrites",
    "test_install_shell_keeps_modified_config_non_tty",
    "test_install_shell_no_extras_skips_optional",
    "test_install_shell_wires_bashrc",
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


def pytest_collection_modifyitems(config, items):
    if sys.platform != "win32":
        return
    skip = pytest.mark.skip(reason="POSIX/hermetic test; covered on the ubuntu jobs")
    for item in items:
        if item.name in _WINDOWS_SKIP:
            item.add_marker(skip)
