"""den verify - format / lint / typecheck one Python file, config-faithfully.

Hidden runtime command (like hook/memory): agents call it after writing code.
The design rule is "discover like the tools do, make the discovery visible,
never override":

- The anchor is the FILE's directory (cwd-independent), exactly like ruff.
- ruff: the nearest-wins discovery (.ruff.toml > ruff.toml > pyproject.toml
  with [tool.ruff]; no merging) is re-walked here ONLY to report which config
  will win; ruff itself runs with no config flags, so its real resolution is
  never overridden. Only when NO config exists anywhere up the tree do den's
  defaults apply (missing public docstrings: D101, D102, D103).
- ty: import resolution needs a real environment, so the project root is
  passed explicitly (--project <root>, root = nearest pyproject.toml/ty.toml
  ancestor) and the venv line reports what ty will see.
- the tools themselves are resolved through PATH only and run by absolute
  path; one that resolves inside the workspace is refused, never executed.
  On Windows shutil.which prepends the current directory (unless
  NoDefaultCurrentDirectoryInExePath is set) and CreateProcess searches it
  too for a path-less name, so a cloned repo shipping `ruff.exe` at its root
  would otherwise run when `den verify` is invoked there.

Output is line-oriented for model consumption: one `config:` line per tool,
then PASS / FAIL / SKIP per stage. FAIL detail is capped; SKIP always names
the next action. Exit 0 = no failures, 1 = failures, 2 = usage. Tool output
is decoded as UTF-8 (what ruff and ty emit, source snippets included), never
the locale codec.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from contextlib import suppress
from pathlib import Path

_MAX_DETAIL_LINES = 30
_DEN_DEFAULT_LINT = ("--extend-select", "D101,D102,D103")


def _ruff_config(file: Path) -> tuple[Path, str] | None:
    """The config file ruff's own discovery will pick for `file`, or None.

    Mirrors ruff's order: walk up from the file's directory; in each dir
    .ruff.toml wins over ruff.toml wins over a pyproject.toml that has a
    [tool.ruff] section (a pyproject WITHOUT that section does not stop the
    walk). Nearest match wins outright - parent configs never merge in.
    """
    d = file.resolve().parent
    while True:
        for name in (".ruff.toml", "ruff.toml"):
            if (d / name).is_file():
                return d / name, name
        py = d / "pyproject.toml"
        if py.is_file():
            try:
                text = py.read_text(encoding="utf-8")
            except OSError:
                text = ""
            if any(line.startswith("[tool.ruff") for line in text.splitlines()):
                return py, "pyproject.toml [tool.ruff]"
        if d.parent == d:
            return None
        d = d.parent


def _project_root(file: Path) -> Path:
    """Nearest ancestor with pyproject.toml or ty.toml, else the file's dir.
    Passed to ty as --project so its resolution never depends on the cwd."""
    d = file.resolve().parent
    while True:
        if (d / "pyproject.toml").is_file() or (d / "ty.toml").is_file():
            return d
        if d.parent == d:
            return file.resolve().parent
        d = d.parent


def _venv_line(root: Path) -> str:
    env = os.environ.get("VIRTUAL_ENV")
    if env:
        return f"venv: {env} (VIRTUAL_ENV)"
    if (root / ".venv").is_dir():
        return f"venv: {root / '.venv'}"
    return (
        "venv: none found (third-party imports may be unresolvable;"
        " run `uv sync` or set VIRTUAL_ENV)"
    )


def _search_path() -> str:
    """PATH with every current-directory entry dropped.

    An empty entry and any relative entry (including a Windows drive-relative
    one) are resolved against the cwd - the very workspace being verified -
    so only absolute directories are allowed to supply a tool.
    """
    entries = os.environ.get("PATH", "").split(os.pathsep)
    return os.pathsep.join(e for e in entries if e and Path(e).is_absolute())


def _resolve_tool(name: str) -> tuple[str | None, str | None]:
    """(absolute path to run, refusal reason) for the tool `name`.

    Both None means "not installed". A hit inside the cwd is refused rather
    than run: shutil.which re-inserts the current directory ahead of PATH on
    Windows (unless NoDefaultCurrentDirectoryInExePath is set) and
    CreateProcess searches it too for a path-less name, so a cloned repo that
    ships `ruff.exe` at its root would otherwise be executed by a `den verify`
    run there. Handing subprocess an absolute path also stops CreateProcess
    from searching at all.
    """
    hit = shutil.which(name, path=_search_path())
    if hit is None:
        return None, None
    exe = Path(hit)
    if not exe.is_absolute():  # only reachable via the Windows curdir entry
        exe = Path.cwd() / exe
    if exe.resolve().is_relative_to(Path.cwd().resolve()):
        return None, f"refusing {name} resolved inside the workspace ({exe})"
    return str(exe), None


def _stage(label: str, cmd: list[str], counts: dict[str, int]) -> None:
    tool = cmd[0]
    exe, refusal = _resolve_tool(tool)
    if refusal:
        print(f"den verify: {refusal}")
        print(
            f"SKIP {label} ({tool} not run:"
            " remove the workspace copy or run den verify elsewhere)"
        )
        counts["skip"] += 1
        return
    if exe is None:
        print(f"SKIP {label} ({tool} not installed: uv tool install {tool})")
        counts["skip"] += 1
        return
    proc = subprocess.run(
        [exe, *cmd[1:]],
        capture_output=True,
        text=True,
        # ruff and ty emit UTF-8 (source snippets included); the locale codec
        # would raise or mangle on a Windows console page (cp932/cp1252).
        encoding="utf-8",
        errors="replace",
    )
    if proc.returncode == 0:
        print(f"PASS {label}")
        counts["pass"] += 1
        return
    counts["fail"] += 1
    print(f"FAIL {label}")
    lines = (proc.stdout + proc.stderr).splitlines()
    for line in lines[:_MAX_DETAIL_LINES]:
        print(f"  {line}")
    if len(lines) > _MAX_DETAIL_LINES:
        print(f"  ... (+{len(lines) - _MAX_DETAIL_LINES} more lines)")


def _usage() -> None:
    print(
        "usage: den verify <file.py...>\n"
        "\n"
        "Run format (ruff format --check), lint (ruff check), and typecheck\n"
        "(ty check) on each Python file given. Project config always wins:\n"
        "den only adds its defaults (missing-docstring checks) when no ruff\n"
        "config exists anywhere above a file. The `config:` lines show\n"
        "exactly which config file and environment each tool will use.\n"
        "Exit 0 = no failures, 1 = a failure or an unusable file, 2 = usage."
    )


def _reject(file: Path) -> str | None:
    """Why `file` cannot be verified, or None when it can."""
    if not file.is_file():
        return f"file not found: {file}"
    if file.suffix != ".py":
        return (
            "only Python files are supported"
            f" (got {file.suffix or 'no extension'});"
            " for other languages run the language's standard tools"
            " (the coding skill names them per language)"
        )
    return None


def _verify_file(file: Path, counts: dict[str, int]) -> None:
    cfg = _ruff_config(file)
    if cfg:
        path, kind = cfg
        print(f"config: ruff <- {kind} ({path.parent})")
        lint_cmd = ["ruff", "check", str(file)]
    else:
        print(
            "config: ruff <- none -> den defaults "
            f"(+{_DEN_DEFAULT_LINT[1]} missing-docstring checks)"
        )
        lint_cmd = ["ruff", "check", *_DEN_DEFAULT_LINT, str(file)]

    root = _project_root(file)
    print(f"config: ty   <- project root {root} (--project); {_venv_line(root)}")

    _stage("format", ["ruff", "format", "--check", str(file)], counts)
    _stage("lint", lint_cmd, counts)
    _stage("typecheck", ["ty", "check", "--project", str(root), str(file)], counts)


def main(argv: list[str] | None = None) -> int:
    # FAIL detail quotes the tool's own output, so any character can reach
    # stdout; a Windows console or pipe on a narrow code page must degrade
    # rather than raise UnicodeEncodeError over a diagnostic.
    reconfigure = getattr(sys.stdout, "reconfigure", None)
    if callable(reconfigure):
        with suppress(OSError, ValueError):
            reconfigure(errors="replace")
    args = argv if argv is not None else sys.argv[1:]
    if not args or args[0] in {"-h", "--help", "help"}:
        _usage()
        return 0
    files = [Path(a) for a in args]
    # Every argument is a file to verify. A single unusable argument is a
    # usage error (exit 2, as before); among several, an unusable one is
    # reported, counted as a failure, and the rest still run.
    rejected = {f: _reject(f) for f in files}
    if all(rejected.values()):
        for why in rejected.values():
            print(f"den verify: {why}", file=sys.stderr)
        return 2

    counts = {"pass": 0, "fail": 0, "skip": 0}
    for file in files:
        if len(files) > 1:
            print(f"== {file}")
        why = rejected[file]
        if why:
            print(f"den verify: {why}", file=sys.stderr)
            counts["fail"] += 1
            continue
        _verify_file(file, counts)

    scope = f" across {len(files)} files" if len(files) > 1 else ""
    print(
        f"summary: {counts['pass']} passed, {counts['fail']} failed, "
        f"{counts['skip']} skipped{scope}"
    )
    return 1 if counts["fail"] else 0
