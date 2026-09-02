"""Shared definitions for the reference-analysis scripts.

Imported by both find-references.py and check-broken-refs.py so the
per-language definition-site patterns and the skip-directory list live in
one place (previously duplicated and "kept in sync manually").

DEFINITION_PATTERNS values contain the token `{name}`. Each consumer
substitutes it before compiling the regex:

    find-references.py    template.replace("{name}", re.escape(symbol))
                          matches one specific symbol.
    check-broken-refs.py  template.replace("{name}", capture-group)
                          captures any symbol name.

Patterns are applied with re.MULTILINE.

The search plumbing both scripts share lives here too: the ripgrep flags and
skip globs, the parser for ripgrep's output lines, the fallback walker, and
the reader it searches files with. Keeping them in one place is what makes the
two backends return the same files.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterator

# Per-extension definition-site patterns. {name} is the symbol placeholder.
DEFINITION_PATTERNS: dict[str, list[str]] = {
    ".py": [
        r"^\s*(?:async\s+)?def\s+{name}\s*\(",
        r"^\s*class\s+{name}\s*[(:\[]",
        r"^\s*{name}\s*=",
    ],
    ".ts": [
        r"\bfunction\s+{name}\s*[(<]",
        r"\bclass\s+{name}\b",
        r"\binterface\s+{name}\b",
        r"\btype\s+{name}\s*=",
        r"\b(?:const|let|var)\s+{name}\s*[=:]",
    ],
    ".go": [
        r"^func\s+{name}\s*\(",
        r"^func\s+\(\s*\w+\s+\*?\w+\s*\)\s+{name}\s*\(",
        r"^type\s+{name}\s+",
        r"^var\s+{name}\b",
        r"^const\s+{name}\b",
    ],
    ".rs": [
        r"\bfn\s+{name}\s*[<(]",
        r"\bstruct\s+{name}\b",
        r"\benum\s+{name}\b",
        r"\btrait\s+{name}\b",
        r"\b(?:const|static)\s+{name}\b",
    ],
    ".java": [
        r"\bclass\s+{name}\b",
        r"\binterface\s+{name}\b",
        r"\benum\s+{name}\b",
        r"\brecord\s+{name}\b",
    ],
    ".cs": [
        r"\bclass\s+{name}\b",
        r"\binterface\s+{name}\b",
        r"\bstruct\s+{name}\b",
        r"\brecord\s+{name}\b",
        r"\benum\s+{name}\b",
    ],
    ".sh": [
        r"^\s*(?:function\s+)?{name}\s*\(\s*\)",
        r"^\s*{name}\s*=",
    ],
    ".ps1": [
        r"^\s*function\s+(?:global:|script:|local:|private:)?{name}\b",
        r"^\s*filter\s+{name}\b",
        r"^\s*class\s+{name}\b",
        r"^\s*enum\s+{name}\b",
        r"^\s*\$(?:script:|global:)?{name}\s*=",
    ],
}

# The {name} capture used when DISCOVERING definitions (check-broken-refs,
# find-references --in). The default \w+ would truncate PowerShell's
# Verb-Noun names at the hyphen, so "function New-Wrapper" becomes a
# definition of "New" - measured to both flood false broken_refs (a deleted
# Test-* symbol collides with every Test-Path call) and hide real ones
# (New-Wrapper deleted stays "defined" through New-WrapperSuffix).
DEFINITION_CAPTURE: dict[str, str] = {
    ".ps1": r"([\w-]+)",
    ".psm1": r"([\w-]+)",
}
DEFAULT_CAPTURE = r"(\w+)"
# Extensions that share patterns with the canonical one.
DEFINITION_PATTERNS[".tsx"] = DEFINITION_PATTERNS[".ts"]
DEFINITION_PATTERNS[".js"] = DEFINITION_PATTERNS[".ts"]
DEFINITION_PATTERNS[".jsx"] = DEFINITION_PATTERNS[".ts"]
DEFINITION_PATTERNS[".mjs"] = DEFINITION_PATTERNS[".ts"]
DEFINITION_PATTERNS[".psm1"] = DEFINITION_PATTERNS[".ps1"]
DEFINITION_PATTERNS[".cjs"] = DEFINITION_PATTERNS[".ts"]
DEFINITION_PATTERNS[".bash"] = DEFINITION_PATTERNS[".sh"]

# Directories never walked, regardless of language.
SKIP_DIRS: frozenset[str] = frozenset(
    {
        ".git",
        ".hg",
        ".svn",
        "node_modules",
        ".venv",
        "venv",
        "__pycache__",
        "target",
        "build",
        "dist",
        "out",
        ".idea",
        ".vscode",
        ".mypy_cache",
        ".ruff_cache",
        ".pytest_cache",
        ".tox",
    }
)


# Flags added to every ripgrep invocation. The fallback walker knows nothing
# about .gitignore and does not skip dot-entries, so rg is told to search
# ignored and hidden files as well: results must not depend on whether rg
# happens to be installed. SKIP_DIRS (`.git` included) is excluded on both
# sides instead.
#
# --no-config is part of that same guarantee: ripgrep otherwise reads the file
# named by RIPGREP_CONFIG_PATH and applies whatever is in it, so a user whose
# config carries --follow or --text (or another glob) would get the rg backend
# searching symlinked or binary files that the walker skips, on that machine
# only. The scripts pass the flags they need explicitly.
RG_SEARCH_FLAGS: tuple[str, ...] = ("--no-config", "--no-ignore", "--hidden")


def rg_skip_globs() -> list[str]:
    """Return `-g !<dir>` arguments excluding every SKIP_DIRS entry."""
    globs: list[str] = []
    for skip in sorted(SKIP_DIRS):
        globs.extend(["-g", f"!{skip}"])
    return globs


def parse_rg_line(line: str) -> tuple[str, int, str] | None:
    """Parse one `<file>:<lineno>:<content>` line of ripgrep output.

    Returns None when the line carries no usable location.

    On Windows the path starts with a drive letter, so the first colon of
    `C:\\repo\\mod.py:12:content` belongs to the path and the line number
    lands in the LAST field of the three-way split.
    """
    parts = line.split(":", 2)
    if len(parts) != 3:
        return None
    file, lineno_text, content = parts
    if len(file) == 1 and file.isalpha() and lineno_text[:1] in {"\\", "/"}:
        sub = content.split(":", 1)
        if len(sub) != 2:
            return None
        file = f"{file}:{lineno_text}"
        lineno_text, content = sub
    try:
        lineno = int(lineno_text)
    except ValueError:
        return None
    return (file, lineno, content)


def iter_search_files(root: Path, ext: str | None = None) -> Iterator[Path]:
    """Yield every file under `root` that the fallback walker searches.

    Mirrors what the ripgrep backend sees:

    - SKIP_DIRS are pruned by directory NAME below `root`, so a checkout that
      itself lives under `build/`, `dist/`, `target/` ... is still searched.
    - Symlinks are never followed (ripgrep does not follow them without -L),
      so a link committed in the tree cannot pull a file from outside it into
      the results.
    - `ext`, when given, keeps only files with that suffix.

    Binary files are dropped by read_searchable_text, which is where their
    content is first available.
    """
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        here = Path(dirpath)
        for name in sorted(filenames):
            path = here / name
            if ext and path.suffix != ext:
                continue
            if path.is_symlink() or not path.is_file():
                continue
            yield path


def read_searchable_text(path: Path) -> str | None:
    """Return the text of `path`, or None if it must not be searched.

    None means the file could not be read, or that it is binary: ripgrep stops
    searching a file the moment it sees a NUL byte and reports nothing for it
    (verified with rg 15.1.0 on a file whose NUL sits after the match), so the
    walk fallback must not report matches there either - it would otherwise
    happily match text inside an object file, a PDF or a .pyc.

    The whole file is read, so the NUL is found wherever it sits; ripgrep
    applies the same test per read buffer, which differs only for a file that
    matches before a NUL that appears megabytes later.

    Undecodable bytes become U+FFFD rather than disappearing: ripgrep searches
    raw bytes, so it does not match `widget` inside b"wid\xffget()", while
    errors="ignore" would delete the 0xff and forge exactly that hit here.
    U+FFFD is not a word character, so the boundary behaves as rg's does, and
    rg's own output is decoded with errors="replace" on this side too.
    """
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    if "\x00" in text:
        return None
    return text
