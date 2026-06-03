"""Japanese Text Processing — Copy-Paste Cheatsheet.

Regex-based functions for extracting, normalising, and analysing Japanese text.

| Function               | Best For                           | Returns          |
|------------------------|------------------------------------|------------------|
| extract_kanji          | Isolate kanji from mixed text      | list[str]        |
| extract_hiragana       | Pull hiragana runs                 | list[str]        |
| extract_katakana       | Pull full-width katakana runs      | list[str]        |
| contains_japanese      | Detect any JP characters           | bool             |
| split_japanese_english | Tokenise mixed JP/EN text          | list[str]        |
| normalize_nfkc         | NFKC normalisation (FW→ASCII etc.) | str              |
| mask_postal_code       | Redact JP postal codes             | str              |
| extract_postal_codes   | Pull JP postal codes               | list[str]        |
| remove_furigana_parens | Strip parenthesised readings       | str              |
| count_char_types       | Character-type statistics          | dict[str, int]   |

Dependencies:
    stdlib only — no external packages required.
"""

from __future__ import annotations

import re

# =============================================================================
# Constants (inline for copy-paste convenience)
# =============================================================================

CJK_CHARS: str = (
    r"[\u4e00-\u9fff\u3400-\u4dbf]+"  # CJK Unified Ideographs (common + ext-A)
)
HIRAGANA: str = r"[\u3040-\u309f]+"  # Hiragana block
KATAKANA: str = r"[\u30a0-\u30ff]+"  # Katakana block
KATAKANA_HW: str = r"[\uff65-\uff9f]+"  # Half-width Katakana
FULL_WIDTH_ASCII: str = r"[\uff01-\uff5e]+"  # Full-width ASCII variants (！-～)
JP_POSTAL: str = r"\d{3}-\d{4}"  # Japanese postal code (NNN-NNNN)

# =============================================================================
# Extraction
# =============================================================================


def extract_kanji(text: str) -> list[str]:
    """Extract all CJK kanji runs from *text*.

    [Best for] Isolating kanji from mixed Japanese text.
    [Note] Uses the ``CJK_CHARS`` constant (common + ext-A blocks).
    """
    return re.findall(CJK_CHARS, text)


def extract_hiragana(text: str) -> list[str]:
    """Extract all hiragana runs from *text*.

    [Best for] Pulling okurigana or particle sequences.
    [Note] Uses Unicode block U+3040–U+309F.
    """
    return re.findall(HIRAGANA, text)


def extract_katakana(text: str) -> list[str]:
    """Extract all katakana runs from *text* (full-width only).

    [Best for] Identifying loanwords, product names, emphasis text.
    [Note] Half-width katakana (U+FF65–U+FF9F) is matched by ``KATAKANA_HW``.
    """
    return re.findall(KATAKANA, text)


def extract_postal_codes(text: str) -> list[str]:
    """Extract all Japanese postal codes (NNN-NNNN) from *text*.

    [Best for] Parsing address fields, form data.
    [Note] Does not validate against actual postal code ranges.
    """
    return re.findall(JP_POSTAL, text)


# =============================================================================
# Detection & Splitting
# =============================================================================


def contains_japanese(text: str) -> bool:
    """Return ``True`` if *text* contains any Japanese characters (hiragana, katakana, or kanji).

    [Best for] Language detection heuristics, input validation.
    [Note] Does not detect Japanese punctuation or half-width katakana.
    """
    return bool(re.search(r"[\u3040-\u309f\u30a0-\u30ff\u4e00-\u9fff]", text))


def split_japanese_english(text: str) -> list[str]:
    """Split *text* at boundaries between Japanese and ASCII runs.

    [Best for] Tokenising mixed Japanese/English text for search indexing.
    [Note] Keeps each run as a separate token; whitespace is not added.
    """
    return [
        part
        for part in re.split(
            r"([\u3040-\u309f\u30a0-\u30ff\u4e00-\u9fff\u3400-\u4dbf]+)", text
        )
        if part
    ]


# =============================================================================
# Normalisation
# =============================================================================


def normalize_nfkc(text: str) -> str:
    """Apply NFKC normalisation to *text*.

    Covers full-width ASCII → half-width, half-width katakana → full-width,
    and other Unicode compatibility decompositions.

    [Best for] Normalising user input from Japanese IME, standardising katakana.
    [Note] Uses ``unicodedata.normalize('NFKC')``.
    """
    import unicodedata

    return unicodedata.normalize("NFKC", text)


# =============================================================================
# Masking & Cleaning
# =============================================================================


def mask_postal_code(text: str, mask: str = "***-****") -> str:
    """Replace Japanese postal codes (NNN-NNNN) with *mask*.

    [Best for] Anonymising addresses in logs or exports.
    [Note] Uses ``JP_POSTAL`` pattern.
    """
    return re.sub(JP_POSTAL, mask, text)


def remove_furigana_parens(text: str) -> str:
    """Remove parenthesised furigana like ``漢字（かんじ）`` → ``漢字``.

    [Best for] Cleaning text that has inline reading aids.
    [Note] Matches both full-width ``（…）`` and half-width ``(…)`` parentheses
           containing only hiragana/katakana.
    """
    return re.sub(r"[（(][ぁ-ゖァ-ヶー]+[）)]", "", text)


# =============================================================================
# Analysis
# =============================================================================


def count_char_types(text: str) -> dict[str, int]:
    """Count characters by type: kanji, hiragana, katakana, ascii, other.

    [Best for] Text statistics, input analysis dashboards.
    [Note] Half-width katakana is counted under ``katakana``.
    """
    return {
        "kanji": len(re.findall(r"[\u4e00-\u9fff\u3400-\u4dbf]", text)),
        "hiragana": len(re.findall(r"[\u3040-\u309f]", text)),
        "katakana": len(re.findall(r"[\u30a0-\u30ff\uff65-\uff9f]", text)),
        "ascii": len(re.findall(r"[a-zA-Z0-9]", text)),
        "other": len(
            re.findall(
                r"[^\u4e00-\u9fff\u3400-\u4dbf\u3040-\u309f\u30a0-\u30ff\uff65-\uff9fa-zA-Z0-9]",
                text,
            )
        ),
    }


# =============================================================================
# Demo
# =============================================================================

if __name__ == "__main__":
    jp = "東京タワーはTokyo Towerの日本語名です。〒100-0001"

    print(f"extract_kanji     : {extract_kanji(jp)}")
    print(f"extract_hiragana  : {extract_hiragana(jp)}")
    print(f"extract_katakana  : {extract_katakana(jp)}")
    print(f"extract_postal    : {extract_postal_codes(jp)}")
    print(f"contains_japanese : {contains_japanese(jp)}")
    print(f"split_jp_en       : {split_japanese_english(jp)}")
    print(f"normalize_nfkc    : {normalize_nfkc('Ｈｅｌｌｏ１２３　ｶﾀｶﾅ')}")
    print(f"mask_postal       : {mask_postal_code(jp)}")
    print(f"remove_furigana   : {remove_furigana_parens('漢字（かんじ）を読む')}")
    print(f"count_char_types  : {count_char_types(jp)}")
