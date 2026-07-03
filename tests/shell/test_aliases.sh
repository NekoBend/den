#!/usr/bin/env bash
# test_aliases.sh — den's short command names must WIN over PowerShell's built-in
# aliases (an alias outranks a function in pwsh command resolution). den removes the
# conflicting builtin aliases in three places (aliases.ps1: gc/gcm/gl/gps/gu,
# functions.ps1: cd, wrappers.ps1: ls/cat + Windows-only cp/mv/rm). This guards that
# those removals actually work, so a future addition/rename cannot silently let a
# builtin shadow den's function. pwsh-only; runs on the Linux CI pwsh, where these
# cmdlet aliases (gc/gl/gps/gu/cd) still exist -- ls/cat are wrappers that must also
# resolve to a Function. (The Windows-only cp/mv/rm collisions are covered by the
# windows CI job's pwsh smoke.)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

P="$DOTFILES/shell/pwsh"
HELPERS_PS1="$P/_helpers.ps1"

echo "================================================"
echo "  Testing pwsh alias-collision handling"
echo "================================================"

if ! command -v pwsh >/dev/null 2>&1; then
    echo "pwsh not found; skipping alias tests"
    print_summary "test_aliases"
    [ "$FAIL" -eq 0 ]
    return 0 2>/dev/null || exit 0
fi

# Source the chain that defines + de-shadows the wrappers/aliases (order matters:
# _helpers -> wrappers -> coreutils -> functions -> aliases), then check each name
# whose builtin pwsh alias exists on Linux resolves to den's Function, not an Alias.
echo "[pwsh] den commands resolve to functions, not builtin aliases"
actual=$(run_pwsh "$HELPERS_PS1" "
    . '$P/wrappers.ps1'
    . '$P/coreutils.ps1'
    . '$P/functions.ps1'
    . '$P/aliases.ps1'
    \$names = 'g', 'gc', 'gcm', 'gl', 'gps', 'gu', 'cd', 'ls', 'cat', 'grep', 'find'
    \$bad = @()
    foreach (\$n in \$names) {
        \$c = Get-Command \$n -ErrorAction SilentlyContinue
        if (\$null -eq \$c) { \$bad += \"\$n:MISSING\" }
        elseif (\$c.CommandType -ne 'Function') { \$bad += \"\$n:\$(\$c.CommandType)\" }
    }
    if (\$bad.Count) { 'SHADOWED ' + (\$bad -join ' ') } else { 'OK' }
" | tr -d '\r')
assert_eq "pwsh/den commands are functions (not shadowed)" "OK" "$actual"

print_summary "test_aliases"
[ "$FAIL" -eq 0 ]
