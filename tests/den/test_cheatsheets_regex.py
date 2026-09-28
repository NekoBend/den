"""cheatsheets/python/regex: the constants match what their comments promise."""

import hashlib
import importlib.util
import ipaddress
import itertools
import re
import time
from pathlib import Path
from types import ModuleType

import pytest

REGEX_DIR = Path(__file__).resolve().parents[2] / "cheatsheets" / "python" / "regex"

SASAKI = "佐々木"  # a surname written with the iteration mark
HITOBITO = "人々"  # "people"
ADDRESS = "〒100-0001 東京都千代田区 1-1 TEL 03-3213-1111 携帯 090-1234-5678"


def _load(filename: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "cheatsheet_regex_" + filename.removesuffix(".py"), REGEX_DIR / filename
    )
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def patterns() -> ModuleType:
    return _load("patterns.py")


@pytest.fixture(scope="module")
def recipes() -> ModuleType:
    return _load("recipes.py")


@pytest.fixture(scope="module")
def japanese() -> ModuleType:
    return _load("japanese.py")


# --- EMAIL: linear time on long tokens (ReDoS) ----------------------------------


def _elapsed(func, *args) -> float:
    start = time.perf_counter()
    func(*args)
    return time.perf_counter() - start


def test_email_scan_is_linear_on_a_long_token(recipes, patterns):
    # Each start inside a run of local-part characters with no "@" rescanned
    # the whole run: 20k chars took ~0.3 s, 50k ~2 s (mask_emails ~4x that).
    # With the start-of-run lookbehind it is one pass: milliseconds.
    token = "a" * 50_000
    text = "user=alice@example.com token=" + token + " contact bob@corp.co.jp"
    assert _elapsed(recipes.extract_emails, text) < 1.0
    assert _elapsed(recipes.mask_emails, text) < 1.0
    assert _elapsed(re.findall, patterns.EMAIL, text) < 1.0
    assert recipes.extract_emails(text) == ["alice@example.com", "bob@corp.co.jp"]
    assert recipes.mask_emails(text) == (
        "user=***@example.com token=" + token + " contact ***@corp.co.jp"
    )


def test_semver_scan_is_linear_on_a_long_digit_run(patterns):
    assert _elapsed(re.findall, patterns.SEMVER, "1" * 50_000) < 1.0
    assert re.findall(patterns.SEMVER, "v1.2.3 and 10.20.30-rc.1+build.5") == [
        "1.2.3",
        "10.20.30-rc.1+build.5",
    ]


# --- IPV4 / IPV6 / hex digests: no fragments of longer tokens ----------------------


def test_ipv6_finds_whole_compressed_addresses(patterns):
    assert re.findall(patterns.IPV6, "gw 2001:db8::1 up") == ["2001:db8::1"]
    assert re.findall(patterns.IPV6, "fe80::1") == ["fe80::1"]
    assert re.findall(patterns.IPV6, "::1") == ["::1"]
    assert re.findall(patterns.IPV6, "[2001:db8::1]:8080") == ["2001:db8::1"]
    assert re.findall(patterns.IPV6, "2001:db8::1: refused") == ["2001:db8::1"]
    assert re.findall(patterns.IPV6, "1:2:3:4:5:6:7:8:9") == []


def test_ipv6_agrees_with_the_ipaddress_module(patterns):
    # Every zero/non-zero layout of the 8 groups, so "::" lands everywhere.
    values = (0x2001, 0xDB8, 0xA, 0xFFFF, 0x1, 0xABC, 0x12, 0x3456)
    for layout in itertools.product((False, True), repeat=8):
        groups = [
            value if keep else 0 for value, keep in zip(values, layout, strict=True)
        ]
        addr = ipaddress.IPv6Address(":".join(f"{g:x}" for g in groups))
        for form in {addr.compressed, addr.exploded}:
            assert re.findall(patterns.IPV6, f"src {form} ok") == [form]


def test_ipv4_is_not_a_fragment_of_a_longer_number(patterns):
    assert re.findall(patterns.IPV4, "host 10.0.0.256") == []
    assert re.findall(patterns.IPV4, "1.2.3.4567") == []
    assert re.findall(patterns.IPV4, "1.2.3.4.5") == []
    assert re.findall(patterns.IPV4, "Server is 10.0.0.1.") == ["10.0.0.1"]
    assert re.findall(patterns.IPV4, "10.0.0.1:8080, 192.168.1.20") == [
        "10.0.0.1",
        "192.168.1.20",
    ]


def test_md5_does_not_match_inside_a_sha256(patterns):
    sha256 = hashlib.sha256(b"x").hexdigest()
    md5 = hashlib.md5(b"x", usedforsecurity=False).hexdigest()
    assert re.findall(patterns.MD5_HEX, sha256) == []
    assert re.findall(patterns.MD5_HEX, f"md5={md5}") == [md5]
    assert re.findall(patterns.SHA256_HEX, f"sha256:{sha256}") == [sha256]


# --- *_STRICT: really full-string ---------------------------------------------------


@pytest.mark.parametrize(
    ("name", "valid"),
    [
        ("EMAIL_STRICT", "alice@example.com"),
        ("IPV4_STRICT", "1.2.3.4"),
        ("UUID_STRICT", "123e4567-e89b-42d3-a456-426614174000"),
        ("ISO_DATE_STRICT", "2026-09-28"),
        ("PHONE_JP_STRICT", "03-3213-1111"),
        ("JP_POSTAL_STRICT", "100-0001"),
    ],
)
def test_strict_validators_reject_a_trailing_newline(patterns, name, valid):
    # `$` also matches just before a final "\n", so re.match accepted "value\n".
    pattern = getattr(patterns, name)
    assert re.match(pattern, valid)
    assert re.match(pattern, valid + "\n") is None
    assert re.search(pattern, valid + "\n") is None


def test_uuid_strict_accepts_rfc_9562_versions(patterns):
    uuid7 = "01a0e641-b529-775c-a575-779375409aee"  # uuid.uuid7() on 3.14
    assert re.match(patterns.UUID_STRICT, uuid7)
    uuid8 = "01a0e641-b529-875c-a575-779375409aee"
    assert re.match(patterns.UUID_STRICT, uuid8)


def test_syntax_sheet_documents_the_dollar_newline_rule():
    text = (REGEX_DIR / "syntax.md").read_text(encoding="utf-8")
    dollar_row = next(line for line in text.splitlines() if line.startswith("| `$`"))
    assert "final `\\n`" in dollar_row
    assert "Default: match string start/end only" not in text


# --- Japanese: postal codes vs phone numbers, the iteration mark ---------------------


def test_postal_codes_skip_phone_numbers(japanese, patterns):
    assert japanese.extract_postal_codes(ADDRESS) == ["100-0001"]
    assert re.findall(patterns.JP_POSTAL, ADDRESS) == ["100-0001"]
    masked = japanese.mask_postal_code(ADDRESS)
    assert "03-3213-1111" in masked
    assert "090-1234-5678" in masked
    assert "100-0001" not in masked


def test_kanji_helpers_keep_the_iteration_mark(japanese, patterns):
    text = SASAKI + "さんと" + HITOBITO  # "sasaki-san to hitobito"
    assert japanese.extract_kanji(text) == [SASAKI, HITOBITO]
    assert re.findall(patterns.CJK_CHARS, text) == [SASAKI, HITOBITO]
    assert japanese.count_char_types(SASAKI) == {
        "kanji": 3,
        "hiragana": 0,
        "katakana": 0,
        "ascii": 0,
        "other": 0,
    }
    assert japanese.split_japanese_english("Mr " + SASAKI) == ["Mr ", SASAKI]
    assert japanese.contains_japanese("々")
