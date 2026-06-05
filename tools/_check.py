"""den check - run format/lint/typecheck on a source file.

Delegates to run-checks.sh (co-located in the same directory), which
dispatches by file extension to ruff, shellcheck, prettier, gofmt, etc.
Tools that are not installed are reported as SKIPPED rather than failing.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

_SCRIPT = Path(__file__).parent / "run-checks.sh"


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]

    if not args or args[0] in ("-h", "--help"):
        print("usage: den check <file>")
        print("  Run format, lint, and typecheck on a source file.")
        print("  Dispatches by extension: .py .ts .go .rs .java .cs .sh")
        return 0

    file = args[0]

    bash = shutil.which("bash")
    if bash is None:
        print("den check: bash not found on PATH", file=sys.stderr)
        return 1

    if not _SCRIPT.exists():
        print(f"den check: run-checks.sh not found at {_SCRIPT}", file=sys.stderr)
        return 1

    result = subprocess.run([bash, str(_SCRIPT), file])
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
