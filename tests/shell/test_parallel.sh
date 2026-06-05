#!/usr/bin/env bash
# test_parallel.sh — Tests for parallel.sh (bash/zsh) and parallel.ps1 (pwsh).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

PARALLEL_SH_GUARDED="$DOTFILES/shell/posix/parallel.sh"
PARALLEL_SH="/tmp/parallel_test_$$.sh"
PARALLEL_PS1="$DOTFILES/shell/pwsh/parallel.ps1"

make_noninteractive_source_copy "$PARALLEL_SH_GUARDED" "$PARALLEL_SH"

# =============================================================================
# Bash tests
# =============================================================================
echo "================================================"
echo "  Testing parallel.sh with BASH"
echo "================================================"

echo "[bash] guard: non-interactive source skips parallel helpers"
actual=$(bash -c "
	source '$PARALLEL_SH_GUARDED'
	type pcp >/dev/null 2>&1 && echo 'DEFINED' || echo 'UNDEFINED'
" | tr -d '\r')
assert_eq "bash/guard non-interactive" "UNDEFINED" "$actual"

echo "[bash] _count_entries"
setup_fixtures
actual=$(run_bash "$PARALLEL_SH" "_count_entries '$WORK/src'")
assert_eq "bash/_count_entries dir" "5" "$actual"
actual=$(run_bash "$PARALLEL_SH" "_count_entries '$WORK/src/file1.txt'")
assert_eq "bash/_count_entries single file" "1" "$actual"

echo "[bash] _count_entries threshold"
rm -rf "$WORK/huge"
mkdir -p "$WORK/huge"
_parallel_i=1
while [ "$_parallel_i" -le 10001 ]; do
	: > "$WORK/huge/$_parallel_i"
	_parallel_i=$((_parallel_i + 1))
done
unset _parallel_i
actual=$(run_bash "$PARALLEL_SH" "_count_entries '$WORK/huge'")
assert_eq "bash/_count_entries threshold" "10000+" "$actual"
rm -rf "$WORK/huge"

echo "[bash] pcp single file"
setup_fixtures
run_bash "$PARALLEL_SH" "pcp '$WORK/src/file1.txt' '$WORK/dest/'"
assert_success "bash/pcp exit code" "$?"
assert_exists "bash/pcp single file exists" "$WORK/dest/file1.txt"
actual=$(cat "$WORK/dest/file1.txt")
assert_eq "bash/pcp single file content" "hello" "$actual"

echo "[bash] pcp directory"
setup_fixtures
run_bash "$PARALLEL_SH" "pcp '$WORK/src' '$WORK/dest/'"
assert_success "bash/pcp dir exit code" "$?"
assert_exists "bash/pcp dir exists" "$WORK/dest/src"
assert_exists "bash/pcp dir nested" "$WORK/dest/src/subdir/file3.txt"

echo "[bash] pmv"
setup_fixtures
run_bash "$PARALLEL_SH" "pmv '$WORK/src/file1.txt' '$WORK/dest/'"
assert_success "bash/pmv exit code" "$?"
assert_exists "bash/pmv dest exists" "$WORK/dest/file1.txt"
assert_not_exists "bash/pmv src removed" "$WORK/src/file1.txt"

echo "[bash] prm -f"
setup_fixtures
run_bash "$PARALLEL_SH" "prm -f '$WORK/src/file1.txt' '$WORK/src/file2.txt'"
assert_success "bash/prm exit code" "$?"
assert_not_exists "bash/prm file1 removed" "$WORK/src/file1.txt"
assert_not_exists "bash/prm file2 removed" "$WORK/src/file2.txt"
assert_exists "bash/prm subdir untouched" "$WORK/src/subdir/file3.txt"

echo "[bash] prm -f directory"
setup_fixtures
run_bash "$PARALLEL_SH" "prm -f '$WORK/src'"
assert_success "bash/prm dir exit code" "$?"
assert_not_exists "bash/prm dir removed" "$WORK/src"

echo "[bash] ptar"
setup_fixtures
run_bash "$PARALLEL_SH" "cd '$WORK' && ptar '$WORK/out.tar.gz' src"
assert_success "bash/ptar exit code" "$?"
assert_exists "bash/ptar creates archive" "$WORK/out.tar.gz"
actual=$(tar tzf "$WORK/out.tar.gz" | sort)
assert_contains "bash/ptar contains file1" "file1.txt" "$actual"

echo "[bash] ptar tar.bz2"
setup_fixtures
run_bash "$PARALLEL_SH" "ptar '$WORK/out.tar.bz2' '$WORK/src/'*.txt" 2>/dev/null
assert_exists "bash/ptar tar.bz2" "$WORK/out.tar.bz2"
actual=$(tar tjf "$WORK/out.tar.bz2" | head -1)
assert_contains "bash/ptar bz2 content" "txt" "$actual"
rm -f "$WORK/out.tar.bz2"

echo "[bash] ptar tar.xz"
setup_fixtures
run_bash "$PARALLEL_SH" "ptar '$WORK/out.tar.xz' '$WORK/src/'*.txt" 2>/dev/null
assert_exists "bash/ptar tar.xz" "$WORK/out.tar.xz"
actual=$(tar tJf "$WORK/out.tar.xz" | head -1)
assert_contains "bash/ptar xz content" "txt" "$actual"
rm -f "$WORK/out.tar.xz"

# =============================================================================
# Zsh tests
# =============================================================================
echo ""
echo "================================================"
echo "  Testing parallel.sh with ZSH"
echo "================================================"

echo "[zsh] _count_entries"
setup_fixtures
actual=$(run_zsh "$PARALLEL_SH" "_count_entries '$WORK/src'")
assert_eq "zsh/_count_entries dir" "5" "$actual"
actual=$(run_zsh "$PARALLEL_SH" "_count_entries '$WORK/src/file1.txt'")
assert_eq "zsh/_count_entries single file" "1" "$actual"

echo "[zsh] pcp single file"
setup_fixtures
run_zsh "$PARALLEL_SH" "pcp '$WORK/src/file1.txt' '$WORK/dest/'"
assert_success "zsh/pcp exit code" "$?"
assert_exists "zsh/pcp single file exists" "$WORK/dest/file1.txt"
actual=$(cat "$WORK/dest/file1.txt")
assert_eq "zsh/pcp single file content" "hello" "$actual"

echo "[zsh] pcp directory"
setup_fixtures
run_zsh "$PARALLEL_SH" "pcp '$WORK/src' '$WORK/dest/'"
assert_success "zsh/pcp dir exit code" "$?"
assert_exists "zsh/pcp dir exists" "$WORK/dest/src"
assert_exists "zsh/pcp dir nested" "$WORK/dest/src/subdir/file3.txt"

echo "[zsh] pmv"
setup_fixtures
run_zsh "$PARALLEL_SH" "pmv '$WORK/src/file1.txt' '$WORK/dest/'"
assert_success "zsh/pmv exit code" "$?"
assert_exists "zsh/pmv dest exists" "$WORK/dest/file1.txt"
assert_not_exists "zsh/pmv src removed" "$WORK/src/file1.txt"

echo "[zsh] prm -f"
setup_fixtures
run_zsh "$PARALLEL_SH" "prm -f '$WORK/src/file1.txt' '$WORK/src/file2.txt'"
assert_success "zsh/prm exit code" "$?"
assert_not_exists "zsh/prm file1 removed" "$WORK/src/file1.txt"
assert_not_exists "zsh/prm file2 removed" "$WORK/src/file2.txt"
assert_exists "zsh/prm subdir untouched" "$WORK/src/subdir/file3.txt"

echo "[zsh] prm -f directory"
setup_fixtures
run_zsh "$PARALLEL_SH" "prm -f '$WORK/src'"
assert_success "zsh/prm dir exit code" "$?"
assert_not_exists "zsh/prm dir removed" "$WORK/src"

echo "[zsh] ptar"
setup_fixtures
run_zsh "$PARALLEL_SH" "cd '$WORK' && ptar '$WORK/out.tar.gz' src"
assert_success "zsh/ptar exit code" "$?"
assert_exists "zsh/ptar creates archive" "$WORK/out.tar.gz"
actual=$(tar tzf "$WORK/out.tar.gz" | sort)
assert_contains "zsh/ptar contains file1" "file1.txt" "$actual"

echo "[zsh] ptar tar.bz2"
setup_fixtures
run_zsh "$PARALLEL_SH" "ptar '$WORK/out.tar.bz2' '$WORK/src/'*.txt" 2>/dev/null
assert_exists "zsh/ptar tar.bz2" "$WORK/out.tar.bz2"
actual=$(tar tjf "$WORK/out.tar.bz2" | head -1)
assert_contains "zsh/ptar bz2 content" "txt" "$actual"
rm -f "$WORK/out.tar.bz2"

echo "[zsh] ptar tar.xz"
setup_fixtures
run_zsh "$PARALLEL_SH" "ptar '$WORK/out.tar.xz' '$WORK/src/'*.txt" 2>/dev/null
assert_exists "zsh/ptar tar.xz" "$WORK/out.tar.xz"
actual=$(tar tJf "$WORK/out.tar.xz" | head -1)
assert_contains "zsh/ptar xz content" "txt" "$actual"
rm -f "$WORK/out.tar.xz"

# =============================================================================
# PowerShell tests
# =============================================================================
echo ""
echo "================================================"
echo "  Testing parallel.ps1 with PWSH"
echo "================================================"

echo "[pwsh] _CountEntries"
setup_fixtures
actual=$(run_pwsh "$PARALLEL_PS1" "_CountEntries '$WORK/src'")
assert_eq "pwsh/_CountEntries dir" "5" "$actual"
actual=$(run_pwsh "$PARALLEL_PS1" "_CountEntries '$WORK/src/file1.txt'")
assert_eq "pwsh/_CountEntries single file" "1" "$actual"

echo "[pwsh] pcp single file"
setup_fixtures
run_pwsh "$PARALLEL_PS1" "pcp '$WORK/src/file1.txt' '$WORK/dest'"
assert_success "pwsh/pcp exit code" "$?"
assert_exists "pwsh/pcp single file exists" "$WORK/dest/file1.txt"
actual=$(cat "$WORK/dest/file1.txt")
assert_eq "pwsh/pcp single file content" "hello" "$actual"

echo "[pwsh] pcp directory"
setup_fixtures
run_pwsh "$PARALLEL_PS1" "pcp '$WORK/src' '$WORK/dest'"
assert_success "pwsh/pcp dir exit code" "$?"
assert_exists "pwsh/pcp dir exists" "$WORK/dest/src"
assert_exists "pwsh/pcp dir nested" "$WORK/dest/src/subdir/file3.txt"

echo "[pwsh] pmv"
setup_fixtures
run_pwsh "$PARALLEL_PS1" "pmv '$WORK/src/file1.txt' '$WORK/dest'"
assert_success "pwsh/pmv exit code" "$?"
assert_exists "pwsh/pmv dest exists" "$WORK/dest/file1.txt"
assert_not_exists "pwsh/pmv src removed" "$WORK/src/file1.txt"

echo "[pwsh] prm -Force"
setup_fixtures
run_pwsh "$PARALLEL_PS1" "prm -Force '$WORK/src/file1.txt' '$WORK/src/file2.txt'"
assert_success "pwsh/prm exit code" "$?"
assert_not_exists "pwsh/prm file1 removed" "$WORK/src/file1.txt"
assert_not_exists "pwsh/prm file2 removed" "$WORK/src/file2.txt"
assert_exists "pwsh/prm subdir untouched" "$WORK/src/subdir/file3.txt"

echo "[pwsh] prm -Force directory"
setup_fixtures
run_pwsh "$PARALLEL_PS1" "prm -Force '$WORK/src'"
assert_success "pwsh/prm dir exit code" "$?"
assert_not_exists "pwsh/prm dir removed" "$WORK/src"

echo "[pwsh] ptar"
setup_fixtures
run_pwsh "$PARALLEL_PS1" "ptar '$WORK/out.tar.gz' '$WORK/src'"
assert_success "pwsh/ptar exit code" "$?"
assert_exists "pwsh/ptar creates archive" "$WORK/out.tar.gz"
actual=$(tar tzf "$WORK/out.tar.gz" | sort)
assert_contains "pwsh/ptar contains file1" "file1.txt" "$actual"

echo "[pwsh] ptar tar.bz2"
setup_fixtures
run_pwsh "$PARALLEL_PS1" "ptar '$WORK/out.tar.bz2' '$WORK/src/file1.txt' '$WORK/src/file2.txt'" >/dev/null 2>&1
assert_exists "pwsh/ptar tar.bz2" "$WORK/out.tar.bz2"
rm -f "$WORK/out.tar.bz2"

echo "[pwsh] ptar tar.xz"
setup_fixtures
run_pwsh "$PARALLEL_PS1" "ptar '$WORK/out.tar.xz' '$WORK/src/file1.txt' '$WORK/src/file2.txt'" >/dev/null 2>&1
assert_exists "pwsh/ptar tar.xz" "$WORK/out.tar.xz"
rm -f "$WORK/out.tar.xz"

# =============================================================================
# Stderr format tests — Write-Error double-prefix prevention
# =============================================================================
echo ""
echo "================================================"
echo "  Testing stderr format (no double-prefix)"
echo "================================================"

echo "[pwsh] pcp usage stderr"
err=$(run_pwsh_stderr "$PARALLEL_PS1" "pcp '/nonexist'")
assert_contains "pwsh/pcp stderr has usage" "usage:" "$err"
assert_not_contains "pwsh/pcp no double prefix" "pcp: pcp:" "$err"

echo "[pwsh] pmv usage stderr"
err=$(run_pwsh_stderr "$PARALLEL_PS1" "pmv '/nonexist'")
assert_contains "pwsh/pmv stderr has usage" "usage:" "$err"
assert_not_contains "pwsh/pmv no double prefix" "pmv: pmv:" "$err"

echo "[pwsh] prm aborted stderr"
err=$(run_pwsh_stderr "$PARALLEL_PS1" "prm '/nonexist'")
assert_contains "pwsh/prm stderr has aborted" "aborted" "$err"
assert_not_contains "pwsh/prm no double prefix" "prm: prm:" "$err"

echo "[pwsh] ptar not-installed stderr"
err=$(run_pwsh_stderr "$PARALLEL_PS1" "ptar 'test.xyz' 'a'")
assert_not_contains "pwsh/ptar no double prefix" "ptar: ptar:" "$err"

# =============================================================================
# Summary
# =============================================================================
print_summary "test_parallel"
[ "$FAIL" -eq 0 ]
