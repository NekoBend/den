"""Resolve the external tools den starts, never from the working directory.

On Windows shutil.which puts the current directory ahead of PATH (unless
NoDefaultCurrentDirectoryInExePath is set), and CreateProcess searches it too
for a path-less name. A cloned repo or an extracted archive that ships
`uv.exe`, `pwsh.exe`, `winget.exe` or a `den.cmd` at its root would otherwise
run instead of the real tool whenever den is invoked there. So every tool den
starts (uv, den, pwsh, powershell, winget, git, xdg-user-dir, ruff, ty) is
resolved here: PATH with its cwd-relative entries dropped, a hit in the
working directory itself refused on Windows (POSIX never searches it), and the
absolute path handed to subprocess as argv[0] so the OS does no searching of
its own.
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path


def _windows() -> bool:
    # Indirection so tests can flip platform without touching os.name globally
    # (pathlib reads os.name to pick WindowsPath/PosixPath).
    return os.name == "nt"


def search_path() -> str:
    """PATH with every current-directory entry dropped.

    An empty entry and any relative entry (including a Windows drive-relative
    one) are resolved against the cwd - a workspace den does not control - so
    only absolute directories are allowed to supply a tool.
    """
    entries = os.environ.get("PATH", "").split(os.pathsep)
    return os.pathsep.join(e for e in entries if e and Path(e).is_absolute())


def resolve_tool(name: str, path: str | None = None) -> tuple[str | None, str | None]:
    """(absolute path to run, refusal reason) for the tool `name`.

    Both None means "not installed". `path` narrows the search to those
    directories (default: search_path()). A hit in the working directory
    itself is refused rather than run: shutil.which re-inserts the current
    directory ahead of any search path on Windows (unless
    NoDefaultCurrentDirectoryInExePath is set) and CreateProcess searches it
    too for a path-less name, so a cloned repo that ships `ruff.exe` at its
    root would otherwise be executed by a den command run there. Handing
    subprocess an absolute path also stops CreateProcess from searching at all.

    Only the directory itself is refused, because that is all those two
    searches can reach; a tool under it - a project's own .venv/bin/ruff,
    the normal case - is the one the project wants and still runs. And only
    on Windows: POSIX searches neither the cwd nor (after search_path) a
    relative entry, so a hit there came from an absolute PATH entry, as when
    den upgrade runs from ~/.local/bin, and is the tool PATH names.
    """
    hit = shutil.which(name, path=search_path() if path is None else path)
    if hit is None:
        return None, None
    exe = Path(hit)
    relative = not exe.is_absolute()  # via the Windows curdir entry, or `path`
    if relative:
        exe = Path.cwd() / exe
    in_cwd = exe.resolve().parent == Path.cwd().resolve()
    if in_cwd and (relative or _windows()):
        return None, f"refusing {name} resolved inside the workspace ({exe})"
    return str(exe), None


def find_tool(name: str, prefix: str) -> str | None:
    """Absolute path of `name`, or None when it is missing or refused.

    A refusal is reported (one line on stderr, led by `prefix`), so a caller
    that falls back to something else still tells the user why.
    """
    exe, refusal = resolve_tool(name)
    if refusal:
        print(f"{prefix}: {refusal}", file=sys.stderr)
    return exe
