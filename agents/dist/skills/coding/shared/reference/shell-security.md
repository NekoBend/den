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
