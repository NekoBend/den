# Shell reference: script structure

Sections 2, 7, 9, 10, 11, and 12 of the shell reference:
comments, strict mode, script structure, error handling, idiomatic patterns, and validation at script entry.
shared/reference/shell.md lists where every section lives.

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
