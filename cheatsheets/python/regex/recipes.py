"""Regex Practical Recipes — Copy-Paste Cheatsheet.

Ready-to-use functions for email/URL extraction, masking, normalisation, and conversion.

| Function             | Best For                          | Returns   |
|----------------------|-----------------------------------|-----------|
| extract_emails       | Pull emails from text             | list[str] |
| extract_urls         | Pull URLs from text               | list[str] |
| mask_emails          | Redact local part of emails       | str       |
| normalize_whitespace | Collapse whitespace runs          | str       |
| remove_html_tags     | Strip HTML/XML tags               | str       |
| to_snake_case        | CamelCase/kebab to snake_case     | str       |

Dependencies:
    stdlib only — no external packages required.
"""

from __future__ import annotations

import re

# =============================================================================
# Constants (inline for copy-paste convenience)
# =============================================================================

EMAIL: str = r"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"
URL: str = r"https?://[^\s<>\"')\]]+"
WHITESPACE_RUNS: str = r"[\s]+"

# =============================================================================
# Extraction
# =============================================================================


def extract_emails(text: str) -> list[str]:
    """Extract all email addresses from *text*.

    [Best for] Scraping contact info from plain-text or HTML.
    [Note] Uses the ``EMAIL`` constant — not fully RFC 5322 compliant.
    """
    return re.findall(EMAIL, text)


def extract_urls(text: str) -> list[str]:
    """Extract all HTTP/HTTPS URLs from *text*.

    [Best for] Link extraction from logs, documents, chat messages.
    [Note] May include trailing punctuation — post-process if needed.
    """
    return re.findall(URL, text)


# =============================================================================
# Masking & Normalisation
# =============================================================================


def mask_emails(text: str, mask: str = "***") -> str:
    """Replace the local part of every email address with *mask*.

    [Best for] Anonymising logs or user-facing text.
    [Note] ``user@example.com`` → ``***@example.com``.
    """
    return re.sub(
        r"([a-zA-Z0-9._%+\-]+)(@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,})",
        mask + r"\2",
        text,
    )


def normalize_whitespace(text: str) -> str:
    """Collapse any run of whitespace (spaces, tabs, newlines) into a single space.

    [Best for] Cleaning OCR output, HTML-extracted text, user input.
    [Note] Also strips leading/trailing whitespace.
    """
    return re.sub(WHITESPACE_RUNS, " ", text).strip()


def remove_html_tags(text: str) -> str:
    """Strip HTML/XML tags from *text*.

    [Best for] Quick-and-dirty tag removal from trusted content.
    [Note] Not a sanitiser — do **not** use for security-sensitive HTML cleaning.
    """
    return re.sub(r"<[^>]+>", "", text)


# =============================================================================
# Conversion
# =============================================================================


def to_snake_case(text: str) -> str:
    """Convert CamelCase, PascalCase, or kebab-case to snake_case.

    [Best for] Normalising identifiers, API field mapping.
    [Note] Handles consecutive uppercase (``HTMLParser`` → ``html_parser``).
    """
    text = text.replace("-", "_")
    text = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", text)
    text = re.sub(r"([a-z\d])([A-Z])", r"\1_\2", text)
    return text.lower()


# =============================================================================
# Demo
# =============================================================================

if __name__ == "__main__":
    sample = "Contact alice@example.com or bob@corp.co.jp for details."

    print(f"extract_emails    : {extract_emails(sample)}")
    print(
        f"extract_urls      : {extract_urls('Visit https://example.com and http://test.org/path')}"
    )
    print(f"mask_emails       : {mask_emails(sample)}")
    print(
        f"normalize_ws      : {normalize_whitespace('  hello   world\nnew  line  ')!r}"
    )
    print(f"remove_html_tags  : {remove_html_tags('<p>Hello <b>world</b></p>')}")
    print(f"to_snake_case     : {to_snake_case('HTMLParser')}")
    print(f"to_snake_case     : {to_snake_case('myFunctionName')}")
