"""Tests for den install shell (den/_shell.py)."""

import re
import sys
from pathlib import Path

from den import _shell
from den._install import main as install_main

_POSIX_DIR = Path(__file__).resolve().parents[2] / "shell" / "posix"
_PWSH_DIR = Path(__file__).resolve().parents[2] / "shell" / "pwsh"
_CMD_BIN = Path(__file__).resolve().parents[2] / "shell" / "cmd" / "bin"


def _pwsh_sourced_files() -> set[str]:
    """The .ps1 names that init.ps1 dot-sources at startup."""
    text = (_PWSH_DIR / "init.ps1").read_text()
    return set(re.findall(r"\$PSScriptRoot\\(\w+\.ps1)", text))


def _source_all_files() -> set[str]:
    """The .sh names that _helpers.sh's _source_all sources at shell startup."""
    text = (_POSIX_DIR / "_helpers.sh").read_text()
    m = re.search(r"for _sa_f in ([^\n;]+); do", text)
    assert m, "could not find the _source_all loop in _helpers.sh"
    return set(m.group(1).split())


def test_every_posix_feature_file_is_installed_and_sourced():
    # Guard against adding a shell/posix/*.sh that `den install shell` never
    # copies or init.* never sources (the proxy.sh / snippet.sh delivery bug).
    feature_files = {p.name for p in _POSIX_DIR.glob("*.sh") if p.name != "_helpers.sh"}
    installed = set(_shell._POSIX_CORE + _shell._POSIX_EXTRAS)
    sourced = _source_all_files()
    assert feature_files <= installed, (
        f"shell/posix files missing from den install lists: {feature_files - installed}"
    )
    assert feature_files <= sourced, (
        f"shell/posix files not sourced by _source_all: {feature_files - sourced}"
    )


def test_every_pwsh_feature_file_is_installed_and_sourced():
    # Same guard for the pwsh side: every shell/pwsh/*.ps1 (except _helpers.ps1
    # and the init.ps1 entry point) must be in the install lists AND dot-sourced
    # by init.ps1, or it never reaches a real install.
    feature_files = {
        p.name
        for p in _PWSH_DIR.glob("*.ps1")
        if p.name not in ("_helpers.ps1", "init.ps1")
    }
    installed = set(_shell._PWSH_CORE + _shell._PWSH_EXTRAS)
    sourced = _pwsh_sourced_files()
    assert feature_files <= installed, (
        f"shell/pwsh files missing from den install lists: {feature_files - installed}"
    )
    assert feature_files <= sourced, (
        f"shell/pwsh files not dot-sourced by init.ps1: {feature_files - sourced}"
    )


def test_cmd_core_shims_present():
    # cmd is intentionally a subset (no parallel/proxy/snippet), but its core
    # navigation + wrapper + python shims must exist. den globs cmd/bin/*.cmd to
    # install, so a deleted shim just silently vanishes with no other signal; this
    # is the cmd counterpart to the posix/pwsh install-and-sourced wiring guards.
    required = {
        "ls",
        "cat",
        "grep",
        "find",
        "la",
        "ll",  # wrappers
        "up",
        "back",
        "mkcd",
        "again",  # navigation
        "python",
        "pip",
        "uv",  # python
        "which",
        "head",
        "tail",
        "path",
        "toggle-wrapper",
        "toggle-uv",  # utils / toggles
    }
    present = {p.stem for p in _CMD_BIN.glob("*.cmd")}
    missing = required - present
    assert not missing, f"cmd/bin is missing core shims: {sorted(missing)}"


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


def _bundled_posix_bin():
    """The bundled POSIX bin executables den would install (names + bytes)."""
    from den._content import shell_dir

    src = shell_dir() / "posix" / "bin"
    return {p.name: p.read_bytes() for p in src.iterdir() if p.is_file()}


def test_install_shell_bin_flag_installs_executables(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("den._shell._windows", lambda: False)
    assert install_main(["shell", "--bin"]) == 0
    local_bin = tmp_path / ".local" / "bin"
    bundled = _bundled_posix_bin()
    assert bundled, "expected at least one shell/posix/bin/* executable to exist"
    for name, content in bundled.items():
        dst = local_bin / name
        assert dst.read_bytes() == content
        assert dst.stat().st_mode & 0o111  # executable bit set


def test_install_shell_no_bin_skips(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("den._shell._windows", lambda: False)
    assert install_main(["shell", "--no-bin"]) == 0
    assert not (tmp_path / ".local" / "bin").exists()


def test_install_shell_bin_default_non_tty_skips(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("den._shell._windows", lambda: False)
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    assert install_main(["shell"]) == 0
    assert not (tmp_path / ".local" / "bin").exists()


def test_install_shell_bin_prompt_yes_installs(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("den._shell._windows", lambda: False)
    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    monkeypatch.setattr("den._ui.confirm", lambda *a, **k: True)
    assert install_main(["shell"]) == 0
    for name in _bundled_posix_bin():
        assert (tmp_path / ".local" / "bin" / name).is_file()


def test_install_shell_bin_ignored_on_windows(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "AppData" / "Local"))
    monkeypatch.setattr("den._shell._windows", lambda: True)
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    assert install_main(["shell", "--bin"]) == 0
    assert not (tmp_path / ".local" / "bin").exists()
    assert "ignoring --bin" in capsys.readouterr().err


def test_install_shell_bin_dry_run_writes_nothing(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("den._shell._windows", lambda: False)
    assert install_main(["shell", "--dry-run", "--bin"]) == 0
    assert not (tmp_path / ".local" / "bin").exists()


def test_install_shell_bin_keeps_modified_file_content_and_mode(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr("den._shell._windows", lambda: False)
    monkeypatch.setattr("sys.stdin.isatty", lambda: False)
    local_bin = tmp_path / ".local" / "bin"
    local_bin.mkdir(parents=True)
    mine = local_bin / "fixids"
    mine.write_text("#!/bin/sh\n# my own fixids\n")
    mine.chmod(0o600)
    assert install_main(["shell", "--bin"]) == 0
    # non-tty + differing file -> kept as-is: content AND mode untouched
    assert mine.read_text() == "#!/bin/sh\n# my own fixids\n"
    if sys.platform != "win32":
        assert mine.stat().st_mode & 0o777 == 0o600


def _stub_which(present):
    return lambda name: f"/usr/bin/{name}" if name in present else None


def _fake_git(calls, sha_for=None):
    """subprocess.run stub: records commands; rev-parse returns the plugin's
    pinned sha (or sha_for override) so the verification step is exercised."""

    class _R:
        def __init__(self, out=""):
            self.stdout = out

    def run(cmd, **_k):
        calls.append(cmd)
        if "rev-parse" in cmd:
            path = cmd[cmd.index("-C") + 1]
            if sha_for is not None:
                return _R(sha_for + "\n")
            for name, _url, _tag, sha in _shell._ZSH_PLUGINS:
                if name in path:
                    return _R(sha + "\n")
        return _R()

    return run


def test_clone_zsh_plugins_clones_both_pinned(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / ".config"))
    monkeypatch.setattr("den._shell._windows", lambda: False)
    monkeypatch.setattr("den._shell.shutil.which", _stub_which({"zsh", "git"}))
    calls = []
    monkeypatch.setattr("den._shell.subprocess.run", _fake_git(calls))
    _shell._maybe_clone_zsh_plugins(want=True, dry_run=False)
    clones = [c for c in calls if c[:2] == ["git", "clone"]]
    assert len(clones) == 2
    for (name, _url, tag, _sha), cmd in zip(_shell._ZSH_PLUGINS, clones):
        assert "--branch" in cmd and tag in cmd  # pinned tag, not HEAD
        assert name in cmd[-1]
    # every clone is followed by a rev-parse verification
    assert sum(1 for c in calls if "rev-parse" in c) == 2


def test_clone_zsh_plugins_default_off(tmp_path, monkeypatch):
    monkeypatch.setattr("den._shell._windows", lambda: False)
    monkeypatch.setattr("den._shell.shutil.which", _stub_which({"zsh", "git"}))
    calls = []
    monkeypatch.setattr("den._shell.subprocess.run", _fake_git(calls))
    _shell._maybe_clone_zsh_plugins(want=False, dry_run=False)
    assert calls == []  # opt-in: nothing fetched without --zsh-plugins


def test_clone_zsh_plugins_sha_mismatch_removes_clone(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / ".config"))
    monkeypatch.setattr("den._shell._windows", lambda: False)
    monkeypatch.setattr("den._shell.shutil.which", _stub_which({"zsh", "git"}))
    calls = []
    monkeypatch.setattr("den._shell.subprocess.run", _fake_git(calls, sha_for="0" * 40))
    removed = []
    monkeypatch.setattr(
        "den._shell.shutil.rmtree", lambda p, **k: removed.append(str(p))
    )
    _shell._maybe_clone_zsh_plugins(want=True, dry_run=False)
    err = capsys.readouterr().err
    assert "not the pinned commit" in err and "tag may have moved" in err
    assert len(removed) == 2  # both rejected clones deleted


def test_clone_zsh_plugins_no_zsh_skips(tmp_path, monkeypatch):
    monkeypatch.setattr("den._shell._windows", lambda: False)
    monkeypatch.setattr("den._shell.shutil.which", _stub_which({"git"}))  # no zsh
    calls = []
    monkeypatch.setattr("den._shell.subprocess.run", _fake_git(calls))
    _shell._maybe_clone_zsh_plugins(want=True, dry_run=False)
    assert calls == []


def test_clone_zsh_plugins_windows_skips(tmp_path, monkeypatch):
    monkeypatch.setattr("den._shell._windows", lambda: True)
    monkeypatch.setattr("den._shell.shutil.which", _stub_which({"zsh", "git"}))
    calls = []
    monkeypatch.setattr("den._shell.subprocess.run", _fake_git(calls))
    _shell._maybe_clone_zsh_plugins(want=True, dry_run=False)
    assert calls == []


def test_clone_zsh_plugins_skips_existing(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / ".config"))
    monkeypatch.setattr("den._shell._windows", lambda: False)
    monkeypatch.setattr("den._shell.shutil.which", _stub_which({"zsh", "git"}))
    (tmp_path / ".config" / "zsh" / "plugins" / "zsh-autosuggestions").mkdir(
        parents=True
    )
    calls = []
    monkeypatch.setattr("den._shell.subprocess.run", _fake_git(calls))
    _shell._maybe_clone_zsh_plugins(want=True, dry_run=False)
    clones = [c[-1] for c in calls if c[:2] == ["git", "clone"]]
    assert not any("zsh-autosuggestions" in t for t in clones)  # already present
    assert any("zsh-syntax-highlighting" in t for t in clones)  # still cloned
