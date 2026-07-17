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

Output is line-oriented for model consumption: one `config:` line per tool,
then PASS / FAIL / SKIP per stage. FAIL detail is capped; SKIP always names
the next action. Exit 0 = no failures, 1 = failures, 2 = usage.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
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
    return "venv: none found (third-party imports may be unresolvable; run `uv sync` or set VIRTUAL_ENV)"


def _stage(label: str, cmd: list[str], counts: dict[str, int]) -> None:
    if not shutil.which(cmd[0]):
        print(f"SKIP {label} ({cmd[0]} not installed: uv tool install {cmd[0]})")
        counts["skip"] += 1
        return
    proc = subprocess.run(cmd, capture_output=True, text=True)
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
        "usage: den verify <file.py>\n"
        "\n"
        "Run format (ruff format --check), lint (ruff check), and typecheck\n"
        "(ty check) on one Python file. Project config always wins: den only\n"
        "adds its defaults (missing-docstring checks) when no ruff config\n"
        "exists anywhere above the file. The `config:` lines show exactly\n"
        "which config file and environment each tool will use."
    )


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if not args or args[0] in ("-h", "--help", "help"):
        _usage()
        return 0
    if len(args) != 1:
        print("den verify: expected exactly one file", file=sys.stderr)
        return 2
    file = Path(args[0])
    if not file.is_file():
        print(f"den verify: file not found: {file}", file=sys.stderr)
        return 2
    if file.suffix != ".py":
        print(
            f"den verify: only Python files are supported (got {file.suffix or 'no extension'});"
            " for other languages use the coding skill's run-checks.sh",
            file=sys.stderr,
        )
        return 2

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

    counts = {"pass": 0, "fail": 0, "skip": 0}
    _stage("format", ["ruff", "format", "--check", str(file)], counts)
    _stage("lint", lint_cmd, counts)
    _stage("typecheck", ["ty", "check", "--project", str(root), str(file)], counts)

    print(
        f"summary: {counts['pass']} passed, {counts['fail']} failed, "
        f"{counts['skip']} skipped"
    )
    return 1 if counts["fail"] else 0
