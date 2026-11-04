"""renovate.json and the pins it keeps current in .github/workflows.

Renovate (the Mend-hosted GitHub App) proposes every version update as a pull
request. tests/den/test_docker_image.py checks the Dockerfile's pins; these
tests check the configuration and the workflows' `uses:` pins.
"""

import json
import re
from collections.abc import Iterator
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "renovate.json"
WORKFLOWS = ROOT / ".github" / "workflows"
_SHA = re.compile(r"[0-9a-f]{40}")
_VERSION_COMMENT = re.compile(r"v\d+\.\d+\.\d+")


def _config() -> dict:
    return json.loads(CONFIG.read_text(encoding="utf-8"))


def test_renovate_waits_seven_days_for_a_release():
    # A release that is withdrawn or found broken in its first week never
    # becomes a pull request, and an update whose registry gives no publish
    # date is held rather than proposed at once.
    config = _config()
    assert config["minimumReleaseAge"] == "7 days"
    assert config["minimumReleaseAgeBehaviour"] == "timestamp-required"


def test_renovate_merges_nothing_on_its_own():
    config = _config()
    assert config["automerge"] is False
    for key in ("automerge", "platformAutomerge"):
        for rule in config.get("packageRules", []):
            assert rule.get(key) is not True, rule
    assert not any("automerge" in preset.lower() for preset in config["extends"])


def test_renovate_uses_the_presets_for_the_dockerfile_and_the_workflows():
    # The Dockerfile's "# renovate:" comments are written for
    # customManagers:dockerfileVersions, and a workflow's *_VERSION variable
    # for customManagers:githubActionsVersions; docker:pinDigests keeps the
    # base and syntax images pinned by digest, and
    # helpers:pinGitHubActionDigestsToSemver keeps each action pinned to a
    # commit SHA with its exact version in a comment.
    extends = set(_config()["extends"])
    assert {
        "config:recommended",
        "customManagers:dockerfileVersions",
        "customManagers:githubActionsVersions",
        "docker:pinDigests",
        "helpers:pinGitHubActionDigestsToSemver",
    } <= extends


def test_renovate_leaves_the_python_dependencies_alone():
    # Only the Dockerfile, the workflows' actions and the "# renovate:"
    # comments: no Python manager (pep621, pip_requirements, uv, ...), and
    # not the Python versions CI runs (setup-python's python-version).
    config = _config()
    assert set(config["enabledManagers"]) == {
        "dockerfile",
        "github-actions",
        "custom.regex",
    }
    rule = next(
        rule
        for rule in config["packageRules"]
        if rule.get("matchDepTypes") == ["uses-with"]
    )
    assert rule["matchManagers"] == ["github-actions"]
    assert rule["enabled"] is False


def _uses_in(node: object) -> Iterator[str]:
    """Every `uses:` value in a parsed workflow, steps and jobs alike."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "uses" and isinstance(value, str):
                yield value
            else:
                yield from _uses_in(value)
    elif isinstance(node, list):
        for item in node:
            yield from _uses_in(item)


def test_every_workflow_action_is_pinned_to_a_commit_with_its_version():
    # A tag can be moved to other code; a commit SHA cannot. Renovate reads
    # the version in the comment to find the next release.
    workflows = sorted(WORKFLOWS.glob("*.yml"))
    assert workflows
    for path in workflows:
        text = path.read_text(encoding="utf-8")
        lines = list(
            re.finditer(
                r"^\s*(?:-\s+)?uses:\s*(\S+)(?:\s+#\s*(\S+))?\s*$",
                text,
                flags=re.MULTILINE,
            )
        )
        # The line scan sees every `uses:` that YAML does.
        assert sorted(m.group(1) for m in lines) == sorted(
            _uses_in(yaml.safe_load(text))
        ), path.name
        for match in lines:
            ref, comment = match.group(1), match.group(2)
            if ref.startswith("./"):
                continue
            _, _, sha = ref.partition("@")
            assert _SHA.fullmatch(sha), f"{path.name}: {match.group(0).strip()}"
            assert comment and _VERSION_COMMENT.fullmatch(comment), (
                f"{path.name}: {match.group(0).strip()}"
            )
