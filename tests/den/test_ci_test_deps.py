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

import yaml

_ROOT = Path(__file__).resolve().parents[2]
# Import name -> the distribution pip installs it from, where the two differ.
_DIST = {"yaml": "pyyaml"}
_IMPORT_ERRORS = {"ImportError", "ModuleNotFoundError"}
_PYTEST = re.compile(r"\bpython3? -m pytest\b(.*)")
_PIP_INSTALL = re.compile(r"\bpip install\b(.*)")
_APT_INSTALL = re.compile(r"\bapt-get install\b(.*)")
_LINK = re.compile(r"\bln -s\S* .* (\S+)$")  # group 1: the link
_IMPORT_CHECK = re.compile(r"""\bpython3? -c ["']import ([\w., ]+)["']""")
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
    """A job's `run` lines, with continuations joined and comments dropped."""
    lines = []
    for step in job.get("steps", []):
        run = re.sub(r"[\\`]\n", " ", step.get("run", ""))  # bash \, pwsh `
        lines += [line.split(" #")[0] for line in run.splitlines()]
    return [ln for ln in lines if ln.strip() and not ln.lstrip().startswith("#")]


def _pytest_jobs() -> dict[str, dict[str, set[str]]]:
    """Per workflow job that runs pytest: the modules its suites are skipped
    without, and what it pip-installs, puts on PATH (apt-get install, ln -s)
    and imports with `python -c` before its first pytest command."""
    jobs = {}
    for workflow in sorted((_ROOT / ".github" / "workflows").glob("*.yml")):
        parsed = yaml.safe_load(workflow.read_text(encoding="utf-8"))
        for job_id, job in parsed["jobs"].items():
            needed: set[str] = set()
            installed: set[str] = set()
            on_path: set[str] = set()
            imported: set[str] = set()
            ran_pytest = False
            for line in _commands(job):
                if m := _PYTEST.search(line):
                    ran_pytest = True
                    args = [a for a in m.group(1).split() if not a.startswith("-")]
                    for arg in args or ["tests"]:  # a dir, a file or a node id
                        needed |= _skipped_without(_ROOT / arg.split("::")[0])
                elif ran_pytest:
                    continue
                elif m := _PIP_INSTALL.search(line):
                    args = [a for a in m.group(1).split() if not a.startswith("-")]
                    installed |= {_dist(re.split(r"[\[<>=!~;@]", a)[0]) for a in args}
                elif m := _APT_INSTALL.search(line):
                    args = [a for a in m.group(1).split() if not a.startswith("-")]
                    on_path |= {_APT_COMMANDS.get(a, a) for a in args}
                elif m := _LINK.search(line):
                    on_path.add(m.group(1).strip("'\"").rsplit("/", 1)[-1])
                elif m := _IMPORT_CHECK.search(line):
                    imported |= {n.strip().split(".")[0] for n in m.group(1).split(",")}
            if ran_pytest:
                jobs[f"{workflow.name}:{job_id}"] = {
                    "needed": needed,
                    "installed": installed,
                    "on_path": on_path,
                    "imported": imported,
                }
    return jobs


def test_the_scan_finds_what_the_suites_skip_without():
    # Finding nothing would pass the two checks below vacuously, the way the
    # skipped cheatsheet tests passed every CI run.
    assert {"rich", "structlog"} <= _skipped_without(_ROOT / "tests" / "den")
    assert "yaml" in _skipped_without(_ROOT / "tests" / "agents")
    assert {"ci.yml:tests", "ci.yml:windows"} <= _pytest_jobs().keys()


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
