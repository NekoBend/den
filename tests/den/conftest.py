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

import errno
import os
import struct
import sys
from contextlib import contextmanager
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
    "test_install_shell_leaves_zshenv_alone",
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


@pytest.fixture
def hard_link():
    """`link(target, path)` (os.link), or skip where this filesystem cannot
    make a hard link."""

    def _link(target, path):
        try:
            os.link(target, path)
        except (OSError, NotImplementedError) as e:
            pytest.skip(f"no hard links here: {e}")

    return _link


@pytest.fixture
def file_size_limit():
    """`with limit(n):` makes a write that would take a file past `n` bytes
    fail for real (EFBIG; SIGXFSZ is ignored meanwhile), whichever way the
    bytes are written: a full disk or an I/O error part-way through a write,
    in miniature. Skipped where there is no RLIMIT_FSIZE (Windows). Nothing
    else may write a file past `n` bytes inside it: print through capsys."""
    resource = pytest.importorskip("resource")
    import signal

    @contextmanager
    def _limit(n):
        soft, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
        previous = signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
        resource.setrlimit(resource.RLIMIT_FSIZE, (n, hard))
        try:
            yield
        finally:
            resource.setrlimit(resource.RLIMIT_FSIZE, (soft, hard))
            signal.signal(signal.SIGXFSZ, previous)

    return _limit


# POSIX ACL entries as Linux keeps them in system.posix_acl_*: a tag, the
# permission bits, and the uid or gid of a named entry (none for the others).
_ACL_USER_OBJ, _ACL_USER, _ACL_GROUP_OBJ, _ACL_MASK, _ACL_OTHER = 1, 2, 4, 16, 32
_NO_ID = 0xFFFFFFFF


def _posix_acl(*entries: tuple[int, int, int]) -> bytes:
    """An ACL in its extended attribute form: version 2, then each entry."""
    return struct.pack("<I", 2) + b"".join(struct.pack("<HHI", *e) for e in entries)


@pytest.fixture
def set_xattr():
    """`set(path, name, value)`: os.setxattr, or skip where it cannot work:
    den carries extended attributes over on Linux only, and a filesystem may
    keep no ACLs or user.* attributes, or not know the uid an ACL names."""

    def _set(path, name, value):
        if sys.platform != "linux":
            pytest.skip("den carries extended attributes over on Linux only")
        try:
            os.setxattr(path, name, value)
        except OSError as e:
            if e.errno not in {errno.ENOTSUP, errno.EPERM, errno.EINVAL}:
                raise
            pytest.skip(f"no {name} here: {e}")

    return _set


@pytest.fixture
def let_65534_in(set_xattr):
    """`grant(path)`: an ACL entry for uid 65534, a user the tests never run
    as. On a directory it goes in the default ACL (rwx, under an rwx mask),
    which every file made in it afterwards takes; on a file, in the file's
    own ACL (read, under a read mask, as for a 0640 file)."""

    def _grant(path):
        if Path(path).is_dir():
            set_xattr(
                path,
                "system.posix_acl_default",
                _posix_acl(
                    (_ACL_USER_OBJ, 7, _NO_ID),
                    (_ACL_USER, 7, 65534),
                    (_ACL_GROUP_OBJ, 5, _NO_ID),
                    (_ACL_MASK, 7, _NO_ID),
                    (_ACL_OTHER, 5, _NO_ID),
                ),
            )
        else:
            set_xattr(
                path,
                "system.posix_acl_access",
                _posix_acl(
                    (_ACL_USER_OBJ, 6, _NO_ID),
                    (_ACL_USER, 4, 65534),
                    (_ACL_GROUP_OBJ, 4, _NO_ID),
                    (_ACL_MASK, 4, _NO_ID),
                    (_ACL_OTHER, 0, _NO_ID),
                ),
            )

    return _grant


@pytest.fixture
def foreign_stat(monkeypatch):
    """`stand_in(name, whose)`: Path.stat reports another user ("owner") or
    a group den's user is not in ("group") for every file called `name`, as
    for a file that belongs to them; other files stat as they are. A chown
    that would carry that owner or group over to a copy then fails for real,
    since only root gives a file away, and a test needs no second group."""
    mine = {os.getuid(), os.getgid(), *os.getgroups()}
    foreign = next(i for i in range(65534, 0, -1) if i not in mine)
    fields_of: dict[str, int] = {}
    real_stat = Path.stat

    def stat_(self, *args, **kwargs):
        st = real_stat(self, *args, **kwargs)
        field = fields_of.get(self.name)
        if field is None:
            return st
        fields = list(st)
        fields[field] = foreign
        return os.stat_result(fields)

    def _stand_in(name, whose):
        fields_of[name] = 4 if whose == "owner" else 5  # st_uid, st_gid
        monkeypatch.setattr(Path, "stat", stat_)

    return _stand_in


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
