"""Repo-level consistency gates over the model-facing prompt content.

Both tests exist because an outside review found the invariants they assert
were held only by the private generator's discipline, with nothing in THIS
repository able to catch a violation:

- The weak router's <skill_catalog> is a generated artifact; a skill rename
  with no dist rebuild would leave it dispatching to a directory that does
  not exist while CI stayed green (exactly the shape of the code-review ->
  code-audit rename in #57).
- The no-em-dash rule is stated for every model-facing file, but CI's
  character lint globs agents/dist/ only, so a hand-edited skill could ship
  the banned characters unchecked.
"""

from __future__ import annotations

import re
from pathlib import Path

AGENTS = Path(__file__).resolve().parents[3]

# Built from codepoints so the banned characters never appear literally in
# this repo (ruff RUF001 flags them, and the test would otherwise be the one
# file violating the rule it enforces).
BANNED_CHARS = {
    chr(0x2014): "em-dash",
    chr(0x2013): "en-dash",
    chr(0x2212): "minus-sign",
}


def test_weak_catalog_rows_match_the_skill_directories() -> None:
    catalog = (AGENTS / "dist" / "weak" / "AGENTS.md").read_text(encoding="utf-8")
    rows = set(re.findall(r"^\| ([a-z][a-z-]*) +\|", catalog, re.MULTILINE))
    rows.discard("general")  # the documented direct-answer fallback, no dir
    dirs = {p.parent.name for p in (AGENTS / "skills").glob("*/SKILL.md")}
    assert rows == dirs, (
        f"catalog-only (router dispatches to nothing): {sorted(rows - dirs)}; "
        f"dir-only (skill unreachable via the weak router): {sorted(dirs - rows)}"
    )


def test_no_banned_dashes_in_any_model_facing_markdown() -> None:
    offenders: list[str] = []
    for base in ("skills", "shared", "dist"):
        for f in sorted((AGENTS / base).rglob("*.md")):
            text = f.read_text(encoding="utf-8")
            for ch, name in BANNED_CHARS.items():
                if ch in text:
                    line = text[: text.index(ch)].count("\n") + 1
                    offenders.append(f"{f.relative_to(AGENTS)}:{line} {name}")
    assert not offenders, offenders
