"""The CI jobs that run pytest install, and import, what the suites skip without.

pytest.importorskip, like an import under `except ImportError`, turns a module
that CI does not install into skipped tests and a green run. That is how the
cheatsheet tests went unrun in CI: no job that runs pytest installed rich or
structlog. A skip mark that looks for a command with shutil.which does the
same: the tests job installed neither fd, sd, zsh nor ruff.
"""

import ast
import re
import sys
from pathlib import Path

import pytest
import yaml

_ROOT = Path(__file__).resolve().parents[2]
# Import name -> the distribution pip installs it from, where the two differ.
_DIST = {"yaml": "pyyaml"}
_IMPORT_ERRORS = {"ImportError", "ModuleNotFoundError"}
_PIP_INSTALL = re.compile(r"\bpip3? install\b(.*)")
_APT_INSTALL = re.compile(r"\bapt-get install\b(.*)")
_LINK = re.compile(r"\bln -s")
_IMPORT_CHECK = re.compile(r"""\bpython3? -c ["']import ([\w., ]+)["']""")
# The options whose value is a package that a launcher installs: in
# `uv run --with pytest pytest`, the first pytest is that package and the
# second the command. Written as one word, --with=pytest holds its own value.
_PACKAGE_OPTIONS = {"--with", "--with-editable"}
# Where one command ends and the next starts on the same line.
_SEPARATOR = re.compile(r"\s*(?:&&|\|\||;)\s*|\s+\|\s+")
# What an apt package puts on PATH, where that is not the package's name.
_APT_COMMANDS = {"fd-find": "fdfind", "ripgrep": "rg"}
# The commands tests/den's skip marks look for that the ubuntu runner image
# does not ship: the one-liner tests run fd, rg and sd, the dev image's
# zshenv tests zsh, and test_verify's real-ruff test ruff. A command that a
# new skip mark looks for goes here, and into the tests job.
_SKIP_COMMANDS = {"fd", "rg", "ruff", "sd", "zsh"}


def _dist(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def _called_name(call: ast.Call) -> str:
    func = call.func
    if isinstance(func, ast.Attribute):
        return func.attr
    return func.id if isinstance(func, ast.Name) else ""


def _catches_import_error(node: ast.Try) -> bool:
    return any(
        isinstance(name, ast.Name) and name.id in _IMPORT_ERRORS
        for handler in node.handlers
        if handler.type is not None
        for name in ast.walk(handler.type)
    )


def _imports_in(body: list[ast.stmt]) -> set[str]:
    found: set[str] = set()
    for stmt in body:
        if isinstance(stmt, ast.Import):
            found.update(alias.name for alias in stmt.names)
        elif isinstance(stmt, ast.ImportFrom) and stmt.module and not stmt.level:
            found.add(stmt.module)
    return found


def _optional_imports(tree: ast.Module) -> set[str]:
    """What the code imports through importorskip or under except ImportError."""
    found: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and _called_name(node) == "importorskip":
            if node.args and isinstance(node.args[0], ast.Constant):
                found.add(str(node.args[0].value))
        elif isinstance(node, ast.Try) and _catches_import_error(node):
            found |= _imports_in(node.body)
    return found


def _skipped_without(suite: Path) -> set[str]:
    """The third-party modules that some test under <suite> is skipped without."""
    found: set[str] = set()
    files = [suite] if suite.is_file() else sorted(suite.rglob("*.py"))
    for path in files:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        found |= {name.split(".")[0] for name in _optional_imports(tree)}
    # The standard library has nothing to install: tests/agents skips without
    # "resource", which only the POSIX builds of Python have.
    return found - set(sys.stdlib_module_names)


def _commands(job: dict) -> list[str]:
    """A job's `run` commands: continuations joined, comments dropped, and a
    line split where &&, ||, ; or | starts another command."""
    lines = []
    for step in job.get("steps", []):
        run = re.sub(r"[\\`]\n", " ", step.get("run", ""))  # bash \, pwsh `
        lines += [line.split(" #")[0] for line in run.splitlines()]
    return [
        command
        for line in lines
        if not line.lstrip().startswith("#")
        for command in _SEPARATOR.split(line)
        if command.strip()
    ]


def _words(text: str) -> list[str]:
    """<text>'s words without the shell's quotes around them: a quoted
    "rich>=13", the shell-safe way to write >=, still installs rich."""
    return [word.strip("'\"") for word in text.split()]


def _args(text: str) -> list[str]:
    return [word for word in _words(text) if not word.startswith("-")]


def _pytest_targets(command: str) -> list[str] | None:
    """The paths <command> runs pytest on, or None if it runs no pytest.

    pytest runs as a module (`python -m pytest`) or as a command, bare or after
    a launcher and its flags (`uv run --frozen pytest`, `xvfb-run -a pytest`).
    So the first word pytest counts as the run, unless it follows --with or
    --with-editable, whose value is a package. After another option that takes
    a package (`uv run -w pytest pytest`, `uvx --from pytest pytest`), that
    package counts as the run instead; the command's own pytest then names no
    path and is dropped, like the value of an option such as `-k`. In a pip
    install or a `python -c "import ..."`, pytest is a package too.
    """
    if _PIP_INSTALL.search(command) or _IMPORT_CHECK.search(command):
        return None
    words = _words(command)
    for i, word in enumerate(words):
        before = words[i - 1] if i else ""
        if word == "pytest" and before not in _PACKAGE_OPTIONS:
            # A word that names no test file or directory is an option's value
            # (`-p no:cacheprovider`, `-k cheats`): pytest refuses a path that
            # does not exist. Given no path, pytest collects the checkout: its
            # tests are in tests/.
            paths = [
                w for w in words[i + 1 :] if not w.startswith("-") and _is_test_path(w)
            ]
            return paths or ["tests"]
    return None


def _is_test_path(word: str) -> bool:
    """Whether <word> names a test directory, a .py file or a node id in one."""
    path = _ROOT / word.split("::")[0]
    return path.is_dir() or (path.suffix == ".py" and path.is_file())


def _scan_job(job: dict) -> dict[str, set[str]] | None:
    """For a job that runs pytest: the modules its suites are skipped without,
    and what it pip-installs, puts on PATH (apt-get install, ln -s) and imports
    with `python -c` before its first pytest command. None for other jobs."""
    needed: set[str] = set()
    installed: set[str] = set()
    on_path: set[str] = set()
    imported: set[str] = set()
    ran_pytest = False
    for command in _commands(job):
        if (targets := _pytest_targets(command)) is not None:
            ran_pytest = True
            for target in targets:  # a dir, a file or a node id
                needed |= _skipped_without(_ROOT / target.split("::")[0])
        elif ran_pytest:
            continue
        elif m := _PIP_INSTALL.search(command):
            args = _args(m.group(1))
            installed |= {_dist(re.split(r"[\[<>=!~;@]", a)[0]) for a in args}
        elif m := _APT_INSTALL.search(command):
            on_path |= {_APT_COMMANDS.get(a, a) for a in _args(m.group(1))}
        elif _LINK.search(command):
            on_path.add(_words(command)[-1].rsplit("/", 1)[-1])
        elif m := _IMPORT_CHECK.search(command):
            imported |= {n.strip().split(".")[0] for n in m.group(1).split(",")}
    if not ran_pytest:
        return None
    return {
        "needed": needed,
        "installed": installed,
        "on_path": on_path,
        "imported": imported,
    }


def _pytest_jobs() -> dict[str, dict[str, set[str]]]:
    """_scan_job for every workflow job that runs pytest."""
    jobs = {}
    for workflow in sorted((_ROOT / ".github" / "workflows").glob("*.yml")):
        parsed = yaml.safe_load(workflow.read_text(encoding="utf-8"))
        for job_id, job in parsed["jobs"].items():
            if (scan := _scan_job(job)) is not None:
                jobs[f"{workflow.name}:{job_id}"] = scan
    return jobs


def _job(*runs: str) -> dict:
    return {"steps": [{"run": run} for run in runs]}


def test_the_scan_finds_what_the_suites_skip_without():
    # Finding nothing would pass the two checks below vacuously, the way the
    # skipped cheatsheet tests passed every CI run.
    assert {"rich", "structlog"} <= _skipped_without(_ROOT / "tests" / "den")
    assert "yaml" in _skipped_without(_ROOT / "tests" / "agents")
    assert {"ci.yml:tests", "ci.yml:windows"} <= _pytest_jobs().keys()


@pytest.mark.parametrize(
    "run",
    [
        "python3 -m pytest tests/den",
        "uv run --with pytest pytest tests/den",
        "uv run --with=pytest pytest tests/den",
        "uv run --frozen pytest tests/den",
        "xvfb-run -a pytest tests/den",
        "pytest -q tests/den",
        "python -m pytest 'tests/den'",
        "pip install pytest && python -m pytest tests/den",
        "uv run -w pytest pytest",
        "uvx --from pytest pytest",
        "python -m pytest -p no:cacheprovider",
        'python -m pytest -m "not slow"',
    ],
)
def test_the_scan_reads_each_way_of_running_pytest(run):
    # A job whose pytest command the scan did not read went unchecked: it
    # passed with neither rich nor structlog installed.
    scan = _scan_job(_job(run))
    assert scan is not None
    assert {"rich", "structlog"} <= scan["needed"]


@pytest.mark.parametrize(
    "run",
    [
        "pip install pytest pyyaml",
        'python -c "import yaml, pytest"',
        "uv run --with pytest python -V",
        "uv run --with-editable pytest python -V",
    ],
)
def test_the_scan_does_not_take_installing_pytest_for_running_it(run):
    assert _scan_job(_job(run)) is None


def test_quoted_pip_requirements_count_as_installed():
    # With the quotes left on, "rich>=13" read as a distribution named '"rich'.
    scan = _scan_job(
        _job("""pip install "rich>=13" 'structlog<27'""", "python -m pytest tests/den")
    )
    assert scan is not None
    assert {"rich", "structlog"} <= scan["installed"]


def test_pytest_jobs_install_what_their_suites_skip_without():
    missing = {}
    for job_id, job in _pytest_jobs().items():
        wanted = {_dist(_DIST.get(name, name)) for name in job["needed"]}
        if names := sorted(wanted - job["installed"]):
            missing[job_id] = names
    assert not missing, "pip install these in the job, before its pytest step"


def test_pytest_jobs_import_those_modules_before_pytest():
    # importorskip also turns a failed install, or a release that breaks on
    # import, into skips; a `python -c "import ..."` step fails the job instead.
    unchecked = {}
    for job_id, job in _pytest_jobs().items():
        if names := sorted(job["needed"] - job["imported"]):
            unchecked[job_id] = names
    assert not unchecked, 'import these in the job with python -c "import ..." first'


def test_the_tests_job_installs_the_commands_tests_den_skips_without():
    # Without them, 11 tests skipped in every run of the tests job and it
    # stayed green. ruff counts from pip, the rest from apt-get or ln -s.
    job = _pytest_jobs()["ci.yml:tests"]
    missing = sorted(_SKIP_COMMANDS - job["on_path"] - job["installed"])
    assert not missing, "install these in the tests job, before its pytest steps"
