"""Every file a model reads from a skill fits Cline v4.1.22's 8,000-character
tool-result cap.

Cline middle-cuts each tool result above 8,000 UTF-16 units. A skill arrives
as the skills tool's result (formatSkillInvocation), and every other file as
a read_files result with 'N | ' line prefixes. den writes each installed
skill's absolute directory into its paths, so installed copies are measured
under both home shapes: /home/<user>, and C:/Users/<user>, which is 3
characters longer per path. Both use a 16-character user name, longer than
most, so a real home has margin."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from den import _install

try:
    import yaml
except ImportError:  # optional locally; CI installs it
    yaml = None

ROOT = Path(__file__).resolve().parents[2]
CAP = 8_000  # Cline's default tool-result cap (message-builder.ts:28)
RAW_CAP = 6_000  # a file's own length; also keeps it under Copilot CLI's 20KB read
USER = "abcdefghijklmnop"  # 16 characters
# den writes the skill's directory as Path.resolve().as_posix()
# (_install_skill), which starts with one of these.
HOMES = {"linux": f"/home/{USER}", "windows": f"C:/Users/{USER}"}
# Cline's frontmatter split (user-instruction-config-loader.ts).
_FRONTMATTER = re.compile(r"^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$")

# installed and installed --no-den-cli, each under both homes; and dist
VARIANTS = ("den-linux", "den-windows", "den-free-linux", "den-free-windows", "dist")

# Files over a cap, as '<variant>:<skill>/<path>:<metric>'. It let CI stay
# green while the 2026-10 size reduction shrank 117 offenders one change at a
# time, and it is empty now. It may only shrink: a file that goes over a cap
# fails its test, and so does an entry whose file fits again.
KNOWN_OVER: frozenset[str] = frozenset()


def _u16(text: str) -> int:
    """JavaScript's String length: UTF-16 code units."""
    return len(text.encode("utf-16-le")) // 2


def _plain(fm: str, key: str) -> str:
    """The value of `key:` in frontmatter `fm`, which must be a plain one-line
    scalar so the line's text is the value YAML gives Cline. With pyyaml at
    hand, YAML's own reading must equal the line too."""
    m = re.search(rf"^{key}:[ \t]*(.*)$", fm, re.MULTILINE)
    assert m, f"no {key}: line in the frontmatter"
    value = m.group(1).strip()
    assert value, f"{key}: is empty or not on one line"
    assert value[0] not in "\"'|>&*!%@`[{", f"{key}: is not a plain scalar"
    # YAML folds an indented next line into the value, which the line misses
    assert not re.match(r"(?:[ \t]*\r?\n)+[ \t]+\S", fm[m.end() :]), (
        f"{key}: continues on an indented line; write it on one line"
    )
    if yaml is not None:
        parsed = yaml.safe_load(fm)[key]
        assert parsed == value, f"{key}: YAML reads {parsed!r}, the line {value!r}"
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


def _where(variant: str) -> str:
    """What `variant` measures, as a failure message names it."""
    if variant == "dist":
        return "agents/dist/skills"
    flavor, _, shape = variant.rpartition("-")
    how = "den install skills" + (" --no-den-cli" if flavor == "den-free" else "")
    return f"{how} under the {shape.capitalize()}-shaped home {HOMES[shape]}"


def _check(variant: str, base: Path, *, skill_md: bool, metrics: tuple[str, ...]):
    """Measure each skill under `base`: its SKILL.md (skill_md) or every other
    .md file, against each metric's cap, and compare the offenders with the
    KNOWN_OVER entries in the same scope. A failure names the variant and,
    for an installed one, the home it was built under."""
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
        f"{variant} ({_where(variant)}): over a size cap (Cline's 8,000-character"
        " tool-result cap, or den's 6,000 raw cap); shrink or split these files"
        " (KNOWN_OVER may only shrink):\n" + "\n".join(new)
    )
    fits = sorted(e for e in KNOWN_OVER if in_scope(e) and e not in over)
    assert not fits, (
        f"{variant} ({_where(variant)}): these files fit now; delete their"
        " entries from KNOWN_OVER:\n" + "\n".join(fits)
    )


@pytest.fixture(scope="module", params=VARIANTS[:-1])
def installed(request, tmp_path_factory) -> tuple[str, Path]:
    """Every skill as `den install skills` builds it for ~/.agents/skills/
    under the variant's home, with --no-den-cli for den-free."""
    variant: str = request.param
    flavor, _, shape = variant.rpartition("-")
    base = tmp_path_factory.mktemp("skills")
    for name in _install._skill_names():
        _install._materialize(
            name,
            base / name,
            f"{HOMES[shape]}/.agents/skills/{name}/",
            no_den_cli=flavor == "den-free",
        )
    return variant, base


DIST = ROOT / "agents" / "dist" / "skills"


def test_formulas_match_cline():
    skill = "---\nname: n\ndescription: d\n---\n\nbody\n"
    assert len(skills_tool_result(skill)) == 98  # 92 + name + description + body
    assert read_tool_result("a\nb\n") == "1 | a\n2 | b"
    assert read_tool_result("x\n" * 10).startswith(" 1 | x")
    assert _u16("\U0001f600") == 2  # a character outside the BMP counts twice


def test_plain_refuses_a_value_that_continues_on_the_next_line():
    """YAML folds the indented line into the description, so the first line
    alone would undercount what Cline shows."""
    folded = "---\nname: n\ndescription: first line\n  and a second one\n---\n\nb\n"
    with pytest.raises(AssertionError, match="continues on an indented line"):
        skills_tool_result(folded)


@pytest.mark.skipif(yaml is None, reason="needs pyyaml")
def test_plain_refuses_a_line_yaml_reads_differently():
    commented = "---\nname: n\ndescription: d # a YAML comment\n---\n\nbody\n"
    with pytest.raises(AssertionError, match="YAML reads"):
        skills_tool_result(commented)


@pytest.mark.parametrize(
    ("variant", "where"),
    [
        (
            "den-windows",
            f"den install skills under the Windows-shaped home C:/Users/{USER}",
        ),
        (
            "den-free-linux",
            f"den install skills --no-den-cli under the Linux-shaped home /home/{USER}",
        ),
        ("dist", "agents/dist/skills"),
    ],
)
def test_a_file_over_a_cap_fails_naming_its_variant_and_home(tmp_path, variant, where):
    (tmp_path / "s").mkdir()
    (tmp_path / "s" / "SKILL.md").write_text("x\n" * 3_000, encoding="utf-8")
    with pytest.raises(AssertionError) as exc:
        _check(variant, tmp_path, skill_md=True, metrics=("read-tool",))
    assert str(exc.value).startswith(f"{variant} ({where}): over a size cap")
    assert "s/SKILL.md: read-tool 26,999 > 8,000" in str(exc.value)


def _entry(entry: str) -> tuple[str, str, str]:
    """A KNOWN_OVER entry's (variant, <skill>/<path>, metric)."""
    variant, _, rest = entry.partition(":")
    rel, _, metric = rest.rpartition(":")
    return variant, rel, metric


def test_known_over_entries_are_well_formed():
    """An entry no test measures (a misspelt variant, a metric its file's kind
    never gets) is never reported as fitting again, so it would stay forever."""
    assert len(KNOWN_OVER) <= 0  # may only go down: it is empty
    bad = []
    for entry in sorted(KNOWN_OVER):
        variant, rel, metric = _entry(entry)
        skill_md = rel.partition("/")[2] == "SKILL.md"
        metrics = ("skills-tool", "read-tool") if skill_md else ("raw", "read-tool")
        if variant not in VARIANTS or "/" not in rel or metric not in metrics:
            bad.append(entry)
    assert not bad, "malformed KNOWN_OVER entries:\n" + "\n".join(bad)


def _unbuilt(variant: str, base: Path) -> list[str]:
    """The `variant` entries of KNOWN_OVER whose file is not under `base`."""
    return sorted(
        entry
        for entry in KNOWN_OVER
        if _entry(entry)[0] == variant and not (base / _entry(entry)[1]).is_file()
    )


def test_known_over_entries_name_installed_files(installed):
    variant, base = installed
    missing = _unbuilt(variant, base)
    assert not missing, "no such file in this build:\n" + "\n".join(missing)


def test_known_over_entries_name_dist_files():
    missing = _unbuilt("dist", DIST)
    assert not missing, "no such file in agents/dist/skills:\n" + "\n".join(missing)


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
