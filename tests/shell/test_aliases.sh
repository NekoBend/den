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
# The git shortcuts that took over a cmdlet alias run only when typed
# =============================================================================
# gc, gcm, gl, gps and gu are also PowerShell's aliases for Get-Content,
# Get-Command, Get-Location, Get-Process and Get-Unique, which den removes so that
# its git shortcuts win at the prompt. Scripts and modules run from the session
# used to get the shortcuts too: `gps | Sort-Object CPU` pushed to the remote and
# `(gcm tool).Source` made a commit. Now only a command typed at the prompt gets
# den's version; a script or a module gets the cmdlet. A stub git logs each call.
GIT_BIN="$WORK/git-bin"
mkdir -p "$GIT_BIN"
cat > "$GIT_BIN/git" << STUB
#!/bin/sh
echo "git \$*" >> '$WORK/git-calls.log'
echo "STUB-GIT \$*"
STUB
chmod +x "$GIT_BIN/git"
printf 'from the file\n' > "$WORK/config.txt"
cat > "$WORK/use-git-aliases.ps1" << 'PS1'
"gps: $((gps -Id $PID).GetType().Name)"
"gcm: $((gcm Get-Date).CommandType)"
"gl: $((gl).GetType().Name)"
"gc: $(gc -LiteralPath $args[0])"
"gu: $(('b', 'a', 'a' | Sort-Object | gu) -join ',')"
PS1
printf '%s\n' 'function Find-Tool([string]$Name) { "module gcm: $((gcm $Name).CommandType)" }' > "$WORK/finder.psm1"
GIT_PATH="$GIT_BIN:/usr/bin:/bin"

echo "[pwsh] gc/gcm/gl/gps/gu in a script or a module are the cmdlets"
rm -f "$WORK/git-calls.log"
actual=$(run_pwsh_den "\$env:PATH = '$GIT_PATH'" "
    & '$WORK/use-git-aliases.ps1' '$WORK/config.txt'
    Import-Module '$WORK/finder.psm1'
    Find-Tool Get-Date
" 2>&1 | tr -d '\r')
assert_eq "pwsh/git shortcut names in a script and a module" "gps: Process
gcm: Cmdlet
gl: PathInfo
gc: from the file
gu: a,b
module gcm: Cmdlet" "$actual"
assert_eq "pwsh/a script and a module ran no git" "" "$(cat "$WORK/git-calls.log" 2>/dev/null)"

echo "[pwsh] gps and gcm typed at the prompt are still git's"
rm -f "$WORK/git-calls.log"
actual=$(run_pwsh_den "\$env:PATH = '$GIT_PATH'" "gps origin main; gcm 'a message'" 2>&1 | tr -d '\r')
assert_eq "pwsh/typed git shortcuts" "STUB-GIT push origin main
STUB-GIT commit -m a message" "$actual"

# again re-runs a line from the history as it ran when typed, and so does
# snippet run; a script that the line runs gets the cmdlets.
echo "[pwsh] a line again replays runs den's shortcuts, and its scripts the cmdlets"
rm -f "$WORK/git-calls.log"
actual=$(run_pwsh_den "\$env:PATH = '$GIT_PATH'" "
    function global:Read-Host { 'y' }
    Add-History -InputObject ([pscustomobject]@{
        CommandLine = \"gps origin main; & '$WORK/use-git-aliases.ps1' '$WORK/config.txt'\"; ExecutionStatus = 'Completed'
        StartExecutionTime = [datetime]::Now; EndExecutionTime = [datetime]::Now
    })
    again 6>\$null
" 2>&1 | tr -d '\r')
assert_eq "pwsh/again replays as typed" "STUB-GIT push origin main
gps: Process
gcm: Cmdlet
gl: PathInfo
gc: from the file
gu: a,b" "$actual"

# A module that loads while den does brings aliases of its own (fhx with
# Microsoft.PowerShell.Utility, gcb, scb and gtz with
# Microsoft.PowerShell.Management). They were recorded as den's, so a script's
# fhx would run a program named fhx on PATH instead of Format-Hex.
echo "[pwsh] aliases that modules defined while den loaded are not recorded as den's"
actual=$(run_pwsh_den "\$env:PATH = '$GIT_PATH'" "
    'fhx: ' + (Get-Alias -Name fhx).ModuleName
    \$m = @(\$global:_DenOverrides.Keys | Where-Object {
        \$a = Get-Alias -Name \$_ -ErrorAction SilentlyContinue
        \$a -and \$a.ModuleName
    })
    'recorded: ' + ((\$m | Sort-Object) -join ',')
" 2>&1 | tr -d '\r')
assert_eq "pwsh/no module alias recorded as den's" "fhx: Microsoft.PowerShell.Utility
recorded: " "$actual"

# =============================================================================
# open is not den's on macOS
# =============================================================================
# macOS has its own /usr/bin/open, which also opens URLs and takes -a and -R;
# den's open (Invoke-Item) replaced it. $IsMacOS is a constant, set with -Force.
echo "[pwsh] open is den's on Linux, not on macOS"
actual=$(run_pwsh "$HELPERS_PS1" "
    \$env:_DEN_FORCE_INTERACTIVE = '1'
    . '$P/aliases.ps1'
    [bool](Get-Command open -CommandType Function -ErrorAction SilentlyContinue)
    Remove-Item Function:\\open
    Set-Variable -Name IsLinux -Value \$false -Scope Global -Force
    Set-Variable -Name IsMacOS -Value \$true -Scope Global -Force
    . '$P/aliases.ps1'
    [bool](Get-Command open -CommandType Function -ErrorAction SilentlyContinue)
" | tr -d '\r')
assert_eq "pwsh/open on Linux, then on macOS" "True
False" "$actual"

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

# den's code takes over the `code` on PATH, so only a code typed at the prompt is
# den's: a user's script gets that `code`, as without den. Where no `code` was on
# PATH when den loaded, code is den's alone and a script gets den's too. It
# resolves the editor through _ResolveCmd, whose cache was once kept in $script:,
# which inside a user's .ps1 is that script's scope: there the cache was $null and
# code reported "not installed".
echo "[pwsh] code in a script is the code on PATH; typed, it is den's"
printf '%s\n' 'code --version' > "$WORK/usecode.ps1"
actual=$(run_pwsh_den "\$env:PATH = '$CODE_BIN'" "& '$WORK/usecode.ps1'; code --version" 2>&1 | tr -d '\r')
assert_eq "pwsh/code from a script runs the code on PATH" "STUB-CODE --version
STUB-INSIDERS --version" "$actual"
INSIDERS_ONLY="$WORK/insiders-only"
mkdir -p "$INSIDERS_ONLY"
cp "$CODE_BIN/code-insiders" "$INSIDERS_ONLY/"
echo "[pwsh] code works from a user script where only den's code exists"
actual=$(run_pwsh_den "\$env:PATH = '$INSIDERS_ONLY'" "& '$WORK/usecode.ps1'" 2>&1 | tr -d '\r')
assert_eq "pwsh/code from a script, no code on PATH" "STUB-INSIDERS --version" "$actual"

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
# PowerShell adds its own "code: "; run_pwsh_stderr_oneline is the runner whose
# single-line command shows that prefix and the message together, which is the
# only form a hand-written second prefix is visible in (see helpers.sh).
assert_not_contains "pwsh/code no double prefix" "code: code:" "$(run_pwsh_stderr_oneline "$HELPERS_PS1" "\$env:_DEN_FORCE_INTERACTIVE='1'; \$env:PATH='$CODE_CMD_BIN'; . '$P/aliases.ps1'; code 'a%USERPROFILE%b'")"
actual=$(run_pwsh "$HELPERS_PS1" "
    \$env:_DEN_FORCE_INTERACTIVE = '1'
    \$env:PATH = '$CODE_CMD_BIN'
    . '$P/aliases.ps1'
    code 'a%USERPROFILE%b' 2>\$null
" | tr -d '\r')
assert_not_contains "pwsh/code does not reach the shim when refusing" "STUB-CMD" "$actual"

print_summary "test_aliases"
[ "$FAIL" -eq 0 ]
