# Shell worked examples

Worked examples demonstrating the rules in `shared/reference/shell.md`.
The shared domain is a small order-management CLI:
a script that fetches customer orders from an HTTP API and reports on them.
Each block is a fragment illustrating two or three rules.
Cross-references in the prose point to the corresponding `shared/reference/shell.md` section.

Code in these blocks contains only natural comments
(the kind a real developer writes for non-obvious WHY).
Instructional / meta comments belong in this prose, never in the code.

## 1. Script header and strict mode

This block demonstrates shared/reference/shell.md section 2 (header block),
section 7 (strict mode), and section 9 (script structure).

```bash
#!/usr/bin/env bash
# Fetch customer orders from the order service and print a summary.
#
# Usage:
#   fetch-orders.sh <order_id> [<order_id>...]
#
# Environment:
#   API_BASE   Base URL of the order service (required).
#
# Dependencies: curl, jq

set -euo pipefail

readonly API_BASE="${API_BASE:?API_BASE environment variable is required}"
```

The shebang uses `/usr/bin/env bash`
so the script runs against the `bash` found on `PATH` rather than a hardcoded `/bin/bash`
(reference section 13).
The header block documents usage, environment, and dependencies (reference section 2):
the first thing a reader needs.

`set -euo pipefail` enables strict mode (reference section 7):
the script exits on any command failure, undefined variable, or pipeline failure.
`API_BASE` is validated immediately with `${VAR:?message}` (reference section 12):
if it is unset, the script exits with a clear message before doing any work.

## 2. Functions, locals, and error handling

This block demonstrates shared/reference/shell.md section 4 (naming, `local`),
section 10 (stderr and exit codes), and section 5 (quoting).

```bash
# Print an error message to stderr and exit.
die() {
  echo "error: $*" >&2
  exit 1
}

# Fetch a single order by ID and echo its JSON to stdout.
fetch_order() {
  local order_id="$1"
  local response

  response="$(curl -sf "${API_BASE}/orders/${order_id}")" \
    || die "failed to fetch order ${order_id}"

  echo "$response"
}
```

`die` writes to stderr with `>&2` and exits non-zero (reference section 10):
error messages must not pollute stdout, which carries the script's data output.
`fetch_order` declares `order_id` and `response` as `local` (reference section 4)
so they do not leak into the global scope.

Every variable expansion is double-quoted
(`"${API_BASE}/orders/${order_id}"`, `"$response"`) per reference section 5:
the single most important rule for avoiding word-splitting bugs.
The `curl ... || die ...` pattern turns a failed request into a clear error
instead of a silent empty response (the `-f` flag makes curl fail on HTTP errors).

## 3. Iterating safely over arguments

This block demonstrates shared/reference/shell.md section 5 (array quoting),
section 11 (parameter expansion, `printf`), and section 12 (entry validation).

```bash
# Summarize one order's JSON: print "id: total" using jq.
summarize_order() {
  local json="$1"
  local id total
  id="$(jq -r '.id' <<<"$json")"
  total="$(jq -r '.total_cents' <<<"$json")"
  printf 'order %s: %s cents\n' "$id" "$total"
}

process_orders() {
  local order_ids=("$@")

  if [[ "${#order_ids[@]}" -eq 0 ]]; then
    die "no order IDs given"
  fi

  local id json
  for id in "${order_ids[@]}"; do
    json="$(fetch_order "$id")"
    summarize_order "$json"
  done
}
```

`process_orders` collects its arguments into the `order_ids` array
and iterates with `for id in "${order_ids[@]}"` (reference section 5):
the `"${array[@]}"` form quotes each element separately, so IDs are never word-split.
It validates that at least one ID was given before doing work (reference section 12).

`summarize_order` uses a here-string (`<<<"$json"`) to feed jq without a subshell pipe
(reference section 11),
and `printf` instead of `echo` for output with an explicit format (reference section 11),
which is safer for values that might begin with a dash.

## 4. Cleanup with trap

This block demonstrates shared/reference/shell.md section 8 (trap and cleanup)
and section 14 (safe temp files).

```bash
# Fetch all orders into a temp file, then report the total count.
report_orders() {
  local order_ids=("$@")
  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"' RETURN

  local id
  for id in "${order_ids[@]}"; do
    fetch_order "$id" >>"$tmp_file"
  done

  local count
  count="$(wc -l <"$tmp_file")"
  printf 'fetched %s orders\n' "$count"
}
```

`mktemp` creates the temp file with a unique, unpredictable name (reference section 14):
never a hardcoded `/tmp/orders.txt`, which is a symlink-attack and race-condition risk.
`trap 'rm -f "$tmp_file"' RETURN` registers cleanup that runs when the function returns,
on success or failure (reference section 8).

This example uses `RETURN` (function scope) rather than `EXIT` (script scope)
because the temp file is local to `report_orders`.
A script-level temp file would use `trap ... EXIT` at the top level.

## 5. main and script assembly

This block demonstrates shared/reference/shell.md section 9 (script structure, `main "$@"`).

```bash
main() {
  if [[ "$#" -eq 0 ]]; then
    die "usage: $(basename "$0") <order_id> [<order_id>...]"
  fi
  process_orders "$@"
}

main "$@"
```

`main` wraps the top-level logic and is the last thing called,
with `main "$@"` forwarding all script arguments (reference section 9).
This is the shell equivalent of Python's `if __name__ == "__main__"`:
it keeps the functions definable without executing them,
so the script can be sourced in tests (e.g., with Bats)
to test `fetch_order` and `summarize_order` in isolation.

The full script orders its parts as:
shebang, header, `set -euo pipefail`, `readonly` constants, function definitions, `main`,
then the `main "$@"` call (reference section 9).

## Pitfalls

Common mistakes that the rules in `shared/reference/shell.md` are designed to prevent.
Each is a real bug class that ships when the rule is forgotten.

- **Unquoted variable expansions.**
  `rm $file` with `file="a b.txt"` deletes `a` and `b.txt` separately;
  with `file="*"` it deletes everything.
  Always quote: `rm "$file"` (reference section 5).
  This is the most common and most dangerous shell bug.
- **Omitting `set -euo pipefail`.**
  Without it, a failed command in the middle of the script is ignored
  and execution continues with stale or empty data.
  Enable strict mode at the top (reference section 7).
- **Parsing `ls` output.**
  `for f in $(ls)` breaks on filenames with spaces or newlines.
  Use a glob (`for f in *.txt`) or `find ... -print0` with `read -d ''` (reference section 11).
- **Hardcoded `/tmp` paths.**
  A fixed temp path is predictable and exploitable (symlink attack, race condition).
  Use `mktemp` and clean up with `trap` (reference section 14 and 8).
- **`echo` with untrusted or dash-leading data.**
  `echo "$var"` mangles values beginning with `-` or containing escape sequences.
  Use `printf '%s\n' "$var"` (reference section 11).
- **Using `[ ]` where `[[ ]]` is safer.**
  Single-bracket test subjects unquoted variables to word splitting and lacks `&&`, `||`, and `=~`.
  Prefer `[[ ]]` in Bash (reference section 11).
- **`eval` on user input.**
  Passing user-controlled data to `eval` is arbitrary command execution.
  Use namerefs (`declare -n`) for indirection instead (reference section 14).
