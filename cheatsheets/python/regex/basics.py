"""Regex Basics — Copy-Paste Cheatsheet.

Core operations: match, search, extract, replace, split, and validate with ``re``.

| Function               | Best For                          | Returns                      |
|------------------------|-----------------------------------|------------------------------|
| find_first             | First occurrence of a pattern     | re.Match | None              |
| find_all               | All non-overlapping matches       | list[str]                    |
| find_all_with_pos      | Matches with character positions   | list[tuple[str, int, int]]   |
| extract_groups         | Structured data from first match  | dict[str, str] | None        |
| extract_all_groups     | Structured data from all matches  | list[dict[str, str]]         |
| replace                | Simple find & replace             | str                          |
| replace_with_func      | Dynamic replacement via callback  | str                          |
| split                  | Split text by pattern             | list[str]                    |
| split_keep_delimiters  | Split but keep delimiters         | list[str]                    |
| is_full_match          | Validate entire string            | bool                         |
| compile_safe           | Compile with error handling       | re.Pattern | None            |

Dependencies:
    stdlib only — no external packages required.
"""

from __future__ import annotations

import re
from collections.abc import Callable

# =============================================================================
# 1. Basics — Match & Search
# =============================================================================


def find_first(pattern: str, text: str, flags: int = 0) -> re.Match[str] | None:
    """Return the first match of *pattern* in *text*, or ``None``.

    [Best for] Checking whether a pattern exists and grabbing its value.
    [Note] Uses ``re.search`` (scans the whole string), not ``re.match``.
    """
    return re.search(pattern, text, flags)


def find_all(pattern: str, text: str, flags: int = 0) -> list[str]:
    """Return all non-overlapping matches of *pattern* in *text*.

    [Best for] Extracting every occurrence of a token/keyword.
    [Note] If *pattern* has groups, ``re.findall`` returns group content.
    """
    return re.findall(pattern, text, flags)


def find_all_with_pos(
    pattern: str, text: str, flags: int = 0
) -> list[tuple[str, int, int]]:
    """Return all matches with their ``(matched_text, start, end)`` positions.

    [Best for] Highlighting, indexing, or slicing around matches.
    [Note] Positions are character offsets (indices) into the original *text* string.
    """
    return [(m.group(), m.start(), m.end()) for m in re.finditer(pattern, text, flags)]


# =============================================================================
# 2. Named Groups & Structured Extraction
# =============================================================================


def extract_groups(pattern: str, text: str, flags: int = 0) -> dict[str, str] | None:
    """Extract named groups from the first match as a dict.

    [Best for] Parsing structured strings (log lines, DSN, semver).
    [Note] Returns ``None`` when there is no match.

    Example pattern::

        r"(?P<year>\\d{4})-(?P<month>\\d{2})-(?P<day>\\d{2})"
    """
    m = re.search(pattern, text, flags)
    return m.groupdict() if m else None


def extract_all_groups(pattern: str, text: str, flags: int = 0) -> list[dict[str, str]]:
    """Extract named groups from every match as a list of dicts.

    [Best for] Tabular-like extraction from repeated structured data.
    [Note] Returns an empty list when there are no matches.
    """
    return [m.groupdict() for m in re.finditer(pattern, text, flags)]


# =============================================================================
# 3. Replace & Substitute
# =============================================================================


def replace(pattern: str, repl: str, text: str, count: int = 0, flags: int = 0) -> str:
    """Replace occurrences of *pattern* with *repl*.

    [Best for] Simple find-and-replace with regex power.
    [Note] ``count=0`` replaces all occurrences. Back-references (``\\1``) work.
    """
    return re.sub(pattern, repl, text, count=count, flags=flags)


def replace_with_func(
    pattern: str, func: Callable[[re.Match[str]], str], text: str, flags: int = 0
) -> str:
    """Replace each match using a callback that receives the Match object.

    [Best for] Dynamic replacements (upper-casing, lookups, arithmetic).
    [Note] *func* is called once per non-overlapping match, left to right.
    """
    return re.sub(pattern, func, text, flags=flags)


# =============================================================================
# 4. Split
# =============================================================================


def split(pattern: str, text: str, maxsplit: int = 0, flags: int = 0) -> list[str]:
    """Split *text* by a regex *pattern*.

    [Best for] Splitting on variable-width delimiters (e.g. ``r"\\s*,\\s*"``).
    [Note] ``maxsplit=0`` means no limit.
    """
    return re.split(pattern, text, maxsplit=maxsplit, flags=flags)


def split_keep_delimiters(pattern: str, text: str, flags: int = 0) -> list[str]:
    """Split *text* by *pattern* but keep the delimiters in the result list.

    [Best for] Tokenisers that need to preserve separator tokens.
    [Note] Wraps *pattern* in a capturing group so ``re.split`` retains it.
           *pattern* must not contain capturing groups — use ``(?:...)`` instead.
    """
    capturing = f"({pattern})"
    return [part for part in re.split(capturing, text, flags=flags) if part]


# =============================================================================
# 5. Validation Helpers
# =============================================================================


def is_full_match(pattern: str, text: str, flags: int = 0) -> bool:
    """Return ``True`` only if *pattern* matches the entire *text*.

    [Best for] Input validation (e.g. "is this a valid ISO date?").
    [Note] Uses ``re.fullmatch`` — no need to add ``^…$`` anchors yourself.
    """
    return re.fullmatch(pattern, text, flags) is not None


def compile_safe(pattern: str, flags: int = 0) -> re.Pattern[str] | None:
    """Compile a regex, returning ``None`` instead of raising on bad syntax.

    [Best for] User-supplied patterns, config-driven matching.
    [Note] Logs nothing — the caller decides how to handle ``None``.
    """
    try:
        return re.compile(pattern, flags)
    except re.error:
        return None


# =============================================================================
# Demo
# =============================================================================

if __name__ == "__main__":
    EMAIL = r"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"
    ISO_DATE = r"\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])"
    sample = "Contact alice@example.com or bob@corp.co.jp for details."

    m = find_first(r"\w+@\w+\.\w+", sample)
    print(f"find_first        : {m.group() if m else None}")
    print(f"find_all          : {find_all(EMAIL, sample)}")
    print(f"find_all_with_pos : {find_all_with_pos(EMAIL, sample)}")

    date_pat = r"(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})"
    print(f"extract_groups    : {extract_groups(date_pat, 'Today is 2026-03-25.')}")

    print(f"replace           : {replace(r'\d+', '#', 'Room 101, Floor 3')}")
    print(f"split_keep_delim  : {split_keep_delimiters(r'[,;]', 'a,b;c,d')}")
    print(f"is_full_match     : {is_full_match(ISO_DATE, '2026-03-25')}")
