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
    \$log1 = myecho test1 6>&1 | Where-Object { \$_ -match 'dotfiles' }
    \$log2 = myecho test2 6>&1 | Where-Object { \$_ -match 'dotfiles' }
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
    Initialize-Cache 'pwshcachetool' 'powershell'
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
    Initialize-Cache 'pwshcachetool' 'powershell'
    \$cacheFile = Join-Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'shell-cache') 'pwshcachetool-init.ps1'
    Get-Content -Raw -LiteralPath \$cacheFile
" 2>/dev/null | tr -d '\r')
assert_contains "pwsh/Initialize-Cache regenerated" "v2:powershell" "$actual"
run_pwsh "$HELPERS_PS1" "
    Remove-Item -LiteralPath (Join-Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'shell-cache') 'pwshcachetool-init.ps1') -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\PWSH_CACHE_TEST -ErrorAction SilentlyContinue
" >/dev/null 2>&1

# =============================================================================
# Summary
# =============================================================================
print_summary "test_helpers"
[ "$FAIL" -eq 0 ]
