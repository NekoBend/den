#!/usr/bin/env bash
# test_helpers.sh — Tests for _helpers.sh (DRY helpers module).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

HELPERS_SH="$DOTFILES/shell/posix/_helpers.sh"
HELPERS_PS1="$DOTFILES/shell/pwsh/_helpers.ps1"

# Isolate pwsh's LocalApplicationData (XDG_DATA_HOME off Windows) under WORK so the
# Initialize-Cache tests never touch the real ~/.local/share/shell-cache. The
# directory must exist: GetFolderPath('LocalApplicationData') returns '' when
# XDG_DATA_HOME names a missing one.
export XDG_DATA_HOME="$WORK/xdg"
mkdir -p "$XDG_DATA_HOME"

# Drop the color codes around the wrapper notice so whole lines can be compared.
strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

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

# --- _wrap_log native hint names the FALLBACK, not the wrapper name ---
echo "[bash] _wrap_log native hint = fallback command"
actual=$(run_bash_stderr "$HELPERS_SH" "_wrap myla echo '' ls '-A'; myla x >/dev/null")
assert_contains "bash/native hint is fallback" "command ls -A" "$actual"
assert_not_contains "bash/native hint not wrapper name" "command myla" "$actual"

echo "[bash] _wrap_log native hint = none when no fallback"
actual=$(run_bash_stderr "$HELPERS_SH" "_wrap mytree echo '' '' ''; mytree x >/dev/null")
assert_not_contains "bash/native hint none" "native:" "$actual"

# --- _wrap_log line format: short, with the hints in one parenthesis ---
# The whole line is compared (color codes stripped), so a hint that comes back
# or a section that moves fails here, not only a missing substring.
echo "[bash] _wrap_log line with a native fallback"
actual=$(run_bash_stderr "$HELPERS_SH" "_wrap myla echo '' ls '-A'; myla x >/dev/null" | strip_ansi)
assert_eq "bash/_wrap_log line with flags" "[den] myla -> echo  (native: command ls -A, off: tgl-wr)" "$actual"
actual=$(run_bash_stderr "$HELPERS_SH" "_wrap myls echo '' ls ''; myls x >/dev/null" | strip_ansi)
assert_eq "bash/_wrap_log line without flags" "[den] myls -> echo  (native: command ls, off: tgl-wr)" "$actual"

echo "[bash] _wrap_log hint leaves out presentation-only flags"
actual=$(run_bash_stderr "$HELPERS_SH" "_wrap myls echo '' ls '--color=auto'; myls x >/dev/null" | strip_ansi)
assert_eq "bash/_wrap_log hint drops --color=auto" "[den] myls -> echo  (native: command ls, off: tgl-wr)" "$actual"
actual=$(run_bash_stderr "$HELPERS_SH" "_wrap myla echo '' ls '-A --color=auto'; myla x >/dev/null" | strip_ansi)
assert_eq "bash/_wrap_log hint keeps -A" "[den] myla -> echo  (native: command ls -A, off: tgl-wr)" "$actual"
actual=$(run_bash_stderr "$HELPERS_SH" "_wrap myll echo '' ls '--colour=always -lF --color'; myll x >/dev/null" | strip_ansi)
assert_eq "bash/_wrap_log hint keeps -lF only" "[den] myll -> echo  (native: command ls -lF, off: tgl-wr)" "$actual"

echo "[bash] _wrap_log line without a native equivalent"
actual=$(run_bash_stderr "$HELPERS_SH" "_wrap mytree echo '' '' ''; mytree x >/dev/null" | strip_ansi)
assert_eq "bash/_wrap_log line no native" "[den] mytree -> echo  (off: tgl-wr)" "$actual"

echo "[bash] _wrap_log stays dim"
actual=$(run_bash_stderr "$HELPERS_SH" "_wrap mytree echo '' '' ''; mytree x >/dev/null" | od -An -c | tr -s ' \n' ' ')
assert_contains "bash/_wrap_log dim on" "033 [ 2 m [ d e n ]" "$actual"
assert_contains "bash/_wrap_log dim off" "033 [ 0 m \n" "$actual"

echo "[bash] _DEN_WRAPPER_LOG=0 silences the line"
actual=$(run_bash_stderr "$HELPERS_SH" "_wrap myla echo '' ls '-A'; _DEN_WRAPPER_LOG=0; myla x >/dev/null")
assert_eq "bash/_DEN_WRAPPER_LOG=0 silences" "" "$actual"

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

# --- tgl-wr: the short name for toggle-wrapper ---
# `bash -c` is non-interactive, so an alias would not even expand here: this
# checks that tgl-wr is a real function that does what toggle-wrapper does.
echo "[bash] tgl-wr is a function"
actual=$(run_bash "$HELPERS_SH" "type -t tgl-wr")
assert_eq "bash/tgl-wr type" "function" "$actual"

echo "[bash] tgl-wr flips like toggle-wrapper"
actual=$(run_bash "$HELPERS_SH" "tgl-wr; echo \"\$_DEN_WRAPPERS \$STARSHIP_WRAPPER_STATE\"")
assert_eq "bash/tgl-wr OFF" "wrappers: OFF (using native commands)
0 OFF" "$actual"
actual=$(run_bash "$HELPERS_SH" "tgl-wr >/dev/null; tgl-wr; echo \"\$_DEN_WRAPPERS \${STARSHIP_WRAPPER_STATE:-unset}\"")
assert_eq "bash/tgl-wr ON again" "wrappers: ON (using modern tools)
1 unset" "$actual"

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

echo "[zsh] _wrap_log native hint = fallback command"
actual=$(run_zsh_stderr "$HELPERS_SH" "_wrap myla echo '' ls '-A'; myla x >/dev/null")
assert_contains "zsh/native hint is fallback" "command ls -A" "$actual"
assert_not_contains "zsh/native hint not wrapper name" "command myla" "$actual"

echo "[zsh] _wrap_log native hint = none when no fallback"
actual=$(run_zsh_stderr "$HELPERS_SH" "_wrap mytree echo '' '' ''; mytree x >/dev/null")
assert_not_contains "zsh/native hint none" "native:" "$actual"

echo "[zsh] _wrap_log line with a native fallback"
actual=$(run_zsh_stderr "$HELPERS_SH" "_wrap myla echo '' ls '-A'; myla x >/dev/null" | strip_ansi)
assert_eq "zsh/_wrap_log line with flags" "[den] myla -> echo  (native: command ls -A, off: tgl-wr)" "$actual"
actual=$(run_zsh_stderr "$HELPERS_SH" "_wrap myls echo '' ls ''; myls x >/dev/null" | strip_ansi)
assert_eq "zsh/_wrap_log line without flags" "[den] myls -> echo  (native: command ls, off: tgl-wr)" "$actual"

echo "[zsh] _wrap_log hint leaves out presentation-only flags"
actual=$(run_zsh_stderr "$HELPERS_SH" "_wrap myls echo '' ls '--color=auto'; myls x >/dev/null" | strip_ansi)
assert_eq "zsh/_wrap_log hint drops --color=auto" "[den] myls -> echo  (native: command ls, off: tgl-wr)" "$actual"
actual=$(run_zsh_stderr "$HELPERS_SH" "_wrap myla echo '' ls '-A --color=auto'; myla x >/dev/null" | strip_ansi)
assert_eq "zsh/_wrap_log hint keeps -A" "[den] myla -> echo  (native: command ls -A, off: tgl-wr)" "$actual"
actual=$(run_zsh_stderr "$HELPERS_SH" "_wrap myll echo '' ls '--colour=always -lF --color'; myll x >/dev/null" | strip_ansi)
assert_eq "zsh/_wrap_log hint keeps -lF only" "[den] myll -> echo  (native: command ls -lF, off: tgl-wr)" "$actual"

echo "[zsh] _wrap_log line without a native equivalent"
actual=$(run_zsh_stderr "$HELPERS_SH" "_wrap mytree echo '' '' ''; mytree x >/dev/null" | strip_ansi)
assert_eq "zsh/_wrap_log line no native" "[den] mytree -> echo  (off: tgl-wr)" "$actual"

echo "[zsh] _DEN_WRAPPER_LOG=0 silences the line"
actual=$(run_zsh_stderr "$HELPERS_SH" "_wrap myla echo '' ls '-A'; _DEN_WRAPPER_LOG=0; myla x >/dev/null")
assert_eq "zsh/_DEN_WRAPPER_LOG=0 silences" "" "$actual"

echo "[zsh] _wsfx creates function"
actual=$(run_zsh "$HELPERS_SH" "_wsfx echow echo ''; type echow" 2>/dev/null)
assert_contains "zsh/_wsfx creates function" "function" "$actual"

echo "[zsh] toggle-wrapper"
actual=$(run_zsh "$HELPERS_SH" "toggle-wrapper >/dev/null; echo \$_DEN_WRAPPERS")
assert_eq "zsh/toggle OFF" "0" "$actual"

echo "[zsh] toggle round trip"
actual=$(run_zsh "$HELPERS_SH" "toggle-wrapper >/dev/null; toggle-wrapper >/dev/null; echo \$_DEN_WRAPPERS")
assert_eq "zsh/toggle ON again" "1" "$actual"

echo "[zsh] tgl-wr is a function"
actual=$(run_zsh "$HELPERS_SH" "whence -w tgl-wr")
assert_eq "zsh/tgl-wr type" "tgl-wr: function" "$actual"

echo "[zsh] tgl-wr flips like toggle-wrapper"
actual=$(run_zsh "$HELPERS_SH" "tgl-wr; echo \"\$_DEN_WRAPPERS \$STARSHIP_WRAPPER_STATE\"")
assert_eq "zsh/tgl-wr OFF" "wrappers: OFF (using native commands)
0 OFF" "$actual"
actual=$(run_zsh "$HELPERS_SH" "tgl-wr >/dev/null; tgl-wr; echo \"\$_DEN_WRAPPERS \${STARSHIP_WRAPPER_STATE:-unset}\"")
assert_eq "zsh/tgl-wr ON again" "wrappers: ON (using modern tools)
1 unset" "$actual"

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

# --- tgl-wr: the short name for toggle-wrapper ---
echo "[pwsh] tgl-wr is a function"
actual=$(run_pwsh "$HELPERS_PS1" "(Get-Command tgl-wr).CommandType" | tr -d '\r')
assert_eq "pwsh/tgl-wr type" "Function" "$actual"

echo "[pwsh] tgl-wr flips like toggle-wrapper"
actual=$(run_pwsh "$HELPERS_PS1" "
    \$env:_DEN_WRAPPERS = '1'
    \$msg = @(tgl-wr 6>&1) -join ''
    Write-Output \"\$msg|\$env:_DEN_WRAPPERS|\$env:STARSHIP_WRAPPER_STATE\"
    \$msg = @(tgl-wr 6>&1) -join ''
    Write-Output \"\$msg|\$env:_DEN_WRAPPERS|\$([bool]\$env:STARSHIP_WRAPPER_STATE)\"
" | tr -d '\r')
assert_eq "pwsh/tgl-wr OFF then ON" "wrappers: OFF (using native commands)|0|OFF
wrappers: ON (using modern tools)|1|False" "$actual"

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

# --- _WrapLog line format: short, one hint in a parenthesis, DarkGray ---
echo "[pwsh] _WrapLog line"
actual=$(run_pwsh "$HELPERS_PS1" "
    \$env:_DEN_WRAPPER_LOG = '1'
    New-Wrapper 'myecho' 'echo' '' '' '' ''
    \$rec = myecho test1 6>&1 | Where-Object { \$_ -is [System.Management.Automation.InformationRecord] }
    Write-Output \"\$(\$rec.MessageData.Message)|\$(\$rec.MessageData.ForegroundColor)\"
" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/_WrapLog line" "[den] myecho -> echo  (off: tgl-wr)|DarkGray" "$actual"

echo "[pwsh] _DEN_WRAPPER_LOG=0 silences the line"
actual=$(run_pwsh "$HELPERS_PS1" "
    \$env:_DEN_WRAPPER_LOG = '0'
    New-Wrapper 'myecho' 'echo' '' '' '' ''
    @(myecho test1 6>&1 | Where-Object { \$_ -is [System.Management.Automation.InformationRecord] }).Count
" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/_DEN_WRAPPER_LOG=0 silences" "0" "$actual"

# --- Pipeline forwarding ---
echo "[pwsh] Pipeline forwarding"
actual=$(run_pwsh "$HELPERS_PS1" "
    New-Wrapper 'mycat' 'nonexistent_modern' '' 'cat' '' ''
    'hello_pipe' | mycat
" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/pipeline forwarding" "hello_pipe" "$actual"

# --- The helpers and the wrappers they build, called from a user script ---
# A function's $script: is the scope of the script that is RUNNING it, not of the
# file that defined it, so the command cache _helpers.ps1 kept there was $null
# inside a user's .ps1: every call printed "You cannot call a method on a
# null-valued expression" and the wrapper fell through to its fallback. Called
# here from a script run with &, and from a function inside that script.
echo "[pwsh] helpers and wrappers work from a user script"
echo "native test" > "$WORK/pwsh_script_wrap.txt"
cat > "$WORK/pwsh_caller.ps1" <<'EOF'
param([string]$File)
"any:$(_ResolveCmd 'sh')"
"app:$([bool](_ResolveCmd 'sh' 'App'))"
"missing:[$(_ResolveCmd 'nonexistent_xyz' 'App')]"
mycat $File
myprintf 'modern\n'
printfw 'suffix\n'
function Invoke-Inner([string]$F) { mycat $F }
Invoke-Inner $File
EOF
actual=$(run_pwsh "$HELPERS_PS1" "
    \$env:_DEN_WRAPPER_LOG = '0'
    New-Wrapper 'mycat' 'nonexistent_modern' '' 'cat' '' ''
    New-Wrapper 'myprintf' 'printf' '' '' '' ''
    New-WrapperSuffix 'printfw' 'printf' ''
    & '$WORK/pwsh_caller.ps1' '$WORK/pwsh_script_wrap.txt'
" 2>"$WORK/pwsh_caller.err" | tr -d '\r')
assert_eq "pwsh/helpers from a script" "any:sh
app:True
missing:[]
native test
modern
suffix
native test" "$actual"
assert_eq "pwsh/helpers from a script: no errors" "" "$(tr -d '\r' < "$WORK/pwsh_caller.err")"

# The whole class: any function that reads $script: state breaks the same way,
# so den's pwsh files keep none (comments aside).
echo "[pwsh] no \$script: state in shell/pwsh"
actual=$(grep -inE '\$\{?script:' "$DOTFILES"/shell/pwsh/*.ps1 | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true)
assert_eq "pwsh/no \$script: state" "" "$actual"

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

# --- _DenTrustedCacheOwner: the Windows cache-owner decision, by SID ---
# Test-CacheSafe compares security identifiers, not account names: a file created
# from an elevated session (or with UAC off) is owned by BUILTIN\Administrators
# (S-1-5-32-544), the likely cause of the refusals a name comparison gave, and
# account-name formats can also differ. This pure helper is the whole decision and
# runs anywhere; the Test-CacheSafe block below drives it through the Windows branch.
echo "[pwsh] _DenTrustedCacheOwner decides by SID"
_user_sid='S-1-5-21-1111111111-2222222222-3333333333-1001'
_other_sid='S-1-5-21-1111111111-2222222222-3333333333-1002'
actual=$(run_pwsh "$HELPERS_PS1" "
    \$u = '$_user_sid'
    \$g = @('S-1-1-0', 'S-1-5-32-545', 'S-1-5-11')
    'user=' + (_DenTrustedCacheOwner -OwnerSid \$u -UserSid \$u -UserGroupSids \$g)
    'system=' + (_DenTrustedCacheOwner -OwnerSid 'S-1-5-18' -UserSid \$u -UserGroupSids \$g)
    'admins-in-token=' + (_DenTrustedCacheOwner -OwnerSid 'S-1-5-32-544' -UserSid \$u -UserGroupSids (\$g + 'S-1-5-32-544'))
    'admins-not-in-token=' + (_DenTrustedCacheOwner -OwnerSid 'S-1-5-32-544' -UserSid \$u -UserGroupSids \$g)
    'admins-no-groups=' + (_DenTrustedCacheOwner -OwnerSid 'S-1-5-32-544' -UserSid \$u -UserGroupSids @())
    'other-user=' + (_DenTrustedCacheOwner -OwnerSid '$_other_sid' -UserSid \$u -UserGroupSids (\$g + '$_other_sid'))
    'empty-owner=' + (_DenTrustedCacheOwner -OwnerSid '' -UserSid \$u -UserGroupSids \$g)
    'empty-owner-empty-user=' + (_DenTrustedCacheOwner -OwnerSid '' -UserSid '' -UserGroupSids @(''))
" 2>/dev/null | tr -d '\r')
assert_contains "pwsh/owner = user SID trusted" "user=True" "$actual"
assert_contains "pwsh/owner = SYSTEM trusted" "system=True" "$actual"
assert_contains "pwsh/owner = Administrators, in token, trusted" "admins-in-token=True" "$actual"
assert_contains "pwsh/owner = Administrators, not in token, refused" "admins-not-in-token=False" "$actual"
assert_contains "pwsh/owner = Administrators, no groups, refused" "admins-no-groups=False" "$actual"
assert_contains "pwsh/owner = another user refused" "other-user=False" "$actual"
assert_contains "pwsh/empty owner refused" "empty-owner=False" "$actual"
assert_contains "pwsh/empty owner + empty user refused" "empty-owner-empty-user=False" "$actual"

# --- _DenTokenGroupSids: enabled groups plus deny-only groups ---
# Under UAC a non-elevated admin holds Administrators only as a deny-only group,
# which WindowsIdentity.Groups leaves out; the DenyOnlySid claims carry it. A
# stand-in object replaces the WindowsIdentity so this runs off Windows.
echo "[pwsh] _DenTokenGroupSids includes deny-only groups"
actual=$(run_pwsh "$HELPERS_PS1" "
    \$u = '$_user_sid'
    \$claim = { param(\$t, \$v) [pscustomobject]@{ Type = \$t; Value = \$v } }
    \$filtered = [pscustomobject]@{
        Groups = @([pscustomobject]@{ Value = 'S-1-1-0' }, [pscustomobject]@{ Value = 'S-1-5-32-545' })
        Claims = @(
            (& \$claim ([System.Security.Claims.ClaimTypes]::GroupSid) 'S-1-5-32-545'),
            (& \$claim ([System.Security.Claims.ClaimTypes]::DenyOnlySid) 'S-1-5-32-544'),
            (& \$claim ([System.Security.Claims.ClaimTypes]::Name) 'S-1-5-32-551')
        )
    }
    \$plain = [pscustomobject]@{
        Groups = @([pscustomobject]@{ Value = 'S-1-1-0' })
        Claims = @((& \$claim ([System.Security.Claims.ClaimTypes]::GroupSid) 'S-1-1-0'))
    }
    \$fs = @(_DenTokenGroupSids \$filtered)
    \$ps = @(_DenTokenGroupSids \$plain)
    'filtered=' + (\$fs -join ',')
    'filtered-admins-trusted=' + (_DenTrustedCacheOwner -OwnerSid 'S-1-5-32-544' -UserSid \$u -UserGroupSids \$fs)
    'plain-admins-trusted=' + (_DenTrustedCacheOwner -OwnerSid 'S-1-5-32-544' -UserSid \$u -UserGroupSids \$ps)
" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/token groups = enabled + deny-only only" "filtered=S-1-1-0,S-1-5-32-545,S-1-5-32-544" \
    "$(printf '%s\n' "$actual" | grep '^filtered=')"
assert_contains "pwsh/deny-only Administrators trusted" "filtered-admins-trusted=True" "$actual"
assert_contains "pwsh/Administrators absent from token refused" "plain-admins-trusted=False" "$actual"

# --- Test-CacheSafe: the Windows owner branch, through its seam ---
# _OnWindows and _DenCacheOwnerFacts hold every Windows-only read on this path, so
# redefining them after dot-sourcing runs Test-CacheSafe's Windows branch here. The
# account names DISAGREE with the SID verdicts (Administrators and the user's own
# SID under other names, another SID under the user's name), so a name comparison
# fails every case, and asked=1 shows the branch consulted the owner facts at all.
echo "[pwsh] Test-CacheSafe decides the Windows owner check by SID"
printf '%s\n' "\$env:PWSH_CACHE_OWNER = 'ok'" > "$WORK/pwsh_owner.ps1"
actual=$(run_pwsh "$HELPERS_PS1" "
    function _OnWindows { \$true }
    function _DenCacheOwnerFacts([string]\$Path) { \$global:asked++; \$global:facts }
    function probe([string]\$ownerSid, [string]\$ownerName) {
        \$global:asked = 0
        \$global:facts = [pscustomobject]@{
            OwnerSid = \$ownerSid; OwnerName = \$ownerName
            UserSid = '$_user_sid'; UserName = 'HOST\me'
            GroupSids = @('S-1-1-0', 'S-1-5-32-545', 'S-1-5-32-544')
        }
        \$why = \$null
        \$ok = Test-CacheSafe -Path '$WORK/pwsh_owner.ps1' -Reason ([ref]\$why)
        \"\$ok asked=\$(\$global:asked) why=\$why\"
    }
    'admins=' + (probe 'S-1-5-32-544' 'BUILTIN\Administrators')
    'other=' + (probe '$_other_sid' 'HOST\me')
    'self=' + (probe '$_user_sid' 'OTHER\me')
" 2>/dev/null | tr -d '\r')
other_line=$(printf '%s\n' "$actual" | grep '^other=')
assert_contains "pwsh/Test-CacheSafe trusts Administrators owner in token" "admins=True asked=1" "$actual"
assert_contains "pwsh/Test-CacheSafe refuses another user's SID" "other=False asked=1" "$other_line"
assert_contains "pwsh/Test-CacheSafe reason names owner SID" "($_other_sid)" "$other_line"
assert_contains "pwsh/Test-CacheSafe reason names user SID" "($_user_sid)" "$other_line"
assert_contains "pwsh/Test-CacheSafe trusts user's own SID" "self=True asked=1" "$actual"

# --- Initialize-Cache warning says WHY the cache was refused and how to fix it ---
# A symlinked cache is refused on every OS (reparse point); the warning must carry
# the reason (so a report from the field is diagnosable) and the remedy.
echo "[pwsh] Initialize-Cache refusal warning names the reason and remedy"
mkdir -p "$WORK/pwsh_iclink"
cat > "$WORK/pwsh_iclink/pwshcachelink" <<'EOF'
#!/bin/sh
printf "%s\n" "\$env:PWSH_CACHE_LINK = 'regenerated'"
EOF
chmod +x "$WORK/pwsh_iclink/pwshcachelink"
printf "%s\n" "\$env:PWSH_CACHE_LINK = 'linked'" > "$WORK/pwsh_iclink/target.ps1"
actual=$(run_pwsh "$HELPERS_PS1" "
    \$cacheDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'shell-cache'
    [void](New-Item -ItemType Directory -Path \$cacheDir -Force)
    \$cacheFile = Join-Path \$cacheDir 'pwshcachelink-init.ps1'
    Remove-Item -LiteralPath \$cacheFile -Force -ErrorAction SilentlyContinue
    [void](New-Item -ItemType SymbolicLink -Path \$cacheFile -Target '$WORK/pwsh_iclink/target.ps1')
    \$env:PATH = '$WORK/pwsh_iclink:' + \$env:PATH
    \$r = Initialize-Cache 'pwshcachelink' @('init', 'powershell') 3>&1
    Remove-Item -LiteralPath \$cacheFile -Force -ErrorAction SilentlyContinue
    \$r | ForEach-Object { 'out: ' + \$_ }
" 2>/dev/null | tr -d '\r')
assert_contains "pwsh/Initialize-Cache refuses symlinked cache" "refusing to source unsafe cache file" "$actual"
assert_contains "pwsh/Initialize-Cache warning names reason" "reparse point" "$actual"
assert_contains "pwsh/Initialize-Cache warning names remedy" "delete it to regenerate" "$actual"

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
