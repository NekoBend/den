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
"""

from __future__ import annotations

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
