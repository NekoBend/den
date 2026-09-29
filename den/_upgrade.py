"""den upgrade - upgrade den itself via uv, then optionally redeploy content.

den is installed as a uv tool, so the upgrade itself is `uv tool upgrade den`.
The wrinkle is that bundled content (skills, shell sources, parent prompts,
cheatsheets) only reaches disk on `den install ...`: after an upgrade the new
wheel's content sits inside the tool venv until it is redeployed. --refresh
does that redeploy immediately - as subprocesses of the freshly upgraded
`den` binary, never in-process, because this running process still has the
OLD package (and its old bundled data) imported.

uv and the upgraded den are resolved through den._exe and run by absolute
path: a checkout that ships uv.exe or den.cmd at its root must not be what
`den upgrade` runs when invoked there on Windows. The redeploy uses the den in
uv's own tool bin dir (`uv tool dir --bin`), the one the upgrade just
replaced, and falls back to PATH (cwd entries dropped) only when uv cannot
name that dir.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from ._exe import find_tool, resolve_tool

_REFRESH_STEPS = (
    ("install", "skills", "--with-parent"),
    ("install", "shell"),
)


def _windows() -> bool:
    # Indirection so tests can flip platform without touching os.name globally
    # (pathlib reads os.name to pick WindowsPath/PosixPath).
    return os.name == "nt"


def _upgraded_den(uv: str) -> str | None:
    """The den `uv tool upgrade` just replaced, by absolute path, or None.

    uv's tool bin dir comes first because PATH can name another den ahead of
    it (a project venv's); PATH, with its cwd entries dropped, is only the
    fallback for a uv that cannot report the dir. A den in the working
    directory is refused either way (reported on stderr).
    """
    bin_dir = None
    try:
        out = subprocess.run(
            [uv, "tool", "dir", "--bin"],
            capture_output=True,
            text=True,
            # uv prints UTF-8; the locale codec would mangle a non-ASCII home
            encoding="utf-8",
            errors="replace",
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        out = None
    if out is not None and out.returncode == 0:
        lines = [ln.strip() for ln in out.stdout.splitlines() if ln.strip()]
        if lines and Path(lines[-1]).is_absolute():
            bin_dir = lines[-1]
    if bin_dir is not None:
        den, refusal = resolve_tool("den", path=bin_dir)
        if refusal:
            print(f"den upgrade: {refusal}", file=sys.stderr)
            return None
        if den:
            return den
    return find_tool("den", "den upgrade")


def _refresh_steps(*, force: bool) -> tuple[tuple[str, ...], ...]:
    """The redeploy commands. `den install` decides "this file is den's" by
    comparing bytes, and after an upgrade EVERY file the new version changed
    differs -- indistinguishable from a local edit. So a plain --refresh keeps
    them all (silently, when stdin is not a tty) and deploys nothing. --force
    is how a scripted refresh says "the deployed copy is den's, replace it"."""
    return tuple((*step, "--force") if force else step for step in _REFRESH_STEPS)


def _usage() -> None:
    print(
        "usage: den upgrade [--refresh] [--force] [--dry-run]"
        "   (alias: den update)\n"
        "\n"
        "Upgrade den itself (runs `uv tool upgrade den`).\n"
        "\n"
        "  --refresh  after upgrading, redeploy the bundled content by running\n"
        "             `den install skills --with-parent` and `den install shell`\n"
        "             with the new binary\n"
        "  --force    pass --force to those redeploy steps, overwriting deployed\n"
        "             files that differ. After an upgrade every file the new\n"
        "             version changed differs, so a non-interactive --refresh\n"
        "             without it keeps them all and deploys nothing (it then\n"
        "             exits non-zero rather than reporting success).\n"
        "  --dry-run  print the commands without running anything"
    )


def main(  # ruff: ignore[too-many-return-statements, too-many-branches]  # flag parse plus one exit per failure mode
    argv: list[str] | None = None,
) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if args and args[0] in {"-h", "--help", "help"}:
        _usage()
        return 0
    refresh = dry_run = force = False
    for a in args:
        if a == "--refresh":
            refresh = True
        elif a == "--force":
            force = True
        elif a == "--dry-run":
            dry_run = True
        else:
            print(f"den upgrade: unknown argument '{a}'", file=sys.stderr)
            return 2
    if force and not refresh:
        print(
            "den upgrade: --force only applies to --refresh; nothing is"
            " redeployed without it.",
            file=sys.stderr,
        )
    steps = _refresh_steps(force=force)

    uv, refusal = resolve_tool("uv")
    if refusal:
        print(
            f"den upgrade: {refusal}; run den upgrade from another directory.",
            file=sys.stderr,
        )
        return 1
    if uv is None:
        print(
            "den upgrade: uv not found on PATH. den is installed as a uv tool;"
            " install uv (https://docs.astral.sh/uv/) and retry.",
            file=sys.stderr,
        )
        return 1

    upgrade_args = ["tool", "upgrade", "den"]
    if dry_run:
        print(f"[dry-run] would run: uv {' '.join(upgrade_args)}")
        if refresh:
            for step in steps:
                print(f"[dry-run] would run: den {' '.join(step)}")
        return 0

    proc = subprocess.run([uv, *upgrade_args])
    if proc.returncode != 0:
        if _windows():
            # this process runs from the tool venv uv is replacing; Windows
            # locks running executables, POSIX does not care
            print(
                "hint: if uv reported a file-in-use error, the running den"
                " process was locking its own install; run"
                " `uv tool upgrade den` directly instead.",
                file=sys.stderr,
            )
        return proc.returncode

    if not refresh:
        print(
            "note: bundled content (skills, shell, cheatsheets) is only"
            " redeployed by `den install ...`; run `den upgrade --refresh`"
            " (or the install commands yourself) to deploy the new"
            " version's files."
        )
        return 0

    # The upgraded code and bundled data exist only in the new binary; this
    # process still runs the old package, so redeploy via subprocesses.
    den = _upgraded_den(uv)
    if not den:
        print(
            "den upgrade: `den` not found on PATH after the upgrade; run"
            " `den install skills --with-parent` and `den install shell`"
            " manually.",
            file=sys.stderr,
        )
        return 1
    for step in steps:
        proc = subprocess.run([den, *step])
        if proc.returncode != 0:
            # Not "nothing was deployed": an install step exits non-zero when it
            # KEPT even one modified file, having deployed the rest, and a later
            # step fails only after every earlier one already succeeded.
            print(
                f"den upgrade: `den {' '.join(step)}` exited"
                f" {proc.returncode}; the refresh did not complete. Some files"
                " may already be deployed."
                + (
                    ""
                    if force
                    else " Re-run `den upgrade --refresh --force` to deploy the rest."
                ),
                file=sys.stderr,
            )
            return proc.returncode
    return 0
