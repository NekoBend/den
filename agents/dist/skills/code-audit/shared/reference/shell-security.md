# Shell reference: cleanup and security

Sections 8 and 14 of the shell reference:
cleanup with trap, and security against injection and unsafe temp files.
shared/reference/shell.md lists where every section lives.

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

## 14. Security: injection and temp files

**Rule:**

- Never use `eval` with user-supplied input.
  To store or look up a value under a name that comes from input,
  key an associative array with it (`declare -A`, Bash 4.0+):
  `map[$key]=value`, `"${map[$key]}"` and `${map[$key]+set}` use the key as data.
  `unset` expands the key a second time, so single-quote its argument (`unset 'map[$key]'`);
  before Bash 5.2, `[[ -v ]]` and `(( ))` expand it twice too,
  so test with `${map[$key]+set}` and do arithmetic on a copy (`n=${map[$key]:-0}`).
- A nameref (`declare -n`), `printf -v`, or `${!name}` runs code hidden in an array subscript
  inside the name (`x[$(cmd)]` runs `cmd`).
  Use one on a name from input only after checking the name against `^[A-Za-z_][A-Za-z0-9_]*$`,
  and give it a fixed prefix (`cfg_$name`) so the input cannot name `PATH` or `IFS`.
- Always quote variables in command arguments (shell.md section 5).
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

# Value stored under a name that comes from input (Bash 4.0+, no eval):
declare -A settings=()
settings[$key]="$value"
printf '%s\n' "${settings[$key]-}"

# Variable named by input, checked and prefixed first (Bash 4.3+):
if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  printf 'invalid name: %s\n' "$name" >&2
  exit 1
fi
declare -n ref="cfg_$name"
printf '%s\n' "${ref-}"
```
