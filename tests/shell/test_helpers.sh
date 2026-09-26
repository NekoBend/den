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
True|-cus|x
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

# --- _DenRelaunchArgs: the arguments reload starts pwsh with ---
# argv[0] names the program (pwsh.dll, an .exe path, a bare name) and is dropped;
# the rest pass through one element each, spaces, quotes and empty ones included.
# -Legacy pre-quotes them by the Windows command-line rules for a host whose
# native argument passing is legacy. show prints n=<count>: then <each element>.
cat > "$WORK/relaunch_cases.ps1" <<'EOF'
function show([object[]]$a) { "n=$($a.Count):" + (($a | ForEach-Object { "<$_>" }) -join '') }
$payload = 'try { . "C:\Program Files\Microsoft VS Code\si.ps1" } catch {}'
'none ' + (show @(_DenRelaunchArgs -CommandLineArgs @('/opt/microsoft/powershell/7/pwsh.dll')))
'null ' + (show @(_DenRelaunchArgs -CommandLineArgs $null))
'winexe ' + (show @(_DenRelaunchArgs -CommandLineArgs @('C:\Program Files\PowerShell\7\pwsh.exe', '-NoLogo')))
'bare ' + (show @(_DenRelaunchArgs -CommandLineArgs @('powershell', '-NoLogo')))
'vscode ' + (show @(_DenRelaunchArgs -CommandLineArgs @('pwsh.dll', '-noexit', '-command', $payload)))
'odd ' + (show @(_DenRelaunchArgs -CommandLineArgs @('pwsh.dll', '', 'a b', 'x"y', 'end\')))
'legacy ' + (show @(_DenRelaunchArgs -Legacy -CommandLineArgs @('pwsh.dll', '-noexit', '-command', $payload, '', 'plain\', 'dir with space\', 'a\"b')))
EOF
RELAUNCH_OUT=$(run_pwsh "$HELPERS_PS1" ". '$WORK/relaunch_cases.ps1'" | tr -d '\r')
relaunch_case() { printf '%s\n' "$RELAUNCH_OUT" | grep -F -- "$1 " | head -n 1; }

echo "[pwsh] _DenRelaunchArgs with no arguments"
assert_eq "pwsh/_DenRelaunchArgs no arguments" "none n=0:" "$(relaunch_case none)"
assert_eq "pwsh/_DenRelaunchArgs null argv" "null n=0:" "$(relaunch_case null)"

echo "[pwsh] _DenRelaunchArgs drops argv[0] in any form"
assert_eq "pwsh/_DenRelaunchArgs Windows exe path" "winexe n=1:<-NoLogo>" "$(relaunch_case winexe)"
assert_eq "pwsh/_DenRelaunchArgs bare program name" "bare n=1:<-NoLogo>" "$(relaunch_case bare)"

echo "[pwsh] _DenRelaunchArgs keeps a -noexit -command payload whole"
assert_eq "pwsh/_DenRelaunchArgs -noexit -command payload" \
    'vscode n=3:<-noexit><-command><try { . "C:\Program Files\Microsoft VS Code\si.ps1" } catch {}>' \
    "$(relaunch_case vscode)"

echo "[pwsh] _DenRelaunchArgs keeps empty, spaced, quoted and backslash arguments"
assert_eq "pwsh/_DenRelaunchArgs odd arguments" 'odd n=4:<><a b><x"y><end\>' "$(relaunch_case odd)"

echo "[pwsh] _DenRelaunchArgs -Legacy escapes by the Windows rules and leaves the quoting to the host"
assert_eq "pwsh/_DenRelaunchArgs -Legacy" \
    'legacy n=7:<-noexit><-command><try { . \"C:\Program Files\Microsoft VS Code\si.ps1\" } catch {}><""><plain\><dir with space"\\"><a\\\"b>' \
    "$(relaunch_case legacy)"

# The same arguments through a real native command, under each argument passing
# style: every element must arrive intact. Without -Legacy, legacy passing splits
# or mangles them, which shows these runs do exercise it.
cat > "$WORK/relaunch_roundtrip.ps1" <<'EOF'
$argv = @('pwsh.dll', '-noexit', '-command', 'try { . "/p/Microsoft VS Code/si.ps1" } catch {}', '', 'a b', 'x"y', 'dir with space\', 'a\"b', 'plain\',
    'say "hi there" now', 'q"\', 'sp q" \\', 'two  spaces', "tab`there")
$want = ($argv | Select-Object -Skip 1 | ForEach-Object { "[$_]" }) -join ''
function roundtrip([string[]]$pass) { (@(& printf '[%s]' @pass) -join '') }
function verdict([string]$got) { if ($got -eq $want) { 'same' } else { "differs: $got" } }
$PSNativeCommandArgumentPassing = 'Standard'
'standard-detected ' + (_DenLegacyArgPassing)
'standard ' + (verdict (roundtrip @(_DenRelaunchArgs -CommandLineArgs $argv)))
$PSNativeCommandArgumentPassing = 'Windows'
'windows-detected ' + (_DenLegacyArgPassing)
$PSNativeCommandArgumentPassing = 'Legacy'
'legacy-detected ' + (_DenLegacyArgPassing)
'legacy ' + (verdict (roundtrip @(_DenRelaunchArgs -CommandLineArgs $argv -Legacy)))
'legacy-unquoted ' + ((verdict (roundtrip @(_DenRelaunchArgs -CommandLineArgs $argv))) -ne 'same')
EOF
ROUNDTRIP_OUT=$(run_pwsh "$HELPERS_PS1" ". '$WORK/relaunch_roundtrip.ps1'" | tr -d '\r')
roundtrip_case() { printf '%s\n' "$ROUNDTRIP_OUT" | grep -F -- "$1 " | head -n 1; }

echo "[pwsh] _DenLegacyArgPassing reads \$PSNativeCommandArgumentPassing"
assert_eq "pwsh/_DenLegacyArgPassing Standard" "standard-detected False" "$(roundtrip_case standard-detected)"
assert_eq "pwsh/_DenLegacyArgPassing Windows" "windows-detected False" "$(roundtrip_case windows-detected)"
assert_eq "pwsh/_DenLegacyArgPassing Legacy" "legacy-detected True" "$(roundtrip_case legacy-detected)"

echo "[pwsh] _DenRelaunchArgs round-trips through a native command"
assert_eq "pwsh/_DenRelaunchArgs round trip, Standard passing" "standard same" "$(roundtrip_case standard)"
assert_eq "pwsh/_DenRelaunchArgs -Legacy round trip, Legacy passing" "legacy same" "$(roundtrip_case legacy)"
assert_eq "pwsh/_DenRelaunchArgs unquoted breaks under Legacy passing" "legacy-unquoted True" "$(roundtrip_case legacy-unquoted)"

# Windows PowerShell 5.1 cannot run here, so its legacy passing is modelled from
# the binder it shares with PowerShell before PowerShell/PowerShell 8bca1f50c5
# (NativeCommandParameterBinder.appendOneNativeArgument): the arguments joined
# with a space, an empty one dropped, and one put in double quotes, as it is,
# when a whitespace character in it follows an even number of double quotes,
# escaped ones included. .NET splits ProcessStartInfo.Arguments by the Windows
# command-line rules on Linux too, which stands in for the new shell. The Windows
# CI job runs the real 5.1 (tests/shell/relaunch_argv.ps1).
cat > "$WORK/relaunch_ps51.ps1" <<'EOF'
function bind51([string[]]$tokens) {
    $parts = foreach ($t in $tokens) {
        $quotes = 0
        $wrap = $false
        foreach ($ch in $t.ToCharArray()) {
            if ($ch -eq '"') { $quotes++ } elseif ([char]::IsWhiteSpace($ch) -and $quotes % 2 -eq 0) { $wrap = $true }
        }
        if ($wrap) { '"' + $t + '"' } else { $t }
    }
    $parts -join ' '
}
function split51([string[]]$argv) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new('printf', '[%s] ' + (bind51 @(_DenRelaunchArgs -Legacy -CommandLineArgs $argv)))
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $want = ($argv | Select-Object -Skip 1 | ForEach-Object { "[$_]" }) -join ''
    if ($out -eq $want) { 'same' } else { "differs: $out" }
}
'vscode ' + (split51 @('powershell.exe', '-noexit', '-command', 'try { . "C:\Program Files\Microsoft VS Code\si.ps1" } catch {}'))
'dot ' + (split51 @('powershell.exe', '-noexit', '-command', '. "C:\Program Files\x\shellIntegration.ps1"'))
'spaces ' + (split51 @('powershell.exe', 'a b', 'two  spaces', "tab`there", 'dir with space\', 'C:\dir\', 'x\\'))
'quotes ' + (split51 @('powershell.exe', 'x"y', '"quoted"', 'say "hi there" now', 'a\"b', 'q"\', 'sp q" \\', 'end \"'))
'empty ' + (split51 @('powershell.exe', '', '-NoLogo', ''))
'odd-quotes ' + (split51 @('powershell.exe', '"C:\a b"'))
EOF
PS51_OUT=$(run_pwsh "$HELPERS_PS1" ". '$WORK/relaunch_ps51.ps1'" | tr -d '\r')
ps51_case() { printf '%s\n' "$PS51_OUT" | grep -F -- "$1 " | head -n 1; }

echo "[pwsh] _DenRelaunchArgs -Legacy survives Windows PowerShell 5.1's quoting (modelled)"
assert_eq "pwsh/_DenRelaunchArgs 5.1 VS Code payload" "vscode same" "$(ps51_case vscode)"
assert_eq "pwsh/_DenRelaunchArgs 5.1 dot-source payload" "dot same" "$(ps51_case dot)"
assert_eq "pwsh/_DenRelaunchArgs 5.1 spaces and trailing backslashes" "spaces same" "$(ps51_case spaces)"
assert_eq "pwsh/_DenRelaunchArgs 5.1 embedded quotes" "quotes same" "$(ps51_case quotes)"
assert_eq "pwsh/_DenRelaunchArgs 5.1 empty arguments" "empty same" "$(ps51_case empty)"
# The one shape 5.1 still splits, as the comment on _DenRelaunchArgs says.
assert_eq "pwsh/_DenRelaunchArgs 5.1 splits a quoted path with a space" \
    'odd-quotes differs: ["C:\a][b"]' "$(ps51_case odd-quotes)"

echo "[pwsh] _DenRelaunchArgs on a real launch drops only the program"
actual=$(pwsh -NoProfile -NonInteractive -Command ". '$HELPERS_PS1'; \$r = @(_DenRelaunchArgs -CommandLineArgs ([Environment]::GetCommandLineArgs())); '{0}|{1}|{2}' -f \$r.Count, \$r[0], \$r[1]" | tr -d '\r')
assert_eq "pwsh/_DenRelaunchArgs real launch" "4|-NoProfile|-NonInteractive" "$actual"

# reload resumes in the current directory: -WorkingDirectory, in every spelling
# pwsh reads, goes with its value, and so does -RemoveWorkingDirectoryTrailingCharacter.
# The same words after -Command, -File or a script path are payload and stay.
# Each line is `<label> <expected>`, run as `<label>|<arguments>` below.
cat > "$WORK/relaunch_wd_cases.ps1" <<'EOF'
function show([object[]]$a) { "n=$($a.Count):" + (($a | ForEach-Object { "<$_>" }) -join '') }
function rl([string[]]$rest) { show @(_DenRelaunchArgs -CommandLineArgs (@('pwsh.dll') + $rest)) }
$en = [string][char]0x2013; $em = [string][char]0x2014; $bar = [string][char]0x2015
foreach ($sw in '-WorkingDirectory', '-workingdirectory', '-WORKINGDIR', '-wor', '-wo', '-wd', '-WD',
    '--wd', '--workingdirectory', '/wd', '/WorkingDirectory', "${en}wd", "${em}wo", "${bar}workingdirectory", ' -wd ') {
    "spelling[$sw] " + (rl @('-NoLogo', $sw, '/a b', '-NoExit'))
}
'first ' + (rl @('-wd', '/a', '-NoLogo'))
'last ' + (rl @('-NoLogo', '-wd', '/a'))
'twice ' + (rl @('-wd', '/a', '-NoLogo', '--wd', '/b'))
'switch-like-value ' + (rl @('-wd', '-NoExit', '-NoLogo'))
'missing-value ' + (rl @('-NoLogo', '-wd'))
'trailing-char ' + (rl @('-NoExit', '-RemoveWorkingDirectoryTrailingCharacter', '-WorkingDirectory', 'C:\x!', '-Command', 'x'))
'trailing-char-abbrev ' + (rl @('-removeworkingdirectory', '-wd', '/a'))
'w-is-windowstyle ' + (rl @('-w', 'Hidden', '-NoExit'))
'after-command ' + (rl @('-noexit', '-command', 'Set-Location', '-wd', '/a'))
'after-command-whole ' + (rl @('-noexit', '-c', 'pwsh -wd /a'))
'after-file ' + (rl @('-NoExit', '-File', 's.ps1', '-wd', '/a'))
'after-script ' + (rl @('s.ps1', '-WorkingDirectory', '/a'))
'after-cwa ' + (rl @('-noexit', '-cwa', '$args', '-wd', '/a'))
'after-encoded ' + (rl @('-enc', 'Zm9v', '-wd', '/a', '-noexit'))
'wd-value-of-value ' + (rl @('-ep', '-wd', '-NoExit'))
'legacy ' + (show @(_DenRelaunchArgs -Legacy -CommandLineArgs @('pwsh.dll', '-wd', '/a b', '-noexit', '-c', 'x')))
EOF
RELAUNCH_WD_OUT=$(run_pwsh "$HELPERS_PS1" ". '$WORK/relaunch_wd_cases.ps1'" | tr -d '\r')
relaunch_wd_case() { printf '%s\n' "$RELAUNCH_WD_OUT" | grep -F -- "$1 " | head -n 1; }

echo "[pwsh] _DenRelaunchArgs drops -WorkingDirectory in every spelling"
# One line per spelling (the dashes come from PowerShell, so the locale does not matter).
assert_eq "pwsh/_DenRelaunchArgs spellings tried" "15" "$(printf '%s\n' "$RELAUNCH_WD_OUT" | grep -c '^spelling\[')"
while IFS= read -r line; do
    assert_eq "pwsh/_DenRelaunchArgs drops ${line%% n=*} and its value" "${line%% n=*} n=2:<-NoLogo><-NoExit>" "$line"
done < <(printf '%s\n' "$RELAUNCH_WD_OUT" | grep '^spelling\[')
assert_eq "pwsh/_DenRelaunchArgs drops -wd first" "first n=1:<-NoLogo>" "$(relaunch_wd_case first)"
assert_eq "pwsh/_DenRelaunchArgs drops -wd last" "last n=1:<-NoLogo>" "$(relaunch_wd_case last)"
assert_eq "pwsh/_DenRelaunchArgs drops every -wd" "twice n=1:<-NoLogo>" "$(relaunch_wd_case twice)"
assert_eq "pwsh/_DenRelaunchArgs drops a -wd value that looks like a switch" \
    "switch-like-value n=1:<-NoLogo>" "$(relaunch_wd_case switch-like-value)"
assert_eq "pwsh/_DenRelaunchArgs drops a -wd without a value" "missing-value n=1:<-NoLogo>" "$(relaunch_wd_case missing-value)"

echo "[pwsh] _DenRelaunchArgs drops -RemoveWorkingDirectoryTrailingCharacter"
assert_eq "pwsh/_DenRelaunchArgs Explorer's Open here launch" \
    "trailing-char n=3:<-NoExit><-Command><x>" "$(relaunch_wd_case trailing-char)"
assert_eq "pwsh/_DenRelaunchArgs keeps an abbreviated trailing-character switch (a script path to pwsh)" \
    "trailing-char-abbrev n=3:<-removeworkingdirectory><-wd></a>" "$(relaunch_wd_case trailing-char-abbrev)"
assert_eq "pwsh/_DenRelaunchArgs keeps -w (WindowStyle)" "w-is-windowstyle n=3:<-w><Hidden><-NoExit>" "$(relaunch_wd_case w-is-windowstyle)"

echo "[pwsh] _DenRelaunchArgs keeps -wd inside a payload"
assert_eq "pwsh/_DenRelaunchArgs -wd after -command" \
    "after-command n=5:<-noexit><-command><Set-Location><-wd></a>" "$(relaunch_wd_case after-command)"
assert_eq "pwsh/_DenRelaunchArgs -wd in the -c text" "after-command-whole n=3:<-noexit><-c><pwsh -wd /a>" "$(relaunch_wd_case after-command-whole)"
assert_eq "pwsh/_DenRelaunchArgs -wd after -File" \
    "after-file n=5:<-NoExit><-File><s.ps1><-wd></a>" "$(relaunch_wd_case after-file)"
assert_eq "pwsh/_DenRelaunchArgs -wd after a script path" \
    "after-script n=3:<s.ps1><-WorkingDirectory></a>" "$(relaunch_wd_case after-script)"
assert_eq "pwsh/_DenRelaunchArgs -wd after -cwa" \
    'after-cwa n=5:<-noexit><-cwa><$args><-wd></a>' "$(relaunch_wd_case after-cwa)"
assert_eq "pwsh/_DenRelaunchArgs -wd after -enc's value is a switch" \
    "after-encoded n=3:<-enc><Zm9v><-noexit>" "$(relaunch_wd_case after-encoded)"
assert_eq "pwsh/_DenRelaunchArgs -wd as another switch's value stays" \
    "wd-value-of-value n=3:<-ep><-wd><-NoExit>" "$(relaunch_wd_case wd-value-of-value)"
assert_eq "pwsh/_DenRelaunchArgs -Legacy drops -wd before quoting" \
    'legacy n=3:<-noexit><-c><x>' "$(relaunch_wd_case legacy)"

# --- _DenVSCodeEnv: what VS Code's shell integration took out of the environment ---
# The integration script moves VSCODE_NONCE, _STABLE, _A11Y_MODE and
# _SHELL_ENV_REPORTING into $Global:__VSCodeState; reload hands them back.
cat > "$WORK/vscode_env.ps1" <<'EOF'
function envs([hashtable]$h) { "n=$($h.Count):" + (($h.Keys | Sort-Object | ForEach-Object { "$_=$($h[$_])" }) -join ';') }
'outside ' + (envs (_DenVSCodeEnv))
$Global:__VSCodeState = @{ Nonce = 'n0'; IsStable = '1'; IsA11yMode = $null; EnvVarsToReport = @('PATH', 'VIRTUAL_ENV') }
'full ' + (envs (_DenVSCodeEnv))
$Global:__VSCodeState = @{ Nonce = ''; IsA11yMode = '1'; EnvVarsToReport = @() }
'a11y ' + (envs (_DenVSCodeEnv))
EOF
VSENV_OUT=$(run_pwsh "$HELPERS_PS1" ". '$WORK/vscode_env.ps1'" | tr -d '\r')
vsenv_case() { printf '%s\n' "$VSENV_OUT" | grep -F -- "$1 " | head -n 1; }

echo "[pwsh] _DenVSCodeEnv outside VS Code"
assert_eq "pwsh/_DenVSCodeEnv outside VS Code" "outside n=0:" "$(vsenv_case outside)"
echo "[pwsh] _DenVSCodeEnv restores what the integration script took"
assert_eq "pwsh/_DenVSCodeEnv full state" \
    "full n=3:VSCODE_NONCE=n0;VSCODE_SHELL_ENV_REPORTING=PATH,VIRTUAL_ENV;VSCODE_STABLE=1" "$(vsenv_case full)"
assert_eq "pwsh/_DenVSCodeEnv skips empty values" "a11y n=1:VSCODE_A11Y_MODE=1" "$(vsenv_case a11y)"

# --- reload (init.ps1) starts pwsh again ---
# reload used to dot-source $PROFILE inside its own function scope, so a function
# added to the config was gone again when reload returned. It now starts the same
# pwsh with the same arguments, waits, and exits with its exit code. These tests
# run den's config from a copy (so a test can add to functions.ps1) under a
# scratch HOME whose profile prints the PID of every shell that loads it.
RL_HOME="$WORK/reload_home"
RL_CFG="$WORK/reload_cfg"
mkdir -p "$RL_HOME/.config/powershell" "$RL_CFG" "$WORK/reload dir"
cp "$DOTFILES"/shell/pwsh/*.ps1 "$RL_CFG/"
# The profile also ends a runaway chain of reloads: the fifth nested shell exits 99.
printf '%s\n' '$env:_RL_LOADS = 1 + [int]$env:_RL_LOADS' \
    'if ([int]$env:_RL_LOADS -gt 4) { "RUNAWAY"; [Environment]::Exit(99) }' \
    '"PROFILE-LOADED PID=$PID"' ". '$RL_CFG/init.ps1'" >"$RL_HOME/.config/powershell/Microsoft.PowerShell_profile.ps1"
# si.ps1 stands in for VS Code's shellIntegration.ps1, which moves VSCODE_NONCE
# out of the environment into $Global:__VSCodeState.
printf '%s\n' \
    'if (-not (Test-Path variable:global:__VSCodeState)) { $Global:__VSCodeState = @{ Nonce = $env:VSCODE_NONCE }; $env:VSCODE_NONCE = $null }' \
    '"SI-LOADED ARGS=$(([Environment]::GetCommandLineArgs() | Select-Object -Skip 1) -join "|")"' \
    '"SI-NONCE=[$($Global:__VSCodeState.Nonce)] ENV=[$env:VSCODE_NONCE]"' >"$WORK/reload dir/si.ps1"

# run_reload_session <pwsh args...> - start pwsh as a REPL on pipes, add a function
# to a fresh copy of functions.ps1 and run reload; once a second shell has loaded
# the profile, call that function (it prints its PID and directory) and exit 7.
# RL_PRE, when set, is a line run just before reload. VSCODE_NONCE is set, as
# VS Code sets it. Prints the output, then RC=<exit code>. The second half of the
# input goes out only then, so the relaunched shell reads it.
run_reload_session() {
    local line out='' loaded=0 rc pid rfd wfd
    cp "$DOTFILES/shell/pwsh/functions.ps1" "$RL_CFG/functions.ps1"
    coproc RLS { env -u _DEN_FORCE_INTERACTIVE VSCODE_NONCE=rl-nonce HOME="$RL_HOME" XDG_CONFIG_HOME="$RL_HOME/.config" timeout 90 pwsh -NoLogo "$@" 2>&1; }
    pid=$RLS_PID
    exec {rfd}<&"${RLS[0]}" {wfd}>&"${RLS[1]}"
    printf '%s\n' "Add-Content -LiteralPath '$RL_CFG/functions.ps1' -Value 'function reload-probe { \"PROBE-OK PID=\$PID PWD=[\$(\$PWD.Path)]\" }'" \
        ${RL_PRE:+"$RL_PRE"} 'reload' >&"$wfd"
    while IFS= read -r -t 60 line <&"$rfd"; do
        out+="$line"$'\n'
        case "$line" in *PROFILE-LOADED*) loaded=$((loaded + 1)) ;; esac
        [ "$loaded" -ge 2 ] && break
    done
    printf '%s\n' 'reload-probe' 'exit 7' >&"$wfd"
    exec {wfd}>&-
    while IFS= read -r -t 60 line <&"$rfd"; do out+="$line"$'\n'; done
    exec {rfd}<&-
    wait "$pid"
    rc=$?
    printf '%sRC=%s\n' "$out" "$rc"
}

echo "[pwsh] reload starts a new pwsh that sees a function added to the config"
# reload_pid <n> - the PID of the nth shell that loaded the profile in RL_OUT.
reload_pid() { printf '%s\n' "$RL_OUT" | grep -oE 'PROFILE-LOADED PID=[0-9]+' | sed -n "$1s/.*=//p"; }
RL_OUT=$(run_reload_session | tr -d '\r')
RL_PID1=$(reload_pid 1)
RL_PID2=$(reload_pid 2)
assert_match "pwsh/reload loads the profile in a second shell" '^[0-9]+$' "$RL_PID2"
if [ -n "$RL_PID2" ] && [ "$RL_PID1" != "$RL_PID2" ]; then actual=new; else actual=same; fi
assert_eq "pwsh/reload runs a new process" "new" "$actual"
assert_contains "pwsh/reload makes the added function visible" "PROBE-OK PID=$RL_PID2" "$RL_OUT"
assert_contains "pwsh/reload exits with the new shell's exit code" "RC=7" "$RL_OUT"

echo "[pwsh] reload keeps the launch arguments (VS Code's -noexit -command)"
RL_PAYLOAD="try { . \"$WORK/reload dir/si.ps1\" } catch {}"
RL_OUT=$(run_reload_session -noexit -command "$RL_PAYLOAD" | tr -d '\r')
RL_SI=$(printf '%s\n' "$RL_OUT" | grep -oE 'SI-LOADED ARGS=.*')
assert_eq "pwsh/reload runs the -command payload again" "2" "$(printf '%s\n' "$RL_SI" | grep -c 'SI-LOADED')"
assert_eq "pwsh/reload passes the same arguments" "SI-LOADED ARGS=-NoLogo|-noexit|-command|$RL_PAYLOAD" "$(printf '%s\n' "$RL_SI" | sed -n 2p)"
assert_contains "pwsh/reload under -noexit -command sees the added function" "PROBE-OK PID=$(reload_pid 2)" "$RL_OUT"
assert_contains "pwsh/reload under -noexit -command exits with the new shell's code" "RC=7" "$RL_OUT"
assert_eq "pwsh/reload hands VS Code's nonce back to the new shell" \
    "SI-NONCE=[rl-nonce] ENV=[]"$'\n'"SI-NONCE=[rl-nonce] ENV=[]" "$(printf '%s\n' "$RL_OUT" | grep -oE 'SI-NONCE=.*')"

# reload starts the new shell where the old one is now: a -WorkingDirectory from
# the launch is left out, not applied again. The first shell starts in "wd start",
# moves to "wd moved" and reloads.
RL_WD="$WORK/reload wd"
mkdir -p "$RL_WD/start" "$RL_WD/moved"
RL_MOVE="\"START-PWD=[\$(\$PWD.Path)]\"; Set-Location -LiteralPath '$RL_WD/moved'"

echo "[pwsh] reload resumes in the current directory, not at -wd"
RL_OUT=$(RL_PRE="$RL_MOVE" run_reload_session -wd "$RL_WD/start" | tr -d '\r')
assert_contains "pwsh/reload -wd: the first shell started at -wd" "START-PWD=[$RL_WD/start]" "$RL_OUT"
assert_contains "pwsh/reload -wd: the new shell is in the current directory" \
    "PROBE-OK PID=$(reload_pid 2) PWD=[$RL_WD/moved]" "$RL_OUT"
assert_contains "pwsh/reload -wd exits with the new shell's code" "RC=7" "$RL_OUT"

echo "[pwsh] reload resumes in the current directory with -WorkingDirectory and a -noexit -command payload"
RL_OUT=$(RL_PRE="$RL_MOVE" run_reload_session -WorkingDirectory "$RL_WD/start" -noexit -command "$RL_PAYLOAD" | tr -d '\r')
RL_SI=$(printf '%s\n' "$RL_OUT" | grep -oE 'SI-LOADED ARGS=.*')
assert_eq "pwsh/reload -WorkingDirectory: the first shell has it" \
    "SI-LOADED ARGS=-NoLogo|-WorkingDirectory|$RL_WD/start|-noexit|-command|$RL_PAYLOAD" "$(printf '%s\n' "$RL_SI" | sed -n 1p)"
assert_eq "pwsh/reload -WorkingDirectory: the new shell gets the rest" \
    "SI-LOADED ARGS=-NoLogo|-noexit|-command|$RL_PAYLOAD" "$(printf '%s\n' "$RL_SI" | sed -n 2p)"
assert_contains "pwsh/reload -WorkingDirectory: the new shell is in the current directory" \
    "PROBE-OK PID=$(reload_pid 2) PWD=[$RL_WD/moved]" "$RL_OUT"

# A -Command or -File run is no REPL, so reload only clears the caches and warns.
# _DEN_FORCE_INTERACTIVE=1 must not change that. The script calls reload only on
# its first run, so a guard that failed shows up as a second run, not a loop.
cat >"$WORK/reload_guard.ps1" <<EOF
\$runs = @(Get-Content -LiteralPath '$WORK/reload_runs.txt').Count
Add-Content -LiteralPath '$WORK/reload_runs.txt' -Value \$PID
. '$RL_CFG/init.ps1'
if (\$runs -eq 0) { reload }
'AFTER-RELOAD'
EOF

echo "[pwsh] reload does not restart a -Command run"
: >"$WORK/reload_runs.txt"
actual=$(env HOME="$RL_HOME" XDG_CONFIG_HOME="$RL_HOME/.config" _DEN_FORCE_INTERACTIVE=1 timeout 60 pwsh -NoProfile -Command ". '$WORK/reload_guard.ps1'" 2>&1 | tr -d '\r')
assert_contains "pwsh/reload -Command warns" "reload: caches cleared, but not restarting" "$actual"
assert_contains "pwsh/reload -Command continues" "AFTER-RELOAD" "$actual"
assert_eq "pwsh/reload -Command runs once" "1" "$(grep -c . "$WORK/reload_runs.txt")"

echo "[pwsh] reload does not restart a -File run"
: >"$WORK/reload_runs.txt"
actual=$(env -u _DEN_FORCE_INTERACTIVE HOME="$RL_HOME" XDG_CONFIG_HOME="$RL_HOME/.config" timeout 60 pwsh -NoProfile -File "$WORK/reload_guard.ps1" 2>&1 | tr -d '\r')
assert_contains "pwsh/reload -File warns" "reload: caches cleared, but not restarting" "$actual"
assert_contains "pwsh/reload -File continues" "AFTER-RELOAD" "$actual"
assert_eq "pwsh/reload -File runs once" "1" "$(grep -c . "$WORK/reload_runs.txt")"

# When the executable cannot be started, reload warns and the session goes on
# (it must not exit). Get-Process is shadowed to report a missing executable.
echo "[pwsh] reload stays in the session when pwsh cannot be started"
actual=$(printf '%s\n' "function Get-Process { [pscustomobject]@{ Path = '$WORK/no-such-pwsh' } }" 'reload' '"STILL-HERE DEPTH-ENV=[$env:_DEN_RELOAD_DEPTH]"' 'exit 3' |
    env -u _DEN_FORCE_INTERACTIVE HOME="$RL_HOME" XDG_CONFIG_HOME="$RL_HOME/.config" timeout 60 pwsh -NoLogo 2>&1 | tr -d '\r'
    echo "RC=${PIPESTATUS[1]}")
assert_contains "pwsh/reload start failure warns" "reload: could not start" "$actual"
assert_contains "pwsh/reload start failure keeps the session" "STILL-HERE DEPTH-ENV=[]" "$actual"
assert_contains "pwsh/reload start failure exit code is the session's" "RC=3" "$actual"

# exit in a nested prompt (the debugger's, $Host.EnterNestedPrompt()) only leaves
# that prompt, so a shell started from there would, once it ended, drop the user
# back into this stale session. reload warns instead.
echo "[pwsh] reload does not restart from a nested prompt"
actual=$(printf '%s\n' '$Host.EnterNestedPrompt()' 'reload' '"NESTED-AFTER LEVEL=$NestedPromptLevel PID=$PID"' 'exit' 'exit 3' |
    env -u _DEN_FORCE_INTERACTIVE HOME="$RL_HOME" XDG_CONFIG_HOME="$RL_HOME/.config" timeout 60 pwsh -NoLogo 2>&1 | tr -d '\r'
    echo "RC=${PIPESTATUS[1]}")
RL_PID1=$(printf '%s\n' "$actual" | grep -oE 'PROFILE-LOADED PID=[0-9]+' | sed -n '1s/.*=//p')
assert_contains "pwsh/reload nested prompt warns" "not restarting: reload was called from a nested prompt" "$actual"
assert_contains "pwsh/reload nested prompt stays in the session" "NESTED-AFTER LEVEL=1 PID=$RL_PID1" "$actual"
assert_eq "pwsh/reload nested prompt starts no shell" "1" "$(printf '%s\n' "$actual" | grep -c 'PROFILE-LOADED')"
assert_contains "pwsh/reload nested prompt exit code" "RC=3" "$actual"

# A reload in the startup payload runs again in every shell it starts. The count of
# reloads in a row travels in _DEN_RELOAD_DEPTH; starting at 7, the first reload
# starts the eighth shell, whose own startup reload must refuse.
echo "[pwsh] reload stops after 8 reloads in a row"
actual=$(printf '%s\n' '"DEEPEST DEPTH=$_DenReloadDepth ENV=[$env:_DEN_RELOAD_DEPTH]"' 'exit 5' |
    env -u _DEN_FORCE_INTERACTIVE _DEN_RELOAD_DEPTH=7 HOME="$RL_HOME" XDG_CONFIG_HOME="$RL_HOME/.config" timeout 60 pwsh -NoLogo -NoExit -Command reload 2>&1 | tr -d '\r'
    echo "RC=${PIPESTATUS[1]}")
assert_eq "pwsh/reload limit starts one more shell" "2" "$(printf '%s\n' "$actual" | grep -c 'PROFILE-LOADED')"
assert_contains "pwsh/reload limit warns" "not restarting: 8 reloads in a row led to this shell" "$actual"
assert_contains "pwsh/reload limit passes the count on, out of the environment" "DEEPEST DEPTH=8 ENV=[]" "$actual"
assert_contains "pwsh/reload limit exit code" "RC=5" "$actual"

# The call operator takes a '--%' element as its own stop-parsing token, so such
# launch arguments cannot be passed on.
echo "[pwsh] reload does not restart a launch whose arguments hold --%"
actual=$(printf '%s\n' 'reload' 'exit 6' |
    env -u _DEN_FORCE_INTERACTIVE HOME="$RL_HOME" XDG_CONFIG_HOME="$RL_HOME/.config" timeout 60 pwsh -NoLogo -NoExit -Command echo --% x 2>&1 | tr -d '\r'
    echo "RC=${PIPESTATUS[1]}")
assert_contains "pwsh/reload --% warns" "not restarting: its launch arguments hold '--%'" "$actual"
assert_eq "pwsh/reload --% starts no shell" "1" "$(printf '%s\n' "$actual" | grep -c 'PROFILE-LOADED')"
assert_contains "pwsh/reload --% exit code" "RC=6" "$actual"

# =============================================================================
# Summary
# =============================================================================
print_summary "test_helpers"
[ "$FAIL" -eq 0 ]
