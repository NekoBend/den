#!/usr/bin/env bash
# test_wrappers.sh — Tests for wrappers.sh (bash/zsh) and wrappers.ps1 (pwsh).
# Tests fallback paths (bat/fd/rg/lsd are NOT installed in test image).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

HELPERS_SH="$DOTFILES/shell/posix/_helpers.sh"
WRAPPERS_SH="$DOTFILES/shell/posix/wrappers.sh"
HELPERS_PS1="$DOTFILES/shell/pwsh/_helpers.ps1"
WRAPPERS_PS1="$DOTFILES/shell/pwsh/wrappers.ps1"

# wrappers.sh has an interactive guard (case $- in *i*).
# Use bash --norc -ic / zsh -ic to bypass it (--norc avoids .bashrc alias conflicts).
# _helpers.sh must be sourced first (provides _wrap/_wsfx).
run_bash_i() {
    bash --norc -ic "source '$HELPERS_SH' && source '$1' && $2" 2>/dev/null
}

run_zsh_i() {
    zsh -ic "source '$HELPERS_SH' && source '$1' && $2" 2>/dev/null
}

# wrappers.ps1 has [Environment]::UserInteractive guard.
# Strip the guard line before dot-sourcing.
# Prepend _helpers.ps1 so New-Wrapper/New-WrapperSuffix are available.
# Place outside $WORK to avoid deletion by $() subshell EXIT trap.
WRAPPERS_PS1_STRIPPED="/tmp/wrappers_stripped_$$.ps1"
{
    echo ". '$HELPERS_PS1'"
    grep -v 'UserInteractive' "$WRAPPERS_PS1" | sed '/Remove-Item alias:ls/d'
} > "$WRAPPERS_PS1_STRIPPED"
# Combined wrappers + coreutils for pipe chain tests
COREUTILS_PS1="$DOTFILES/shell/pwsh/coreutils.ps1"
COMBINED_PS1="/tmp/wrappers_combined_$$.ps1"
{
    cat "$WRAPPERS_PS1_STRIPPED"
    grep -v 'UserInteractive' "$COREUTILS_PS1"
} > "$COMBINED_PS1"

_cleanup_wrappers() { rm -f "$WRAPPERS_PS1_STRIPPED" "$COMBINED_PS1"; }
trap '_cleanup_wrappers' EXIT

# =============================================================================
# Bash tests (fallback paths — no bat/fd/rg/lsd installed)
# =============================================================================
echo "================================================"
echo "  Testing wrappers.sh with BASH (fallback)"
echo "================================================"

# --- cat fallback → command cat ---
echo "[bash] cat fallback"
echo "hello wrapper" > "$WORK/wrap_test.txt"
actual=$(run_bash_i "$WRAPPERS_SH" "cat '$WORK/wrap_test.txt'")
assert_eq "bash/cat fallback" "hello wrapper" "$actual"

# --- find fallback → command find ---
echo "[bash] find fallback"
setup_fixtures
actual=$(run_bash_i "$WRAPPERS_SH" "find '$WORK/src' -name '*.txt' -type f | sort")
assert_contains "bash/find fallback file1" "file1.txt" "$actual"
assert_contains "bash/find fallback file3" "file3.txt" "$actual"

# --- grep fallback → command grep ---
echo "[bash] grep fallback"
echo -e "apple\nbanana\ncherry" > "$WORK/grep_test.txt"
actual=$(run_bash_i "$WRAPPERS_SH" "grep 'banana' '$WORK/grep_test.txt'")
assert_eq "bash/grep fallback" "banana" "$actual"

# --- ls fallback → command ls ---
echo "[bash] ls fallback"
setup_fixtures
actual=$(run_bash_i "$WRAPPERS_SH" "ls '$WORK/src'")
assert_contains "bash/ls fallback" "file1.txt" "$actual"

# --- la fallback → command ls -A ---
echo "[bash] la fallback"
mkdir -p "$WORK/la_test"
echo "visible" > "$WORK/la_test/visible.txt"
echo "hidden" > "$WORK/la_test/.hidden"
actual=$(run_bash_i "$WRAPPERS_SH" "la '$WORK/la_test'")
assert_contains "bash/la shows hidden" ".hidden" "$actual"
assert_contains "bash/la shows visible" "visible.txt" "$actual"
rm -rf "$WORK/la_test"

# --- ll fallback → command ls -lF ---
echo "[bash] ll fallback"
setup_fixtures
actual=$(run_bash_i "$WRAPPERS_SH" "ll '$WORK/src'")
assert_contains "bash/ll long format" "file1.txt" "$actual"

# =============================================================================
# Zsh tests (fallback paths)
# =============================================================================
echo ""
echo "================================================"
echo "  Testing wrappers.sh with ZSH (fallback)"
echo "================================================"

echo "[zsh] cat fallback"
echo "hello wrapper" > "$WORK/wrap_test.txt"
actual=$(run_zsh_i "$WRAPPERS_SH" "cat '$WORK/wrap_test.txt'")
assert_eq "zsh/cat fallback" "hello wrapper" "$actual"

echo "[zsh] find fallback"
setup_fixtures
actual=$(run_zsh_i "$WRAPPERS_SH" "find '$WORK/src' -name '*.txt' -type f | sort")
assert_contains "zsh/find fallback file1" "file1.txt" "$actual"

echo "[zsh] grep fallback"
echo -e "apple\nbanana\ncherry" > "$WORK/grep_test.txt"
actual=$(run_zsh_i "$WRAPPERS_SH" "grep 'banana' '$WORK/grep_test.txt'")
assert_eq "zsh/grep fallback" "banana" "$actual"

echo "[zsh] ls fallback"
setup_fixtures
actual=$(run_zsh_i "$WRAPPERS_SH" "ls '$WORK/src'")
assert_contains "zsh/ls fallback" "file1.txt" "$actual"

echo "[zsh] la fallback"
mkdir -p "$WORK/la_test"
echo "visible" > "$WORK/la_test/visible.txt"
echo "hidden" > "$WORK/la_test/.hidden"
actual=$(run_zsh_i "$WRAPPERS_SH" "la '$WORK/la_test'")
assert_contains "zsh/la shows hidden" ".hidden" "$actual"
assert_contains "zsh/la shows visible" "visible.txt" "$actual"
rm -rf "$WORK/la_test"

echo "[zsh] ll fallback"
setup_fixtures
actual=$(run_zsh_i "$WRAPPERS_SH" "ll '$WORK/src'")
assert_contains "zsh/ll long format" "file1.txt" "$actual"

# =============================================================================
# PowerShell tests (fallback paths)
# =============================================================================
echo ""
echo "================================================"
echo "  Testing wrappers.ps1 with PWSH (fallback)"
echo "================================================"

echo "[pwsh] cat fallback → Get-Content"
echo "hello wrapper" > "$WORK/wrap_test.txt"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "cat '$WORK/wrap_test.txt' | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_eq "pwsh/cat fallback" "hello wrapper" "$actual"

echo "[pwsh] grep fallback → Select-String"
echo -e "apple\nbanana\ncherry" > "$WORK/grep_test.txt"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "grep 'banana' '$WORK/grep_test.txt'")
assert_eq "pwsh/grep fallback" "banana" "$actual"

echo "[pwsh] ls fallback → Get-ChildItem"
setup_fixtures
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "ls '$WORK/src'")
assert_contains "pwsh/ls fallback" "file1.txt" "$actual"

echo "[pwsh] la fallback → Get-ChildItem -Force"
mkdir -p "$WORK/la_test"
echo "visible" > "$WORK/la_test/visible.txt"
echo "hidden" > "$WORK/la_test/.hidden"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "la '$WORK/la_test'")
assert_contains "pwsh/la shows hidden" ".hidden" "$actual"
rm -rf "$WORK/la_test"

echo "[pwsh] find fallback → Get-ChildItem -Recurse"
setup_fixtures
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "find '$WORK/src' | Out-String")
assert_contains "pwsh/find fallback file1" "file1.txt" "$actual"

echo "[pwsh] ll fallback → Format-List"
setup_fixtures
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "ll '$WORK/src' | Out-String")
assert_contains "pwsh/ll fallback" "file1.txt" "$actual"

echo "[pwsh] lt fallback uses relative paths"
setup_fixtures
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "Set-Location '$WORK'; lt 'src' | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/lt relative path" "src/file1.txt" "$actual"
assert_not_contains "pwsh/lt not absolute" "$WORK" "$actual"

echo "[pwsh] llt fallback uses relative paths"
setup_fixtures
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "Set-Location '$WORK'; llt 'src' | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/llt relative path" "src/file1.txt" "$actual"
assert_not_contains "pwsh/llt not absolute" "$WORK" "$actual"

# =============================================================================
# PowerShell extended tests — grep (Select-String) arguments
# =============================================================================
echo ""
echo "[pwsh] grep argument tests"
printf 'apple\nbanana\ncherry\navocado\n' > "$WORK/fruits.txt"

# grep multiple matches
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "grep 'a' '$WORK/fruits.txt'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/grep multi apple" "apple" "$actual"
assert_contains "pwsh/grep multi banana" "banana" "$actual"
assert_contains "pwsh/grep multi avocado" "avocado" "$actual"

# grep case-insensitive (-i flag required since fallback is now case-sensitive)
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "grep -i 'BANANA' '$WORK/fruits.txt'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_eq "pwsh/grep case-insensitive" "banana" "$actual"

# grep regex pattern
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "grep 'a..le' '$WORK/fruits.txt'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_eq "pwsh/grep regex" "apple" "$actual"

# grep no match → empty
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "grep 'xyz' '$WORK/fruits.txt'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_eq "pwsh/grep no match" "" "$actual"

# grep multi-file
echo "hello world" > "$WORK/gm1.txt"
echo "goodbye world" > "$WORK/gm2.txt"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "grep 'world' '$WORK/gm1.txt' '$WORK/gm2.txt'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/grep multi-file hello" "hello world" "$actual"
assert_contains "pwsh/grep multi-file goodbye" "goodbye world" "$actual"

# =============================================================================
# PowerShell extended tests — cat (Get-Content)
# =============================================================================
echo ""
echo "[pwsh] cat argument tests"
echo "content-one" > "$WORK/cat1.txt"
echo "content-two" > "$WORK/cat2.txt"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "cat '$WORK/cat1.txt','$WORK/cat2.txt' | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/cat multi-file one" "content-one" "$actual"
assert_contains "pwsh/cat multi-file two" "content-two" "$actual"

# =============================================================================
# PowerShell extended tests — lla (Get-ChildItem -Force | Format-Table)
# =============================================================================
echo ""
echo "[pwsh] lla fallback → table format"
setup_fixtures
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "lla '$WORK/src' | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/lla table file1" "file1.txt" "$actual"

# =============================================================================
# PowerShell pipe chain tests (wrappers + coreutils)
# =============================================================================
echo ""
echo "[pwsh] pipe chain tests"
seq 1 20 | while read i; do echo "line$i"; done > "$WORK/lines20.txt"
printf 'apple\nbanana\ncherry\navocado\n' > "$WORK/fruits.txt"

# cat | head → first 5 lines
actual=$(run_pwsh "$COMBINED_PS1" "cat '$WORK/lines20.txt' | head -n 5 | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
line_count=$(echo "$actual" | wc -l | tr -d ' ')
assert_eq "pwsh/cat|head count" "5" "$line_count"
assert_contains "pwsh/cat|head first" "line1" "$actual"

# cat | grep → filter lines
actual=$(run_pwsh "$COMBINED_PS1" "cat '$WORK/fruits.txt' | grep 'an'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/cat|grep banana" "banana" "$actual"

# head | tail → lines 8-10
actual=$(run_pwsh "$COMBINED_PS1" "head -n 10 '$WORK/lines20.txt' | tail -n 3 | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/head|tail line8" "line8" "$actual"
assert_contains "pwsh/head|tail line10" "line10" "$actual"

# cat | tail → last 3 lines
actual=$(run_pwsh "$COMBINED_PS1" "cat '$WORK/lines20.txt' | tail -n 3 | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/cat|tail line20" "line20" "$actual"

# cat | head | wc → 3-stage pipe
actual=$(run_pwsh "$COMBINED_PS1" "(cat '$WORK/lines20.txt' | head -n 5 | wc -l).Lines")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_eq "pwsh/cat|head|wc" "5" "$actual"

# =============================================================================
# PowerShell extended tests — grep additional flags
# =============================================================================
echo ""
echo "[pwsh] grep additional flag tests"
printf 'apple\nbanana\ncherry\navocado\n' > "$WORK/fruits.txt"

# grep -v (invert match)
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "grep -v 'banana' '$WORK/fruits.txt'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/grep -v has apple" "apple" "$actual"
assert_contains "pwsh/grep -v has cherry" "cherry" "$actual"
if echo "$actual" | grep -qF 'banana'; then
    echo "  FAIL: pwsh/grep -v should exclude banana"
    ERRORS+=("pwsh/grep -v exclude banana")
    ((FAIL++)) || true
else
    echo "  PASS: pwsh/grep -v exclude banana"
    ((PASS++)) || true
fi

# grep -c (count)
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "grep -c 'a' '$WORK/fruits.txt'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/grep -c count" "3" "$actual"

# grep -l (filenames only)
echo "hello world" > "$WORK/gm1.txt"
echo "goodbye world" > "$WORK/gm2.txt"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "grep -l 'hello' '$WORK/gm1.txt' '$WORK/gm2.txt'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/grep -l filename" "gm1.txt" "$actual"

# grep pipe input
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "'hello world' | grep 'hello'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/grep pipe" "hello" "$actual"

# =============================================================================
# PowerShell extended tests — find additional flags
# =============================================================================
echo ""
echo "[pwsh] find additional flag tests"
setup_fixtures

# find -name
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "find '$WORK/src' -name '*.txt' | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/find -name file1" "file1.txt" "$actual"

# find -type f
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "find '$WORK/src' -type f | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/find -type f file1" "file1.txt" "$actual"

# find -type d
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "find '$WORK/src' -type d | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/find -type d subdir" "subdir" "$actual"

# =============================================================================
# PowerShell extended tests — lt / llt
# =============================================================================
echo ""
echo "[pwsh] lt / llt fallback tests"
setup_fixtures

# lt fallback
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "lt '$WORK/src' | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/lt fallback file1" "file1.txt" "$actual"

# llt fallback
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "llt '$WORK/src' | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/llt fallback file1" "file1.txt" "$actual"

# =============================================================================
# PowerShell toggle-wrapper test
# =============================================================================
echo ""
echo "[pwsh] toggle-wrapper OFF"
echo "hello wrapper" > "$WORK/wrap_test.txt"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "\$env:_DEN_WRAPPERS='0'; cat '$WORK/wrap_test.txt' | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_eq "pwsh/toggle off cat" "hello wrapper" "$actual"

# --- grep PS fallback: -n (line numbers) ---
echo "[pwsh] grep PS fallback -n"
echo -e "aaa\nbbb\nccc" > "$WORK/grep_n.txt"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "_grep_ps_fallback -n 'bbb' '$WORK/grep_n.txt'" | tr -d '\r')
assert_eq "pwsh/grep -n line number" "2:bbb" "$actual"

# --- grep PS fallback: -r (recursive) ---
echo "[pwsh] grep PS fallback -r"
mkdir -p "$WORK/grepdir/sub"
echo "findme" > "$WORK/grepdir/a.txt"
echo "nope" > "$WORK/grepdir/sub/b.txt"
echo "findme too" > "$WORK/grepdir/sub/c.txt"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "Set-Location '$WORK/grepdir'; _grep_ps_fallback -r 'findme'" | tr -d '\r' | sort)
assert_contains "pwsh/grep -r a.txt" "a.txt" "$actual"
assert_contains "pwsh/grep -r c.txt" "c.txt" "$actual"
rm -rf "$WORK/grepdir"

# --- grep PS fallback: -vi (compound flags) ---
echo "[pwsh] grep PS fallback -vi"
printf "Hello\nworld\nHELLO\n" > "$WORK/grep_vi.txt"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "_grep_ps_fallback -vi 'hello' '$WORK/grep_vi.txt'" | tr -d '\r')
assert_eq "pwsh/grep -vi" "world" "$actual"

# --- find PS fallback: -name + -type combined ---
echo "[pwsh] find PS fallback -name + -type"
setup_fixtures
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "_find_ps_fallback '$WORK/src' -name '*.txt' -type f" | tr -d '\r' | sort)
assert_contains "pwsh/find -name -type f1" "file1.txt" "$actual"
assert_contains "pwsh/find -name -type f3" "file3.txt" "$actual"

# =============================================================================
# Summary
# =============================================================================
print_summary "test_wrappers"
[ "$FAIL" -eq 0 ]
