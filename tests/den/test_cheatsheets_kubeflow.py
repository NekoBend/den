"""cheatsheets/python/kubeflow: the schedules a reader copies must mean what they say.

KFP v1 parses recurring-run schedules with robfig/cron, whose parser reads six
fields with SECONDS first. A 5-field crontab line such as "0 2 * * *" is
therefore second=0 minute=2, and fires at minute 2 of every hour. kfp is not
installed here, so the sheet is inspected with ast rather than imported; a
component function from a docstring example runs on its own.
"""

import ast
import importlib.util
import os
import re
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

PIPELINE = (
    Path(__file__).resolve().parents[2]
    / "cheatsheets"
    / "python"
    / "kubeflow"
    / "v1"
    / "pipeline.py"
)


def _function(name: str) -> ast.FunctionDef:
    tree = ast.parse(PIPELINE.read_text(encoding="utf-8"))
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    raise AssertionError(f"{name} is missing from pipeline.py")


def _create_recurring_run() -> ast.FunctionDef:
    return _function("create_recurring_run")


def test_recurring_run_default_cron_has_six_fields():
    func = _create_recurring_run()
    names = [arg.arg for arg in func.args.args]
    with_default = names[len(names) - len(func.args.defaults) :]
    defaults = dict(zip(with_default, func.args.defaults, strict=True))
    default = defaults["cron_expression"]
    assert isinstance(default, ast.Constant)
    assert len(default.value.split()) == 6, default.value


def test_recurring_run_docstring_examples_have_six_fields():
    doc = ast.get_docstring(_create_recurring_run()) or ""
    examples = re.findall(r'cron_expression="([^"]+)"', doc)
    assert examples, "the docstring should show a cron_expression example"
    for example in examples:
        assert len(example.split()) == 6, example
    assert "standard 5-field" not in doc


def _subprocess_runs(text: str) -> list[str]:
    """Every ``subprocess.run(...)`` call written in ``text``, brackets balanced."""
    calls = []
    for match in re.finditer(r"subprocess\.run\(", text):
        depth = 0
        for end in range(match.end() - 1, len(text)):
            depth += {"(": 1, ")": -1}.get(text[end], 0)
            if depth == 0:
                calls.append(text[match.start() : end + 1])
                break
    return calls


def test_examples_check_the_exit_status_of_what_they_run():
    # subprocess.run without check=True returns a failed run instead of
    # raising, so a component built from such a function reports success.
    calls = [
        call
        for sheet in sorted(PIPELINE.parent.glob("*.py"))
        for call in _subprocess_runs(sheet.read_text(encoding="utf-8"))
    ]
    assert len(calls) == 4, calls
    for call in calls:
        assert "check=True" in call, call


@pytest.mark.skipif(sys.platform == "win32", reason="puts a python symlink on PATH")
def test_train_example_fails_when_train_py_fails(tmp_path, monkeypatch):
    # compile_pipeline's train() returned "done" after train.py exited 7, so a
    # component made from it with create_component_from_func succeeded and
    # the steps after it ran.
    doc = ast.get_docstring(_function("compile_pipeline")) or ""
    example = ast.parse(textwrap.dedent(doc.split("Example::", 1)[1]))
    (train,) = [
        node
        for node in example.body
        if isinstance(node, ast.FunctionDef) and node.name == "train"
    ]
    module_path = tmp_path / "train_example.py"
    module_path.write_text(ast.unparse(train) + "\n", encoding="utf-8")
    spec = importlib.util.spec_from_file_location("train_example", module_path)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "python").symlink_to(sys.executable)
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("PYTHONDONTWRITEBYTECODE", "1")  # no .pyc beside the interpreter
    monkeypatch.chdir(tmp_path)
    (tmp_path / "train.py").write_text("raise SystemExit(7)\n", encoding="utf-8")
    with pytest.raises(subprocess.CalledProcessError) as failure:
        module.train(epochs=1)
    assert failure.value.returncode == 7
