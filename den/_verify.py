"""den verify - format / lint / typecheck Python files, config-faithfully.

Hidden runtime command (like hook/memory): agents call it after writing code.
The design rule is "discover like the tools do, make the discovery visible,
never override":

- The anchor is the FILE's directory, exactly like ruff: a config above the
  file wins whatever the cwd.
- ruff: the nearest-wins discovery (.ruff.toml > ruff.toml > pyproject.toml
  with [tool.ruff]; no merging) is re-walked here ONLY to report which config
  will win; ruff itself runs with no config flags, so its real resolution is
  never overridden. With no config above the file, ruff falls back to the
  project config found from the working directory, then to the user-level
  one (~/.config/ruff/ruff.toml); that is asked of ruff itself
  (`--show-settings`) and reported. Only when ruff names no config at all do
  den's defaults apply (missing public docstrings: D101, D102, D103).
- ty: import resolution needs a real environment, so the project root is
  passed explicitly (--project <root>, root = nearest pyproject.toml/ty.toml
  ancestor) and the venv line reports what ty will see.
- the tools themselves are resolved through PATH only and run by absolute
  path (den._exe, shared with every other command that starts a tool); one
  that resolves to the working directory itself is refused, never executed.
  On Windows shutil.which prepends the current directory (unless
  NoDefaultCurrentDirectoryInExePath is set) and CreateProcess searches it
  too for a path-less name, so a cloned repo shipping `ruff.exe` at its root
  would otherwise run when `den verify` is invoked there.

Output is line-oriented for model consumption: one `config:` line per tool,
then PASS / FAIL / SKIP per stage. FAIL detail is capped; SKIP always names
the next action. Exit 0 = no failures, 1 = failures, 2 = usage. Tool output
is decoded as UTF-8 (what ruff and ty emit, source snippets included), never
the locale codec. Each stage runs once for all the files that share a
project and den's lint settings, not once per file; a file the batch flags
is re-run alone, so every result and FAIL detail is still per file.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from contextlib import suppress
from pathlib import Path

from ._exe import resolve_tool

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


def _settings_path(show_settings: str) -> str | None:
    """The file named by the `Settings path:` line of `ruff check
    --show-settings` output (absent when ruff uses no config file), unquoted:
    ruff prints it Debug-formatted, so a Windows path has its backslashes
    doubled."""
    for line in show_settings.splitlines():
        if line.startswith("Settings path:"):
            raw = line.removeprefix("Settings path:").strip()
            if len(raw) >= 2 and raw[0] == raw[-1] == '"':
                raw = re.sub(r"\\(.)", r"\1", raw[1:-1])
            return raw or None
    return None


def _ruff_fallback_config(file: Path) -> Path | None:
    """The config ruff itself uses for `file` when none is above it, or None.

    ruff then takes the project config found from the working directory, and
    failing that the user-level one. That depends on the cwd and the
    environment rather than on the file, so it is asked of ruff (run exactly
    as the lint stage will run it) instead of re-derived. None when ruff
    names no config, or is missing or refused (its stages report that)."""
    exe, _refusal = resolve_tool("ruff")
    if exe is None:
        return None
    try:
        proc = subprocess.run(
            [exe, "check", "--show-settings", str(file)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    found = _settings_path(proc.stdout) if proc.returncode == 0 else None
    return Path(found) if found else None


def _ruff_config_line(file: Path, fallback: dict[str, Path | None]) -> tuple[str, bool]:
    """(the `config: ruff` line, whether den's defaults apply) for `file`.

    `fallback` memoizes ruff's answer for files with no config above them:
    it is the same for all of them in one run."""
    cfg = _ruff_config(file)
    if cfg:
        path, kind = cfg
        return f"config: ruff <- {kind} ({path.parent})", False
    if "ruff" not in fallback:
        fallback["ruff"] = _ruff_fallback_config(file)
    found = fallback["ruff"]
    if found is not None:
        kind = (
            "pyproject.toml [tool.ruff]"
            if found.name == "pyproject.toml"
            else found.name
        )
        return (
            f"config: ruff <- {kind} ({found.parent}; ruff's fallback,"
            " no config above the file)",
            False,
        )
    return (
        "config: ruff <- none -> den defaults "
        f"(+{_DEN_DEFAULT_LINT[1]} missing-docstring checks)",
        True,
    )


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


# One stage's result for one file: ("pass" | "fail" | "skip", report lines).
_Outcome = tuple[str, list[str]]


def _run(exe: str, args: list[str]) -> tuple[int, list[str]]:
    proc = subprocess.run(
        [exe, *args],
        capture_output=True,
        text=True,
        # ruff and ty emit UTF-8 (source snippets included); the locale codec
        # would raise or mangle on a Windows console page (cp932/cp1252).
        encoding="utf-8",
        errors="replace",
    )
    return proc.returncode, (proc.stdout + proc.stderr).splitlines()


def _failed(label: str, lines: list[str]) -> _Outcome:
    report = [f"FAIL {label}", *(f"  {line}" for line in lines[:_MAX_DETAIL_LINES])]
    if len(lines) > _MAX_DETAIL_LINES:
        report.append(f"  ... (+{len(lines) - _MAX_DETAIL_LINES} more lines)")
    return "fail", report


def _stage(
    label: str, tool: str, args: list[str], files: list[Path]
) -> dict[Path, _Outcome]:
    """Run `tool *args <files>` for a group of files; each file's outcome.

    One process for the whole group, instead of one per file. When it passes,
    every file passes. On exit 1 (diagnostics found, for ruff and ty alike) a
    file whose name the output never mentions had no diagnostic and passes;
    each file it does mention is re-run alone, so its PASS/FAIL and FAIL
    detail are exactly what a per-file run reports. Any other failure (exit
    2: a config or usage error nothing ties to one file) re-runs every file
    alone."""
    exe, refusal = resolve_tool(tool)
    if refusal:
        skip = f"SKIP {label} ({tool} not run:"
        skip += " remove the workspace copy or run den verify elsewhere)"
        return {f: ("skip", [f"den verify: {refusal}", skip]) for f in files}
    if exe is None:
        skip = f"SKIP {label} ({tool} not installed: uv tool install {tool})"
        return {f: ("skip", [skip]) for f in files}
    rc, lines = _run(exe, [*args, *map(str, files)])
    if rc == 0:
        return {f: ("pass", [f"PASS {label}"]) for f in files}
    if len(files) == 1:
        return {files[0]: _failed(label, lines)}
    output = "\n".join(lines).lower()
    suspects = [f for f in files if rc != 1 or f.name.lower() in output]
    outcomes: dict[Path, _Outcome] = {f: ("pass", [f"PASS {label}"]) for f in files}
    for f in suspects or files:
        rc, lines = _run(exe, [*args, str(f)])
        if rc != 0:
            outcomes[f] = _failed(label, lines)
    return outcomes


def _usage() -> None:
    print(
        "usage: den verify <file.py...>\n"
        "\n"
        "Run format (ruff format --check), lint (ruff check), and typecheck\n"
        "(ty check) on each Python file given. Project config always wins:\n"
        "den only adds its defaults (missing-docstring checks) when ruff\n"
        "finds no config for a file (none above it, none from the working\n"
        "directory, no user-level one). The `config:` lines show exactly\n"
        "which config file and environment each tool will use.\n"
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


def _verify_all(
    files: list[Path],
) -> tuple[dict[Path, list[str]], dict[Path, list[_Outcome]]]:
    """(the config lines, the stage outcomes) of each usable file.

    Files are grouped by whether den's lint defaults apply and by ty's
    project root, and each stage runs once per group (see _stage): ruff
    resolves each file's own config itself, and ty checks one project."""
    fallback: dict[str, Path | None] = {}
    configs: dict[Path, list[str]] = {}
    groups: dict[tuple[bool, Path], list[Path]] = {}
    for file in dict.fromkeys(files):
        ruff_line, defaults = _ruff_config_line(file, fallback)
        root = _project_root(file)
        configs[file] = [
            ruff_line,
            f"config: ty   <- project root {root} (--project); {_venv_line(root)}",
        ]
        groups.setdefault((defaults, root), []).append(file)
    outcomes: dict[Path, list[_Outcome]] = {f: [] for f in configs}
    for (defaults, root), group in groups.items():
        lint = ["check", *(_DEN_DEFAULT_LINT if defaults else ())]
        for label, tool, args in (
            ("format", "ruff", ["format", "--check"]),
            ("lint", "ruff", lint),
            ("typecheck", "ty", ["check", "--project", str(root)]),
        ):
            for file, outcome in _stage(label, tool, args, group).items():
                outcomes[file].append(outcome)
    return configs, outcomes


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

    configs, outcomes = _verify_all([f for f in files if not rejected[f]])
    counts = {"pass": 0, "fail": 0, "skip": 0}
    for file in files:
        if len(files) > 1:
            print(f"== {file}")
        why = rejected[file]
        if why:
            print(f"den verify: {why}", file=sys.stderr)
            counts["fail"] += 1
            continue
        for line in configs[file]:
            print(line)
        for status, report in outcomes[file]:
            for line in report:
                print(line)
            counts[status] += 1

    scope = f" across {len(files)} files" if len(files) > 1 else ""
    print(
        f"summary: {counts['pass']} passed, {counts['fail']} failed, "
        f"{counts['skip']} skipped{scope}"
    )
    return 1 if counts["fail"] else 0
