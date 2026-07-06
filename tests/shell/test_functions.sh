#!/usr/bin/env bash
# test_functions.sh — Tests for functions.sh (bash/zsh) and functions.ps1 (pwsh).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

HELPERS_SH="$DOTFILES/shell/posix/_helpers.sh"
FUNCTIONS_SH_GUARDED="$DOTFILES/shell/posix/functions.sh"
FUNCTIONS_SH="/tmp/functions_test_$$.sh"
HELPERS_PS1="$DOTFILES/shell/pwsh/_helpers.ps1"
FUNCTIONS_PS1="$DOTFILES/shell/pwsh/functions.ps1"

make_noninteractive_source_copy "$FUNCTIONS_SH_GUARDED" "$FUNCTIONS_SH"

# PowerShell functions.ps1 now depends on _helpers.ps1 (Initialize-Cache).
# Create a combined PS1 that loads helpers first.
FUNCTIONS_PS1_COMBINED="/tmp/functions_combined_$$.ps1"
{
    echo ". '$HELPERS_PS1'"
    cat "$FUNCTIONS_PS1"
} > "$FUNCTIONS_PS1_COMBINED"
_cleanup_functions() { rm -f "$FUNCTIONS_PS1_COMBINED" "$FUNCTIONS_SH"; }
trap '_cleanup_functions' EXIT

# =============================================================================
# Helper: create a known test file for hash tests
# =============================================================================
setup_hash_file() {
    echo -n "test content" > "$WORK/hashfile.txt"
}

# Expected hashes of "test content" (no trailing newline)
EXPECTED_MD5="9473fdd0d880a43c21b7778d34872157"
EXPECTED_SHA256="6ae8a75555209fd6c44157c0aed8016e763ff435a19cf186f76863140143ff72"
EXPECTED_SHA512="0cbf4caef38047bba9a24e621a961484e5d2a92176a859e7eb27df343dd34eb98d538a6c5f4da1ce302ec250b821cc001e46cc97a704988297185a4df7e99602"

# =============================================================================
# Bash tests
# =============================================================================
echo "================================================"
echo "  Testing functions.sh with BASH"
echo "================================================"

echo "[bash] guard: non-interactive source skips functions"
actual=$(bash -c "
    source '$FUNCTIONS_SH_GUARDED'
    type digest >/dev/null 2>&1 && echo 'DEFINED' || echo 'UNDEFINED'
" | tr -d '\r')
assert_eq "bash/guard non-interactive" "UNDEFINED" "$actual"

# --- digest ---
echo "[bash] digest md5"
setup_hash_file
actual=$(run_bash "$FUNCTIONS_SH" "digest md5 '$WORK/hashfile.txt'")
assert_eq "bash/digest md5" "$EXPECTED_MD5" "$actual"

echo "[bash] digest sha256"
setup_hash_file
actual=$(run_bash "$FUNCTIONS_SH" "digest sha256 '$WORK/hashfile.txt'")
assert_eq "bash/digest sha256" "$EXPECTED_SHA256" "$actual"

echo "[bash] digest bad algo"
actual=$(run_bash "$FUNCTIONS_SH" "digest bad '$WORK/hashfile.txt' 2>&1; echo \$?")
assert_contains "bash/digest bad usage" "usage" "$actual"

echo "[bash] digest sha512"
setup_hash_file
actual=$(run_bash "$FUNCTIONS_SH" "digest sha512 '$WORK/hashfile.txt'")
assert_eq "bash/digest sha512" "$EXPECTED_SHA512" "$actual"

# --- mkfile ---
echo "[bash] mkfile"
run_bash "$FUNCTIONS_SH" "mkfile 1K '$WORK/dummy.bin'" >/dev/null
assert_success "bash/mkfile exit code" "$?"
assert_exists "bash/mkfile created" "$WORK/dummy.bin"
actual=$(stat -c%s "$WORK/dummy.bin")
assert_eq "bash/mkfile size" "1024" "$actual"
rm -f "$WORK/dummy.bin"

# --- archive + extract (tar.gz) ---
echo "[bash] archive + extract tar.gz"
setup_fixtures
run_bash "$FUNCTIONS_SH" "archive '$WORK/test.tar.gz' -C '$WORK' src" 2>/dev/null
assert_success "bash/archive tar.gz exit code" "$?"
assert_exists "bash/archive tar.gz" "$WORK/test.tar.gz"
mkdir -p "$WORK/extracted"
cp "$WORK/test.tar.gz" "$WORK/extracted/"
run_bash "$FUNCTIONS_SH" "cd '$WORK/extracted' && extract '$WORK/extracted/test.tar.gz'"
assert_success "bash/extract tar.gz exit code" "$?"
assert_exists "bash/extract tar.gz" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.tar.gz" "$WORK/extracted"

# --- archive + extract (zip) ---
echo "[bash] archive + extract zip"
setup_fixtures
run_bash "$FUNCTIONS_SH" "cd '$WORK' && archive '$WORK/test.zip' src" 2>/dev/null
assert_success "bash/archive zip exit code" "$?"
assert_exists "bash/archive zip" "$WORK/test.zip"
mkdir -p "$WORK/extracted"
run_bash "$FUNCTIONS_SH" "cd '$WORK/extracted' && extract '$WORK/test.zip'"
assert_success "bash/extract zip exit code" "$?"
assert_exists "bash/extract zip" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.zip" "$WORK/extracted"

echo "[bash] archive + extract tar.bz2"
setup_fixtures
run_bash "$FUNCTIONS_SH" "archive '$WORK/test.tar.bz2' -C '$WORK' src" 2>/dev/null
assert_success "bash/archive tar.bz2 exit code" "$?"
assert_exists "bash/archive tar.bz2" "$WORK/test.tar.bz2"
mkdir -p "$WORK/extracted"
cp "$WORK/test.tar.bz2" "$WORK/extracted/"
run_bash "$FUNCTIONS_SH" "cd '$WORK/extracted' && extract 'test.tar.bz2'" 2>/dev/null
assert_success "bash/extract tar.bz2 exit code" "$?"
assert_exists "bash/extract tar.bz2" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.tar.bz2" "$WORK/extracted"

echo "[bash] archive + extract tar.xz"
setup_fixtures
run_bash "$FUNCTIONS_SH" "archive '$WORK/test.tar.xz' -C '$WORK' src" 2>/dev/null
assert_success "bash/archive tar.xz exit code" "$?"
assert_exists "bash/archive tar.xz" "$WORK/test.tar.xz"
mkdir -p "$WORK/extracted"
cp "$WORK/test.tar.xz" "$WORK/extracted/"
run_bash "$FUNCTIONS_SH" "cd '$WORK/extracted' && extract 'test.tar.xz'" 2>/dev/null
assert_success "bash/extract tar.xz exit code" "$?"
assert_exists "bash/extract tar.xz" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.tar.xz" "$WORK/extracted"

echo "[bash] extract unsupported format"
touch "$WORK/test.foo"
actual=$(run_bash "$FUNCTIONS_SH" "extract '$WORK/test.foo' 2>&1")
assert_contains "bash/extract unsupported" "unsupported" "$actual"
rm -f "$WORK/test.foo"

# --- path ---
echo "[bash] path"
actual=$(run_bash "$FUNCTIONS_SH" "path")
assert_contains "bash/path contains /usr" "/usr" "$actual"

# --- up ---
echo "[bash] up"
actual=$(run_bash "$FUNCTIONS_SH" "mkdir -p '$WORK/a/b/c' && cd '$WORK/a/b/c' && up 2 && pwd")
assert_eq "bash/up 2" "$WORK/a" "$actual"

# --- mkcd ---
echo "[bash] mkcd"
actual=$(run_bash "$FUNCTIONS_SH" "mkcd '$WORK/newdir' && pwd")
assert_eq "bash/mkcd" "$WORK/newdir" "$actual"
assert_exists "bash/mkcd dir" "$WORK/newdir"
rm -rf "$WORK/newdir"

# --- again / sagain / back ---
echo "[bash] again 0"
err=$(run_bash_stderr "$FUNCTIONS_SH" "again 0")
assert_contains "bash/again 0 usage" "usage" "$err"

echo "[bash] again abc"
err=$(run_bash_stderr "$FUNCTIONS_SH" "again abc")
assert_contains "bash/again abc usage" "usage" "$err"

echo "[bash] again no history"
err=$(run_bash_stderr "$FUNCTIONS_SH" "again")
assert_contains "bash/again no history" "no command at position" "$err"

echo "[bash] sagain 0"
err=$(run_bash_stderr "$FUNCTIONS_SH" "sagain 0")
assert_contains "bash/sagain 0 usage" "usage" "$err"

echo "[bash] back 0"
err=$(run_bash_stderr "$FUNCTIONS_SH" "back 0")
assert_contains "bash/back 0 usage" "usage" "$err"

echo "[bash] back 2"
err=$(run_bash_stderr "$FUNCTIONS_SH" "back 2")
assert_contains "bash/back 2 unsupported" "only N=1" "$err"

echo "[bash] back with OLDPWD"
actual=$(run_bash "$FUNCTIONS_SH" "cd /tmp && cd /root && back" 2>/dev/null)
assert_eq "bash/back OLDPWD" "/tmp" "$actual"

# =============================================================================
# Zsh tests
# =============================================================================
echo ""
echo "================================================"
echo "  Testing functions.sh with ZSH"
echo "================================================"

echo "[zsh] digest md5"
setup_hash_file
actual=$(run_zsh "$FUNCTIONS_SH" "digest md5 '$WORK/hashfile.txt'")
assert_eq "zsh/digest md5" "$EXPECTED_MD5" "$actual"

echo "[zsh] digest sha256"
setup_hash_file
actual=$(run_zsh "$FUNCTIONS_SH" "digest sha256 '$WORK/hashfile.txt'")
assert_eq "zsh/digest sha256" "$EXPECTED_SHA256" "$actual"

echo "[zsh] digest sha512"
setup_hash_file
actual=$(run_zsh "$FUNCTIONS_SH" "digest sha512 '$WORK/hashfile.txt'")
assert_eq "zsh/digest sha512" "$EXPECTED_SHA512" "$actual"

echo "[zsh] mkfile"
run_zsh "$FUNCTIONS_SH" "mkfile 1K '$WORK/dummy.bin'" >/dev/null
assert_success "zsh/mkfile exit code" "$?"
assert_exists "zsh/mkfile created" "$WORK/dummy.bin"
actual=$(stat -c%s "$WORK/dummy.bin")
assert_eq "zsh/mkfile size" "1024" "$actual"
rm -f "$WORK/dummy.bin"

echo "[zsh] archive + extract tar.gz"
setup_fixtures
run_zsh "$FUNCTIONS_SH" "archive '$WORK/test.tar.gz' -C '$WORK' src" 2>/dev/null
assert_success "zsh/archive tar.gz exit code" "$?"
assert_exists "zsh/archive tar.gz" "$WORK/test.tar.gz"
mkdir -p "$WORK/extracted"
cp "$WORK/test.tar.gz" "$WORK/extracted/"
run_zsh "$FUNCTIONS_SH" "cd '$WORK/extracted' && extract '$WORK/extracted/test.tar.gz'"
assert_success "zsh/extract tar.gz exit code" "$?"
assert_exists "zsh/extract tar.gz" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.tar.gz" "$WORK/extracted"

echo "[zsh] archive + extract zip"
setup_fixtures
run_zsh "$FUNCTIONS_SH" "cd '$WORK' && archive '$WORK/test.zip' src" 2>/dev/null
assert_success "zsh/archive zip exit code" "$?"
assert_exists "zsh/archive zip" "$WORK/test.zip"
mkdir -p "$WORK/extracted"
run_zsh "$FUNCTIONS_SH" "cd '$WORK/extracted' && extract '$WORK/test.zip'"
assert_success "zsh/extract zip exit code" "$?"
assert_exists "zsh/extract zip" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.zip" "$WORK/extracted"

echo "[zsh] archive + extract tar.bz2"
setup_fixtures
run_zsh "$FUNCTIONS_SH" "archive '$WORK/test.tar.bz2' -C '$WORK' src" 2>/dev/null
assert_success "zsh/archive tar.bz2 exit code" "$?"
assert_exists "zsh/archive tar.bz2" "$WORK/test.tar.bz2"
mkdir -p "$WORK/extracted"
cp "$WORK/test.tar.bz2" "$WORK/extracted/"
run_zsh "$FUNCTIONS_SH" "cd '$WORK/extracted' && extract 'test.tar.bz2'" 2>/dev/null
assert_success "zsh/extract tar.bz2 exit code" "$?"
assert_exists "zsh/extract tar.bz2" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.tar.bz2" "$WORK/extracted"

echo "[zsh] archive + extract tar.xz"
setup_fixtures
run_zsh "$FUNCTIONS_SH" "archive '$WORK/test.tar.xz' -C '$WORK' src" 2>/dev/null
assert_success "zsh/archive tar.xz exit code" "$?"
assert_exists "zsh/archive tar.xz" "$WORK/test.tar.xz"
mkdir -p "$WORK/extracted"
cp "$WORK/test.tar.xz" "$WORK/extracted/"
run_zsh "$FUNCTIONS_SH" "cd '$WORK/extracted' && extract 'test.tar.xz'" 2>/dev/null
assert_success "zsh/extract tar.xz exit code" "$?"
assert_exists "zsh/extract tar.xz" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.tar.xz" "$WORK/extracted"

echo "[zsh] path"
actual=$(run_zsh "$FUNCTIONS_SH" "path")
assert_contains "zsh/path contains /usr" "/usr" "$actual"

echo "[zsh] up"
actual=$(run_zsh "$FUNCTIONS_SH" "mkdir -p '$WORK/a/b/c' && cd '$WORK/a/b/c' && up 2 && pwd")
assert_eq "zsh/up 2" "$WORK/a" "$actual"

echo "[zsh] mkcd"
actual=$(run_zsh "$FUNCTIONS_SH" "mkcd '$WORK/newdir' && pwd")
assert_eq "zsh/mkcd" "$WORK/newdir" "$actual"
assert_exists "zsh/mkcd dir" "$WORK/newdir"
rm -rf "$WORK/newdir"

# --- again / back ---
echo "[zsh] again 0"
err=$(run_zsh_stderr "$FUNCTIONS_SH" "again 0")
assert_contains "zsh/again 0 usage" "usage" "$err"

echo "[zsh] again no history"
err=$(run_zsh_stderr "$FUNCTIONS_SH" "again")
assert_contains "zsh/again no history" "no command" "$err"

echo "[zsh] back 0"
err=$(run_zsh_stderr "$FUNCTIONS_SH" "back 0")
assert_contains "zsh/back 0 usage" "usage" "$err"

echo "[zsh] back 2"
err=$(run_zsh_stderr "$FUNCTIONS_SH" "back 2")
assert_contains "zsh/back 2 unsupported" "only N=1" "$err"

echo "[zsh] back with OLDPWD"
actual=$(run_zsh "$FUNCTIONS_SH" "cd /tmp && cd /root && back" 2>/dev/null)
assert_eq "zsh/back OLDPWD" "/tmp" "$actual"

# =============================================================================
# PowerShell tests
# =============================================================================
echo ""
echo "================================================"
echo "  Testing functions.ps1 with PWSH"
echo "================================================"

echo "[pwsh] digest md5"
setup_hash_file
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "digest md5 '$WORK/hashfile.txt'" 2>/dev/null)
# PowerShell returns UPPERCASE hex
assert_eq "pwsh/digest md5" "${EXPECTED_MD5^^}" "$actual"

echo "[pwsh] digest sha256"
setup_hash_file
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "digest sha256 '$WORK/hashfile.txt'" 2>/dev/null)
assert_eq "pwsh/digest sha256" "${EXPECTED_SHA256^^}" "$actual"

echo "[pwsh] digest sha512"
setup_hash_file
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "digest sha512 '$WORK/hashfile.txt'" 2>/dev/null | tail -1)
assert_eq "pwsh/digest sha512" "${EXPECTED_SHA512^^}" "$actual"

echo "[pwsh] mkfile"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "mkfile 1024 '$WORK/dummy.bin'" >/dev/null
assert_success "pwsh/mkfile exit code" "$?"
assert_exists "pwsh/mkfile created" "$WORK/dummy.bin"
actual=$(stat -c%s "$WORK/dummy.bin")
assert_eq "pwsh/mkfile size" "1024" "$actual"
rm -f "$WORK/dummy.bin"

echo "[pwsh] archive + extract tar.gz"
setup_fixtures
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK'; archive 'test.tar.gz' 'src'"
assert_success "pwsh/archive tar.gz exit code" "$?"
assert_exists "pwsh/archive tar.gz" "$WORK/test.tar.gz"
mkdir -p "$WORK/extracted"
cp "$WORK/test.tar.gz" "$WORK/extracted/"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/extracted'; extract 'test.tar.gz'"
assert_success "pwsh/extract tar.gz exit code" "$?"
assert_exists "pwsh/extract tar.gz" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.tar.gz" "$WORK/extracted"

echo "[pwsh] archive + extract zip"
setup_fixtures
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK'; archive 'test.zip' 'src'"
assert_success "pwsh/archive zip exit code" "$?"
assert_exists "pwsh/archive zip" "$WORK/test.zip"
mkdir -p "$WORK/extracted"
cp "$WORK/test.zip" "$WORK/extracted/"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/extracted'; extract '$WORK/extracted/test.zip'"
assert_success "pwsh/extract zip exit code" "$?"
assert_exists "pwsh/extract zip" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.zip" "$WORK/extracted"

echo "[pwsh] archive + extract tar.bz2"
setup_fixtures
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK'; archive 'test.tar.bz2' 'src'" 2>/dev/null
assert_success "pwsh/archive tar.bz2 exit code" "$?"
assert_exists "pwsh/archive tar.bz2" "$WORK/test.tar.bz2"
mkdir -p "$WORK/extracted"
cp "$WORK/test.tar.bz2" "$WORK/extracted/"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/extracted'; extract 'test.tar.bz2'"
assert_success "pwsh/extract tar.bz2 exit code" "$?"
assert_exists "pwsh/extract tar.bz2" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.tar.bz2" "$WORK/extracted"

echo "[pwsh] archive + extract tar.xz"
setup_fixtures
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK'; archive 'test.tar.xz' 'src'" 2>/dev/null
assert_success "pwsh/archive tar.xz exit code" "$?"
assert_exists "pwsh/archive tar.xz" "$WORK/test.tar.xz"
mkdir -p "$WORK/extracted"
cp "$WORK/test.tar.xz" "$WORK/extracted/"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/extracted'; extract 'test.tar.xz'"
assert_success "pwsh/extract tar.xz exit code" "$?"
assert_exists "pwsh/extract tar.xz" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.tar.xz" "$WORK/extracted"

echo "[pwsh] extract unsupported format"
touch "$WORK/test.foo"
err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "extract '$WORK/test.foo'")
assert_contains "pwsh/extract unsupported" "unsupported" "$err"
rm -f "$WORK/test.foo"

echo "[pwsh] path"
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "path | Out-String")
assert_contains "pwsh/path contains /usr" "/usr" "$actual"

echo "[pwsh] up"
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "
    New-Item -ItemType Directory -Force -Path '$WORK/a/b/c' | Out-Null
    Set-Location '$WORK/a/b/c'
    up 2
    (Get-Location).Path
")
assert_eq "pwsh/up 2" "$WORK/a" "$actual"

echo "[pwsh] mkcd"
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "mkcd '$WORK/newdir'; (Get-Location).Path")
assert_eq "pwsh/mkcd" "$WORK/newdir" "$actual"
assert_exists "pwsh/mkcd dir" "$WORK/newdir"
rm -rf "$WORK/newdir"

# --- again / sagain / back ---
echo "[pwsh] again no history"
err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "again")
assert_contains "pwsh/again no history" "no command at position" "$err"

echo "[pwsh] sagain 0"
err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "sagain -N 0")
assert_contains "pwsh/sagain 0 usage" "usage" "$err"

echo "[pwsh] back 2"
err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "back -N 2")
assert_contains "pwsh/back 2 unsupported" "only N=1" "$err"

echo "[pwsh] back returns to the previous directory (Set-Location -)"
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "cd '$WORK'; cd /; back *>\$null; (Get-Location).Path" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/back previous dir" "$WORK" "$actual"

echo "[pwsh] back on a fresh session is a graceful no-op (empty Set-Location - history)"
# With no prior Set-Location, pwsh's location history is empty and `Set-Location -`
# is a silent no-op (it does not throw), so back stays put and emits no error.
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "\$before = (Get-Location).Path; back *>\$null; \$after = (Get-Location).Path; if (\$before -eq \$after) { 'unchanged' } else { 'moved' }" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/back fresh no-op" "unchanged" "$actual"

# =============================================================================
# Stderr format tests — Write-Error double-prefix prevention
# =============================================================================
echo ""
echo "================================================"
echo "  Testing stderr format (no double-prefix)"
echo "================================================"

echo "[pwsh] mkcd usage stderr"
err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "mkcd")
assert_contains "pwsh/mkcd stderr has usage" "usage:" "$err"
assert_not_contains "pwsh/mkcd no double prefix" "mkcd: mkcd:" "$err"

echo "[pwsh] again usage stderr"
err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "again -N 0")
assert_contains "pwsh/again stderr has usage" "usage:" "$err"
assert_not_contains "pwsh/again no double prefix" "again: again:" "$err"

echo "[pwsh] back usage stderr"
err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "back -N 0")
assert_contains "pwsh/back stderr has usage" "usage:" "$err"
assert_not_contains "pwsh/back no double prefix" "back: back:" "$err"

# =============================================================================
# Summary
# =============================================================================
print_summary "test_functions"
[ "$FAIL" -eq 0 ]
