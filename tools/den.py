"""den - toolkit for LLM-assisted development workflows.

Subcommands:
  check   lint / format / typecheck a file
  verify  check that imported APIs exist
  refs    find where a symbol is referenced
  doc     report docstring coverage
  search  search a codebase (coming soon)
  memory  read/write session memory (coming soon)
  hook    manage agent hook registrations (coming soon)
"""
from __future__ import annotations

import argparse
import sys


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="den",
        description="den toolkit for LLM-assisted development",
    )
    ap.add_argument("--version", action="version", version="den 0.1.0")

    sub = ap.add_subparsers(dest="cmd", metavar="<command>")

    # check
    p_check = sub.add_parser("check", help="lint / format / typecheck a file")
    p_check.add_argument("file", nargs="?", help="file to check (default: current dir)")

    # verify
    p_verify = sub.add_parser("verify", help="check that imported APIs exist")
    p_verify.add_argument("file", help="Python file to verify")

    # refs
    p_refs = sub.add_parser("refs", help="find where a symbol is referenced")
    p_refs.add_argument("--uses", metavar="SYMBOL", required=True, help="symbol name")
    p_refs.add_argument("path", nargs="?", default=".", help="search root (default: .)")

    # doc
    p_doc = sub.add_parser("doc", help="report docstring coverage")
    p_doc.add_argument("file", help="Python file to check")

    # search (stub)
    p_search = sub.add_parser("search", help="search a codebase (coming soon)")
    p_search.add_argument("query", help="search query")
    p_search.add_argument("--in", dest="root", default=".", metavar="DIR")

    # memory (stub)
    p_mem = sub.add_parser("memory", help="read/write session memory (coming soon)")
    p_mem.add_argument("action", choices=["show", "save", "clear"])

    # hook (stub)
    p_hook = sub.add_parser("hook", help="manage agent hook registrations (coming soon)")
    p_hook.add_argument("action", choices=["install", "list", "remove"])
    p_hook.add_argument("--tool", help="tool to manage hooks for")

    args = ap.parse_args()

    if args.cmd is None:
        ap.print_help()
        return 0

    # Dispatch
    if args.cmd == "check":
        from _check import run as _check
        return _check(args.file or ".")
    if args.cmd == "verify":
        from _verify import run as _verify
        return _verify(args.file)
    if args.cmd == "refs":
        from _refs import run as _refs
        return _refs(args.uses, args.path)
    if args.cmd == "doc":
        from _doc import run as _doc
        return _doc(args.file)
    if args.cmd in ("search", "memory", "hook"):
        print(f"den {args.cmd}: coming soon", file=sys.stderr)
        return 1

    ap.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
