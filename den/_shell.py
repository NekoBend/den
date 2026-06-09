"""den install shell - deploy the shell environment (bash/zsh + PowerShell).

Deploys the shell environment (the one cross-platform installer).
Copies the bundled shell config into place and wires the relevant rc files
idempotently. Config files are deployed for both shell families; only rc files
for shells that look relevant (binary on PATH, or rc already present, or native
platform) are wired.

  den install shell [--dry-run] [--no-extras] [--coreutils|--no-coreutils]
                    [--bin|--no-bin]

On Windows the pwsh wrappers can use microsoft/coreutils as their Unix-command
tier (see shell/pwsh/_helpers.ps1). `--coreutils` installs it via winget;
`--no-coreutils` skips it; with neither, an interactive run asks (default no).

`--bin` installs the bundled POSIX helper executables (shell/posix/bin/*, e.g.
fixids) to ~/.local/bin; `--no-bin` skips them; with neither, an interactive
POSIX run asks (default no). They are POSIX-only (need GNU coreutils/find) and
are never installed on Windows.
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

# microsoft/coreutils inlines its PowerShell integration into the profile inside a
# sentinel-delimited block carrying this fixed GUID. den removes it (see
# _disable_coreutils_readline) so its own wrappers govern dispatch.
_COREUTILS_SENTINEL = "60b36fc6-2d59-49df-be51-28dd2f4c3c9a"

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


def _stage_shell_files(
    writer, extras: bool, dry_run: bool, announce: bool, posix_bin: bool = False
):
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

    # POSIX standalone executables (shell/posix/bin/*, e.g. fixids) -> ~/.local/bin,
    # which den's init already adds to PATH (_init_path). They need GNU
    # coreutils/find, so they are never staged on Windows (the symmetric Windows
    # case is the cmd/bin/*.cmd shims above). Optional on install (gated by the
    # caller's y/N), but always staged on uninstall so prior copies are removed.
    if posix_bin and not _windows():
        local_bin = home / ".local" / "bin"
        src_bin = sh / "posix" / "bin"
        if src_bin.is_dir():
            files = sorted(p for p in src_bin.iterdir() if p.is_file())
            if files and announce:
                print(f"posix bin -> {local_bin}")
            for f in files:
                _copy(f, local_bin / f.name, dry_run, writer)

    return posix_dir, pwsh_dir


def _decide_posix_bin(want: bool, skip: bool) -> bool:
    """Whether to install the bundled POSIX helper executables (shell/posix/bin/*,
    e.g. fixids) to ~/.local/bin. POSIX-only: they need GNU coreutils/find and are
    not runnable on Windows. With --bin install without asking; with --no-bin skip;
    otherwise ask on an interactive POSIX run, default no."""
    if _windows():
        if want:
            print("posix bin: POSIX-only; ignoring --bin", file=sys.stderr)
        return False
    if skip:
        return False
    if want:
        return True
    if not sys.stdin.isatty():
        return False
    from . import _ui

    return _ui.confirm(
        "Install POSIX helper executables (shell/posix/bin/*) to ~/.local/bin?",
        False,
    )


def _disable_coreutils_readline(profile: Path) -> bool:
    """Remove microsoft/coreutils' PSConsoleHostReadLine integration block(s) from a
    PowerShell profile. coreutils inlines a readline rewriter that retargets typed
    `ls`/`cat`/... to coreutils before den's wrappers see them, defeating den's
    modern-first dispatch. Each block is bracketed by two sentinel comment lines
    carrying a fixed GUID. Removes each open..close PAIR (plus an adjacent blank on
    each side), so content sitting BETWEEN two separate blocks is never touched.
    Backs the original up to <profile>.den.bak before the first edit. Preserves the
    file's CRLF/LF ending and its encoding (UTF-8, UTF-8-BOM, or UTF-16; a UTF-16
    profile is normalized to little-endian, which is what PowerShell writes), and
    leaves the file untouched if it does not decode. Idempotent: returns True only
    when it removed a block."""
    if not profile.is_file():
        return False
    raw = profile.read_bytes()
    # Preserve the profile's encoding: re-encoding a UTF-16 profile as UTF-8, or
    # dropping bytes via errors='ignore', breaks PowerShell parsing. Detect from a
    # BOM, decode STRICTLY, and bail without editing if it does not decode.
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        enc = "utf-16"
    elif raw[:3] == b"\xef\xbb\xbf":
        enc = "utf-8-sig"
    else:
        enc = "utf-8"
    try:
        text = raw.decode(enc)
    except (UnicodeError, ValueError):
        return False
    crlf = "\r\n" in text
    lines = text.replace("\r\n", "\n").split("\n")
    marks = [i for i, ln in enumerate(lines) if _COREUTILS_SENTINEL in ln]
    # Pair the sentinels (open, close). An odd trailing sentinel (corrupt/partial
    # block) is left in place rather than guessing where it ends.
    spans = []
    for open_i, close_i in zip(marks[0::2], marks[1::2]):
        start, end = open_i, close_i + 1
        if end < len(lines) and lines[end] == "":  # trailing blank
            end += 1
        if start > 0 and lines[start - 1] == "":  # preceding blank
            start -= 1
        spans.append((start, end))
    if not spans:
        return False
    backup = profile.with_suffix(profile.suffix + ".den.bak")
    if not backup.exists():
        backup.write_bytes(raw)
    for start, end in reversed(spans):  # deepest-first keeps earlier indices valid
        del lines[start:end]
    new = "\n".join(lines)
    if crlf:
        new = new.replace("\n", "\r\n")
    profile.write_text(new, encoding=enc, newline="")
    return True


def install_shell(argv: list[str]) -> int:
    dry_run = "--dry-run" in argv
    extras = "--no-extras" not in argv
    force = "--force" in argv
    want_coreutils = "--coreutils" in argv
    skip_coreutils = "--no-coreutils" in argv
    want_bin = "--bin" in argv
    skip_bin = "--no-bin" in argv
    allowed = (
        "--dry-run",
        "--no-extras",
        "--force",
        "--coreutils",
        "--no-coreutils",
        "--bin",
        "--no-bin",
    )
    for a in argv:
        if a not in allowed:
            print(f"den install shell: unexpected arg '{a}'", file=sys.stderr)
            return 2

    home = Path.home()
    writer = _Writer(force)
    install_bin = _decide_posix_bin(want_bin, skip_bin)
    _posix_dir, pwsh_dir = _stage_shell_files(
        writer, extras, dry_run, announce=True, posix_bin=install_bin
    )

    if not dry_run:
        writer.commit()

    # _copy/_Writer write bytes only; deployed executables need their +x bit.
    # Only chmod files whose on-disk content is den's: a file the user modified
    # (and chose to keep at the overwrite prompt) must keep its mode too.
    if install_bin and not dry_run:
        local_bin = home / ".local" / "bin"
        src_bin = shell_dir() / "posix" / "bin"
        if src_bin.is_dir():
            for f in src_bin.iterdir():
                dst = local_bin / f.name
                if f.is_file() and dst.is_file() and dst.read_bytes() == f.read_bytes():
                    dst.chmod(0o755)

    print("wiring shell rc files")
    if shutil.which("bash") or (home / ".bashrc").is_file():
        _wire(home / ".bashrc", _BASH_LINE, dry_run)
    if shutil.which("zsh") or (home / ".zshrc").is_file():
        _wire(home / ".zshrc", _ZSH_LINE, dry_run)
    if _windows() or shutil.which("pwsh"):
        _wire(pwsh_dir / _PWSH_PROFILE, _PWSH_LINE, dry_run)

    rc = _maybe_install_coreutils(want_coreutils, skip_coreutils, dry_run)

    # coreutils installs a PSConsoleHostReadLine rewriter into the profile that
    # retargets typed `ls`/`cat`/... to coreutils BEFORE den's wrappers run,
    # defeating den's modern-first dispatch. den drives coreutils through its own
    # tier (coreutils.exe), so strip that block to let the wrappers govern. Done
    # after the install step so a freshly added block is caught too.
    if not dry_run and (_windows() or shutil.which("pwsh")):
        for prof in (pwsh_dir / _PWSH_PROFILE, pwsh_dir / "profile.ps1"):
            if _disable_coreutils_readline(prof):
                print(f"  [ok] removed coreutils readline integration from {prof}")

    return rc


def _coreutils_present() -> bool:
    """True if microsoft/coreutils is already installed. The binary is normally
    NOT on PATH (its admin/all-user installer only optionally adds a bin\\ subdir,
    never the coreutils.exe dir), so also probe the fixed install location. This
    asks "is the package installed", not "is the tier enabled", so it does not
    honor $_DOTFILES_COREUTILS=0 (that only disables den's runtime dispatch)."""
    if shutil.which("coreutils"):
        return True
    # Mirror the pwsh resolver (_helpers.ps1 _CoreutilsBin): probe both Program
    # Files roots so a 32-bit host is covered too.
    for var in ("ProgramFiles", "ProgramFiles(x86)"):
        base = os.environ.get(var)
        if base and (Path(base) / "coreutils" / "coreutils.exe").is_file():
            return True
    return False


def _maybe_install_coreutils(want: bool, skip: bool, dry_run: bool) -> int:
    """Decide whether to install microsoft/coreutils, then do it. Windows-only
    (the pwsh wrappers consult it only there). With --coreutils install without
    asking; with --no-coreutils skip; otherwise ask on an interactive Windows run
    and default to no. Returns the winget exit code when an install runs, else 0,
    so a flag-driven install failure surfaces from `den install shell`."""
    if skip:
        return 0
    if not _windows():
        if want:
            print("coreutils: --coreutils is Windows-only; ignoring", file=sys.stderr)
        return 0
    if _coreutils_present():
        print("coreutils: already installed")
        return 0
    if not want:
        if not sys.stdin.isatty():
            return 0
        from . import _ui

        if not _ui.confirm(
            "Install microsoft/coreutils (Unix commands for the pwsh wrappers)?",
            False,
        ):
            return 0
    return _install_coreutils(dry_run)


def _install_coreutils(dry_run: bool) -> int:
    """winget-install microsoft/coreutils. Assumes a Windows host with winget."""
    cmd = [
        "winget",
        "install",
        "-e",
        "--id",
        "Microsoft.Coreutils",
        "-s",
        "winget",
        "--accept-package-agreements",
        "--accept-source-agreements",
    ]
    print("coreutils -> " + " ".join(cmd))
    if dry_run:
        return 0
    if not shutil.which("winget"):
        print(
            "coreutils: winget not found; install winget or get coreutils manually",
            file=sys.stderr,
        )
        return 1
    try:
        return subprocess.run(cmd).returncode
    except OSError as exc:
        print(f"coreutils: winget failed: {exc}", file=sys.stderr)
        return 1
