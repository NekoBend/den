"""den cheat - view bundled cheatsheets offline.

den cheat              list available cheatsheets
den cheat <name>       print a cheatsheet (match by path, with or without ext)
"""

from __future__ import annotations

import sys
from pathlib import Path

from ._content import cheatsheets_dir


def _sheets(root: Path) -> list[Path]:
    out = []
    for p in sorted(root.rglob("*")):
        if p.is_file() and "__pycache__" not in p.parts and p.suffix != ".pyc":
            out.append(p.relative_to(root))
    return out


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    root = cheatsheets_dir()
    if not root.is_dir():
        print("den cheat: no cheatsheets are bundled", file=sys.stderr)
        return 1

    sheets = _sheets(root)
    if not args or args[0] in ("-h", "--help"):
        print("usage: den cheat [name]\n\nAvailable cheatsheets:")
        for s in sheets:
            print(f"  {s.as_posix()}")
        return 0

    query = args[0]
    exact = [s for s in sheets if query in (s.as_posix(), s.with_suffix("").as_posix())]
    matches = exact or [
        s
        for s in sheets
        if query in s.as_posix() or query in s.with_suffix("").as_posix()
    ]
    if not matches:
        print(f"den cheat: no cheatsheet matching '{query}'", file=sys.stderr)
        return 1
    if len(matches) > 1:
        print(f"den cheat: '{query}' is ambiguous; pick one:", file=sys.stderr)
        for s in matches:
            print(f"  {s.as_posix()}", file=sys.stderr)
        return 1

    sys.stdout.write((root / matches[0]).read_text(encoding="utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
