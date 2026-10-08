"""Every file a model reads from a skill fits Cline v4.1.22's 8,000-character
tool-result cap.

Cline middle-cuts each tool result above 8,000 UTF-16 units. A skill arrives
as the skills tool's result (formatSkillInvocation), and every other file as
a read_files result with 'N | ' line prefixes. Installed copies are measured
with a 16-character user name, so a longer home path still has margin."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from den import _install

ROOT = Path(__file__).resolve().parents[2]
CAP = 8_000  # Cline's default tool-result cap (message-builder.ts:28)
RAW_CAP = 6_000  # a file's own length; also keeps it under Copilot CLI's 20KB read
HOME = "/home/abcdefghijklmnop"
# Cline's frontmatter split (user-instruction-config-loader.ts).
_FRONTMATTER = re.compile(r"^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$")

# Files over a cap today, as '<variant>:<skill>/<path>:<metric>'. It exists so
# CI stays green while later changes shrink these files one by one, and it may
# only shrink: a file that goes over a cap fails its test, and so does an
# entry whose file fits again, so delete the entry once the file fits.
KNOWN_OVER: frozenset[str] = frozenset(
    {
        "den:code-audit/SKILL.md:skills-tool",
        "den:code-audit/SKILL.md:read-tool",
        "den:code-audit/shared/reference/powershell.md:raw",
        "den:code-audit/shared/reference/python.md:raw",
        "den:code-audit/shared/reference/python.md:read-tool",
        "den:code-audit/shared/reference/rust.md:raw",
        "den:code-audit/shared/reference/rust.md:read-tool",
        "den:code-audit/shared/reference/shell.md:raw",
        "den:code-audit/shared/reference/shell.md:read-tool",
        "den:code-audit/shared/reference/typescript.md:raw",
        "den:code-audit/shared/reference/typescript.md:read-tool",
        "den:coding/SKILL.md:skills-tool",
        "den:coding/SKILL.md:read-tool",
        "den:coding/examples/python.md:raw",
        "den:coding/examples/python.md:read-tool",
        "den:coding/examples/rust.md:raw",
        "den:coding/examples/rust.md:read-tool",
        "den:coding/examples/shell.md:raw",
        "den:coding/examples/shell.md:read-tool",
        "den:coding/examples/typescript.md:raw",
        "den:coding/examples/typescript.md:read-tool",
        "den:coding/shared/reference/architecture.md:raw",
        "den:coding/shared/reference/powershell.md:raw",
        "den:coding/shared/reference/python.md:raw",
        "den:coding/shared/reference/python.md:read-tool",
        "den:coding/shared/reference/rust.md:raw",
        "den:coding/shared/reference/rust.md:read-tool",
        "den:coding/shared/reference/shell.md:raw",
        "den:coding/shared/reference/shell.md:read-tool",
        "den:coding/shared/reference/typescript.md:raw",
        "den:coding/shared/reference/typescript.md:read-tool",
        "den:documenter/SKILL.md:skills-tool",
        "den:documenter/SKILL.md:read-tool",
        "den:git-manager/SKILL.md:skills-tool",
        "den:git-manager/SKILL.md:read-tool",
        "den:grounding/SKILL.md:read-tool",
        "den:orchestrate/SKILL.md:skills-tool",
        "den:orchestrate/SKILL.md:read-tool",
        "den:troubleshoot/SKILL.md:skills-tool",
        "den:troubleshoot/SKILL.md:read-tool",
        "den-free:code-audit/SKILL.md:skills-tool",
        "den-free:code-audit/SKILL.md:read-tool",
        "den-free:code-audit/shared/reference/powershell.md:raw",
        "den-free:code-audit/shared/reference/python.md:raw",
        "den-free:code-audit/shared/reference/python.md:read-tool",
        "den-free:code-audit/shared/reference/rust.md:raw",
        "den-free:code-audit/shared/reference/rust.md:read-tool",
        "den-free:code-audit/shared/reference/shell.md:raw",
        "den-free:code-audit/shared/reference/shell.md:read-tool",
        "den-free:code-audit/shared/reference/typescript.md:raw",
        "den-free:code-audit/shared/reference/typescript.md:read-tool",
        "den-free:coding/SKILL.md:skills-tool",
        "den-free:coding/SKILL.md:read-tool",
        "den-free:coding/examples/python.md:raw",
        "den-free:coding/examples/python.md:read-tool",
        "den-free:coding/examples/rust.md:raw",
        "den-free:coding/examples/rust.md:read-tool",
        "den-free:coding/examples/shell.md:raw",
        "den-free:coding/examples/shell.md:read-tool",
        "den-free:coding/examples/typescript.md:raw",
        "den-free:coding/examples/typescript.md:read-tool",
        "den-free:coding/shared/reference/architecture.md:raw",
        "den-free:coding/shared/reference/powershell.md:raw",
        "den-free:coding/shared/reference/python.md:raw",
        "den-free:coding/shared/reference/python.md:read-tool",
        "den-free:coding/shared/reference/rust.md:raw",
        "den-free:coding/shared/reference/rust.md:read-tool",
        "den-free:coding/shared/reference/shell.md:raw",
        "den-free:coding/shared/reference/shell.md:read-tool",
        "den-free:coding/shared/reference/typescript.md:raw",
        "den-free:coding/shared/reference/typescript.md:read-tool",
        "den-free:documenter/SKILL.md:skills-tool",
        "den-free:documenter/SKILL.md:read-tool",
        "den-free:git-manager/SKILL.md:skills-tool",
        "den-free:git-manager/SKILL.md:read-tool",
        "den-free:grounding/SKILL.md:read-tool",
        "den-free:orchestrate/SKILL.md:skills-tool",
        "den-free:orchestrate/SKILL.md:read-tool",
        "den-free:troubleshoot/SKILL.md:read-tool",
        "dist:code-audit/SKILL.md:read-tool",
        "dist:code-audit/shared/reference/powershell.md:raw",
        "dist:code-audit/shared/reference/python.md:raw",
        "dist:code-audit/shared/reference/python.md:read-tool",
        "dist:code-audit/shared/reference/rust.md:raw",
        "dist:code-audit/shared/reference/rust.md:read-tool",
        "dist:code-audit/shared/reference/shell.md:raw",
        "dist:code-audit/shared/reference/shell.md:read-tool",
        "dist:code-audit/shared/reference/typescript.md:raw",
        "dist:code-audit/shared/reference/typescript.md:read-tool",
        "dist:coding/SKILL.md:skills-tool",
        "dist:coding/SKILL.md:read-tool",
        "dist:coding/examples/python.md:raw",
        "dist:coding/examples/python.md:read-tool",
        "dist:coding/examples/rust.md:raw",
        "dist:coding/examples/rust.md:read-tool",
        "dist:coding/examples/shell.md:raw",
        "dist:coding/examples/shell.md:read-tool",
        "dist:coding/examples/typescript.md:raw",
        "dist:coding/examples/typescript.md:read-tool",
        "dist:coding/shared/reference/architecture.md:raw",
        "dist:coding/shared/reference/powershell.md:raw",
        "dist:coding/shared/reference/python.md:raw",
        "dist:coding/shared/reference/python.md:read-tool",
        "dist:coding/shared/reference/rust.md:raw",
        "dist:coding/shared/reference/rust.md:read-tool",
        "dist:coding/shared/reference/shell.md:raw",
        "dist:coding/shared/reference/shell.md:read-tool",
        "dist:coding/shared/reference/typescript.md:raw",
        "dist:coding/shared/reference/typescript.md:read-tool",
        "dist:documenter/SKILL.md:skills-tool",
        "dist:documenter/SKILL.md:read-tool",
        "dist:git-manager/SKILL.md:skills-tool",
        "dist:git-manager/SKILL.md:read-tool",
        "dist:grounding/SKILL.md:read-tool",
        "dist:orchestrate/SKILL.md:skills-tool",
        "dist:orchestrate/SKILL.md:read-tool",
        "dist:troubleshoot/SKILL.md:read-tool",
    }
)


def _u16(text: str) -> int:
    """JavaScript's String length: UTF-16 code units."""
    return len(text.encode("utf-16-le")) // 2


def _plain(fm: str, key: str) -> str:
    """The value of `key:` in frontmatter `fm`, which must be a plain one-line
    scalar so the line's text is the value YAML gives Cline."""
    m = re.search(rf"^{key}:[ \t]*(.*)$", fm, re.MULTILINE)
    assert m, f"no {key}: line in the frontmatter"
    value = m.group(1).strip()
    assert value, f"{key}: is empty or not on one line"
    assert value[0] not in "\"'|>&*!%@`[{", f"{key}: is not a plain scalar"
    return value


def skills_tool_result(text: str) -> str:
    """What Cline's skills tool returns for a SKILL.md with no args
    (formatSkillInvocation, user-instruction-plugin.ts:32-49)."""
    m = _FRONTMATTER.match(text.removeprefix("\ufeff"))
    assert m, "SKILL.md has no frontmatter"
    fm, body = m.groups()
    name, desc = _plain(fm, "name"), _plain(fm, "description")
    return (
        f"<command-name>{name}</command-name>\n<command-instructions>\n"
        f"Description: {desc}\n\n{body.strip()}\n</command-instructions>"
    )


def read_tool_result(text: str) -> str:
    """What Cline's read_files returns for a whole file (file-read.ts:160-170):
    readline's lines, each behind its line number padded to the last one's."""
    lines = text.replace("\r\n", "\n").split("\n")
    if lines[-1] == "":
        lines.pop()
    width = len(str(len(lines)))
    return "\n".join(f"{i:>{width}} | {line}" for i, line in enumerate(lines, 1))


def _measure(metric: str, text: str) -> tuple[int, int]:
    """(size, cap) of a file's `text` under `metric`."""
    if metric == "skills-tool":
        return _u16(skills_tool_result(text)), CAP
    if metric == "read-tool":
        return _u16(read_tool_result(text)), CAP
    return _u16(text), RAW_CAP


def _check(variant: str, base: Path, *, skill_md: bool, metrics: tuple[str, ...]):
    """Measure each skill under `base`: its SKILL.md (skill_md) or every other
    .md file, against each metric's cap, and compare the offenders with the
    KNOWN_OVER entries in the same scope."""
    over: dict[str, str] = {}
    for skill in sorted(p for p in base.iterdir() if p.is_dir()):
        for md in sorted(skill.rglob("*.md")):
            if (md == skill / "SKILL.md") != skill_md:
                continue
            text = md.read_bytes().decode("utf-8")
            rel = md.relative_to(base).as_posix()
            for metric in metrics:
                n, cap = _measure(metric, text)
                if n > cap:
                    over[f"{variant}:{rel}:{metric}"] = (
                        f"{rel}: {metric} {n:,} > {cap:,}"
                    )

    def in_scope(entry: str) -> bool:
        v, rel, metric = entry.split(":")
        return (
            v == variant
            and metric in metrics
            and (rel.split("/", 1)[1] == "SKILL.md") == skill_md
        )

    new = sorted(over[k] for k in over.keys() - KNOWN_OVER)
    assert not new, (
        "over Cline's tool-result cap; shrink or split these files"
        " (KNOWN_OVER may only shrink):\n" + "\n".join(new)
    )
    fits = sorted(e for e in KNOWN_OVER if in_scope(e) and e not in over)
    assert not fits, (
        "these files fit now; delete their entries from KNOWN_OVER:\n" + "\n".join(fits)
    )


@pytest.fixture(scope="module", params=[False, True], ids=["den", "den-free"])
def installed(request, tmp_path_factory) -> tuple[str, Path]:
    """Every skill as `den install skills` builds it for ~/.agents/skills/."""
    no_den_cli: bool = request.param
    base = tmp_path_factory.mktemp("skills")
    for name in _install._skill_names():
        _install._materialize(
            name, base / name, f"{HOME}/.agents/skills/{name}/", no_den_cli=no_den_cli
        )
    return ("den-free" if no_den_cli else "den"), base


DIST = ROOT / "agents" / "dist" / "skills"


def test_formulas_match_cline():
    skill = "---\nname: n\ndescription: d\n---\n\nbody\n"
    assert len(skills_tool_result(skill)) == 98  # 92 + name + description + body
    assert read_tool_result("a\nb\n") == "1 | a\n2 | b"
    assert read_tool_result("x\n" * 10).startswith(" 1 | x")
    assert _u16("\U0001f600") == 2  # a character outside the BMP counts twice


def test_installed_skill_md_fits_the_skills_tool_cap(installed):
    variant, base = installed
    _check(variant, base, skill_md=True, metrics=("skills-tool",))


def test_installed_skill_md_fits_the_read_tool_cap(installed):
    """The weak router tells the model to read SKILL.md with a file tool."""
    variant, base = installed
    _check(variant, base, skill_md=True, metrics=("read-tool",))


def test_installed_reference_files_fit_the_read_tool_cap(installed):
    variant, base = installed
    _check(variant, base, skill_md=False, metrics=("raw", "read-tool"))


def test_dist_skill_md_fits_the_skills_tool_cap():
    _check("dist", DIST, skill_md=True, metrics=("skills-tool",))


def test_dist_skill_md_fits_the_read_tool_cap():
    _check("dist", DIST, skill_md=True, metrics=("read-tool",))


def test_dist_reference_files_fit_the_read_tool_cap():
    _check("dist", DIST, skill_md=False, metrics=("raw", "read-tool"))
