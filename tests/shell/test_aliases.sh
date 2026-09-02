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
#
# run_pwsh uses `pwsh -NonInteractive -Command`, which the _DenInteractive gate
# treats as non-interactive, so set _DEN_FORCE_INTERACTIVE=1 to load the gated
# wrappers.ps1/coreutils.ps1/aliases.ps1. This test cannot pass silently if they did
# NOT load: the builtin `gc`/`gl`/... would remain Aliases (and `ls`/`cat` would
# resolve to the native Application), which the assert rejects.
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
    \$env:_DEN_FORCE_INTERACTIVE = '1'
    . '$P/wrappers.ps1'
    . '$P/coreutils.ps1'
    . '$P/functions.ps1'
    . '$P/aliases.ps1'
    \$names = 'g', 'gc', 'gcm', 'gl', 'gps', 'gu', 'cd', 'ls', 'cat', 'grep', 'find'
    \$bad = @()
    foreach (\$n in \$names) {
        \$c = Get-Command \$n -ErrorAction SilentlyContinue
        if (\$null -eq \$c) { \$bad += (\$n + ':MISSING') }
        elseif (\$c.CommandType -ne 'Function') { \$bad += (\$n + ':' + \$c.CommandType) }
    }
    if (\$bad.Count) { 'SHADOWED ' + (\$bad -join ' ') } else { 'OK' }
" | tr -d '\r')
assert_eq "pwsh/den commands are functions (not shadowed)" "OK" "$actual"

# =============================================================================
# code: cross-platform fallback (code-insiders -> code -> code.cmd)
# =============================================================================
# `code.cmd` is a Windows-only launcher name, so probing only that name left
# Linux/macOS pwsh with stable VS Code installed reporting "not installed".
# Stub executables on a throwaway PATH stand in for the real editors.
CODE_BIN="$WORK/code-bin"
CODE_EMPTY="$WORK/code-empty"
mkdir -p "$CODE_BIN" "$CODE_EMPTY"
cat > "$CODE_BIN/code" << 'STUB'
#!/bin/sh
echo "STUB-CODE $*"
STUB
chmod +x "$CODE_BIN/code"

echo "[pwsh] code falls back to stable code (no code-insiders installed)"
actual=$(run_pwsh "$HELPERS_PS1" "
    \$env:_DEN_FORCE_INTERACTIVE = '1'
    \$env:PATH = '$CODE_BIN'
    . '$P/aliases.ps1'
    code --version
" | tr -d '\r')
assert_contains "pwsh/code falls back to stable code" "STUB-CODE --version" "$actual"

cat > "$CODE_BIN/code-insiders" << 'STUB'
#!/bin/sh
echo "STUB-INSIDERS $*"
STUB
chmod +x "$CODE_BIN/code-insiders"

echo "[pwsh] code prefers code-insiders when both exist"
actual=$(run_pwsh "$HELPERS_PS1" "
    \$env:_DEN_FORCE_INTERACTIVE = '1'
    \$env:PATH = '$CODE_BIN'
    . '$P/aliases.ps1'
    code .
" | tr -d '\r')
assert_contains "pwsh/code prefers code-insiders" "STUB-INSIDERS ." "$actual"

echo "[pwsh] code warns when no editor is installed"
actual=$(run_pwsh "$HELPERS_PS1" "
    \$env:_DEN_FORCE_INTERACTIVE = '1'
    \$env:PATH = '$CODE_EMPTY'
    . '$P/aliases.ps1'
    code . 3>&1
" | tr -d '\r')
assert_contains "pwsh/code warns when absent" "VS Code is not installed" "$actual"

# =============================================================================
# _ShapeCmdArgs: what the Windows .cmd shim is handed
# =============================================================================
# The `code` branch that uses this only fires on Windows (a resolved .cmd/.bat
# launcher), and the Windows CI job runs a load smoke test only, so the shaping
# rules are covered here as a pure function: quote what PowerShell would pass
# bare (cmd does not split inside quotes), leave what it already quotes, double a
# trailing backslash, and refuse the two characters cmd re-parsing cannot be
# protected from (`"` ends a quoted run; `%VAR%` is substituted from the
# environment with no command-line escape).
shape_args() {
    run_pwsh "$HELPERS_PS1" "
        \$env:_DEN_FORCE_INTERACTIVE = '1'
        . '$P/aliases.ps1'
        $1
    " | tr -d '\r'
}

echo "[pwsh] _ShapeCmdArgs quoting rules"
actual=$(shape_args "(_ShapeCmdArgs @('plain.md')) -join '|'")
assert_eq "pwsh/_ShapeCmdArgs quotes a space-free argument" '"plain.md"' "$actual"

actual=$(shape_args "(_ShapeCmdArgs @('my file.md')) -join '|'")
assert_eq "pwsh/_ShapeCmdArgs leaves a whitespace argument alone" 'my file.md' "$actual"

actual=$(shape_args "(_ShapeCmdArgs @('C:\src\')) -join '|'")
assert_eq "pwsh/_ShapeCmdArgs doubles trailing backslashes" '"C:\src\\"' "$actual"

echo "[pwsh] _ShapeCmdArgs keeps an ampersand name in one argument"
actual=$(shape_args "\$r = _ShapeCmdArgs @('notes&evil&.md'); \"\$(\$r.Count):\$(\$r -join '|')\"")
assert_eq "pwsh/_ShapeCmdArgs & stays one quoted argument" '1:"notes&evil&.md"' "$actual"

actual=$(shape_args "\$r = _ShapeCmdArgs @('a.md', 'b c.md', 'd&e.md'); \"\$(\$r.Count):\$(\$r -join '|')\"")
assert_eq "pwsh/_ShapeCmdArgs keeps argument count and order" '3:"a.md"|b c.md|"d&e.md"' "$actual"

echo "[pwsh] _ShapeCmdArgs refuses what cmd re-parsing cannot survive"
actual=$(shape_args "try { \$null = _ShapeCmdArgs @('say\"hi.md'); 'NOTHROW' } catch { 'THREW: ' + \$_.Exception.Message }")
assert_contains "pwsh/_ShapeCmdArgs refuses a quote" "THREW: argument contains a quote" "$actual"

actual=$(shape_args "try { \$null = _ShapeCmdArgs @('a%USERPROFILE%b'); 'NOTHROW' } catch { 'THREW: ' + \$_.Exception.Message }")
assert_contains "pwsh/_ShapeCmdArgs refuses a percent sign" "THREW: argument contains a percent sign" "$actual"

# --- end to end through a stub .cmd launcher ---
CODE_CMD_BIN="$WORK/code-cmd-bin"
mkdir -p "$CODE_CMD_BIN"
cat > "$CODE_CMD_BIN/code.cmd" << 'STUB'
#!/bin/sh
printf 'STUB-CMD[%s]\n' "$*"
STUB
chmod +x "$CODE_CMD_BIN/code.cmd"

echo "[pwsh] code shapes arguments for a .cmd launcher"
actual=$(run_pwsh "$HELPERS_PS1" "
    \$env:_DEN_FORCE_INTERACTIVE = '1'
    \$env:PATH = '$CODE_CMD_BIN'
    . '$P/aliases.ps1'
    code 'notes&evil&.md'
" | tr -d '\r')
assert_contains "pwsh/code hands the shim one quoted argument" 'STUB-CMD["notes&evil&.md"]' "$actual"

echo "[pwsh] code refuses an argument cmd.exe would re-parse"
err=$(run_pwsh_stderr "$HELPERS_PS1" "
    \$env:_DEN_FORCE_INTERACTIVE = '1'
    \$env:PATH = '$CODE_CMD_BIN'
    . '$P/aliases.ps1'
    code 'a%USERPROFILE%b'
")
assert_contains "pwsh/code refuses a percent argument" "percent sign" "$err"
actual=$(run_pwsh "$HELPERS_PS1" "
    \$env:_DEN_FORCE_INTERACTIVE = '1'
    \$env:PATH = '$CODE_CMD_BIN'
    . '$P/aliases.ps1'
    code 'a%USERPROFILE%b' 2>\$null
" | tr -d '\r')
assert_not_contains "pwsh/code does not reach the shim when refusing" "STUB-CMD" "$actual"

print_summary "test_aliases"
[ "$FAIL" -eq 0 ]
