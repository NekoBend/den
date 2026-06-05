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
}
# Extensions that share patterns with the canonical one.
DEFINITION_PATTERNS[".tsx"] = DEFINITION_PATTERNS[".ts"]
DEFINITION_PATTERNS[".js"] = DEFINITION_PATTERNS[".ts"]
DEFINITION_PATTERNS[".jsx"] = DEFINITION_PATTERNS[".ts"]
DEFINITION_PATTERNS[".mjs"] = DEFINITION_PATTERNS[".ts"]
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
