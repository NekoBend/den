"""Every skill's SKILL.md frontmatter must parse as STRICT YAML.

A `: ` (colon-space) in an unquoted description once silently broke the `coding`
skill in cline (strict YAML parser dropped it) while Claude Code's lenient parser
accepted it, so the skill was missing only in some tools. This guards the whole
class: each frontmatter must strict-parse to a mapping with name == dir name and
a non-empty description.
"""

from pathlib import Path

import pytest

yaml = pytest.importorskip("yaml")

_SKILLS = sorted((Path(__file__).resolve().parents[3] / "skills").glob("*/SKILL.md"))


def _frontmatter(text: str) -> str:
    assert text.startswith("---"), "SKILL.md must start with a --- frontmatter fence"
    parts = text.split("---", 2)
    assert len(parts) >= 3, "SKILL.md frontmatter must be closed with a --- fence"
    return parts[1]


def test_there_are_skills():
    assert _SKILLS, "no skills/*/SKILL.md found"


@pytest.mark.parametrize("skill", _SKILLS, ids=lambda p: p.parent.name)
def test_skill_frontmatter_is_strict_yaml(skill):
    name = skill.parent.name
    data = yaml.safe_load(_frontmatter(skill.read_text(encoding="utf-8")))
    assert isinstance(data, dict), f"{name}: frontmatter did not parse to a mapping"
    assert data.get("name") == name, (
        f"{name}: frontmatter `name` must equal the directory name (got {data.get('name')!r})"
    )
    desc = data.get("description")
    assert isinstance(desc, str) and desc.strip(), (
        f"{name}: frontmatter needs a non-empty `description`"
    )
