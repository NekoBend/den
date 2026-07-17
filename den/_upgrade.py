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

import shutil
import subprocess
import sys

_REFRESH_STEPS = (
    ("install", "skills", "--with-parent"),
    ("install", "shell"),
)


def _usage() -> None:
    print(
        "usage: den upgrade [--refresh] [--dry-run]   (alias: den update)\n"
        "\n"
        "Upgrade den itself (runs `uv tool upgrade den`).\n"
        "\n"
        "  --refresh  after upgrading, redeploy the bundled content by running\n"
        "             `den install skills --with-parent` and `den install shell`\n"
        "             with the new binary\n"
        "  --dry-run  print the commands without running anything"
    )


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if args and args[0] in ("-h", "--help", "help"):
        _usage()
        return 0
    refresh = dry_run = False
    for a in args:
        if a == "--refresh":
            refresh = True
        elif a == "--dry-run":
            dry_run = True
        else:
            print(f"den upgrade: unknown argument '{a}'", file=sys.stderr)
            return 2

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
            for step in _REFRESH_STEPS:
                print(f"[dry-run] would run: den {' '.join(step)}")
        return 0

    proc = subprocess.run(upgrade_cmd)
    if proc.returncode != 0:
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
    for step in _REFRESH_STEPS:
        proc = subprocess.run([den, *step])
        if proc.returncode != 0:
            return proc.returncode
    return 0
