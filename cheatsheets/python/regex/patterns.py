"""Common Regex Patterns — Copy-Paste Constants.

50+ ready-to-use raw-string constants organized into 8 categories:
Network/Web, Date/Time, Numbers/Currency, Identifiers/Code,
Files/Paths, Whitespace/Text, Japanese, and Validation (anchored).

Import nothing — just copy the constant you need.

Dependencies:
    stdlib only — no external packages required.
"""

# =============================================================================
# 1. Network & Web
# =============================================================================

EMAIL: str = r"(?<![a-zA-Z0-9._%+\-])[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"  # RFC-ish email; (?<!...) tries each run once (linear, no ReDoS)
URL: str = r"https?://[^\s<>\"')\]]+"  # HTTP/HTTPS URLs
DOMAIN: str = (
    r"(?:[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}"  # FQDN
)
IPV4: str = r"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)(?!\.?\d)"  # 0.0.0.0 to 255.255.255.255, never a piece of a longer number (a trailing "." is fine)
IPV6: str = (
    r"(?<![0-9a-fA-F])(?<![0-9a-fA-F]:)(?:"  # not the tail of a longer address...
    r"(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}"  # full 8-group
    r"|(?:[0-9a-fA-F]{1,4}:){1,7}:"  # trailing ::
    r"|(?:[0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}"  # 1 group after ::
    r"|(?:[0-9a-fA-F]{1,4}:){1,5}(?::[0-9a-fA-F]{1,4}){1,2}"  # 2 groups after ::
    r"|(?:[0-9a-fA-F]{1,4}:){1,4}(?::[0-9a-fA-F]{1,4}){1,3}"  # 3 groups after ::
    r"|(?:[0-9a-fA-F]{1,4}:){1,3}(?::[0-9a-fA-F]{1,4}){1,4}"  # 4 groups after ::
    r"|(?:[0-9a-fA-F]{1,4}:){1,2}(?::[0-9a-fA-F]{1,4}){1,5}"  # 5 groups after ::
    r"|[0-9a-fA-F]{1,4}:(?::[0-9a-fA-F]{1,4}){1,6}"  # 6 groups after ::
    r"|::(?:[0-9a-fA-F]{1,4}:){0,5}[0-9a-fA-F]{1,4}"  # leading ::
    r"|::"  # :: alone
    r")(?![0-9a-fA-F]|:[0-9a-fA-F:])"  # ...nor cut short: "2001:db8::1", not "2001:db8::"
)  # common IPv6 forms (no embedded IPv4); a ":" next to it as punctuation is fine
MAC_ADDR: str = (
    r"(?:[0-9a-fA-F]{2}[:\-]){5}[0-9a-fA-F]{2}"  # MAC address (colon or dash)
)
URL_SLUG: str = r"[a-z0-9]+(?:-[a-z0-9]+)*"  # URL slug (lowercase-dashed)
URL_QUERY_PARAM: str = r"[?&]([a-zA-Z0-9_]+)=([^&#]*)"  # key=value from query string

# =============================================================================
# 2. Date & Time
# =============================================================================

ISO_DATE: str = r"\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])"  # YYYY-MM-DD
ISO_DATETIME: str = r"\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])[T ](?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+\-]\d{2}:?\d{2})?"  # ISO 8601 datetime
TIME_24H: str = r"(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?"  # HH:MM or HH:MM:SS (24h)
TIME_12H: str = (
    r"(?:0?[1-9]|1[0-2]):[0-5]\d(?::[0-5]\d)?\s*[AaPp][Mm]"  # 12-hour with AM/PM
)
DATE_JP: str = (
    r"\d{4}年(?:0?[1-9]|1[0-2])月(?:0?[1-9]|[12]\d|3[01])日"  # YYYY年MM月DD日
)
DATE_SLASH: str = (
    r"\d{2,4}/(?:0?[1-9]|1[0-2])/(?:0?[1-9]|[12]\d|3[01])"  # YYYY/MM/DD or YY/MM/DD
)

# =============================================================================
# 3. Numbers & Currency
# =============================================================================

INTEGER: str = r"-?\d+"  # optional sign + digits
DECIMAL: str = r"-?\d+\.\d+"  # decimal number
SIGNED_NUMBER: str = r"[+\-]?\d+(?:\.\d+)?(?:[eE][+\-]?\d+)?"  # int/float/scientific
HEX_COLOR: str = r"#(?:[0-9a-fA-F]{3}){1,2}"  # #RGB or #RRGGBB
HEX_NUMBER: str = r"0[xX][0-9a-fA-F]+"  # 0x prefix hex
CURRENCY_USD: str = r"\$[\d,]+(?:\.\d{2})?"  # $1,234.56
CURRENCY_JPY: str = r"[¥￥][\d,]+"  # ¥1,234 or ￥1,234
COMMA_NUMBER: str = r"\d{1,3}(?:,\d{3})+"  # 1,000 or 1,000,000

# =============================================================================
# 4. Identifiers & Code
# =============================================================================

UUID: str = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"  # UUID, any version (8-4-4-4-12 hex)
SEMVER: str = r"(?<!\d)\d+\.\d+\.\d+(?:-[a-zA-Z0-9.]+)?(?:\+[a-zA-Z0-9.]+)?"  # Semantic versioning; (?<!\d) keeps long digit runs linear
SNAKE_CASE: str = r"[a-z][a-z0-9]*(?:_[a-z0-9]+)+"  # snake_case identifier
CAMEL_CASE: str = r"[a-z][a-zA-Z0-9]*(?:[A-Z][a-z0-9]+)+"  # camelCase identifier
BASE64: str = r"[A-Za-z0-9+/]{4,}(?:={0,2})"  # Base64 encoded string (broad match — false positives expected)
JWT: str = r"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"  # JSON Web Token
SHA256_HEX: str = (
    r"(?<![0-9a-fA-F])[0-9a-fA-F]{64}(?![0-9a-fA-F])"  # SHA-256 hex digest
)
MD5_HEX: str = r"(?<![0-9a-fA-F])[0-9a-fA-F]{32}(?![0-9a-fA-F])"  # MD5 hex digest (not a slice of a SHA-256)

# =============================================================================
# 5. Files & Paths
# =============================================================================

FILE_EXT: str = r"\.[a-zA-Z0-9]{1,10}"  # file extension (.py, .tar.gz last part)
UNIX_PATH: str = r"/(?:[a-zA-Z0-9._\-]+/)*[a-zA-Z0-9._\-]+"  # /usr/local/bin/python
WINDOWS_PATH: str = (
    r"[a-zA-Z]:\\(?:[^\\\/:*?\"<>|\r\n]+\\)*[^\\\/:*?\"<>|\r\n]*"  # C:\Users\file.txt
)
IMAGE_EXT: str = (
    r"\.(?:jpe?g|png|gif|bmp|svg|webp|ico|tiff?)"  # common image extensions
)
VIDEO_EXT: str = r"\.(?:mp4|avi|mkv|mov|wmv|flv|webm|m4v)"  # common video extensions

# =============================================================================
# 6. Whitespace & Text
# =============================================================================

WHITESPACE_RUNS: str = r"[\s]+"  # one or more whitespace chars
BLANK_LINE: str = r"^\s*$"  # blank or whitespace-only line (use MULTILINE)
LEADING_WHITESPACE: str = r"^[ \t]+"  # leading spaces/tabs (use MULTILINE)
TRAILING_WHITESPACE: str = r"[ \t]+$"  # trailing spaces/tabs (use MULTILINE)
DOUBLE_SPACES: str = r" {2,}"  # two or more consecutive spaces
MARKDOWN_HEADING: str = r"^#{1,6}\s+.+"  # Markdown heading (use MULTILINE)
MARKDOWN_LINK: str = r"\[([^\]]+)\]\(([^)]+)\)"  # [text](url)
MARKDOWN_IMAGE: str = r"!\[([^\]]*)\]\(([^)]+)\)"  # ![alt](url)

# =============================================================================
# 7. Japanese
# =============================================================================

CJK_CHARS: str = r"[\u4e00-\u9fff\u3400-\u4dbf\u3005-\u3007]+"  # CJK Unified Ideographs (common + ext-A) + 々〆〇 (U+3005-U+3007)
HIRAGANA: str = r"[\u3040-\u309f]+"  # Hiragana block
KATAKANA: str = r"[\u30a0-\u30ff]+"  # Katakana block
KATAKANA_HW: str = r"[\uff65-\uff9f]+"  # Half-width Katakana
FULL_WIDTH_ASCII: str = r"[\uff01-\uff5e]+"  # Full-width ASCII variants (！-～)
PHONE_JP: str = r"0\d{1,4}-\d{1,4}-\d{3,4}"  # Japanese phone (0X-XXXX-XXXX variants)
JP_POSTAL: str = r"(?<![\d-])\d{3}-\d{4}(?![\d-])"  # Japanese postal code (NNN-NNNN), not a piece of a phone number
JP_YEAR_ERA: str = (
    r"(?:令和|平成|昭和|大正|明治)[元\d]{1,2}年"  # Japanese era year (令和5年 etc.)
)

# =============================================================================
# 8. Validation (anchored — use for full-string matching)
# =============================================================================
# \A...\Z, not ^...$: in Python, $ also matches just before a final "\n", so
# re.match(r"^...$", "alice@example.com\n") succeeds. (re.fullmatch with the
# unanchored pattern is the other safe spelling.)

EMAIL_STRICT: str = (
    r"\A[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}\Z"  # full-string email
)
IPV4_STRICT: str = r"\A(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\Z"  # full-string IPv4
UUID_STRICT: str = r"\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\Z"  # RFC 9562 UUID, versions 1-8
ISO_DATE_STRICT: str = (
    r"\A\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])\Z"  # full-string YYYY-MM-DD
)
PHONE_JP_STRICT: str = r"\A0\d{1,4}-\d{1,4}-\d{3,4}\Z"  # full-string JP phone
JP_POSTAL_STRICT: str = r"\A\d{3}-\d{4}\Z"  # full-string JP postal code
