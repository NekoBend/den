"""den-free skill copies: agents/dist/skills/ and `den install skills --no-den-cli`.

The skills under agents/src/ mention den's own CLI (`den verify`, `den board`)
and reference shared/ resources relative to the source tree. Someone without
den cannot use them as-is. This module builds copies that stand alone: every
den CLI mention is replaced or removed through the substitution table in
agents/src/no-den-cli.toml (each anchor must match exactly once, so a source
edit that strands an anchor fails the build instead of shipping stale text),
the shared/ resources each skill references are copied inside it, and every
shared/ reference becomes a path relative to the skill's own directory.

  python3 -m den._portable            regenerate agents/dist/skills/
  python3 -m den._portable --check    exit 1 if the committed copy is stale
  python3 -m den._portable --out DIR  build somewhere else
"""

from __future__ import annotations

import shutil
import sys
import tempfile
import tomllib
from pathlib import Path

from ._content import content_root
from ._install import _materialize, _skill_names

_TABLE = "no-den-cli.toml"
_PREAMBLE = (
    "Paths under `shared/` in this skill are relative to the skill's own directory.\n"
)
_DIST_README = """# den-free skill copies

Generated from `agents/src/skills/` by `python3 -m den._portable`; do not edit
here. Each directory is a self-contained skill: copy it into the directory your
tool reads skills from (for example `~/.claude/skills/<name>/`) and it works
without den installed. Compared with the source skills: the `den verify`
shortcut mentions and the den board paragraphs are removed (each skill
names its checks tool-by-tool), and `shared/` paths are relative to the
skill.
"""


def table() -> dict[str, list[dict[str, str]]]:
    path = content_root() / "agents" / "src" / _TABLE
    return tomllib.loads(path.read_text(encoding="utf-8"))


def strip_den_cli(name: str, text: str) -> str:
    """Apply the skill's substitutions; every anchor must occur exactly once."""
    for entry in table().get(name, []):
        n = text.count(entry["from"])
        if n != 1:
            msg = f"{name}: anchor occurs {n} times, expected 1: {entry['from'][:70]!r}"
            raise ValueError(msg)
        text = text.replace(entry["from"], entry["to"], 1)
    return text


def _add_preamble(skill_md: Path) -> None:
    lines = skill_md.read_text(encoding="utf-8").split("\n")
    for i, line in enumerate(lines):
        if line.startswith("# "):
            lines[i : i + 1] = [line, "", _PREAMBLE.rstrip("\n")]
            break
    skill_md.write_text("\n".join(lines), encoding="utf-8")


def build_tree(out: Path) -> None:
    """Build every skill's den-free copy under `out` (replacing it)."""
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    for name in _skill_names():
        work = out / name
        _materialize(name, work, "shared/", no_den_cli=True)
        if (work / "shared").is_dir():  # the note is only true when shared/ ships
            _add_preamble(work / "SKILL.md")
    (out / "README.md").write_text(_DIST_README, encoding="utf-8")


def _differences(a: Path, b: Path) -> list[str]:
    """Exact tree comparison: byte content AND the executable bit. filecmp's
    shallow stat signatures are avoided on purpose - a committed script that
    lost +x must fail --check, or every copied skill ships a run-checks.sh
    that dies with permission denied."""
    files_a = {p.relative_to(a) for p in a.rglob("*") if p.is_file()}
    files_b = {p.relative_to(b) for p in b.rglob("*") if p.is_file()}
    out = [f"only in built: {x}" for x in sorted(map(str, files_a - files_b))]
    out += [f"only in committed: {x}" for x in sorted(map(str, files_b - files_a))]
    for rel in sorted(files_a & files_b, key=str):
        fa, fb = a / rel, b / rel
        if fa.read_bytes() != fb.read_bytes():
            out.append(f"differs: {rel}")
        elif (fa.stat().st_mode & 0o111) != (fb.stat().st_mode & 0o111):
            out.append(f"executable bit differs: {rel}")
    return out


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    out = content_root() / "agents" / "dist" / "skills"
    check = False
    i = 0
    while i < len(args):
        if args[i] == "--check":
            check = True
        elif args[i] == "--out" and i + 1 < len(args):
            out = Path(args[i + 1]).expanduser()
            i += 1
        else:
            print(__doc__)
            return 2
        i += 1
    if not check:
        build_tree(out)
        print(f"built den-free skills -> {out}")
        return 0
    with tempfile.TemporaryDirectory() as td:
        fresh = Path(td) / "skills"
        build_tree(fresh)
        if not out.is_dir():
            print(f"STALE: {out} does not exist; run python3 -m den._portable")
            return 1
        diffs = _differences(fresh, out)
    if diffs:
        print("STALE: agents/dist/skills differs from a fresh build:")
        print("\n".join(f"  {d}" for d in diffs))
        return 1
    print(f"ok: {out} is current")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
