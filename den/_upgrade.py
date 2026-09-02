"""den upgrade - upgrade den itself via uv, then optionally redeploy content.

den is installed as a uv tool, so the upgrade itself is `uv tool upgrade den`.
The wrinkle is that bundled content (skills, shell sources, parent prompts,
cheatsheets) only reaches disk on `den install ...`: after an upgrade the new
wheel's content sits inside the tool venv until it is redeployed. --refresh
does that redeploy immediately - as subprocesses of the freshly upgraded
`den` binary, never in-process, because this running process still has the
OLD package (and its old bundled data) imported.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys

_REFRESH_STEPS = (
    ("install", "skills", "--with-parent"),
    ("install", "shell"),
)


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

    if not shutil.which("uv"):
        print(
            "den upgrade: uv not found on PATH. den is installed as a uv tool;"
            " install uv (https://docs.astral.sh/uv/) and retry.",
            file=sys.stderr,
        )
        return 1

    upgrade_cmd = ["uv", "tool", "upgrade", "den"]
    if dry_run:
        print(f"[dry-run] would run: {' '.join(upgrade_cmd)}")
        if refresh:
            for step in steps:
                print(f"[dry-run] would run: den {' '.join(step)}")
        return 0

    proc = subprocess.run(upgrade_cmd)
    if proc.returncode != 0:
        if os.name == "nt":
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
    den = shutil.which("den")
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
            print(
                f"den upgrade: `den {' '.join(step)}` exited"
                f" {proc.returncode}; the new version's files are NOT deployed."
                + (
                    ""
                    if force
                    else " If it kept files that differ, re-run"
                    " `den upgrade --refresh --force`."
                ),
                file=sys.stderr,
            )
            return proc.returncode
    return 0
