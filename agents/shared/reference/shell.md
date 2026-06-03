# Shell language reference

Shell-specific conventions for the `coding` skill.
Layered on top of `architecture.md` (12 generic rules).
When both apply, this file refines or specializes the generic rule.
Never contradict.

Shell scripts target Bash
unless the project requires POSIX sh compatibility.
Section 13 governs which Bash version features are admissible.

## 1. Style guide: Google Shell Style Guide

**Rule:** Follow the Google Shell Style Guide
(`google.github.io/styleguide/shellguide.html`) as the baseline.
**Why:** The Google guide is the most comprehensive published shell style reference.
It covers naming, quoting, function declarations, error handling,
and when to stop using shell
(the guide recommends: if the script exceeds ~100 lines, rewrite in Python or another language).

## 2. Comments: header block and inline

**Rule:** Every script starts with a description block immediately after the shebang:

```bash
#!/usr/bin/env bash
# Brief one-line description of what this script does.
#
# Usage:
#   script_name [options] <args>
#
# Dependencies: jq, curl
```

Use `#` comments to explain WHY, not WHAT.
Functions get a one-line description above the declaration.
**Why:** Shell scripts are often run by people who did not write them.
The header block is the first thing they read.
Documenting dependencies prevents "command not found" surprises.

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

## 7. Strict mode: set -euo pipefail

**Rule:** Every script starts with:

```bash
set -euo pipefail
```

- `-e`: exit on any command failure.
- `-u`: exit on undefined variable reference.
- `-o pipefail`: a pipeline fails if any command in it fails.

Known caveats: `-e` does not trigger inside command substitutions on older Bash,
and it does not catch failures in commands before `&&` or `||`.
Test exit codes explicitly when these patterns appear.

**Why:** Without strict mode, a failing command in the middle of a script is silently ignored
and the script continues with stale or missing data.
Strict mode turns silent corruption into an immediate, diagnosable failure.

## 8. Signal handling and cleanup: trap

**Rule:** Register a cleanup function with `trap` for any script
that creates temporary files, acquires locks, or starts background processes:

```bash
cleanup() {
  rm -f "$tmp_file"
}
trap cleanup EXIT
```

Use `trap ... EXIT` (not `trap ... ERR`) so cleanup runs on both success and failure.
For more granular control, trap `INT` and `TERM` separately.

**Why:** Without `trap EXIT`, a script killed by Ctrl-C or a pipeline error
leaves temporary files, held locks, and orphaned background processes behind.
`EXIT` is the catch-all that fires regardless of how the script ends.

## 9. Script structure

**Rule:** Organize scripts in this order:

1. Shebang (`#!/usr/bin/env bash`)
2. Script-level comment block (section 2)
3. `set -euo pipefail`
4. Constants (`readonly`)
5. Function definitions
6. `main` function
7. `main "$@"` call at the bottom

Wrap logic in a `main()` function rather than running at the top level.
This prevents variables from leaking into the global scope
and makes the script testable (functions can be sourced without executing `main`).

**Why:** The `main "$@"` pattern is the shell equivalent of Python's `if __name__ == "__main__"`.
It keeps the script importable by other scripts via `source` without side effects.

## 10. Error handling: exit codes and stderr

**Rule:** Write error messages to stderr (`>&2`), not stdout.
Use meaningful exit codes: 0 for success, 1 for general errors, 2 for usage errors.
When wrapping other commands, preserve their exit code or document why you override it.

**Why:** stdout carries the script's data output (consumed by pipes and command substitution).
Mixing errors into stdout corrupts the data stream.
Callers check `$?` to decide what happened;
a meaningful exit code lets them react without parsing error messages.
**Example:**

```bash
die() {
  echo "error: $*" >&2
  exit 1
}

fetch_customer_order() {
  local order_id="$1"
  local response
  response="$(curl -sf "https://api.example.com/orders/${order_id}")" \
    || die "failed to fetch customer order ${order_id}"
  echo "$response"
}
```

## 11. Idiomatic patterns

**Rule:** Prefer Bash's native idioms over manual equivalents:

- **`[[ ]]`** over `[ ]` for tests
  (no word splitting, supports `=~`, `&&`, `||` inside the brackets).
- **`$(command)`** over backticks for command substitution (nestable, more readable).
- **Parameter expansion** (`${var:-default}`, `${var:?error}`, `${var%suffix}`, `${var#prefix}`)
  over `sed`/`awk` for simple string manipulation.
- **`printf`** over `echo` for output that may contain escape sequences or leading dashes.
- **`mapfile` / `readarray`** (Bash 4+) for reading lines into an array
  instead of `while read` loops with manual appending.
- **Here-strings (`<<<`)** over `echo "$var" | command` to avoid a subshell.

**Why:** See architecture.md section 12 (Idiomatic over portable).
Shell idioms avoid subshell overhead and quoting pitfalls inherent in pipe-based alternatives.
**Example:**

```bash
local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
local base="${filename%.*}"

if [[ "$status" =~ ^(shipped|delivered)$ ]]; then
  printf "Order %s is complete.\n" "$order_id"
fi
```

## 12. Validation at script entry

**Rule:** Validate arguments and required environment variables at the top of `main()`
before any work begins.
Use `${VAR:?message}` for required environment variables.
Print a usage message and exit 2 on invalid arguments.

**Why:** See architecture.md section 9 (Validate at boundaries, trust internals).
The script's entry point is the boundary;
internal functions trust that arguments have already been checked.
Failing early with a clear message saves the user from cryptic errors deep in the script.
**Example:**

```bash
main() {
  local order_id="${1:?usage: $(basename "$0") <order_id>}"
  readonly API_BASE="${API_BASE:?API_BASE environment variable is required}"

  local result
  result="$(fetch_customer_order "$order_id")"
  echo "$result"
}
```

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

## 14. Security: injection and temp files

**Rule:**

- Never use `eval` with user-supplied input.
  If indirect variable access is needed, use nameref (`declare -n`, Bash 4.3+) instead.
- Always quote variables in command arguments (section 5).
  An unquoted variable containing `; rm -rf /` is a command injection.
- Create temporary files with `mktemp`, not hardcoded paths in `/tmp`.
  Register cleanup via `trap EXIT` (section 8).
- Do not store secrets in command-line arguments (visible in `ps aux`).
  Use environment variables or files with restricted permissions.

**Why:** Shell scripts run with the user's full privileges.
Unquoted expansions, `eval`, and predictable temp paths
are the shell equivalents of SQL injection, XSS, and race conditions.
`shellcheck` flags many of these patterns, but not all;
the rules above are defense in depth.
**Example:**

```bash
# Safe temp file with cleanup:
tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

# Safe indirect variable (Bash 4.3+, no eval):
declare -n ref="$var_name"
echo "${ref}"
```
