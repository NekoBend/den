"""cheatsheets/python/kubeflow: the schedules a reader copies must mean what they say.

KFP v1 parses recurring-run schedules with robfig/cron, whose parser reads six
fields with SECONDS first. A 5-field crontab line such as "0 2 * * *" is
therefore second=0 minute=2, and fires at minute 2 of every hour. kfp is not
installed here, so the sheet is inspected with ast rather than imported.
"""

import ast
import re
from pathlib import Path

PIPELINE = (
    Path(__file__).resolve().parents[2]
    / "cheatsheets"
    / "python"
    / "kubeflow"
    / "v1"
    / "pipeline.py"
)


def _create_recurring_run() -> ast.FunctionDef:
    tree = ast.parse(PIPELINE.read_text(encoding="utf-8"))
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == "create_recurring_run":
            return node
    raise AssertionError("create_recurring_run is missing from pipeline.py")


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
