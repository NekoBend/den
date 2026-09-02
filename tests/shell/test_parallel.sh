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
# Argument coverage (bash + zsh): quoting, flag parsing, both exec branches,
# multi-source, error paths, formats
# =============================================================================
for sh in bash zsh; do
    runner="run_$sh"
    runner_err="run_${sh}_stderr"
    echo ""
    echo "================================================"
    echo "  Argument coverage: parallel.sh with $sh"
    echo "================================================"

    echo "[$sh] pcp: destination with spaces stays one argument"
    setup_fixtures
    mkdir -p "$WORK/My Documents"
    $runner "$PARALLEL_SH" "pcp '$WORK/src/file1.txt' '$WORK/My Documents'" >/dev/null
    assert_success "$sh/pcp space-dest exit code" "$?"
    assert_exists "$sh/pcp space-dest file placed" "$WORK/My Documents/file1.txt"
    assert_not_exists "$sh/pcp space-dest no stray 'Documents'" "$WORK/Documents"

    echo "[$sh] pcp: shell metacharacters in the destination are inert"
    setup_fixtures
    $runner "$PARALLEL_SH" "cd '$WORK/dest' && pcp '$WORK/src/file1.txt' 'x;touch INJECTED'" >/dev/null 2>&1
    assert_not_exists "$sh/pcp no command injection" "$WORK/dest/INJECTED"
    assert_exists "$sh/pcp semicolon is a literal filename" "$WORK/dest/x;touch INJECTED"

    echo "[$sh] _parallel_exec: non-GNU parallel on PATH falls back to xargs, same result"
    setup_fixtures
    mkdir -p "$WORK/fakebin" "$WORK/gnu" "$WORK/xargs"
    printf '#!/bin/sh\necho "not gnu parallel"\n' > "$WORK/fakebin/parallel"
    chmod +x "$WORK/fakebin/parallel"
    $runner "$PARALLEL_SH" "pcp '$WORK/src/file1.txt' '$WORK/src/file2.txt' '$WORK/gnu'" >/dev/null
    assert_success "$sh/pcp default-branch exit code" "$?"
    $runner "$PARALLEL_SH" "PATH='$WORK/fakebin:$PATH' pcp '$WORK/src/file1.txt' '$WORK/src/file2.txt' '$WORK/xargs'" >/dev/null
    assert_success "$sh/pcp xargs-branch exit code" "$?"
    assert_eq "$sh/_parallel_exec branch parity" "$(ls "$WORK/gnu" | sort | tr '\n' ' ')" "$(ls "$WORK/xargs" | sort | tr '\n' ' ')"
    assert_eq "$sh/_parallel_exec both files copied" "file1.txt file2.txt " "$(ls "$WORK/xargs" | sort | tr '\n' ' ')"
    rm -rf "$WORK/fakebin"

    echo "[$sh] pcp/pmv: two sources into a directory"
    setup_fixtures
    $runner "$PARALLEL_SH" "pcp '$WORK/src/file1.txt' '$WORK/src/file2.txt' '$WORK/dest/'" >/dev/null
    assert_success "$sh/pcp two-source exit code" "$?"
    assert_exists "$sh/pcp two-source file1" "$WORK/dest/file1.txt"
    assert_exists "$sh/pcp two-source file2" "$WORK/dest/file2.txt"
    setup_fixtures
    $runner "$PARALLEL_SH" "pmv '$WORK/src/file1.txt' '$WORK/src/file2.txt' '$WORK/dest/'" >/dev/null
    assert_success "$sh/pmv two-source exit code" "$?"
    assert_exists "$sh/pmv two-source file2 moved" "$WORK/dest/file2.txt"
    assert_not_exists "$sh/pmv two-source src gone" "$WORK/src/file2.txt"

    echo "[$sh] pcp/pmv: two sources need a directory destination"
    setup_fixtures
    err=$($runner_err "$PARALLEL_SH" "pcp '$WORK/src/file1.txt' '$WORK/src/file2.txt' '$WORK/nodir'")
    assert_contains "$sh/pcp dest-not-dir message" "is not a directory" "$err"
    $runner "$PARALLEL_SH" "pcp '$WORK/src/file1.txt' '$WORK/src/file2.txt' '$WORK/nodir'" >/dev/null 2>&1
    assert_failure "$sh/pcp dest-not-dir exit code" "$?"
    assert_not_exists "$sh/pcp dest-not-dir nothing written" "$WORK/nodir"
    $runner "$PARALLEL_SH" "pmv '$WORK/src/file1.txt' '$WORK/src/file2.txt' '$WORK/nodir'" >/dev/null 2>&1
    assert_failure "$sh/pmv dest-not-dir exit code" "$?"
    assert_exists "$sh/pmv dest-not-dir sources untouched" "$WORK/src/file1.txt"

    echo "[$sh] pcp: overwrites an existing read-only destination file"
    setup_fixtures
    echo "old" > "$WORK/dest/file1.txt"
    chmod 444 "$WORK/dest/file1.txt"
    $runner "$PARALLEL_SH" "pcp '$WORK/src/file1.txt' '$WORK/dest/'" >/dev/null 2>&1
    assert_success "$sh/pcp read-only overwrite exit code" "$?"
    assert_eq "$sh/pcp read-only overwrite content" "hello" "$(cat "$WORK/dest/file1.txt")"

    echo "[$sh] failing job propagates a nonzero exit code"
    setup_fixtures
    $runner "$PARALLEL_SH" "pcp '$WORK/does-not-exist' '$WORK/dest/'" >/dev/null 2>&1
    assert_failure "$sh/pcp missing source rc" "$?"
    $runner "$PARALLEL_SH" "pmv '$WORK/does-not-exist' '$WORK/dest/'" >/dev/null 2>&1
    assert_failure "$sh/pmv missing source rc" "$?"
    printf 'y\n' | $runner "$PARALLEL_SH" "prm '$WORK/does-not-exist/x'" >/dev/null 2>&1
    assert_failure "$sh/prm missing path rc (rm -r, not -f)" "$?"

    echo "[$sh] prm: confirmation accept and abort"
    setup_fixtures
    printf 'y\n' | $runner "$PARALLEL_SH" "prm '$WORK/src/file1.txt'" >/dev/null 2>&1
    assert_success "$sh/prm y exit code" "$?"
    assert_not_exists "$sh/prm y removed" "$WORK/src/file1.txt"
    printf 'n\n' | $runner "$PARALLEL_SH" "prm '$WORK/src/file2.txt'" >/dev/null 2>&1
    assert_failure "$sh/prm n exit code" "$?"
    assert_exists "$sh/prm n kept" "$WORK/src/file2.txt"
    err=$(printf 'n\n' | $runner_err "$PARALLEL_SH" "prm '$WORK/src/file2.txt'")
    assert_contains "$sh/prm n message" "aborted" "$err"

    echo "[$sh] prm: a file named -f cannot flip force mode"
    setup_fixtures
    : > "$WORK/src/-f"
    printf 'y\n' | $runner "$PARALLEL_SH" "cd '$WORK/src' && prm *" >/dev/null 2>&1
    assert_failure "$sh/prm glob with -f file refuses" "$?"
    assert_exists "$sh/prm glob with -f: file1 kept" "$WORK/src/file1.txt"
    assert_exists "$sh/prm glob with -f: -f kept" "$WORK/src/-f"
    err=$($runner_err "$PARALLEL_SH" "cd '$WORK/src' && prm *" </dev/null)
    assert_contains "$sh/prm glob with -f names the ambiguity" "both a flag and an existing file" "$err"
    printf 'y\n' | $runner "$PARALLEL_SH" "cd '$WORK/src' && prm -- -f" >/dev/null 2>&1
    assert_success "$sh/prm -- -f exit code" "$?"
    assert_not_exists "$sh/prm -- -f removed the file" "$WORK/src/-f"
    assert_exists "$sh/prm -- -f left others" "$WORK/src/file1.txt"

    echo "[$sh] prm: flags after the first path are paths; unknown option rejected"
    setup_fixtures
    : > "$WORK/src/-f"
    printf 'y\n' | $runner "$PARALLEL_SH" "cd '$WORK/src' && prm -- file1.txt -f" >/dev/null 2>&1
    assert_success "$sh/prm trailing -f as operand exit code" "$?"
    assert_not_exists "$sh/prm trailing -f as operand removed" "$WORK/src/-f"
    setup_fixtures
    $runner "$PARALLEL_SH" "prm -x '$WORK/src/file1.txt'" >/dev/null 2>&1
    assert_failure "$sh/prm unknown option rc" "$?"
    assert_exists "$sh/prm unknown option removed nothing" "$WORK/src/file1.txt"
    $runner "$PARALLEL_SH" "prm --force" >/dev/null 2>&1
    assert_failure "$sh/prm no paths rc" "$?"
    err=$($runner_err "$PARALLEL_SH" "prm")
    assert_contains "$sh/prm no paths usage" "usage:" "$err"

    echo "[$sh] ptar: a source starting with - is a file; .tgz .tar .tbz2 .txz"
    setup_fixtures
    echo "dash" > "$WORK/src/-dash.txt"
    $runner "$PARALLEL_SH" "cd '$WORK/src' && ptar '$WORK/out.tgz' -dash.txt file1.txt" >/dev/null
    assert_success "$sh/ptar dash source exit code" "$?"
    assert_contains "$sh/ptar dash source archived" "-dash.txt" "$(tar tzf "$WORK/out.tgz")"
    $runner "$PARALLEL_SH" "cd '$WORK/src' && ptar '$WORK/out.tar' file1.txt" >/dev/null
    assert_success "$sh/ptar .tar exit code" "$?"
    assert_contains "$sh/ptar .tar content" "file1.txt" "$(tar tf "$WORK/out.tar")"
    $runner "$PARALLEL_SH" "cd '$WORK/src' && ptar '$WORK/out.tbz2' file1.txt" >/dev/null
    assert_contains "$sh/ptar .tbz2 content" "file1.txt" "$(tar tjf "$WORK/out.tbz2")"
    $runner "$PARALLEL_SH" "cd '$WORK/src' && ptar '$WORK/out.txz' file1.txt" >/dev/null
    assert_contains "$sh/ptar .txz content" "file1.txt" "$(tar tJf "$WORK/out.txz")"
    $runner "$PARALLEL_SH" "ptar '$WORK/out.rar' '$WORK/src/file1.txt'" >/dev/null 2>&1
    assert_failure "$sh/ptar unsupported format rc" "$?"
    rm -f "$WORK"/out.*

    echo "[$sh] pxargs"
    actual=$(printf 'a\nb\n' | $runner "$PARALLEL_SH" "pxargs -n1 echo" | sort | tr '\n' ' ')
    assert_eq "$sh/pxargs runs one job per line" "a b " "$actual"
done

# =============================================================================
# Argument coverage (pwsh): usage without prompts, wildcards, --force, -- for tar
# =============================================================================
echo ""
echo "================================================"
echo "  Argument coverage: parallel.ps1 with PWSH"
echo "================================================"

echo "[pwsh] zero arguments print usage (no interactive prompt)"
for fn in pcp pmv prm ptar; do
    err=$(timeout 60 bash -c "$(declare -f run_pwsh_stderr); run_pwsh_stderr '$PARALLEL_PS1' '$fn'")
    assert_contains "pwsh/$fn zero-arg usage" "usage:" "$err"
done

echo "[pwsh] pcp: wildcard sources are expanded"
setup_fixtures
run_pwsh "$PARALLEL_PS1" "pcp '$WORK/src/*.txt' '$WORK/dest'" >/dev/null
assert_success "pwsh/pcp wildcard exit code" "$?"
assert_exists "pwsh/pcp wildcard file1" "$WORK/dest/file1.txt"
assert_exists "pwsh/pcp wildcard file2" "$WORK/dest/file2.txt"

echo "[pwsh] pcp: destination with spaces"
setup_fixtures
mkdir -p "$WORK/My Documents"
run_pwsh "$PARALLEL_PS1" "pcp '$WORK/src/file1.txt' '$WORK/My Documents'" >/dev/null
assert_exists "pwsh/pcp space-dest file placed" "$WORK/My Documents/file1.txt"

echo "[pwsh] pmv: two wildcard-expanded sources"
setup_fixtures
run_pwsh "$PARALLEL_PS1" "pmv '$WORK/src/*.txt' '$WORK/dest'" >/dev/null
assert_exists "pwsh/pmv wildcard moved file2" "$WORK/dest/file2.txt"
assert_not_exists "pwsh/pmv wildcard src gone" "$WORK/src/file2.txt"

echo "[pwsh] prm: --force long flag and wildcard paths"
setup_fixtures
run_pwsh "$PARALLEL_PS1" "prm --force '$WORK/src/file1.txt'" >/dev/null
assert_success "pwsh/prm --force exit code" "$?"
assert_not_exists "pwsh/prm --force removed" "$WORK/src/file1.txt"
run_pwsh "$PARALLEL_PS1" "prm -Force '$WORK/src/*.txt'" >/dev/null
assert_not_exists "pwsh/prm wildcard removed file2" "$WORK/src/file2.txt"
assert_exists "pwsh/prm wildcard left subdir" "$WORK/src/subdir/file3.txt"

echo "[pwsh] ptar: a source starting with - is a file; .tar format"
setup_fixtures
echo "dash" > "$WORK/src/-dash.txt"
run_pwsh "$PARALLEL_PS1" "Set-Location '$WORK/src'; ptar '$WORK/out.tgz' '-dash.txt' 'file1.txt'" >/dev/null
assert_success "pwsh/ptar dash source exit code" "$?"
assert_contains "pwsh/ptar dash source archived" "-dash.txt" "$(tar tzf "$WORK/out.tgz")"
run_pwsh "$PARALLEL_PS1" "ptar '$WORK/out.tar' '$WORK/src/file1.txt'" >/dev/null
assert_exists "pwsh/ptar .tar" "$WORK/out.tar"
rm -f "$WORK"/out.*

# =============================================================================
# Summary
# =============================================================================
print_summary "test_parallel"
[ "$FAIL" -eq 0 ]
