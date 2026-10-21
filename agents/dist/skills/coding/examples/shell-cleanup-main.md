# Shell worked examples: cleanup and main

Examples 4 and 5 and the Pitfalls list of the shell worked examples:
cleanup with trap, the `main` function that assembles the script, and common mistakes.

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
