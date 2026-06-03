# Regex Syntax Cheatsheet

> Python `re` module syntax. Always use **raw strings** (`r"..."`) for patterns.

---

## 1. Metacharacters

| Syntax | Description                      | Example       | Matches       |
|--------|----------------------------------|---------------|---------------|
| `.`    | Any char except newline (`\n`)   | `r"a.c"`      | `abc`, `a1c`  |
| `\`    | Escape metacharacter             | `r"\."`       | literal `.`   |
| `\|`   | Alternation (OR)                 | `r"cat\|dog"` | `cat`, `dog`  |
| `()`   | Group / capture                  | `r"(ab)+"`    | `ab`, `abab`  |
| `[]`   | Character class                  | `r"[aeiou]"`  | `a`, `e`, `i` |

---

## 2. Character Classes

| Syntax        | Description                   | Equivalent                       |
|---------------|-------------------------------|----------------------------------|
| `[abc]`       | Any of `a`, `b`, `c`          | -                                |
| `[^abc]`      | Any char except `a`, `b`, `c` | -                                |
| `[a-z]`       | Lowercase letter range        | -                                |
| `[a-zA-Z0-9]` | Alphanumeric                  | -                                |
| `\d`          | Digit                         | `[0-9]` (with `re.ASCII`)        |
| `\D`          | Non-digit                     | `[^0-9]`                         |
| `\w`          | Word character                | `[a-zA-Z0-9_]` (with `re.ASCII`) |
| `\W`          | Non-word character            | `[^a-zA-Z0-9_]`                  |
| `\s`          | Whitespace                    | `[ \t\n\r\f\v]`                  |
| `\S`          | Non-whitespace                | `[^ \t\n\r\f\v]`                 |

> **Note:** Without `re.ASCII`, `\d`, `\w`, `\s` match Unicode characters (e.g. `\d` matches `٣`).

---

## 3. Quantifiers

| Syntax  | Description        | Example      | Matches             |
|---------|--------------------|--------------|---------------------|
| `*`     | 0 or more (greedy) | `r"ab*"`     | `a`, `ab`, `abbb`   |
| `+`     | 1 or more (greedy) | `r"ab+"`     | `ab`, `abbb`        |
| `?`     | 0 or 1 (greedy)    | `r"colou?r"` | `color`, `colour`   |
| `{n}`   | Exactly n          | `r"\d{4}"`   | `2026`              |
| `{n,}`  | n or more          | `r"\d{2,}"`  | `12`, `123`, `1234` |
| `{n,m}` | Between n and m    | `r"\d{2,4}"` | `12`, `123`, `1234` |

### Greedy vs Lazy

| Greedy  | Lazy     | Behaviour                |
|---------|----------|--------------------------|
| `*`     | `*?`     | Match as few as possible |
| `+`     | `+?`     | Match as few as possible |
| `?`     | `??`     | Match as few as possible |
| `{n,m}` | `{n,m}?` | Match as few as possible |

```xml
Input:  "<b>bold</b>"
Greedy: r"<.+>"   → "<b>bold</b>"  (one match, longest)
Lazy:   r"<.+?>"  → "<b>", "</b>"  (two matches, shortest each)
```

---

## 4. Anchors & Boundaries

| Syntax | Description                                   | Notes                                    |
|--------|-----------------------------------------------|------------------------------------------|
| `^`    | Start of string (or line with `re.MULTILINE`) | -                                        |
| `$`    | End of string (or line with `re.MULTILINE`)   | -                                        |
| `\A`   | Start of string (always)                      | Ignores `re.MULTILINE`                   |
| `\Z`   | End of string (always)                        | Ignores `re.MULTILINE`                   |
| `\b`   | Word boundary                                 | `r"\bword\b"` matches `word` not `sword` |
| `\B`   | Non-word boundary                             | `r"\Bword"` matches `sword` not `word`   |

---

## 5. Groups & Capturing

| Syntax          | Description            | Example                                    |
|-----------------|------------------------|--------------------------------------------|
| `(...)`         | Capturing group        | `r"(foo)(bar)"` -> `\1`=`foo`, `\2`=`bar`  |
| `(?:...)`       | Non-capturing group    | `r"(?:foo)bar"` - groups without capturing |
| `(?P<name>...)` | Named group            | `r"(?P<year>\d{4})"` -> `m.group("year")`  |
| `(?P=name)`     | Named backreference    | `r"(?P<w>\w+) (?P=w)"` matches `the the`   |
| `\1`, `\2`      | Numbered backreference | `r"(\w+) \1"` matches `the the`            |
| `(?#...)`       | Inline comment         | `r"foo(?# this is a comment)bar"`          |

---

## 6. Lookahead & Lookbehind

| Syntax     | Name                | Description         | Example         | Matches               |
|------------|---------------------|---------------------|-----------------|-----------------------|
| `(?=...)`  | Positive lookahead  | Followed by ...     | `r"\w+(?=@)"`   | `user` in `user@host` |
| `(?!...)`  | Negative lookahead  | NOT followed by ... | `r"foo(?!bar)"` | `foo` in `foobaz`     |
| `(?<=...)` | Positive lookbehind | Preceded by ...     | `r"(?<=@)\w+"`  | `host` in `user@host` |
| `(?<!...)` | Negative lookbehind | NOT preceded by ... | `r"(?<!un)do"`  | `do` in `doable`      |

> **Note:** Lookbehinds must be **fixed-width** in Python — no `*`, `+`, or `{n,m}` inside.

---

## 7. Flags

| Flag Constant   | Inline | Effect                                     |
|-----------------|--------|--------------------------------------------|
| `re.IGNORECASE` | `(?i)` | Case-insensitive matching                  |
| `re.MULTILINE`  | `(?m)` | `^`/`$` match at line boundaries           |
| `re.DOTALL`     | `(?s)` | `.` matches `\n` too                       |
| `re.VERBOSE`    | `(?x)` | Allow whitespace & `#` comments in pattern |
| `re.ASCII`      | `(?a)` | `\w`, `\d`, `\s` match ASCII only          |
| `re.UNICODE`    | `(?u)` | Unicode matching (default in Python 3)     |

Combine with `|`: `re.IGNORECASE | re.MULTILINE`

Inline at pattern start: `r"(?im)^hello"` — case-insensitive + multiline.

---

## 8. Common Pitfalls

| Pitfall                   | Problem                                     | Fix                                                            |
|---------------------------|---------------------------------------------|----------------------------------------------------------------|
| Greedy by default         | `r"<.+>"` matches too much                  | Use lazy `r"<.+?>"` or negated class `r"<[^>]+>"`              |
| Catastrophic backtracking | `r"(a+)+"` on `"aaaaab"` - exponential time | Use atomic patterns or possessive-style rewrites               |
| `re.match` vs `re.search` | `re.match` only checks start of string      | Use `re.search` for anywhere, `re.fullmatch` for entire string |
| Missing raw string        | `"\b"` is backspace, not word boundary      | Always use `r"\b"`                                             |
| `^`/`$` in multiline      | Default: match string start/end only        | Add `re.MULTILINE` or use `\A`/`\Z` explicitly                 |
| Character class escaping  | `[` inside `[]` needs escaping              | Use `r"[\[\]]"` or place `]` first: `r"[][]"`                  |
| Empty alternation         | `r"(foo\|)"` matches empty string           | Ensure alternation branches are non-empty, or use `?`          |
