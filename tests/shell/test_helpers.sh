#!/usr/bin/env bash
# test_helpers.sh — Tests for _helpers.sh (DRY helpers module).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

HELPERS_SH="$DOTFILES/shell/posix/_helpers.sh"
HELPERS_PS1="$DOTFILES/shell/pwsh/_helpers.ps1"

# =============================================================================
# Bash tests
# =============================================================================
echo "================================================"
echo "  Testing _helpers.sh with BASH"
echo "================================================"

# --- _wrap creates function ---
echo "[bash] _wrap creates function"
actual=$(run_bash "$HELPERS_SH" "_wrap testcmd echo '' cat ''; type testcmd" 2>/dev/null)
assert_contains "bash/_wrap creates function" "function" "$actual"

# --- _wrap fallback when modern not found ---
echo "[bash] _wrap fallback (modern not available)"
actual=$(run_bash "$HELPERS_SH" "_wrap mycat nonexistent_tool '' cat ''; mycat '$WORK/wrap_test.txt'" 2>/dev/null)
echo "hello test" > "$WORK/wrap_test.txt"
actual=$(run_bash "$HELPERS_SH" "_wrap mycat nonexistent_tool '' cat ''; mycat '$WORK/wrap_test.txt'" 2>/dev/null)
assert_eq "bash/_wrap fallback" "hello test" "$actual"

# --- _wrap error when no modern and no fallback ---
echo "[bash] _wrap no fallback error"
actual=$(run_bash "$HELPERS_SH" "_wrap mytest nonexistent_tool '' '' ''; mytest 2>&1; echo \$?" 2>/dev/null)
assert_contains "bash/_wrap no fallback" "not installed" "$actual"

# --- _wrap_log native one-off hint names the FALLBACK, not the wrapper name ---
echo "[bash] _wrap_log native one-off = fallback command"
actual=$(run_bash_stderr "$HELPERS_SH" "_wrap myla echo '' ls '-A'; myla x >/dev/null")
assert_contains "bash/native one-off is fallback" "command ls -A" "$actual"
assert_not_contains "bash/native one-off not wrapper name" "command myla" "$actual"

echo "[bash] _wrap_log native one-off = none when no fallback"
actual=$(run_bash_stderr "$HELPERS_SH" "_wrap mytree echo '' '' ''; mytree x >/dev/null")
assert_contains "bash/native one-off none" "(no native equivalent)" "$actual"

# --- _wsfx creates function ---
echo "[bash] _wsfx creates function"
actual=$(run_bash "$HELPERS_SH" "_wsfx echow echo ''; type echow" 2>/dev/null)
assert_contains "bash/_wsfx creates function" "function" "$actual"

# --- _wsfx error when tool not found ---
echo "[bash] _wsfx missing tool"
actual=$(run_bash "$HELPERS_SH" "_wsfx mytool nonexistent_xyz ''; mytool 2>&1" 2>/dev/null)
assert_contains "bash/_wsfx missing" "not installed" "$actual"

# --- toggle-wrapper ---
echo "[bash] toggle-wrapper"
actual=$(run_bash "$HELPERS_SH" "toggle-wrapper >/dev/null; echo \$_DEN_WRAPPERS")
assert_eq "bash/toggle OFF" "0" "$actual"

echo "[bash] toggle-wrapper round trip"
actual=$(run_bash "$HELPERS_SH" "toggle-wrapper >/dev/null; toggle-wrapper >/dev/null; echo \$_DEN_WRAPPERS")
assert_eq "bash/toggle ON again" "1" "$actual"

echo "[bash] toggle sets STARSHIP_WRAPPER_STATE"
actual=$(run_bash "$HELPERS_SH" "toggle-wrapper >/dev/null; echo \$STARSHIP_WRAPPER_STATE")
assert_eq "bash/toggle STARSHIP OFF" "OFF" "$actual"

echo "[bash] toggle clears STARSHIP_WRAPPER_STATE"
actual=$(run_bash "$HELPERS_SH" "toggle-wrapper >/dev/null; toggle-wrapper >/dev/null; echo \${STARSHIP_WRAPPER_STATE:-unset}")
assert_eq "bash/toggle STARSHIP ON" "unset" "$actual"

# --- _wrap respects toggle ---
echo "[bash] _wrap respects toggle OFF"
echo "native test" > "$WORK/toggle_test.txt"
actual=$(run_bash "$HELPERS_SH" "
    _wrap mycat nonexistent_modern '' cat ''
    export _DEN_WRAPPERS=0
    mycat '$WORK/toggle_test.txt'
" 2>/dev/null)
assert_eq "bash/_wrap toggle OFF uses fallback" "native test" "$actual"

# --- _init_path ---
echo "[bash] _init_path adds to PATH"
actual=$(run_bash "$HELPERS_SH" "_init_path /test/new/path; echo \$PATH" 2>/dev/null)
assert_contains "bash/_init_path adds" "/test/new/path" "$actual"

echo "[bash] _init_path no duplicate"
actual=$(run_bash "$HELPERS_SH" "_init_path /usr/bin; echo \$PATH | tr ':' '\n' | grep -c '/usr/bin'" 2>/dev/null)
assert_eq "bash/_init_path no dup" "1" "$actual"

# --- _source_all ---
echo "[bash] _source_all sources files"
mkdir -p "$WORK/srcall"
echo 'SRCALL_TEST=loaded' > "$WORK/srcall/aliases.sh"
actual=$(run_bash "$HELPERS_SH" "_source_all '$WORK/srcall'; echo \$SRCALL_TEST" 2>/dev/null)
assert_eq "bash/_source_all" "loaded" "$actual"
rm -rf "$WORK/srcall"

# --- _init_cache regenerates when binary is newer ---
echo "[bash] _init_cache regenerates when binary newer"
mkdir -p "$WORK/icbin"
cat > "$WORK/icbin/faketool" <<'EOF'
#!/bin/sh
echo "# v1 init for $1"
EOF
chmod +x "$WORK/icbin/faketool"
HOME_OVERRIDE="$WORK/ichome"
mkdir -p "$HOME_OVERRIDE"
run_bash "$HELPERS_SH" "
    export PATH='$WORK/icbin:'\$PATH HOME='$HOME_OVERRIDE' XDG_CACHE_HOME=
    _init_cache faketool bash >/dev/null
" >/dev/null 2>&1
cache_file="$HOME_OVERRIDE/.cache/shell/faketool-init.bash"
first=$(cat "$cache_file" 2>/dev/null)
assert_contains "bash/_init_cache initial" "v1" "$first"
# Update binary so its mtime is newer than the cache
sleep 1
cat > "$WORK/icbin/faketool" <<'EOF'
#!/bin/sh
echo "# v2 init for $1"
EOF
chmod +x "$WORK/icbin/faketool"
run_bash "$HELPERS_SH" "
    export PATH='$WORK/icbin:'\$PATH HOME='$HOME_OVERRIDE' XDG_CACHE_HOME=
    _init_cache faketool bash >/dev/null
" >/dev/null 2>&1
second=$(cat "$cache_file" 2>/dev/null)
assert_contains "bash/_init_cache regenerated" "v2" "$second"
rm -rf "$WORK/icbin" "$HOME_OVERRIDE"

# =============================================================================
# Zsh tests
# =============================================================================
echo ""
echo "================================================"
echo "  Testing _helpers.sh with ZSH"
echo "================================================"

echo "[zsh] _wrap creates function"
actual=$(run_zsh "$HELPERS_SH" "_wrap testcmd echo '' cat ''; type testcmd" 2>/dev/null)
assert_contains "zsh/_wrap creates function" "function" "$actual"

echo "[zsh] _wrap fallback"
echo "hello test" > "$WORK/wrap_test.txt"
actual=$(run_zsh "$HELPERS_SH" "_wrap mycat nonexistent_tool '' cat ''; mycat '$WORK/wrap_test.txt'" 2>/dev/null)
assert_eq "zsh/_wrap fallback" "hello test" "$actual"

echo "[zsh] _wrap_log native one-off = fallback command"
actual=$(run_zsh_stderr "$HELPERS_SH" "_wrap myla echo '' ls '-A'; myla x >/dev/null")
assert_contains "zsh/native one-off is fallback" "command ls -A" "$actual"
assert_not_contains "zsh/native one-off not wrapper name" "command myla" "$actual"

echo "[zsh] _wrap_log native one-off = none when no fallback"
actual=$(run_zsh_stderr "$HELPERS_SH" "_wrap mytree echo '' '' ''; mytree x >/dev/null")
assert_contains "zsh/native one-off none" "(no native equivalent)" "$actual"

echo "[zsh] _wsfx creates function"
actual=$(run_zsh "$HELPERS_SH" "_wsfx echow echo ''; type echow" 2>/dev/null)
assert_contains "zsh/_wsfx creates function" "function" "$actual"

echo "[zsh] toggle-wrapper"
actual=$(run_zsh "$HELPERS_SH" "toggle-wrapper >/dev/null; echo \$_DEN_WRAPPERS")
assert_eq "zsh/toggle OFF" "0" "$actual"

echo "[zsh] toggle round trip"
actual=$(run_zsh "$HELPERS_SH" "toggle-wrapper >/dev/null; toggle-wrapper >/dev/null; echo \$_DEN_WRAPPERS")
assert_eq "zsh/toggle ON again" "1" "$actual"

echo "[zsh] _init_path adds to PATH"
actual=$(run_zsh "$HELPERS_SH" "_init_path /test/new/path; echo \$PATH" 2>/dev/null)
assert_contains "zsh/_init_path adds" "/test/new/path" "$actual"

echo "[zsh] _init_path no duplicate"
actual=$(run_zsh "$HELPERS_SH" "_init_path /usr/bin; echo \$PATH | tr ':' '\n' | grep -c '/usr/bin'" 2>/dev/null)
assert_eq "zsh/_init_path no dup" "1" "$actual"

echo "[zsh] _source_all sources files"
mkdir -p "$WORK/srcall"
echo 'SRCALL_TEST=loaded' > "$WORK/srcall/aliases.sh"
actual=$(run_zsh "$HELPERS_SH" "_source_all '$WORK/srcall'; echo \$SRCALL_TEST" 2>/dev/null)
assert_eq "zsh/_source_all" "loaded" "$actual"
rm -rf "$WORK/srcall"

# =============================================================================
# PowerShell tests
# =============================================================================
echo ""
echo "================================================"
echo "  Testing _helpers.ps1 with PWSH"
echo "================================================"

# --- New-Wrapper creates function ---
echo "[pwsh] New-Wrapper creates function"
actual=$(run_pwsh "$HELPERS_PS1" "
    New-Wrapper 'mytool' 'echo' '' '' '' ''
    Get-Command mytool -ErrorAction SilentlyContinue | Select-Object -ExpandProperty CommandType
" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/New-Wrapper creates function" "Function" "$actual"

# --- New-Wrapper fallback to native command ---
echo "[pwsh] New-Wrapper fallback to native"
echo "native test" > "$WORK/pwsh_wrap.txt"
actual=$(run_pwsh "$HELPERS_PS1" "
    New-Wrapper 'mycat' 'nonexistent_modern' '' 'cat' '' ''
    mycat '$WORK/pwsh_wrap.txt'
" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/New-Wrapper native fallback" "native test" "$actual"

# --- New-Wrapper PS-only fallback ---
echo "[pwsh] New-Wrapper PS-only fallback"
actual=$(run_pwsh "$HELPERS_PS1" "
    New-Wrapper 'myfunc' 'nonexistent_mod' '' 'nonexistent_native' '' 'Write-Output \"fallback_result\"'
    myfunc
" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/New-Wrapper PS fallback" "fallback_result" "$actual"

# --- New-Wrapper no fallback shows warning ---
echo "[pwsh] New-Wrapper no fallback warning"
actual=$(run_pwsh "$HELPERS_PS1" "
    New-Wrapper 'myfunc' 'nonexistent_mod' '' 'nonexistent_native' '' ''
    myfunc 2>&1 | Out-String
" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/New-Wrapper no fallback" "not installed" "$actual"

# --- New-WrapperSuffix creates function ---
echo "[pwsh] New-WrapperSuffix creates function"
actual=$(run_pwsh "$HELPERS_PS1" "
    New-WrapperSuffix 'echow' 'echo' ''
    Get-Command echow -ErrorAction SilentlyContinue | Select-Object -ExpandProperty CommandType
" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/New-WrapperSuffix creates function" "Function" "$actual"

# --- New-WrapperSuffix missing tool warning ---
echo "[pwsh] New-WrapperSuffix missing tool"
actual=$(run_pwsh "$HELPERS_PS1" "
    New-WrapperSuffix 'mytool' 'nonexistent_xyz' ''
    mytool 2>&1 | Out-String
" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/New-WrapperSuffix missing" "not installed" "$actual"

# --- toggle-wrapper sets OFF ---
echo "[pwsh] toggle-wrapper OFF"
actual=$(run_pwsh "$HELPERS_PS1" "
    \$env:_DEN_WRAPPERS = '1'
    toggle-wrapper *>\$null
    \$env:_DEN_WRAPPERS
" | tr -d '\r')
assert_eq "pwsh/toggle OFF" "0" "$actual"

# --- toggle-wrapper round trip ---
echo "[pwsh] toggle-wrapper round trip"
actual=$(run_pwsh "$HELPERS_PS1" "
    \$env:_DEN_WRAPPERS = '1'
    toggle-wrapper *>\$null
    toggle-wrapper *>\$null
    \$env:_DEN_WRAPPERS
" | tr -d '\r')
assert_eq "pwsh/toggle ON again" "1" "$actual"

# --- toggle-wrapper sets STARSHIP_WRAPPER_STATE ---
echo "[pwsh] toggle sets STARSHIP_WRAPPER_STATE"
actual=$(run_pwsh "$HELPERS_PS1" "
    \$env:_DEN_WRAPPERS = '1'
    toggle-wrapper *>\$null
    \$env:STARSHIP_WRAPPER_STATE
" | tr -d '\r')
assert_eq "pwsh/toggle STARSHIP OFF" "OFF" "$actual"

# --- New-Wrapper respects toggle OFF ---
echo "[pwsh] New-Wrapper respects toggle OFF"
echo "toggle test" > "$WORK/pwsh_toggle.txt"
actual=$(run_pwsh "$HELPERS_PS1" "
    New-Wrapper 'mycat' 'nonexistent_modern' '' 'cat' '' ''
    \$env:_DEN_WRAPPERS = '0'
    mycat '$WORK/pwsh_toggle.txt'
" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/New-Wrapper toggle OFF uses native" "toggle test" "$actual"

# --- _WrapLog prints on every call (no once-per-session dedup) ---
# The hint is intentionally emitted on EVERY wrapped call so a user never misses
# that a modern tool was substituted; _DEN_WRAPPER_LOG=0 silences it.
echo "[pwsh] _WrapLog prints every call"
actual=$(run_pwsh "$HELPERS_PS1" "
    \$env:_DEN_WRAPPER_LOG = '1'
    New-Wrapper 'myecho' 'echo' '' '' '' ''
    \$log1 = myecho test1 6>&1 | Where-Object { \$_ -match '\[den\]' }
    \$log2 = myecho test2 6>&1 | Where-Object { \$_ -match '\[den\]' }
    Write-Output \"first:\$([bool]\$log1)|second:\$([bool]\$log2)\"
" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/_WrapLog prints every call" "first:True|second:True" "$actual"

# --- Pipeline forwarding ---
echo "[pwsh] Pipeline forwarding"
actual=$(run_pwsh "$HELPERS_PS1" "
    New-Wrapper 'mycat' 'nonexistent_modern' '' 'cat' '' ''
    'hello_pipe' | mycat
" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/pipeline forwarding" "hello_pipe" "$actual"

# --- Initialize-Cache regenerates when binary is newer ---
echo "[pwsh] Initialize-Cache regenerates when binary newer"
mkdir -p "$WORK/pwsh_icbin"
cat > "$WORK/pwsh_icbin/pwshcachetool" <<'EOF'
#!/bin/sh
printf "%s\n" "\$env:PWSH_CACHE_TEST = 'v1:$2'"
EOF
chmod +x "$WORK/pwsh_icbin/pwshcachetool"
run_pwsh "$HELPERS_PS1" "
    Remove-Item -LiteralPath (Join-Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'shell-cache') 'pwshcachetool-init.ps1') -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\PWSH_CACHE_TEST -ErrorAction SilentlyContinue
" >/dev/null 2>&1
actual=$(run_pwsh "$HELPERS_PS1" "
    \$env:PATH = '$WORK/pwsh_icbin:' + \$env:PATH
    [void](Initialize-Cache 'pwshcachetool' @('init', 'powershell'))
    \$cacheFile = Join-Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'shell-cache') 'pwshcachetool-init.ps1'
    Get-Content -Raw -LiteralPath \$cacheFile
" 2>/dev/null | tr -d '\r')
assert_contains "pwsh/Initialize-Cache initial" "v1:powershell" "$actual"
sleep 1
cat > "$WORK/pwsh_icbin/pwshcachetool" <<'EOF'
#!/bin/sh
printf "%s\n" "\$env:PWSH_CACHE_TEST = 'v2:$2'"
EOF
chmod +x "$WORK/pwsh_icbin/pwshcachetool"
actual=$(run_pwsh "$HELPERS_PS1" "
    \$env:PATH = '$WORK/pwsh_icbin:' + \$env:PATH
    [void](Initialize-Cache 'pwshcachetool' @('init', 'powershell'))
    \$cacheFile = Join-Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'shell-cache') 'pwshcachetool-init.ps1'
    Get-Content -Raw -LiteralPath \$cacheFile
" 2>/dev/null | tr -d '\r')
assert_contains "pwsh/Initialize-Cache regenerated" "v2:powershell" "$actual"
run_pwsh "$HELPERS_PS1" "
    Remove-Item -LiteralPath (Join-Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'shell-cache') 'pwshcachetool-init.ps1') -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\PWSH_CACHE_TEST -ErrorAction SilentlyContinue
" >/dev/null 2>&1

# --- _DenInteractive reads pwsh's real launch switches ---
# _DenInteractive inspects [Environment]::GetCommandLineArgs(), so these cases
# launch pwsh with the switches under test instead of going through run_pwsh
# (which adds -NonInteractive), and run with _DEN_FORCE_INTERACTIVE unset. The
# first argument is the text fed on stdin: `exit` ends the REPL that -NoExit (or
# a plain launch) starts, and a run without a REPL never reads it. DENI=<bool>
# is grepped out of the prompt noise; the REPL's echo of the typed command shows
# the literal `DENI=$(...)`, which the True|False alternation skips.
run_pwsh_deni() {
    local input="$1"
    shift
    printf '%s\nexit\n' "$input" |
        env -u _DEN_FORCE_INTERACTIVE timeout 60 pwsh -NoProfile -NoLogo "$@" 2>&1 |
        grep -oE 'DENI=(True|False)' | head -n 1
}
DENI_CMD=". '$HELPERS_PS1'; \"DENI=\$(_DenInteractive)\""
printf '%s\n' "$DENI_CMD" > "$WORK/deni.ps1"
DENI_EC=$(DENI_CMD="$DENI_CMD" pwsh -NoProfile -NonInteractive -Command '[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($env:DENI_CMD))' | tr -d '\r')

echo "[pwsh] _DenInteractive plain REPL"
assert_eq "pwsh/_DenInteractive plain REPL" "DENI=True" "$(run_pwsh_deni "$DENI_CMD")"

echo "[pwsh] _DenInteractive -Command alone"
assert_eq "pwsh/_DenInteractive -Command" "DENI=False" "$(run_pwsh_deni '' -Command "$DENI_CMD")"

echo "[pwsh] _DenInteractive -noexit -command (VS Code shell integration)"
assert_eq "pwsh/_DenInteractive -noexit -command" "DENI=True" "$(run_pwsh_deni '' -noexit -command "$DENI_CMD")"

echo "[pwsh] _DenInteractive -noe (shortest -NoExit abbreviation)"
assert_eq "pwsh/_DenInteractive -noe -c" "DENI=True" "$(run_pwsh_deni '' -noe -c "$DENI_CMD")"

echo "[pwsh] _DenInteractive -NoExit -File"
assert_eq "pwsh/_DenInteractive -NoExit -File" "DENI=True" "$(run_pwsh_deni '' -NoExit -File "$WORK/deni.ps1")"

echo "[pwsh] _DenInteractive -EncodedCommand then -NoExit"
assert_eq "pwsh/_DenInteractive -ec then -NoExit" "DENI=True" "$(run_pwsh_deni '' -EncodedCommand "$DENI_EC" -NoExit)"

# pwsh reads every argument after -Command as command text and every argument
# after the -File path as a script argument, so a trailing -NoExit starts no REPL.
# The command text ends in `#` so the appended " -NoExit" is a comment.
echo "[pwsh] _DenInteractive -Command then -NoExit (command text)"
assert_eq "pwsh/_DenInteractive -Command then -NoExit" "DENI=False" "$(run_pwsh_deni '' -Command "$DENI_CMD #" -NoExit)"

echo "[pwsh] _DenInteractive -File then -NoExit (script argument)"
assert_eq "pwsh/_DenInteractive -File then -NoExit" "DENI=False" "$(run_pwsh_deni '' -File "$WORK/deni.ps1" -NoExit)"

# -NonInteractive stays authoritative even though -NoExit keeps a REPL open.
echo "[pwsh] _DenInteractive -NonInteractive -NoExit -Command"
assert_eq "pwsh/_DenInteractive -NonInteractive -NoExit -Command" "DENI=False" "$(run_pwsh_deni '' -NonInteractive -NoExit -Command "$DENI_CMD")"

echo "[pwsh] _DenInteractive -NoExit -noni -Command"
assert_eq "pwsh/_DenInteractive -NoExit -noni -Command" "DENI=False" "$(run_pwsh_deni '' -NoExit -noni -Command "$DENI_CMD")"

# pwsh accepts every prefix of -NonInteractive down to -noni.
echo "[pwsh] _DenInteractive -NoExit -nonint -Command"
assert_eq "pwsh/_DenInteractive -NoExit -nonint -Command" "DENI=False" "$(run_pwsh_deni '' -NoExit -nonint -Command "$DENI_CMD")"

echo "[pwsh] _DenInteractive -NoExit -NonInter -Command"
assert_eq "pwsh/_DenInteractive -NoExit -NonInter -Command" "DENI=False" "$(run_pwsh_deni '' -NoExit -NonInter -Command "$DENI_CMD")"

# More real launches for the switch forms _DenLaunchIsRepl reads the way pwsh does.
echo "[pwsh] _DenInteractive /noexit -command (slash prefix)"
assert_eq "pwsh/_DenInteractive /noexit -command" "DENI=True" "$(run_pwsh_deni '' /noexit -command "$DENI_CMD")"

echo "[pwsh] _DenInteractive -ExecutionPolicy Bypass (switch value is not a script)"
assert_eq "pwsh/_DenInteractive -ExecutionPolicy Bypass" "DENI=True" "$(run_pwsh_deni "$DENI_CMD" -ExecutionPolicy Bypass)"

echo "[pwsh] _DenInteractive -fi <script> (abbreviated -File)"
assert_eq "pwsh/_DenInteractive -fi" "DENI=False" "$(run_pwsh_deni '' -fi "$WORK/deni.ps1")"

echo "[pwsh] _DenInteractive <script> (implicit -File)"
assert_eq "pwsh/_DenInteractive bare script" "DENI=False" "$(run_pwsh_deni '' "$WORK/deni.ps1")"

echo "[pwsh] _DenInteractive -enc <b64> (abbreviated -EncodedCommand)"
assert_eq "pwsh/_DenInteractive -enc" "DENI=False" "$(run_pwsh_deni '' -enc "$DENI_EC")"

# --- _DenLaunchIsRepl: pwsh's switch parsing, case by case ---
# Each expected value is what pwsh 7.6.6 did with the same arguments: True where
# a REPL stayed open, False where pwsh ran a payload (or printed) and exited.
# Two kinds of case differ from pwsh on purpose: -NonInteractive keeps a REPL
# open, but den treats it as non-interactive, and -s starts pwsh's server mode,
# which reads stdin but is no REPL. One pwsh process runs them all;
# each line is `<expected>|<arguments>`, arguments separated by `|`, with
# {EN} standing for an en dash (U+2013) and {EMPTY} for an empty argument.
LAUNCH_CASES='True|
True|-noexit|-c|x
True|/noexit|-c|x
True|--noexit|-c|x
True|{EN}noexit|-c|x
True|-ExecutionPolicy|Bypass
True|-ep|Bypass
True|-ex|Bypass
True|-wd|/tmp
True|-wo|/tmp
True|-inp|text
True|-if|text
True|-o|text
True|-of|text
True|-settings|/dev/null
True|-custompipename|x
True|-l
True|-noprofileloadtime
True|-noexit|script.ps1
True|-NoLogo|-NoExit|-ep|Bypass|-c|x
True|-interactive|-noexit|-c|x
True|-enc|Zm9v|-noexit
False|-c|x
False|-com|x
False|-f|s.ps1
False|-fi|s.ps1
False|script.ps1|a|b
False|/abs/script.ps1
False|-e|Zm9v
False|-enc|Zm9v
False|-cwa|x|y
False|-commandwithargs|x
False|-bogus
False|/bogus
False|{EMPTY}
False|-ExecutionPolicy:Bypass
False|-in|text
False|-i|-c|x
False|-no
False|-s
False|-v
False|-h
False|-?
False|-noni
False|-NoExit|-nonint|-c|x
False|-c|x|-noexit
False|-f|s.ps1|-noexit'
LAUNCH_OUT=$(LAUNCH_CASES="$LAUNCH_CASES" run_pwsh "$HELPERS_PS1" '
    foreach ($line in ($env:LAUNCH_CASES -split "`n")) {
        $parts = $line.Split("|")
        $launch = @($parts | Select-Object -Skip 1 | ForEach-Object {
            if ($_ -eq "{EMPTY}") { "" } else { $_.Replace("{EN}", [string][char]0x2013) }
        })
        if ($line -match "^(True|False)\|$") { $launch = @() }
        "{0} => {1}" -f $line, (_DenLaunchIsRepl -Arguments $launch)
    }
' | tr -d '\r')
while IFS= read -r case_line; do
    expected="${case_line%%|*}"
    assert_eq "pwsh/_DenLaunchIsRepl ${case_line#*|}" "$case_line => $expected" \
        "$(printf '%s\n' "$LAUNCH_OUT" | grep -F -x -- "$case_line => True" || printf '%s\n' "$LAUNCH_OUT" | grep -F -x -- "$case_line => False")"
done <<<"$LAUNCH_CASES"

# =============================================================================
# Summary
# =============================================================================
print_summary "test_helpers"
[ "$FAIL" -eq 0 ]
