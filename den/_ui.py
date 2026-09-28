"""Interactive UI helpers.

Uses questionary (checkbox / confirm) and rich (styled output) when they are
installed AND we are in a terminal; otherwise falls back to plain stdin prompts
and print(), so the CLI works with no third-party deps and in pipes / CI.
"""

from __future__ import annotations

import sys
from typing import Any


def _console() -> Any:  # ruff: ignore[any-type]  # rich Console or None
    try:
        from rich.console import Console
    except Exception:
        return None
    return Console()


def say(message: str, *, style: str | None = None) -> None:
    """Print, styled via rich when available (rich auto-degrades off-TTY).

    The message is printed literally: callers list file paths before the
    overwrite and removal prompts, and Rich markup would drop a `[client]`
    directory, eat the backslash of a Windows `\\[X]` one, or raise
    MarkupError on `[/old]`. No caller uses markup; `style` is the styling."""
    console = _console()
    if console is not None:
        console.print(message, style=style, highlight=False, markup=False, emoji=False)
    else:
        print(message)


# ruff: ignore[boolean-type-hint-positional-argument, boolean-default-value-positional-argument]
# The bool IS the question's default; callers read confirm(prompt, default=False).
def confirm(prompt: str, default: bool = False) -> bool:
    """Ask a yes/no question. Ctrl-C raises KeyboardInterrupt (den.cli ends
    with 130): questionary's ask() would swallow it and return None, and the
    plain prompt below then asked again, where the next Enter took the
    default. `except Exception` does not catch it (a BaseException)."""
    if sys.stdin.isatty():
        try:
            import questionary

            res = questionary.confirm(
                prompt, default=default, auto_enter=False
            ).unsafe_ask()
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
    chosen names (empty if nothing selected). Ctrl-C raises KeyboardInterrupt,
    as in confirm()."""
    if sys.stdin.isatty():
        try:
            import questionary

            choices = [questionary.Choice(name, checked=chk) for name, chk in options]
            picked = questionary.checkbox(title, choices=choices).unsafe_ask()
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
