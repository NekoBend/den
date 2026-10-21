# Shell language reference

Shell-specific conventions for the `coding` skill.
Layered on top of `architecture.md` (12 generic rules).
When both apply, this file refines or specializes the generic rule.
Never contradict.

Shell scripts target Bash
unless the project requires POSIX sh compatibility.
Section 13 governs which Bash version features are admissible.

## Where each section lives

This file holds sections 1, 3, 4, 5, 6, and 13.

- shared/reference/shell-structure.md (sections 2, 7, 9, 10, 11, and 12): read it now as well.
- shared/reference/shell-security.md (sections 8 and 14): read it now as well.

"section N" in any of these files means the section with that number;
this list names the file that holds it.

## 1. Style guide: Google Shell Style Guide

**Rule:** Follow the Google Shell Style Guide
(`google.github.io/styleguide/shellguide.html`) as the baseline.
**Why:** The Google guide is the most comprehensive published shell style reference.
It covers naming, quoting, function declarations, error handling,
and when to stop using shell
(the guide recommends: if the script exceeds ~100 lines, rewrite in Python or another language).

## 3. Tooling: shellcheck + shfmt

**Rule:** Default linter is `shellcheck`.
Default formatter is `shfmt` with Google-compatible options (`shfmt -i 2 -ci -s`).
Both run in CI.
**Why:** `shellcheck` catches quoting bugs, deprecated syntax, portability issues,
and common logic errors.
`shfmt` enforces consistent indentation (2 spaces), case indent (`-ci`),
and simplification (`-s`).
Together they are the shell equivalent of `ruff` + `gofmt`.
**Run order:** `shfmt -w .` then `shellcheck *.sh`.

## 4. Naming

**Rule:**

- Functions: `snake_case` (lowercase with underscores).
- Local variables inside functions: `snake_case`, declared with `local`.
- Global/environment variables and constants: `UPPER_SNAKE_CASE`.
- Script filenames: `kebab-case` or `snake_case`,
  always with `.sh` extension (or no extension for installed executables).
- No `camelCase` or `PascalCase` anywhere in shell scripts.

**Why:** The Google Shell Style Guide codifies these patterns.
`local` prevents accidental pollution of the global scope,
which is the default in Bash.
`UPPER_SNAKE` for globals matches the POSIX environment variable convention
(`PATH`, `HOME`, `LANG`).
**Example:**

```bash
readonly MAX_RETRIES=5
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/myapp"

fetch_customer_order() {
  local order_id="$1"
  # ...
}
```

## 5. Variable quoting and expansion

**Rule:** Always double-quote variable expansions:
`"$var"`, `"${var}"`, `"$(command)"`, `"${array[@]}"`.
The ONLY exception is inside `[[ ]]` on the left-hand side of `=~` (regex match),
where quoting changes semantics.

**Why:** Unquoted variables undergo word splitting and pathname (glob) expansion.
A filename with spaces or a variable containing `*` silently breaks an unquoted expansion.
This is the single most common class of shell bugs
and the most frequently flagged by shellcheck (SC2086).
**Example:**

```bash
local file="$1"
if [[ -f "$file" ]]; then
  wc -l "$file"
fi

# Iterate array elements safely:
for item in "${items[@]}"; do
  process "$item"
done
```

## 6. Bash version features

**Rule:** Use the highest-version form admissible by the target Bash version (see section 13).
Common version-gated features:

| Bash | Feature | Legacy alternative |
|---|---|---|
| 3.2+ | `[[ ]]` extended test | `[ ]` with quoting gymnastics |
| 4.0+ | associative arrays (`declare -A`) | key=value parsing hacks |
| 4.0+ | `&>>` append both stdout and stderr | `>> file 2>&1` |
| 4.3+ | nameref (`declare -n`) | `eval` for indirect variables |
| 4.4+ | `${var@Q}` quoted expansion | manual quote escaping |

**Why:** Newer Bash features replace fragile `eval`-based workarounds with safe built-in syntax.
Associative arrays and namerefs in particular eliminate patterns
that are prone to injection.
**Defer to section 13** before applying.

## 13. Version and portability awareness

**Rule:** Before proposing Bash-specific features (sections 5, 6, 11),
check the target environment:

- Shebang (`#!/usr/bin/env bash` vs `#!/bin/sh`):
  if `sh`, restrict to POSIX syntax (no `[[ ]]`, no arrays, no `local` in POSIX strict mode).
- Bash version: macOS ships Bash 3.2 (2007) due to GPLv3 licensing.
  If the script targets macOS without Homebrew Bash,
  do not use Bash 4+ features (associative arrays, namerefs, `mapfile`).
- Alpine/BusyBox: `/bin/sh` is `ash`, not Bash.
  Bash must be explicitly installed.

**Why:** Assuming Bash 5 on a macOS CI runner or an Alpine container without Bash installed
produces a confusing runtime failure.
Checking the shebang and the target platform before proposing features prevents portability breaks.
**When unknown:** ask the user for the target shell and platform before proposing Bash-specific syntax.
