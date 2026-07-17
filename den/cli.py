"""den - the installer for your LLM skills and machine environment.

  install    deploy skills, the shell environment, hooks, or cheatsheets
  uninstall  remove den-installed files (keeping ones you changed)

Runtime plumbing invoked by installed hooks and skills (not part of the
everyday surface):
  hook    the per-turn worker + hook lifecycle (den hook run/list/imprint/memory)
  memory  workspace session memory (also reachable as den hook memory)
  verify  format/lint/typecheck one Python file, config-faithfully (skills
          call this after writing code; see den/_verify.py)
"""

from __future__ import annotations

import sys

from . import __version__


def _usage() -> None:
    print(
        "usage: den <command> [args]\n"
        "\n"
        "den installs your LLM skills and machine environment.\n"
        "\n"
        "Commands:\n"
        "  install   [skills|shell|hook|cheatsheets]  deploy (interactive if no target)\n"
        "  uninstall [skills|shell|hook|cheatsheets]  remove den-installed files\n"
        "\n"
        "Run 'den <command> --help' for command-specific options.\n"
        "(den hook / den memory / den verify are runtime plumbing for hooks and skills.)"
    )


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]

    if not args or args[0] in ("-h", "--help", "help"):
        _usage()
        return 0

    if args[0] == "--version":
        print(f"den {__version__}")
        return 0

    cmd, rest = args[0], args[1:]

    if cmd == "verify":
        from ._verify import main as _main

        return _main(rest)

    if cmd == "memory":
        from ._memory import main as _main

        return _main(rest)

    if cmd == "hook":
        from ._hook import main as _main

        return _main(rest)

    if cmd == "install":
        from ._install import main as _main

        return _main(rest)

    if cmd == "uninstall":
        from ._uninstall import main as _main

        return _main(rest)

    print(f"den: unknown command '{cmd}'. Run 'den --help'.", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
