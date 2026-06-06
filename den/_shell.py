"""den install shell - deploy the shell environment (bash/zsh + PowerShell).

Deploys the shell environment (the one cross-platform installer).
Copies the bundled shell config into place and wires the relevant rc files
idempotently. Config files are deployed for both shell families; only rc files
for shells that look relevant (binary on PATH, or rc already present, or native
platform) are wired.

  den install shell [--dry-run] [--no-extras]
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

from ._install import _Writer

from ._content import shell_dir

_COMMENT = "# ===== den ====="
_PWSH_PROFILE = "Microsoft.PowerShell_profile.ps1"

_POSIX_CORE = ["_helpers.sh", "wrappers.sh", "aliases.sh", "functions.sh", "hwinfo.sh"]
_POSIX_EXTRAS = ["python.sh", "ffmpeg.sh", "parallel.sh"]
_PWSH_CORE = [
    "_helpers.ps1",
    "init.ps1",
    "wrappers.ps1",
    "coreutils.ps1",
    "aliases.ps1",
    "functions.ps1",
    "hwinfo.ps1",
]
_PWSH_EXTRAS = ["python.ps1", "ffmpeg.ps1", "parallel.ps1"]

_BASH_LINE = (
    '[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
)
_ZSH_LINE = '[ -f "$HOME/.config/shell/init.zsh" ] && . "$HOME/.config/shell/init.zsh"'
_PWSH_LINE = '. "$PSScriptRoot\\init.ps1"'


def _windows() -> bool:
    # Indirection so tests can flip platform without touching os.name globally
    # (pathlib reads os.name to pick WindowsPath/PosixPath).
    return os.name == "nt"


def _query_pwsh_profile() -> Path | None:
    """Ask the real PowerShell for $PROFILE so we honor OneDrive-redirected
    Documents and the PS5 (powershell) vs PS7 (pwsh) profile dirs. Returns the
    profile FILE path, or None when no PowerShell is available."""
    for exe in ("pwsh", "powershell"):
        if not shutil.which(exe):
            continue
        try:
            out = subprocess.run(
                [exe, "-NoProfile", "-Command", "$PROFILE.CurrentUserCurrentHost"],
                capture_output=True,
                text=True,
                timeout=20,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        if out.returncode != 0:
            continue
        # Take the last non-empty line and require a .ps1 path, so a banner or
        # warning line on stdout cannot corrupt the result.
        lines = [ln.strip() for ln in out.stdout.splitlines() if ln.strip()]
        if lines and lines[-1].lower().endswith(".ps1"):
            return Path(lines[-1])
    return None


def _pwsh_profile_dir() -> Path:
    # Only query on Windows -- that is where the OneDrive-redirected Documents
    # and PS5/PS7 profile-dir differences bite. POSIX keeps the fixed path (and
    # avoids spawning a subprocess on every install).
    if _windows():
        queried = _query_pwsh_profile()
        if queried is not None:
            return queried.parent
        return Path("~/Documents/PowerShell").expanduser()
    return Path("~/.config/powershell").expanduser()


def _localappdata() -> Path:
    env = os.environ.get("LOCALAPPDATA")
    return Path(env) if env else Path.home() / "AppData" / "Local"


def _copy(src: Path, dst: Path, dry_run: bool, writer: _Writer) -> None:
    if not src.is_file():
        return
    if dry_run:
        print(f"  [dry] {dst}")
        return
    writer.stage(dst, src.read_bytes())


def _wire(rc: Path, line: str, dry_run: bool) -> None:
    if rc.is_file() and line in rc.read_text(encoding="utf-8", errors="ignore"):
        print(f"  [skip] {rc} already configured")
        return
    if dry_run:
        print(f"  [dry] {'append to' if rc.is_file() else 'create'} {rc}")
        return
    rc.parent.mkdir(parents=True, exist_ok=True)
    if rc.is_file():
        with rc.open("a", encoding="utf-8") as fh:
            fh.write(f"\n{_COMMENT}\n{line}\n")
        print(f"  [ok] appended to {rc}")
    else:
        rc.write_text(f"{_COMMENT}\n{line}\n", encoding="utf-8")
        print(f"  [ok] created {rc}")


def _stage_shell_files(writer, extras: bool, dry_run: bool, announce: bool):
    """Stage every shell file den deploys (no commit). Returns (posix_dir,
    pwsh_dir). Shared by install (writes) and uninstall (plans removal), so the
    dest paths and bundled content match exactly."""
    sh = shell_dir()
    home = Path.home()
    posix_dir = home / ".config" / "shell"
    pwsh_dir = _pwsh_profile_dir()

    if announce:
        print(f"shell (posix) -> {posix_dir}")
    for f in _POSIX_CORE + (_POSIX_EXTRAS if extras else []):
        _copy(sh / "posix" / f, posix_dir / f, dry_run, writer)
    _copy(sh / "bash" / "init.bash", posix_dir / "init.bash", dry_run, writer)
    _copy(sh / "zsh" / "init.zsh", posix_dir / "init.zsh", dry_run, writer)
    _copy(
        sh / "starship" / "starship.toml",
        home / ".config" / "starship.toml",
        dry_run,
        writer,
    )

    if announce:
        print(f"shell (pwsh) -> {pwsh_dir}")
    for f in _PWSH_CORE + (_PWSH_EXTRAS if extras else []):
        _copy(sh / "pwsh" / f, pwsh_dir / f, dry_run, writer)

    # cmd / Clink shims (Windows only): bin/*.cmd + starship.lua -> %LOCALAPPDATA%\clink
    if _windows():
        clink = _localappdata() / "clink"
        if announce:
            print(f"cmd/Clink -> {clink}")
        _copy(sh / "cmd" / "starship.lua", clink / "starship.lua", dry_run, writer)
        cmd_bin = sh / "cmd" / "bin"
        if cmd_bin.is_dir():
            for f in sorted(cmd_bin.glob("*.cmd")):
                _copy(f, clink / "bin" / f.name, dry_run, writer)

    return posix_dir, pwsh_dir


def install_shell(argv: list[str]) -> int:
    dry_run = "--dry-run" in argv
    extras = "--no-extras" not in argv
    force = "--force" in argv
    for a in argv:
        if a not in ("--dry-run", "--no-extras", "--force"):
            print(f"den install shell: unexpected arg '{a}'", file=sys.stderr)
            return 2

    home = Path.home()
    writer = _Writer(force)
    _posix_dir, pwsh_dir = _stage_shell_files(writer, extras, dry_run, announce=True)

    if not dry_run:
        writer.commit()

    print("wiring shell rc files")
    if shutil.which("bash") or (home / ".bashrc").is_file():
        _wire(home / ".bashrc", _BASH_LINE, dry_run)
    if shutil.which("zsh") or (home / ".zshrc").is_file():
        _wire(home / ".zshrc", _ZSH_LINE, dry_run)
    if _windows() or shutil.which("pwsh"):
        _wire(pwsh_dir / _PWSH_PROFILE, _PWSH_LINE, dry_run)

    return 0
