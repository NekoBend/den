"""Interactive UI helpers.

Uses questionary (checkbox / confirm) and rich (styled output) when they are
installed AND we are in a terminal; otherwise falls back to plain stdin prompts
and print(), so the CLI works with no third-party deps and in pipes / CI.
"""

from __future__ import annotations

import sys


def _console():
    try:
        from rich.console import Console
    except Exception:
        return None
    return Console()


def say(message: str, *, style: str | None = None) -> None:
    """Print, styled via rich when available (rich auto-degrades off-TTY)."""
    console = _console()
    if console is not None:
        console.print(message, style=style, highlight=False)
    else:
        print(message)


def confirm(prompt: str, default: bool) -> bool:
    if sys.stdin.isatty():
        try:
            import questionary

            res = questionary.confirm(prompt, default=default, auto_enter=False).ask()
            if res is not None:
                return bool(res)
        except Exception:
            pass
    suffix = "[Y/n]" if default else "[y/N]"
    try:
        ans = input(f"{prompt} {suffix} ").strip().lower()
    except EOFError:
        return default
    return default if not ans else ans.startswith("y")


def select(title: str, options: list[tuple[str, bool]]) -> list[str]:
    """Checkbox multi-select. options = [(name, default_checked)]; returns the
    chosen names (empty if nothing selected or cancelled)."""
    if sys.stdin.isatty():
        try:
            import questionary

            choices = [questionary.Choice(name, checked=chk) for name, chk in options]
            picked = questionary.checkbox(title, choices=choices).ask()
            return list(picked) if picked else []
        except Exception:
            pass
    # fallback: ask y/N per item
    say(title)
    chosen: list[str] = []
    for name, default in options:
        if confirm(f"  {name}", default):
            chosen.append(name)
    return chosen
