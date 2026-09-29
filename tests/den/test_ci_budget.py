"""The shell-tests CI job's time budget covers an uncached image build."""

import re
from pathlib import Path

import yaml

_ROOT = Path(__file__).resolve().parents[2]
# The slowest uncached build of tests/shell/Dockerfile on record, 39m8s (see
# the comment on the build step in ci.yml).
_SLOWEST_COLD_BUILD_MINUTES = 40


def _shell_tests_job() -> dict:
    ci = (_ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
    return yaml.safe_load(ci)["jobs"]["shell-tests"]


def test_shell_tests_budget_covers_a_cold_build():
    # A job cancelled mid-build exports no layer cache, so a budget below a
    # cold build fails that run and leaves the next one cold as well.
    job = _shell_tests_job()
    steps = {step.get("name"): step for step in job["steps"]}
    build = steps["Build the shell test image"].get("timeout-minutes", 0)
    run = steps["Run the shell tests"].get("timeout-minutes", 0)
    assert build >= _SLOWEST_COLD_BUILD_MINUTES
    assert run > 0
    assert job["timeout-minutes"] >= build + run


def test_shell_test_image_base_is_pinned_by_digest():
    # A floating tag moves when Ubuntu republishes it, and every cached layer
    # goes cold with it.
    dockerfile = (_ROOT / "tests" / "shell" / "Dockerfile").read_text(encoding="utf-8")
    froms = [ln for ln in dockerfile.splitlines() if ln.startswith("FROM ")]
    assert froms
    for line in froms:
        assert re.search(r"@sha256:[0-9a-f]{64}(\s|$)", line), line
