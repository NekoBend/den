"""den-free skill copies: agents/dist/skills/ and `den install skills --no-den-cli`.

The skills under agents/src/ mention den's own CLI (`den verify`, `den board`)
and reference shared/ resources relative to the source tree. Someone without
den cannot use them as-is. This module builds copies that stand alone: every
den CLI mention is replaced or removed through the substitution table in
agents/src/no-den-cli.toml (each anchor must match exactly once, so a source
edit that strands an anchor fails the build instead of shipping stale text),
the shared/ resources each skill references are copied inside it (following
the shared files that name other shared files), and every shared/ reference
becomes a path relative to the skill's own directory. Skill-local examples/ and
reference/ paths are written from the skill root and stay as written here;
`den install skills` makes them absolute. A reference that names nothing the
copy ships fails the build.

  python3 -m den._portable            regenerate agents/dist/skills/
  python3 -m den._portable --check    exit 1 if the committed copy is stale
  python3 -m den._portable --out DIR  build into DIR instead; DIR must be
                                      absent, empty, or hold a previous build
                                      (its README.md; anything else: exit 2).
                                      There only README.md and the skill
                                      directories are replaced; every other
                                      entry is left alone.
"""

from __future__ import annotations

import shutil
import sys
import tempfile
import tomllib
from pathlib import Path

from ._content import content_root
from ._install import _PATH_RE, _materialize, _skill_names

_TABLE = "no-den-cli.toml"
_PREAMBLE = (
    "Paths under `shared/`, `examples/` and `reference/` in this skill are relative"
    " to the skill's own directory.\n"
)
_DIST_README = """# den-free skill copies

Generated from `agents/src/skills/` by `python3 -m den._portable`; do not edit
here. Each directory is a self-contained skill: copy it into the directory your
tool reads skills from (for example `~/.claude/skills/<name>/`) and it works
without den installed. Compared with the source skills: the `den verify`
shortcut mentions, the den board paragraphs and the pointer to den's
cheatsheets are removed (each skill names its checks tool-by-tool), and
`shared/`, `examples/` and `reference/` paths are relative to the skill.

Each skill restates a short set of rules for a run with no parent prompt.
den's parent prompts (`agents/dist/parents/`) hold the full set, so place one
where your tool reads its instructions as well, for example
`~/.claude/CLAUDE.md`.
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


def edit_in_place(path: Path, key: str) -> None:
    """Apply table `key` to `path`, keeping the file's own line endings.

    The anchors are written with LF, so the text is matched with LF and written
    back in the source's style; a file the table leaves unchanged is not
    rewritten at all, so its bytes stay those of the den-aware copy (den
    uninstall recognizes a file only by its bytes)."""
    raw = path.read_bytes()
    text = raw.decode("utf-8")
    crlf = b"\r\n" in raw
    plain = text.replace("\r\n", "\n") if crlf else text
    new = strip_den_cli(key, plain)
    if new == plain:
        return
    path.write_bytes((new.replace("\n", "\r\n") if crlf else new).encode("utf-8"))


def strip_shared(work: Path) -> None:
    """Apply the `shared/...` tables to the shared files bundled in skill copy `work`.

    A key names a path under agents/src/; the skill copy holds its shared/ files
    at the same relative path, so a file the skill does not bundle is skipped.
    """
    for key in table():
        target = work / key
        if key.startswith("shared/") and target.is_file():
            edit_in_place(target, key)


def _add_preamble(skill_md: Path) -> None:
    lines = skill_md.read_text(encoding="utf-8").split("\n")
    for i, line in enumerate(lines):
        if line.startswith("# "):
            lines[i : i + 1] = [line, "", _PREAMBLE.rstrip("\n")]
            break
    skill_md.write_text("\n".join(lines), encoding="utf-8", newline="")


def _ships_a_relative_path(work: Path) -> bool:
    """Whether a .md file in skill copy `work` holds a shared/ or skill-local
    path. A .md that is not UTF-8 is skipped, as _materialize skips it."""
    for md in work.rglob("*.md"):
        try:
            text = md.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        if _PATH_RE.search(text):
            return True
    return False


def _replaceable(out: Path) -> bool:
    """True when build_tree may build into `out`: absent, an empty directory,
    or a previous den-free build (the generated README.md's first line)."""
    if not out.exists() and not out.is_symlink():
        return True
    if out.is_symlink() or not out.is_dir():
        return False
    if not any(out.iterdir()):
        return True
    try:
        first = (out / "README.md").read_text(encoding="utf-8").split("\n", 1)[0]
    except (OSError, UnicodeDecodeError):
        return False
    return first == _DIST_README.split("\n", 1)[0]


def _remove(path: Path) -> None:
    """Delete `path` if present; a symlink is unlinked, never followed."""
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def build_tree(out: Path, *, whole: bool = False) -> None:
    """Build every skill's den-free copy under `out`.

    Raises FileExistsError, deleting nothing, when `out` holds anything but a
    previous build: `--out ~/.claude/skills` must not take the user's own
    skills with it. In a previous build only README.md and the skill
    directories this build generates are replaced, and every other entry is
    left alone: the bulk copy `cp -r dist/skills/* ~/.claude/skills/` puts
    that README next to the user's own skills. whole=True replaces `out`
    entirely instead, for den's own agents/dist/skills, where a skill retired
    from agents/src must disappear too."""
    if not _replaceable(out):
        msg = (
            f"{out} is not empty and not a previous den-free build; refusing to"
            " replace it (build into a new directory and copy the skills over)"
        )
        raise FileExistsError(msg)
    if whole:
        _remove(out)
    out.mkdir(parents=True, exist_ok=True)
    # First, so a build that stops midway (a stale anchor) is still recognized
    # as den's own and the next run may replace it.
    _remove(out / "README.md")
    (out / "README.md").write_text(_DIST_README, encoding="utf-8")
    for name in _skill_names():
        work = out / name
        _remove(work)
        _materialize(name, work, "", no_den_cli=True)
        if _ships_a_relative_path(work):  # the note is only true there
            _add_preamble(work / "SKILL.md")


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
    own = True  # den's own dist dir, rebuilt whole; --out may hold other skills
    check = False
    i = 0
    while i < len(args):
        if args[i] == "--check":
            check = True
        elif args[i] == "--out" and i + 1 < len(args):
            out = Path(args[i + 1]).expanduser()
            own = False
            i += 1
        else:
            print(__doc__)
            return 2
        i += 1
    if not check:
        try:
            build_tree(out, whole=own)
        except FileExistsError as exc:
            print(f"den._portable: {exc}", file=sys.stderr)
            return 2
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
