# Shell worked examples

Worked examples demonstrating the rules in `shared/reference/shell.md` and the files it lists.
The shared domain is a small order-management CLI:
a script that fetches customer orders from an HTTP API and reports on them.
Each block is a fragment illustrating two or three rules.
Cross-references in the prose point to the corresponding `shared/reference/shell.md` section
unless they name another reference file.

Code in these blocks contains only natural comments
(the kind a real developer writes for non-obvious WHY).
Instructional / meta comments belong in this prose, never in the code.

## Where each example lives

- examples/shell-cleanup-main.md (Examples 4 and 5 and the Pitfalls list): read it after this file.

Compare your code against every file you read.

## 1. Script header and strict mode

This block demonstrates shared/reference/shell-structure.md section 2 (header block),
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
The header block documents usage, environment, and dependencies (shell-structure.md section 2):
the first thing a reader needs.

`set -euo pipefail` enables strict mode (shell-structure.md section 7):
the script exits on any command failure, undefined variable, or pipeline failure.
`API_BASE` is validated immediately with `${VAR:?message}` (shell-structure.md section 12):
if it is unset, the script exits with a clear message before doing any work.

## 2. Functions, locals, and error handling

This block demonstrates shared/reference/shell.md section 4 (naming, `local`),
section 5 (quoting), and shell-structure.md section 10 (stderr and exit codes).

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

`die` writes to stderr with `>&2` and exits non-zero (shell-structure.md section 10):
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
shell-structure.md section 11 (parameter expansion, `printf`), and section 12 (entry validation).

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
It validates that at least one ID was given before doing work (shell-structure.md section 12).

`summarize_order` uses a here-string (`<<<"$json"`) to feed jq without a subshell pipe
(shell-structure.md section 11),
and `printf` instead of `echo` for output with an explicit format (shell-structure.md section 11),
which is safer for values that might begin with a dash.
