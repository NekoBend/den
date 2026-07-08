#!/usr/bin/env bash
# test_coreutils.sh — Tests for coreutils.ps1 (PowerShell only).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

COREUTILS_PS1="$DOTFILES/shell/pwsh/coreutils.ps1"

# Strip the `_DenInteractive` guard for non-interactive testing.
# Place outside $WORK to avoid deletion by $() subshell EXIT trap.
COREUTILS_PS1_STRIPPED="/tmp/coreutils_stripped_$$.ps1"
grep -v '_DenInteractive' "$COREUTILS_PS1" > "$COREUTILS_PS1_STRIPPED"
_cleanup_coreutils() { rm -f "$COREUTILS_PS1_STRIPPED"; }
trap '_cleanup_coreutils' EXIT

# =============================================================================
# PowerShell tests
# =============================================================================
echo "================================================"
echo "  Testing coreutils.ps1 with PWSH"
echo "================================================"

# --- Shared helpers ---
clean() { tr -d '\r' | sed '/^$/d'; }

setup_multiline() {
    seq 1 20 > "$WORK/lines.txt"
}

# =============================================================================
# head
# =============================================================================

echo "[pwsh] head default (10 lines)"
setup_multiline
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "head '$WORK/lines.txt' | Out-String" | clean)
line_count=$(echo "$actual" | wc -l)
assert_eq "head default line count" "10" "$line_count"
assert_eq "head default first line" "1" "$(echo "$actual" | head -1)"
assert_eq "head default last line" "10" "$(echo "$actual" | tail -1)"

echo "[pwsh] head -n 3"
setup_multiline
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "head -n 3 '$WORK/lines.txt' | Out-String" | clean)
assert_eq "head -n 3 line count" "3" "$(echo "$actual" | wc -l)"
assert_eq "head -n 3 last line" "3" "$(echo "$actual" | tail -1)"

echo "[pwsh] head -5 shorthand"
setup_multiline
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "head -5 '$WORK/lines.txt' | Out-String" | clean)
assert_eq "head -5 line count" "5" "$(echo "$actual" | wc -l)"
assert_eq "head -5 last line" "5" "$(echo "$actual" | tail -1)"

echo "[pwsh] head pipe input"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "1..20 | head -n 5 | Out-String" | clean)
assert_eq "head pipe line count" "5" "$(echo "$actual" | wc -l)"
assert_eq "head pipe first line" "1" "$(echo "$actual" | head -1)"

echo "[pwsh] head multi-file"
setup_multiline
seq 100 105 > "$WORK/other.txt"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "head -n 2 '$WORK/lines.txt' '$WORK/other.txt' | Out-String" | clean)
assert_contains "head multi-file header 1" "==> $WORK/lines.txt <==" "$actual"
assert_contains "head multi-file header 2" "==> $WORK/other.txt <==" "$actual"

echo "[pwsh] head empty file"
> "$WORK/empty.txt"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "head '$WORK/empty.txt' | Out-String" | clean)
assert_eq "head empty file" "" "$actual"

echo "[pwsh] head single-line file"
echo "only" > "$WORK/single.txt"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "head '$WORK/single.txt' | Out-String" | clean)
assert_eq "head single-line" "only" "$actual"

echo "[pwsh] head file with spaces"
echo "spaced" > "$WORK/my file.txt"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "head '$WORK/my file.txt' | Out-String" | clean)
assert_eq "head spaces in name" "spaced" "$actual"

# =============================================================================
# tail
# =============================================================================

echo "[pwsh] tail default (10 lines)"
setup_multiline
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "tail '$WORK/lines.txt' | Out-String" | clean)
line_count=$(echo "$actual" | wc -l)
assert_eq "tail default line count" "10" "$line_count"
assert_eq "tail default first line" "11" "$(echo "$actual" | head -1)"
assert_eq "tail default last line" "20" "$(echo "$actual" | tail -1)"

echo "[pwsh] tail -n 5"
setup_multiline
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "tail -n 5 '$WORK/lines.txt' | Out-String" | clean)
assert_eq "tail -n 5 line count" "5" "$(echo "$actual" | wc -l)"
assert_eq "tail -n 5 first line" "16" "$(echo "$actual" | head -1)"

echo "[pwsh] tail -3 shorthand"
setup_multiline
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "tail -3 '$WORK/lines.txt' | Out-String" | clean)
assert_eq "tail -3 line count" "3" "$(echo "$actual" | wc -l)"
assert_eq "tail -3 first line" "18" "$(echo "$actual" | head -1)"

echo "[pwsh] tail pipe input"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "1..20 | tail -n 3 | Out-String" | clean)
assert_eq "tail pipe line count" "3" "$(echo "$actual" | wc -l)"
assert_eq "tail pipe last line" "20" "$(echo "$actual" | tail -1)"

echo "[pwsh] tail multi-file"
setup_multiline
seq 100 105 > "$WORK/other.txt"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "tail -n 2 '$WORK/lines.txt' '$WORK/other.txt' | Out-String" | clean)
assert_contains "tail multi-file header 1" "==> $WORK/lines.txt <==" "$actual"
assert_contains "tail multi-file header 2" "==> $WORK/other.txt <==" "$actual"

echo "[pwsh] tail empty file"
> "$WORK/empty.txt"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "tail '$WORK/empty.txt' | Out-String" | clean)
assert_eq "tail empty file" "" "$actual"

# =============================================================================
# wc
# =============================================================================

echo "[pwsh] wc no flags (all properties)"
printf "hello world\nfoo bar baz\n" > "$WORK/wc_test.txt"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "\$m = wc '$WORK/wc_test.txt'; Write-Output \"\$(\$m.Lines):\$(\$m.Words):\$(\$m.Characters)\"" | clean)
assert_eq "wc no flags lines:words:chars" "2:5:24" "$actual"

echo "[pwsh] wc -l"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "\$m = wc -l '$WORK/wc_test.txt'; Write-Output \$m.Lines" | clean)
assert_eq "wc -l lines" "2" "$actual"

echo "[pwsh] wc -w"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "\$m = wc -w '$WORK/wc_test.txt'; Write-Output \$m.Words" | clean)
assert_eq "wc -w words" "5" "$actual"

echo "[pwsh] wc -c (characters)"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "\$m = wc -c '$WORK/wc_test.txt'; Write-Output \$m.Characters" | clean)
assert_eq "wc -c characters" "24" "$actual"

echo "[pwsh] wc -lw combined"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "\$m = wc -lw '$WORK/wc_test.txt'; Write-Output \"\$(\$m.Lines):\$(\$m.Words)\"" | clean)
assert_eq "wc -lw combined" "2:5" "$actual"

echo "[pwsh] wc pipe input"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "\$m = 'hello world' | wc -w; Write-Output \$m.Words" | clean)
assert_eq "wc pipe words" "2" "$actual"

echo "[pwsh] wc multi-file table"
printf "aaa\nbbb\n" > "$WORK/wc_a.txt"
printf "ccc\n" > "$WORK/wc_b.txt"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "wc -l '$WORK/wc_a.txt' '$WORK/wc_b.txt' | Out-String" | clean)
assert_contains "wc multi-file has total" "total" "$actual"

# =============================================================================
# split
# =============================================================================

echo "[pwsh] split -l 10 (default prefix x)"
seq 1 25 > "$WORK/split_input.txt"
run_pwsh "$COREUTILS_PS1_STRIPPED" "Set-Location '$WORK'; split -l 10 '$WORK/split_input.txt'" >/dev/null
assert_success "split -l exit code" "$?"
assert_exists "split -l xaa" "$WORK/xaa"
assert_exists "split -l xab" "$WORK/xab"
assert_exists "split -l xac" "$WORK/xac"
actual=$(wc -l < "$WORK/xaa")
assert_eq "split -l xaa 10 lines" "10" "$(echo "$actual" | tr -d ' ')"
actual=$(wc -l < "$WORK/xac")
assert_eq "split -l xac 5 lines" "5" "$(echo "$actual" | tr -d ' ')"
rm -f "$WORK"/x??

echo "[pwsh] split -n l/5 (chunk mode)"
run_pwsh "$COREUTILS_PS1_STRIPPED" "Set-Location '$WORK'; split -n l/5 '$WORK/split_input.txt'" >/dev/null
assert_success "split -n exit code" "$?"
assert_exists "split -n xaa" "$WORK/xaa"
assert_exists "split -n xae" "$WORK/xae"
assert_not_exists "split -n no xaf" "$WORK/xaf"
rm -f "$WORK"/x??

echo "[pwsh] split positional prefix"
run_pwsh "$COREUTILS_PS1_STRIPPED" "Set-Location '$WORK'; split -l 10 '$WORK/split_input.txt' chunk_" >/dev/null
assert_exists "split prefix chunk_aa" "$WORK/chunk_aa"
assert_exists "split prefix chunk_ab" "$WORK/chunk_ab"
rm -f "$WORK"/chunk_??

echo "[pwsh] split -a 3 (suffix length)"
run_pwsh "$COREUTILS_PS1_STRIPPED" "Set-Location '$WORK'; split -l 10 -a 3 '$WORK/split_input.txt'" >/dev/null
assert_exists "split -a 3 xaaa" "$WORK/xaaa"
assert_exists "split -a 3 xaab" "$WORK/xaab"
rm -f "$WORK"/x??? "$WORK/split_input.txt"

echo "[pwsh] split -b (byte split)"
dd if=/dev/zero bs=1 count=100 of="$WORK/bytefile.bin" 2>/dev/null
run_pwsh "$COREUTILS_PS1_STRIPPED" "Set-Location '$WORK'; split -b 30 '$WORK/bytefile.bin'" >/dev/null
assert_exists "split -b xaa" "$WORK/xaa"
assert_exists "split -b xab" "$WORK/xab"
assert_exists "split -b xad" "$WORK/xad"
# 100 bytes / 30 = 4 files (30+30+30+10)
actual=$(wc -c < "$WORK/xaa" | tr -d ' ')
assert_eq "split -b first chunk size" "30" "$actual"
actual=$(wc -c < "$WORK/xad" | tr -d ' ')
assert_eq "split -b last chunk size" "10" "$actual"
rm -f "$WORK"/xa? "$WORK/bytefile.bin"

# =============================================================================
# touch
# =============================================================================

echo "[pwsh] touch create"
rm -f "$WORK/touchfile.txt"
run_pwsh "$COREUTILS_PS1_STRIPPED" "touch '$WORK/touchfile.txt'"
assert_success "touch create exit code" "$?"
assert_exists "touch create" "$WORK/touchfile.txt"

echo "[pwsh] touch update timestamp"
echo "content" > "$WORK/touchfile2.txt"
touch -t 200001011200 "$WORK/touchfile2.txt"
old_ts=$(stat -c %Y "$WORK/touchfile2.txt")
run_pwsh "$COREUTILS_PS1_STRIPPED" "touch '$WORK/touchfile2.txt'"
assert_success "touch update exit code" "$?"
new_ts=$(stat -c %Y "$WORK/touchfile2.txt")
if [ "$new_ts" -gt "$old_ts" ]; then
    echo "  PASS: touch update timestamp"
    ((PASS++)) || true
else
    echo "  FAIL: touch update timestamp (old=$old_ts, new=$new_ts)"
    ERRORS+=("touch update timestamp")
    ((FAIL++)) || true
fi
rm -f "$WORK/touchfile.txt" "$WORK/touchfile2.txt"

# =============================================================================
# which
# =============================================================================

echo "[pwsh] which"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "which pwsh")
assert_contains "which finds pwsh" "pwsh" "$actual"

# =============================================================================
# df / env — smoke tests
# =============================================================================

echo "[pwsh] df smoke test"
run_pwsh "$COREUTILS_PS1_STRIPPED" "df | Out-Null" >/dev/null 2>&1
assert_success "df runs without error" "$?"

echo "[pwsh] env smoke test"
run_pwsh "$COREUTILS_PS1_STRIPPED" "env | Out-Null" >/dev/null 2>&1
assert_success "env runs without error" "$?"

# =============================================================================
# touch — multiple files
# =============================================================================

echo "[pwsh] touch multiple files"
rm -f "$WORK/a.txt" "$WORK/b.txt" "$WORK/c.txt"
run_pwsh "$COREUTILS_PS1_STRIPPED" "touch '$WORK/a.txt' '$WORK/b.txt' '$WORK/c.txt'"
assert_exists "touch multi a.txt" "$WORK/a.txt"
assert_exists "touch multi b.txt" "$WORK/b.txt"
assert_exists "touch multi c.txt" "$WORK/c.txt"
rm -f "$WORK/a.txt" "$WORK/b.txt" "$WORK/c.txt"

# =============================================================================
# which — extended tests
# =============================================================================

echo "[pwsh] which multiple args"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "which pwsh bash | Out-String" | clean)
assert_contains "which multi pwsh" "pwsh" "$actual"
assert_contains "which multi bash" "bash" "$actual"

echo "[pwsh] which -a flag"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "which -a pwsh | Out-String" | clean)
assert_contains "which -a pwsh" "pwsh" "$actual"

echo "[pwsh] which not found"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "which nonexistent_cmd_xyz | Out-String" | clean)
assert_eq "which not found" "" "$actual"

# =============================================================================
# head — extended tests
# =============================================================================

echo "[pwsh] head -n -N (exclude last N)"
setup_multiline
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "head -n -5 '$WORK/lines.txt' | Out-String" | clean)
line_count=$(echo "$actual" | wc -l)
assert_eq "head -n -5 line count" "15" "$line_count"
assert_eq "head -n -5 last line" "15" "$(echo "$actual" | tail -1)"

echo "[pwsh] head -q (quiet multi-file)"
setup_multiline
seq 100 105 > "$WORK/other.txt"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "head -q -n 2 '$WORK/lines.txt' '$WORK/other.txt' | Out-String" | clean)
if echo "$actual" | grep -qF '==>'; then
    echo "  FAIL: head -q should suppress headers"
    ERRORS+=("head -q suppress headers")
    ((FAIL++)) || true
else
    echo "  PASS: head -q suppress headers"
    ((PASS++)) || true
fi

echo "[pwsh] head -v (verbose single-file)"
setup_multiline
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "head -v -n 2 '$WORK/lines.txt' | Out-String" | clean)
assert_contains "head -v shows header" "==>" "$actual"

# =============================================================================
# tail — extended tests
# =============================================================================

echo "[pwsh] tail -n +N (start from line N)"
setup_multiline
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "tail -n +16 '$WORK/lines.txt' | Out-String" | clean)
line_count=$(echo "$actual" | wc -l)
assert_eq "tail -n +16 line count" "5" "$line_count"
assert_eq "tail -n +16 first line" "16" "$(echo "$actual" | head -1)"

echo "[pwsh] tail -q (quiet multi-file)"
setup_multiline
seq 100 105 > "$WORK/other.txt"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "tail -q -n 2 '$WORK/lines.txt' '$WORK/other.txt' | Out-String" | clean)
if echo "$actual" | grep -qF '==>'; then
    echo "  FAIL: tail -q should suppress headers"
    ERRORS+=("tail -q suppress headers")
    ((FAIL++)) || true
else
    echo "  PASS: tail -q suppress headers"
    ((PASS++)) || true
fi

echo "[pwsh] tail -v (verbose single file)"
setup_multiline
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "tail -v -n 2 '$WORK/lines.txt' | Out-String" | clean)
assert_contains "tail -v header" "==> " "$actual"
assert_contains "tail -v last line" "20" "$actual"

# =============================================================================
# split — stdin
# =============================================================================

echo "[pwsh] split stdin"
rm -f "$WORK"/x??
run_pwsh "$COREUTILS_PS1_STRIPPED" "Set-Location '$WORK'; 1..25 | split -l 10" >/dev/null
assert_exists "split stdin xaa" "$WORK/xaa"
assert_exists "split stdin xab" "$WORK/xab"
assert_exists "split stdin xac" "$WORK/xac"
rm -f "$WORK"/x??

# =============================================================================
# env — extended tests
# =============================================================================

echo "[pwsh] env NAME=VALUE format"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "env | Out-String" | clean)
assert_contains "env output has =" "=" "$actual"

echo "[pwsh] env VAR=val command"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "env FOO=bar pwsh -c 'Write-Output \$env:FOO'" | clean)
assert_eq "env VAR=val command" "bar" "$actual"

# =============================================================================
# wc — pipe character count
# =============================================================================

echo "[pwsh] wc -c pipe"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "\$m = 'hello' | wc -c; Write-Output \$m.Characters" | clean)
assert_contains "wc -c pipe chars" "6" "$actual"

echo "[pwsh] wc empty file"
> "$WORK/empty.txt"
actual=$(run_pwsh "$COREUTILS_PS1_STRIPPED" "wc '$WORK/empty.txt' | Out-String" | clean)
assert_contains "wc empty lines 0" "0" "$actual"

# =============================================================================
# Stderr format tests — Write-Error double-prefix prevention
# =============================================================================
echo ""
echo "================================================"
echo "  Testing stderr format (no double-prefix)"
echo "================================================"

echo "[pwsh] split stderr"
err=$(run_pwsh_stderr "$COREUTILS_PS1_STRIPPED" "echo 'x' | split -n 0")
assert_not_contains "pwsh/split no double prefix" "split: split:" "$err"

echo "[pwsh] touch usage stderr"
err=$(run_pwsh_stderr "$COREUTILS_PS1_STRIPPED" "touch")
assert_contains "pwsh/touch stderr has message" "usage:" "$err"
assert_not_contains "pwsh/touch no double prefix" "touch: touch:" "$err"

echo "[pwsh] which usage stderr"
err=$(run_pwsh_stderr "$COREUTILS_PS1_STRIPPED" "which")
assert_contains "pwsh/which stderr has message" "usage:" "$err"
assert_not_contains "pwsh/which no double prefix" "which: which:" "$err"

# =============================================================================
# Summary
# =============================================================================
print_summary "test_coreutils"
[ "$FAIL" -eq 0 ]

