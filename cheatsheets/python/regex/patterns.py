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

EMAIL: str = r"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"  # RFC-ish email
URL: str = r"https?://[^\s<>\"')\]]+"  # HTTP/HTTPS URLs
DOMAIN: str = (
    r"(?:[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}"  # FQDN
)
IPV4: str = r"(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)"  # 0.0.0.0–255.255.255.255
IPV6: str = (
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
)  # common IPv6 forms (no embedded IPv4)
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

UUID: str = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"  # UUID v1-v5
SEMVER: str = (
    r"\d+\.\d+\.\d+(?:-[a-zA-Z0-9.]+)?(?:\+[a-zA-Z0-9.]+)?"  # Semantic versioning
)
SNAKE_CASE: str = r"[a-z][a-z0-9]*(?:_[a-z0-9]+)+"  # snake_case identifier
CAMEL_CASE: str = r"[a-z][a-zA-Z0-9]*(?:[A-Z][a-z0-9]+)+"  # camelCase identifier
BASE64: str = r"[A-Za-z0-9+/]{4,}(?:={0,2})"  # Base64 encoded string (broad match — false positives expected)
JWT: str = r"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"  # JSON Web Token
SHA256_HEX: str = r"[0-9a-fA-F]{64}"  # SHA-256 hex digest
MD5_HEX: str = r"[0-9a-fA-F]{32}"  # MD5 hex digest

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

CJK_CHARS: str = (
    r"[\u4e00-\u9fff\u3400-\u4dbf]+"  # CJK Unified Ideographs (common + ext-A)
)
HIRAGANA: str = r"[\u3040-\u309f]+"  # Hiragana block
KATAKANA: str = r"[\u30a0-\u30ff]+"  # Katakana block
KATAKANA_HW: str = r"[\uff65-\uff9f]+"  # Half-width Katakana
FULL_WIDTH_ASCII: str = r"[\uff01-\uff5e]+"  # Full-width ASCII variants (！-～)
PHONE_JP: str = r"0\d{1,4}-\d{1,4}-\d{3,4}"  # Japanese phone (0X-XXXX-XXXX variants)
JP_POSTAL: str = r"\d{3}-\d{4}"  # Japanese postal code (NNN-NNNN)
JP_YEAR_ERA: str = (
    r"(?:令和|平成|昭和|大正|明治)[元\d]{1,2}年"  # Japanese era year (令和5年 etc.)
)

# =============================================================================
# 8. Validation (anchored — use for full-string matching)
# =============================================================================

EMAIL_STRICT: str = (
    r"^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$"  # full-string email
)
IPV4_STRICT: str = r"^(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)$"  # full-string IPv4
UUID_STRICT: str = r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"  # RFC 4122 UUID
ISO_DATE_STRICT: str = (
    r"^\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])$"  # full-string YYYY-MM-DD
)
PHONE_JP_STRICT: str = r"^0\d{1,4}-\d{1,4}-\d{3,4}$"  # full-string JP phone
JP_POSTAL_STRICT: str = r"^\d{3}-\d{4}$"  # full-string JP postal code
