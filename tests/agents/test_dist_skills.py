"""agents/dist/skills/ holds den-free copies of the skills, generated from
agents/src/ by den/_portable.py: den CLI mentions substituted away through
agents/src/no-den-cli.toml, shared/ resources bundled per skill, shared/
references relative to the skill. These tests keep the committed copy honest."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from den import _portable
from den._install import _skill_names
from den._install import main as install_main

ROOT = Path(__file__).resolve().parents[2]
DEN_CLI = re.compile(r"\bden (verify|board|hook|memory|install)\b")
SHARED_REF = re.compile(r"(?<![\w/.])shared/(reference|scripts)/([A-Za-z0-9_./-]+)")


def test_committed_copy_is_current():
    assert _portable.main(["--check"]) == 0


def test_every_skill_has_a_den_free_copy(tmp_path):
    _portable.build_tree(tmp_path)
    built = {p.name for p in tmp_path.iterdir() if p.is_dir()}
    assert built == set(_skill_names())


def test_skills_never_mention_den_cli(tmp_path):
    _portable.build_tree(tmp_path)
    for md in tmp_path.rglob("*.md"):
        if md.parent == tmp_path:
            continue  # the top-level README explains the substitutions by name
        hit = DEN_CLI.search(md.read_text(encoding="utf-8"))
        assert hit is None, f"{md.relative_to(tmp_path)}: {hit.group(0)!r}"


def test_shared_refs_resolve_inside_each_skill(tmp_path):
    _portable.build_tree(tmp_path)
    for skill in (p for p in tmp_path.iterdir() if p.is_dir()):
        for md in skill.rglob("*.md"):
            for m in SHARED_REF.finditer(md.read_text(encoding="utf-8")):
                target = skill / "shared" / m.group(1) / m.group(2).rstrip(".")
                assert target.exists(), f"{md.relative_to(tmp_path)}: {m.group(0)}"


def test_anchor_drift_fails_the_build(monkeypatch):
    monkeypatch.setattr(
        _portable, "table", lambda: {"coding": [{"from": "NOT IN THE SKILL", "to": ""}]}
    )
    with pytest.raises(ValueError, match="occurs 0 times"):
        _portable.strip_den_cli("coding", "some skill text")


def test_install_flag_applies_the_table(tmp_path):
    assert install_main(["skills", "--target", str(tmp_path), "--no-den-cli"]) == 0
    text = (tmp_path / "skills" / "coding" / "SKILL.md").read_text(encoding="utf-8")
    assert DEN_CLI.search(text) is None
    assert f"{tmp_path.resolve().as_posix()}/skills/coding/shared/scripts/" in text
