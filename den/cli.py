"""den - unified toolkit CLI for LLM-assisted development.

Subcommands:
  check   lint / format / typecheck a file (dispatches to run-checks.sh)
  verify  check that imported APIs exist
  refs    find definitions or usages of a symbol across a source tree
  doc     report docstring / doc-comment coverage
  memory  read/write workspace session memory (.den/memory.md)
  hook    install per-tool hooks that imprint context every turn
  cheat   view bundled cheatsheets offline
  install deploy skills, or the shell environment, into place
"""

from __future__ import annotations

import sys

from . import __version__


def _usage() -> None:
    print(
        "usage: den <command> [args]\n"
        "\n"
        "Commands:\n"
        "  check  <file>              lint / format / typecheck a file\n"
        "  verify <file>              check that imported APIs exist\n"
        "  refs   --def|-uses|-in ... find symbol definitions or usages\n"
        "  doc    <file>              docstring / doc-comment coverage\n"
        "  memory show|save|log|...   workspace session memory\n"
        "  hook   install|run|imprint per-turn imprint hooks\n"
        "  cheat  [name]              view bundled cheatsheets\n"
        "  install skills|shell       deploy skills or the shell environment\n"
        "\n"
        "Run 'den <command> --help' for command-specific options."
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

    if cmd == "check":
        from ._check import main as _main

        return _main(rest)

    if cmd == "verify":
        from ._verify import main as _main

        return _main(rest)

    if cmd == "refs":
        from ._refs import main as _main

        return _main(rest)

    if cmd == "doc":
        from ._doc import main as _main

        return _main(rest)

    if cmd == "memory":
        from ._memory import main as _main

        return _main(rest)

    if cmd == "hook":
        from ._hook import main as _main

        return _main(rest)

    if cmd == "cheat":
        from ._cheat import main as _main

        return _main(rest)

    if cmd == "install":
        from ._install import main as _main

        return _main(rest)

    print(f"den: unknown command '{cmd}'. Run 'den --help'.", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
