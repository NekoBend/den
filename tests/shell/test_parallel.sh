#!/usr/bin/env bash
# test_parallel.sh — Tests for parallel.sh (bash/zsh) and parallel.ps1 (pwsh).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

PARALLEL_SH_GUARDED="$DOTFILES/shell/posix/parallel.sh"
PARALLEL_SH="$TESTTMP/parallel_test.sh"
# parallel.ps1 takes _ResolvePaths from _helpers.ps1, which init.ps1 loads
# first; this file loads both in that order.
PARALLEL_PS1="$TESTTMP/parallel_test.ps1"
printf ". '%s'\n. '%s'\n" "$DOTFILES/shell/pwsh/_helpers.ps1" "$DOTFILES/shell/pwsh/parallel.ps1" > "$PARALLEL_PS1"

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

    echo "[$sh] prm: a DANGLING symlink named -f is refused too (-e follows links)"
    setup_fixtures
    ln -s "$WORK/does-not-exist" "$WORK/src/-f"
    printf 'y\n' | $runner "$PARALLEL_SH" "cd '$WORK/src' && prm *" >/dev/null 2>&1
    assert_failure "$sh/prm glob with dangling -f symlink refuses" "$?"
    assert_exists "$sh/prm dangling -f: file1 kept" "$WORK/src/file1.txt"
    err=$($runner_err "$PARALLEL_SH" "cd '$WORK/src' && prm *" </dev/null)
    assert_contains "$sh/prm dangling -f names the ambiguity" "both a flag and an existing file" "$err"
    printf 'y\n' | $runner "$PARALLEL_SH" "cd '$WORK/src' && prm -- -f" >/dev/null 2>&1
    assert_success "$sh/prm -- removes the dangling -f symlink" "$?"
    if [ -L "$WORK/src/-f" ]; then
        echo "  FAIL: $sh/prm -- dangling -f symlink removed"; ERRORS+=("$sh/prm -- dangling -f symlink removed"); ((FAIL++)) || true
    else
        echo "  PASS: $sh/prm -- dangling -f symlink removed"; ((PASS++)) || true
    fi

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

    echo "[$sh] ptar: a tar failure fails the compressed pipeline forms too"
    # tar | compressor reported the compressor's status, so a source tar could
    # not read still exited 0, and the redirection had already truncated the
    # output: `ptar backup.tgz dir && prm -f dir` deleted unarchived data.
    setup_fixtures
    echo "PRECIOUS" > "$WORK/keep.tgz"
    echo "PRECIOUS" > "$WORK/keep.tar"
    for _out in out.tar.xz out.tgz out.tbz2 keep.tgz keep.tar; do
        $runner "$PARALLEL_SH" "cd '$WORK' && ptar '$WORK/$_out' src missing-src" >/dev/null 2>&1
        assert_failure "$sh/ptar $_out with a missing source fails" "$?"
    done
    assert_not_exists "$sh/ptar failed .tar.xz leaves no archive" "$WORK/out.tar.xz"
    assert_not_exists "$sh/ptar failed .tgz leaves no archive" "$WORK/out.tgz"
    assert_eq "$sh/ptar failed run keeps an existing output" "PRECIOUS" "$(cat "$WORK/keep.tgz")"
    assert_eq "$sh/ptar failed .tar run keeps an existing output" "PRECIOUS" "$(cat "$WORK/keep.tar")"
    assert_eq "$sh/ptar failed run leaves no staging directory" "" "$(ls -A "$WORK" | grep '^\.ptar\.' | tr -d '\n')"
    $runner "$PARALLEL_SH" "cd '$WORK' && ptar '$WORK/keep.tgz' src" >/dev/null 2>&1
    assert_success "$sh/ptar .tgz over an existing output exit code" "$?"
    assert_contains "$sh/ptar .tgz replaced the existing output" "src/file1.txt" "$(tar tzf "$WORK/keep.tgz" 2>/dev/null)"
    mkdir -p "$WORK/adir.tgz"
    $runner "$PARALLEL_SH" "cd '$WORK' && ptar '$WORK/adir.tgz' src" >/dev/null 2>&1
    assert_failure "$sh/ptar refuses a directory as the output" "$?"
    assert_eq "$sh/ptar put nothing inside the directory output" "" "$(ls -A "$WORK/adir.tgz")"
    rm -rf "$WORK"/out.* "$WORK/keep.tgz" "$WORK/adir.tgz"

    echo "[$sh] ptar: an output inside its source leaves the staging directory out"
    # The threaded forms build the archive in a private .ptar.XXXXXX beside
    # <out>; with <out> inside a source, tar stored that directory and the
    # half-written archive in it.
    setup_fixtures
    for _out in out.tar.xz out.tgz out.tbz2; do
        $runner "$PARALLEL_SH" "cd '$WORK/src' && ptar $_out ." >/dev/null 2>&1
        assert_success "$sh/ptar $_out inside its source exit code" "$?"
        actual=$(tar tf "$WORK/src/$_out" 2>/dev/null)
        assert_contains "$sh/ptar $_out inside its source stored the files" "subdir/file3.txt" "$actual"
        assert_not_contains "$sh/ptar $_out inside its source left staging out" ".ptar." "$actual"
    done
    rm -f "$WORK"/src/out.*

    echo "[$sh] ptar: a rerun leaves the previous archive out of the new one"
    # On the threaded forms tar writes to a pipe, so it could not tell that
    # <out> was its own archive: a rerun of `ptar backup.tgz .` stored the
    # previous backup.tgz, files deleted since and all, inside the new one.
    setup_fixtures
    for _out in out.tar.xz out.tgz out.tbz2; do
        $runner "$PARALLEL_SH" "cd '$WORK/src' && ptar $_out . && ptar $_out ." >/dev/null 2>&1
        assert_success "$sh/ptar $_out rerun exit code" "$?"
        actual=$(tar tf "$WORK/src/$_out" 2>/dev/null)
        assert_contains "$sh/ptar $_out rerun stored the files" "subdir/file3.txt" "$actual"
        assert_not_contains "$sh/ptar $_out rerun left the previous archive out" "$_out" "$actual"
        assert_eq "$sh/ptar $_out rerun leaves no staging directory" "" "$(ls -A "$WORK/src" | grep '^\.ptar\.' | tr -d '\n')"
        rm -f "$WORK/src/$_out"
    done

    echo "[$sh] ptar: the single-threaded fallbacks leave their own output out too"
    # Without pigz or pbzip2, ptar ran `tar czf <out>` or `tar cjf <out>`,
    # which cannot tell that it is reading its own archive either (its
    # compressor is a pipe too): a rerun stored the old archive inside the new
    # one, and a failed run left a cut archive where the old one had been. A
    # PATH with tar, gzip and bzip2 but none of the threaded tools, and no xz,
    # takes the fallbacks.
    rm -rf "$WORK/fb"
    mkdir -p "$WORK/fb/bin" "$WORK/fb/d"
    for _t in tar gzip bzip2 mktemp mv rm sh cat; do ln -s "$(command -v "$_t")" "$WORK/fb/bin/$_t"; done
    echo a > "$WORK/fb/d/a.txt"; echo b > "$WORK/fb/d/b.txt"
    for _out in all.tgz all.tbz2; do
        actual=$($runner "$PARALLEL_SH" "PATH='$WORK/fb/bin' && cd '$WORK/fb/d' && ptar $_out * && ptar $_out *" 2>&1)
        assert_success "$sh/ptar $_out fallback rerun over a glob holding the output exit code" "$?"
        assert_contains "$sh/ptar $_out ran the fallback" "(using standard)" "$actual"
        assert_eq "$sh/ptar $_out fallback rerun over a glob holding the output" "a.txt b.txt " "$(tar tf "$WORK/fb/d/$_out" 2>/dev/null | sort | tr '\n' ' ')"
        $runner "$PARALLEL_SH" "PATH='$WORK/fb/bin' && cd '$WORK/fb/d' && ptar $_out ." >/dev/null 2>&1
        assert_success "$sh/ptar $_out fallback over its own folder exit code" "$?"
        assert_eq "$sh/ptar $_out fallback over its own folder leaves itself out" "./ ./a.txt ./b.txt " "$(tar tf "$WORK/fb/d/$_out" 2>/dev/null | sort | tr '\n' ' ')"
        cp "$WORK/fb/d/$_out" "$WORK/fb/before"
        $runner "$PARALLEL_SH" "PATH='$WORK/fb/bin' && cd '$WORK/fb/d' && ptar $_out a.txt missing" >/dev/null 2>&1
        assert_failure "$sh/ptar $_out fallback with a missing source fails" "$?"
        assert_eq "$sh/ptar $_out fallback failed run keeps the previous archive" "$(sha256sum < "$WORK/fb/before")" "$(sha256sum < "$WORK/fb/d/$_out")"
        assert_eq "$sh/ptar $_out fallback leaves no staging directory" "" "$(ls -A "$WORK/fb/d" | grep '^\.ptar\.' | tr -d '\n')"
        rm -f "$WORK/fb/d/$_out" "$WORK/fb/before"
    done
    # With no xz at all, .txz fails, and what was there stays.
    echo PRECIOUS > "$WORK/fb/d/keep.txz"
    $runner "$PARALLEL_SH" "PATH='$WORK/fb/bin' && cd '$WORK/fb/d' && ptar keep.txz a.txt" >/dev/null 2>&1
    assert_failure "$sh/ptar .txz with no xz fails" "$?"
    assert_eq "$sh/ptar .txz with no xz keeps what was there" "PRECIOUS" "$(cat "$WORK/fb/d/keep.txz")"
    assert_eq "$sh/ptar .txz with no xz leaves no staging directory" "" "$(ls -A "$WORK/fb/d" | grep '^\.ptar\.' | tr -d '\n')"
    rm -rf "$WORK/fb"

    echo "[$sh] ptar: a source that is the output itself is left out"
    # `ptar all.tgz *` run again: the glob holds the old all.tgz.
    rm -rf "$WORK/glob"
    mkdir -p "$WORK/glob"
    echo a > "$WORK/glob/a.txt"; echo b > "$WORK/glob/b.txt"
    for _out in all.tar.xz all.tgz all.tbz2; do
        $runner "$PARALLEL_SH" "cd '$WORK/glob' && ptar $_out * && ptar $_out *" >/dev/null 2>&1
        assert_success "$sh/ptar $_out rerun over a glob holding the output exit code" "$?"
        assert_eq "$sh/ptar $_out rerun over a glob holding the output" "a.txt b.txt " "$(tar tf "$WORK/glob/$_out" 2>/dev/null | sort | tr '\n' ' ')"
        rm -f "$WORK/glob/$_out"
    done
    $runner "$PARALLEL_SH" "cd '$WORK/glob' && ptar all.tgz a.txt" >/dev/null 2>&1
    cp "$WORK/glob/all.tgz" "$WORK/all.tgz.before"
    err=$($runner_err "$PARALLEL_SH" "cd '$WORK/glob' && ptar all.tgz ./all.tgz '$WORK/glob/all.tgz'")
    assert_contains "$sh/ptar with only the output as a source says so" "no source besides the output" "$err"
    $runner "$PARALLEL_SH" "cd '$WORK/glob' && ptar all.tgz ./all.tgz" >/dev/null 2>&1
    assert_failure "$sh/ptar with only the output as a source fails" "$?"
    assert_eq "$sh/ptar with only the output as a source keeps it" "$(sha256sum < "$WORK/all.tgz.before")" "$(sha256sum < "$WORK/glob/all.tgz")"
    rm -rf "$WORK/glob" "$WORK/all.tgz.before"

    echo "[$sh] ptar: a hard link to the output is left out too"
    # Under another name: only a source with the output's name was checked,
    # so latest.tgz, a hard link to backup.tgz, stayed a source, and with
    # backup.tgz moved aside it still held the previous archive.
    rm -rf "$WORK/hl"
    mkdir -p "$WORK/hl"
    echo a > "$WORK/hl/a.txt"; echo b > "$WORK/hl/b.txt"
    $runner "$PARALLEL_SH" "cd '$WORK/hl' && ptar backup.tgz a.txt" >/dev/null 2>&1
    ln "$WORK/hl/backup.tgz" "$WORK/hl/latest.tgz"
    cp "$WORK/hl/backup.tgz" "$WORK/hl.before"
    $runner "$PARALLEL_SH" "cd '$WORK/hl' && ptar backup.tgz latest.tgz" >/dev/null 2>"$WORK/hl.err"
    assert_failure "$sh/ptar with only a hard link to the output as a source fails" "$?"
    assert_contains "$sh/ptar with only a hard link to the output as a source says so" "no source besides the output" "$(cat "$WORK/hl.err")"
    assert_eq "$sh/ptar with only a hard link to the output as a source keeps it" "$(sha256sum < "$WORK/hl.before")" "$(sha256sum < "$WORK/hl/backup.tgz")"
    $runner "$PARALLEL_SH" "cd '$WORK/hl' && ptar backup.tgz *" >/dev/null 2>&1
    assert_success "$sh/ptar over a glob holding a hard link to the output exit code" "$?"
    assert_eq "$sh/ptar over a glob holding a hard link to the output" "a.txt b.txt " "$(tar tf "$WORK/hl/backup.tgz" 2>/dev/null | sort | tr '\n' ' ')"
    rm -rf "$WORK/hl" "$WORK/hl.before" "$WORK/hl.err"

    echo "[$sh] ptar: a previous archive that cannot be put back is kept and named"
    # The existing output now waits in the staging directory while tar runs.
    # A pigz stub that fails after putting a directory (holding a 'previous'
    # directory) where the archive goes makes moving it back fail, as a
    # directory that turned read-only would, even as root.
    rm -rf "$WORK/back"
    mkdir -p "$WORK/back/bin" "$WORK/back/src"
    echo x > "$WORK/back/src/x"
    echo PRECIOUS > "$WORK/back/keep.tgz"
    printf '#!/bin/sh\ncat > /dev/null\nmkdir -p keep.tgz/previous\nexit 3\n' > "$WORK/back/bin/pigz"
    chmod +x "$WORK/back/bin/pigz"
    err=$($runner_err "$PARALLEL_SH" "PATH='$WORK/back/bin:$PATH' && cd '$WORK/back' && ptar keep.tgz src")
    assert_contains "$sh/ptar says where the previous archive was kept" "ptar: previous 'keep.tgz' kept at ./.ptar." "$err"
    assert_eq "$sh/ptar kept the previous archive it could not put back" "PRECIOUS" "$(cat "$WORK/back"/.ptar.*/previous 2>/dev/null)"
    rm -rf "$WORK/back"

    echo "[$sh] ptar: a directory made at the output while tar runs takes in neither archive"
    # ptar refuses a directory at <out> before it starts, but another program
    # can make one there while tar runs, and the old archive is out of the way
    # then. mv moved the new archive INTO that directory, ptar reported
    # success, and the old archive went with the staging directory. A pigz
    # stub that makes an empty directory at <out> stands in for that program.
    # The same runs again with a BSD-like mv (no --version, no -T): once with
    # the directory there before the rename, once with it made by mv's own
    # call, after the check (the race the check cannot close).
    rm -rf "$WORK/race"
    mkdir -p "$WORK/race/bin" "$WORK/race/bsd" "$WORK/race/src"
    echo x > "$WORK/race/src/x"
    printf '#!/bin/sh\ngzip -c\nmkdir keep.tgz\n' > "$WORK/race/bin/pigz"
    chmod +x "$WORK/race/bin/pigz"
    printf '#!/bin/sh\ncase "$1" in --version|-*T*) echo "mv: illegal option" >&2; exit 64 ;; esac\nif [ -n "${MKDIR_AT-}" ] && [ "$4" = "$MKDIR_AT" ] && [ ! -e "$4" ]; then mkdir "$4"; fi\nexec %s "$@"\n' "$(command -v mv)" > "$WORK/race/bsd/mv"
    chmod +x "$WORK/race/bsd/mv"
    for _mv in gnu bsd bsd-late; do
        case $_mv in
            gnu) _path="$WORK/race/bin:$PATH" _env= ;;
            bsd) _path="$WORK/race/bin:$WORK/race/bsd:$PATH" _env= ;;
            *) _path="$WORK/race/bsd:$PATH" _env="MKDIR_AT=keep.tgz" ;;
        esac
        rm -rf "$WORK/race/keep.tgz" "$WORK/race"/.ptar.*
        echo PRECIOUS > "$WORK/race/keep.tgz"
        $runner "$PARALLEL_SH" "PATH='$_path' && export $_env PATH && cd '$WORK/race' && ptar keep.tgz src" >/dev/null 2>"$WORK/race.err"
        assert_failure "$sh/ptar ($_mv mv) with a directory made at the output fails" "$?"
        assert_contains "$sh/ptar ($_mv mv) with a directory made at the output says where the previous archive is" "ptar: previous 'keep.tgz' kept at ./.ptar." "$(cat "$WORK/race.err")"
        assert_eq "$sh/ptar ($_mv mv) with a directory made at the output keeps the previous archive" "PRECIOUS" "$(cat "$WORK/race"/.ptar.*/previous 2>/dev/null)"
        if [ "$_mv" = bsd-late ]; then
            # mv itself made the directory, so the new archive is in it, and
            # ptar says so.
            assert_contains "$sh/ptar ($_mv mv) says where the new archive went" "ptar: output 'keep.tgz' is a directory; 'archive' went into it" "$(cat "$WORK/race.err")"
        else
            assert_eq "$sh/ptar ($_mv mv) put nothing in the directory made at the output" "" "$(ls -A "$WORK/race/keep.tgz")"
        fi
    done
    # With no previous archive, the run that used to report success fails.
    rm -rf "$WORK/race/keep.tgz" "$WORK/race"/.ptar.*
    $runner "$PARALLEL_SH" "PATH='$WORK/race/bin:$PATH' && cd '$WORK/race' && ptar keep.tgz src" >/dev/null 2>&1
    assert_failure "$sh/ptar with a directory made at a new output fails" "$?"
    assert_eq "$sh/ptar with a directory made at a new output put nothing in it" "" "$(ls -A "$WORK/race/keep.tgz")"
    assert_eq "$sh/ptar with a directory made at a new output leaves no staging directory" "" "$(ls -A "$WORK/race" | grep '^\.ptar\.' | tr -d '\n')"
    rm -rf "$WORK/race" "$WORK/race.err"

    # The steps run in a subshell, which inherits a caller's `set -e`. A
    # failing tar or mv in plain sight ended it before the restore: the
    # previous archive stayed in the staging directory, and nothing said so.
    # A pigz stub stands in for the compressor, as above.
    echo "[$sh] ptar under set -euo pipefail puts the previous archive back, or says where it is"
    rm -rf "$WORK/strict"
    mkdir -p "$WORK/strict/bin" "$WORK/strict/src"
    echo x > "$WORK/strict/src/x"
    _strict="set -euo pipefail; source '$PARALLEL_SH'; PATH='$WORK/strict/bin:$PATH'; cd '$WORK/strict'"
    printf '#!/bin/sh\nexec gzip -c\n' > "$WORK/strict/bin/pigz"
    chmod +x "$WORK/strict/bin/pigz"
    echo PRECIOUS > "$WORK/strict/keep.tgz"
    actual=$("$sh" -c "$_strict; ptar keep.tgz src missing; echo after" 2>&1)
    assert_failure "$sh/ptar under set -e with tar failing fails" "$?"
    assert_not_contains "$sh/ptar under set -e with tar failing stops its caller" "after" "$actual"
    assert_eq "$sh/ptar under set -e with tar failing puts the previous archive back" "PRECIOUS" "$(cat "$WORK/strict/keep.tgz" 2>/dev/null)"
    assert_eq "$sh/ptar under set -e with tar failing leaves no staging directory" "" "$(ls -A "$WORK/strict" | grep '^\.ptar\.' | tr -d '\n')"
    # The compressor fails, and then the move back (as above).
    printf '#!/bin/sh\ncat > /dev/null\nmkdir -p keep.tgz/previous\nexit 3\n' > "$WORK/strict/bin/pigz"
    actual=$("$sh" -c "$_strict; ptar keep.tgz src; echo after" 2>&1)
    assert_contains "$sh/ptar under set -e with the move back failing says where the previous archive is" "ptar: previous 'keep.tgz' kept at ./.ptar." "$actual"
    assert_eq "$sh/ptar under set -e with the move back failing keeps the previous archive" "PRECIOUS" "$(cat "$WORK/strict"/.ptar.*/previous 2>/dev/null)"
    rm -rf "$WORK/strict/keep.tgz" "$WORK/strict"/.ptar.*
    # The archive is written, and putting it in place fails, then the move back.
    echo PRECIOUS > "$WORK/strict/keep.tgz"
    printf '#!/bin/sh\ncat > /dev/null\nmkdir -p keep.tgz/archive keep.tgz/previous\n' > "$WORK/strict/bin/pigz"
    actual=$("$sh" -c "$_strict; ptar keep.tgz src; echo after" 2>&1)
    assert_contains "$sh/ptar under set -e with publishing failing says where the previous archive is" "ptar: previous 'keep.tgz' kept at ./.ptar." "$actual"
    assert_eq "$sh/ptar under set -e with publishing failing keeps the previous archive" "PRECIOUS" "$(cat "$WORK/strict"/.ptar.*/previous 2>/dev/null)"
    # And with no staging directory to be had, ptar says so.
    actual=$("$sh" -c "$_strict; ptar nodir/out.tgz src; echo after" 2>&1)
    assert_contains "$sh/ptar under set -e says it cannot create a staging directory" "ptar: cannot create a temporary directory in 'nodir'" "$actual"
    # A cleanup that fails (an rm that refuses the staging directory) is not
    # a failed ptar: the new archive is already in place, so ptar still
    # succeeds and its caller goes on.
    rm -rf "$WORK/strict/keep.tgz" "$WORK/strict"/.ptar.*
    printf '#!/bin/sh\nexec gzip -c\n' > "$WORK/strict/bin/pigz"
    printf '#!/bin/sh\nfor a; do case $a in *.ptar.*) exit 1 ;; esac; done\nexec %s "$@"\n' "$(command -v rm)" > "$WORK/strict/bin/rm"
    chmod +x "$WORK/strict/bin/rm"
    echo PRECIOUS > "$WORK/strict/keep.tgz"
    actual=$("$sh" -c "$_strict; ptar keep.tgz src; echo after" 2>&1)
    assert_success "$sh/ptar under set -e with the cleanup failing succeeds" "$?"
    assert_contains "$sh/ptar under set -e with the cleanup failing lets its caller go on" "after" "$actual"
    assert_eq "$sh/ptar under set -e with the cleanup failing published the archive" "src/ src/x " "$(tar tzf "$WORK/strict/keep.tgz" 2>/dev/null | sort | tr '\n' ' ')"
    rm -rf "$WORK/strict"

    # Between moving the existing output aside and putting it back there is
    # no <out>, so a Ctrl-C (or a TERM or HUP) while tar runs must not end the
    # function there; and a run whose tar and compressor finish all the same
    # must not publish the new archive, deleting the old one, before the
    # signal is raised again. A tar stub runs the real tar, then sends the
    # signal to its whole process group, as Ctrl-C at a terminal does,
    # ignores it itself and exits 0; a pigz stub ignores it too. The run gets
    # a process group of its own (set -m), with SIGINT at its default (env
    # --default-signal, coreutils 8.31+), as test_functions.sh does for
    # archive, and its output is read through a pipe, which ends only when
    # every process of the run has, the subshell that puts things back
    # included: no timing decides what the checks see.
    if ! env --default-signal=INT true 2>/dev/null; then
        echo "[$sh] ptar that gets a signal while tar runs"
        echo "  SKIP: env has no --default-signal"
    else
        rm -rf "$WORK/sig"
        mkdir -p "$WORK/sig/bin"
        printf '#!/bin/sh\ntrap "" INT TERM HUP\n%s "$@" || exit\nkill -s "$SIG" 0\nexit 0\n' "$(command -v tar)" > "$WORK/sig/bin/tar"
        printf '#!/bin/sh\ntrap "" INT TERM HUP\nexec %s -c\n' "$(command -v gzip)" > "$WORK/sig/bin/pigz"
        chmod +x "$WORK/sig/bin/tar" "$WORK/sig/bin/pigz"
        for _sig in INT TERM HUP; do
            echo "[$sh] ptar that gets SIG$_sig while tar runs puts the previous archive back"
            rm -rf "$WORK/sig/run"
            mkdir -p "$WORK/sig/run/src"
            echo x > "$WORK/sig/run/src/x"
            echo PRECIOUS > "$WORK/sig/run/keep.tgz"
            actual=$(
                set -m
                env --default-signal=INT SIG="$_sig" "$sh" -c "source '$PARALLEL_SH' && PATH='$WORK/sig/bin:$PATH' && cd '$WORK/sig/run' && ptar keep.tgz src; echo after" 2>&1 &
                wait "$!"
                echo "status=$?"
            )
            assert_eq "$sh/ptar after SIG$_sig keeps the previous archive" "PRECIOUS" "$(cat "$WORK/sig/run/keep.tgz" 2>/dev/null)"
            assert_eq "$sh/ptar after SIG$_sig leaves no staging directory" "" "$(ls -A "$WORK/sig/run" | grep '^\.ptar\.' | tr -d '\n')"
            # The signal is raised again, so the caller stops as it would have.
            assert_not_contains "$sh/ptar after SIG$_sig stops its caller" "after" "$actual"
            assert_not_contains "$sh/ptar after SIG$_sig does not report success" "status=0" "$actual"
        done
        rm -rf "$WORK/sig"
    fi

    echo "[$sh] pcp/pmv/prm hand each job a batch of operands, not one each"
    # One cp/mv/rm per operand made `pcp * dest` over a few thousand small
    # files 10-70x slower than a plain cp. cp, mv and rm stubs on PATH log one
    # line per run, on both the GNU parallel and the xargs branch.
    setup_fixtures
    mkdir -p "$WORK/logbin" "$WORK/fakebin"
    printf '#!/bin/sh\necho "not gnu parallel"\n' > "$WORK/fakebin/parallel"
    chmod +x "$WORK/fakebin/parallel"
    for _t in cp mv rm; do
        printf '#!/bin/sh\necho run >> "%s/%s.log"\nexec %s "$@"\n' "$WORK" "$_t" "$(command -v "$_t")" > "$WORK/logbin/$_t"
        chmod +x "$WORK/logbin/$_t"
    done
    _n=$(( $(nproc 2>/dev/null || echo 4) * 4 ))
    for _branch in gnu xargs; do
        _path="$WORK/logbin:$PATH"
        [ "$_branch" = xargs ] && _path="$WORK/logbin:$WORK/fakebin:$PATH"
        rm -rf "$WORK/many" "$WORK/copied" "$WORK/moved" "$WORK"/*.log
        mkdir -p "$WORK/many" "$WORK/copied" "$WORK/moved"
        _i=1
        while [ "$_i" -le "$_n" ]; do echo x > "$WORK/many/f$_i"; _i=$((_i + 1)); done
        $runner "$PARALLEL_SH" "cd '$WORK/many' && PATH='$_path' pcp * '$WORK/copied'" >/dev/null 2>&1
        assert_success "$sh/$_branch pcp batch exit code" "$?"
        assert_eq "$sh/$_branch pcp copied every file" "$_n" "$(ls "$WORK/copied" | wc -l | tr -d ' ')"
        _runs=$(cat "$WORK/cp.log" 2>/dev/null | wc -l | tr -d ' ')
        assert_eq "$sh/$_branch pcp ran cp fewer times than files ($_runs of $_n)" "yes" "$([ "$_runs" -ge 1 ] && [ "$_runs" -lt "$_n" ] && echo yes)"
        $runner "$PARALLEL_SH" "cd '$WORK/many' && PATH='$_path' pmv * '$WORK/moved'" >/dev/null 2>&1
        assert_success "$sh/$_branch pmv batch exit code" "$?"
        assert_eq "$sh/$_branch pmv moved every file" "$_n" "$(ls "$WORK/moved" | wc -l | tr -d ' ')"
        _runs=$(cat "$WORK/mv.log" 2>/dev/null | wc -l | tr -d ' ')
        assert_eq "$sh/$_branch pmv ran mv fewer times than files ($_runs of $_n)" "yes" "$([ "$_runs" -ge 1 ] && [ "$_runs" -lt "$_n" ] && echo yes)"
        $runner "$PARALLEL_SH" "cd '$WORK/moved' && PATH='$_path' prm -f -- *" >/dev/null 2>&1
        assert_success "$sh/$_branch prm batch exit code" "$?"
        assert_eq "$sh/$_branch prm removed every file" "0" "$(ls "$WORK/moved" | wc -l | tr -d ' ')"
        _runs=$(cat "$WORK/rm.log" 2>/dev/null | wc -l | tr -d ' ')
        assert_eq "$sh/$_branch prm ran rm fewer times than files ($_runs of $_n)" "yes" "$([ "$_runs" -ge 1 ] && [ "$_runs" -lt "$_n" ] && echo yes)"
    done

    echo "[$sh] the GNU parallel probe runs once per shell, and again after PATH moves"
    # `parallel --version` costs about 60 ms and ran on every call.
    if _real_parallel=$(command -v parallel) && "$_real_parallel" --version 2>/dev/null | grep -q 'GNU parallel'; then
        mkdir -p "$WORK/probebin" "$WORK/d1" "$WORK/d2" "$WORK/d3"
        printf '#!/bin/sh\n[ "$1" = --version ] && echo probe >> "%s/probe.log"\nexec %s "$@"\n' "$WORK" "$_real_parallel" > "$WORK/probebin/parallel"
        chmod +x "$WORK/probebin/parallel"
        rm -f "$WORK/probe.log"
        $runner "$PARALLEL_SH" "export PATH='$WORK/probebin:$PATH'; pcp '$WORK/src/file1.txt' '$WORK/d1' && pcp '$WORK/src/file2.txt' '$WORK/d2' && PATH='$WORK/fakebin:$PATH' pcp '$WORK/src/file1.txt' '$WORK/d3'" >/dev/null 2>&1
        assert_success "$sh/cached probe exit code" "$?"
        assert_eq "$sh/GNU parallel probed once for two calls" "1" "$(wc -l < "$WORK/probe.log" | tr -d ' ')"
        assert_exists "$sh/cached probe second call copied" "$WORK/d2/file2.txt"
        assert_exists "$sh/a non-GNU parallel later on PATH falls back to xargs" "$WORK/d3/file1.txt"
    else
        echo "  SKIP: GNU parallel is not installed"
    fi
    rm -rf "$WORK/logbin" "$WORK/fakebin" "$WORK/probebin"

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

echo "[pwsh] ptar: a tar failure is a failure"
# tar's exit code was never checked: a source tar could not read left a
# partial archive while ptar, and `pwsh -Command`, reported success.
setup_fixtures
for _out in out.tgz out.tar.xz out.tar; do
    run_pwsh "$PARALLEL_PS1" "Set-Location '$WORK'; ptar '$_out' src missing-src" >/dev/null 2>&1
    assert_failure "pwsh/ptar $_out with a missing source exits nonzero" "$?"
done
err=$(run_pwsh_stderr_oneline "$PARALLEL_PS1" "Set-Location '$WORK'; ptar out.tgz src missing-src")
assert_contains "pwsh/ptar names tar's exit code" "tar exited 2" "$err"
actual=$(run_pwsh "$PARALLEL_PS1" "Set-Location '$WORK'; try { ptar out.tgz src missing-src 2>\$null } catch { 'caught' }" 2>/dev/null | tr -d '\r' | tail -1)
assert_eq "pwsh/ptar failure is a terminating error" "caught" "$actual"
rm -f "$WORK"/out.*

echo "[pwsh] ptar: a rerun leaves the previous archive out, and a failed run keeps it"
# pwsh's ptar ran `tar czf <out>`, and GNU tar cannot tell that it is reading
# its own archive when it compresses: a rerun of `ptar backup.tgz .` stored
# the old archive (and the one being written) inside the new one, and a
# failed tar left a cut archive where the old one had been.
for _out in all.tgz all.tbz2 all.txz all.tar; do
    rm -rf "$WORK/own" "$WORK/own.before"
    mkdir -p "$WORK/own"
    echo a > "$WORK/own/a.txt"; echo b > "$WORK/own/b.txt"
    run_pwsh "$PARALLEL_PS1" "Set-Location '$WORK/own'; ptar $_out a.txt b.txt; ptar $_out (Get-ChildItem -Name)" >/dev/null 2>&1
    assert_success "pwsh/ptar $_out rerun over a list holding the output exit code" "$?"
    assert_eq "pwsh/ptar $_out rerun over a list holding the output" "a.txt b.txt " "$(tar tf "$WORK/own/$_out" 2>/dev/null | sort | tr '\n' ' ')"
    run_pwsh "$PARALLEL_PS1" "Set-Location '$WORK/own'; ptar $_out ." >/dev/null 2>&1
    assert_success "pwsh/ptar $_out over its own folder exit code" "$?"
    assert_eq "pwsh/ptar $_out over its own folder leaves itself out" "./ ./a.txt ./b.txt " "$(tar tf "$WORK/own/$_out" 2>/dev/null | sort | tr '\n' ' ')"
    cp "$WORK/own/$_out" "$WORK/own.before"
    err=$(run_pwsh_stderr_oneline "$PARALLEL_PS1" "Set-Location '$WORK/own'; ptar $_out a.txt missing")
    assert_contains "pwsh/ptar $_out with a missing source names tar's exit code" "tar exited 2" "$err"
    assert_not_contains "pwsh/ptar $_out put the old archive back and says nothing of a kept copy" "kept at" "$err"
    assert_eq "pwsh/ptar $_out failed run keeps the previous archive" "$(sha256sum < "$WORK/own.before")" "$(sha256sum < "$WORK/own/$_out")"
    assert_eq "pwsh/ptar $_out leaves nothing behind" "" "$(ls -A "$WORK/own" | grep '^\.ptar\.' | tr -d '\n')"
done
err=$(run_pwsh_stderr_oneline "$PARALLEL_PS1" "Set-Location '$WORK/own'; ptar all.tar ./all.tar")
assert_contains "pwsh/ptar with only the output as a source says so" "no source besides the output" "$err"
# A directory made at the output while tar runs (a gzip stub, which tar runs
# for -z, makes it) takes in neither archive.
rm -rf "$WORK/own" "$WORK/own.before"
mkdir -p "$WORK/own/bin" "$WORK/own/src"
echo x > "$WORK/own/src/x"
echo PRECIOUS > "$WORK/own/keep.tgz"
printf '#!/bin/sh\n%s "$@"\nmkdir keep.tgz\n' "$(command -v gzip)" > "$WORK/own/bin/gzip"
chmod +x "$WORK/own/bin/gzip"
err=$(run_pwsh_stderr_oneline "$PARALLEL_PS1" "\$env:PATH='$WORK/own/bin:' + \$env:PATH; Set-Location '$WORK/own'; ptar keep.tgz src")
assert_contains "pwsh/ptar with a directory made at the output says where the previous archive is" "ptar: previous 'keep.tgz' kept at .ptar." "$err"
assert_eq "pwsh/ptar with a directory made at the output keeps the previous archive" "PRECIOUS" "$(cat "$WORK/own"/.ptar.*/previous 2>/dev/null)"
assert_eq "pwsh/ptar put nothing in the directory made at the output" "" "$(ls -A "$WORK/own/keep.tgz")"
rm -rf "$WORK/own"

echo "[pwsh] ptar on Windows drops a source spelled like the output but for case only when it is the output"
# Windows takes BACKUP.TGZ for backup.tgz in an ordinary folder, but a
# case-sensitive one (WSL makes them) holds the two as files of their own,
# and ptar left BACKUP.TGZ out of the archive without a word. The folder is
# asked now (_DenOneEntry). Linux's file system stands in for a
# case-sensitive folder, and $env:OS = 'Windows_NT' selects Windows' rule,
# as test_functions.sh does for archive.
rm -rf "$WORK/cs"
mkdir -p "$WORK/cs/src"
echo x > "$WORK/cs/src/x"
echo upper > "$WORK/cs/BACKUP.TGZ"
tar czf "$WORK/cs/backup.tgz" -C "$WORK/cs" src
actual=$(run_pwsh "$PARALLEL_PS1" "\$env:OS = 'Windows_NT'; Set-Location '$WORK/cs'; ptar backup.tgz BACKUP.TGZ src" 2>&1; echo "status=$?")
assert_contains "pwsh/ptar on Windows with a source that differs from the output only in case exits 0" "status=0" "$actual"
assert_eq "pwsh/ptar on Windows keeps a source that differs from the output only in case" "BACKUP.TGZ src/ src/x " "$(tar tzf "$WORK/cs/backup.tgz" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
actual=$(run_pwsh "$PARALLEL_PS1" "\$env:OS = 'Windows_NT'; Set-Location '$WORK/cs'; ptar backup.tgz BACKUP.TGZ" 2>&1; echo "status=$?")
assert_contains "pwsh/ptar on Windows with only that source exits 0" "status=0" "$actual"
assert_eq "pwsh/ptar on Windows with only that source archives it" "BACKUP.TGZ " "$(tar tzf "$WORK/cs/backup.tgz" 2>/dev/null | tr '\n' ' ')"
# A folder that cannot be listed cannot say whether the two are one file:
# the source is refused, naming both, before anything is moved. Root lists
# any folder.
if [ "$(id -u)" -eq 0 ]; then
    echo "  SKIP: root can list any folder"
else
    echo PRECIOUS > "$WORK/cs/backup.tgz"
    chmod 311 "$WORK/cs"
    actual=$(run_pwsh "$PARALLEL_PS1" "\$env:OS = 'Windows_NT'; Set-Location '$WORK/cs'; ptar backup.tgz BACKUP.TGZ src" 2>&1 | tr -d '\r'; echo "status=${PIPESTATUS[0]}")
    chmod 755 "$WORK/cs"
    assert_contains "pwsh/ptar on Windows that cannot list the folder fails" "status=1" "$actual"
    assert_contains "pwsh/ptar on Windows that cannot list the folder names both" "cannot tell whether '$WORK/cs/BACKUP.TGZ' and '$WORK/cs/backup.tgz' are one file" "$actual"
    assert_eq "pwsh/ptar on Windows that cannot list the folder keeps the old archive" "PRECIOUS" "$(cat "$WORK/cs/backup.tgz" 2>/dev/null)"
    assert_eq "pwsh/ptar on Windows that cannot list the folder leaves no staging folder" "" "$(ls -A "$WORK/cs" | grep '^\.ptar\.' | tr -d '\n')"
fi
rm -rf "$WORK/cs"

echo "[pwsh] pcp/pmv/prm: a path that fails is a failure"
# Each path runs in a ForEach-Object -Parallel worker, and the workers' errors
# reached neither $? nor the process status: `pcp missing dest` exited 0, and
# `pcp a b dest && prm -Force a b` went on to remove a file never copied.
setup_fixtures
run_pwsh "$PARALLEL_PS1" "Set-Location '$WORK'; pcp src/file1.txt missing.txt dest && prm -Force src/file1.txt" >/dev/null 2>&1
assert_failure "pwsh/pcp with a missing source exits nonzero" "$?"
assert_exists "pwsh/pcp with a missing source still copied the others" "$WORK/dest/file1.txt"
assert_exists "pwsh/pcp failure stops a && chain" "$WORK/src/file1.txt"
run_pwsh "$PARALLEL_PS1" "Set-Location '$WORK'; pmv src/file2.txt missing.txt dest" >/dev/null 2>&1
assert_failure "pwsh/pmv with a missing source exits nonzero" "$?"
assert_exists "pwsh/pmv with a missing source still moved the others" "$WORK/dest/file2.txt"
run_pwsh "$PARALLEL_PS1" "Set-Location '$WORK'; prm -Force src/subdir missing.txt" >/dev/null 2>&1
assert_failure "pwsh/prm with a missing path exits nonzero" "$?"
assert_not_exists "pwsh/prm with a missing path still removed the others" "$WORK/src/subdir"
# The count is of the errors the workers reported, not of paths: one
# unreadable file can report two.
for _fn in pcp pmv; do
    err=$(run_pwsh_stderr_oneline "$PARALLEL_PS1" "Set-Location '$WORK'; $_fn missing.txt dest")
    assert_contains "pwsh/$_fn counts the errors" "$_fn: 1 error(s)" "$err"
    actual=$(run_pwsh "$PARALLEL_PS1" "Set-Location '$WORK'; try { $_fn missing.txt dest 2>\$null } catch { 'caught' }" 2>/dev/null | tr -d '\r' | tail -1)
    assert_eq "pwsh/$_fn failure is a terminating error" "caught" "$actual"
done
err=$(run_pwsh_stderr_oneline "$PARALLEL_PS1" "Set-Location '$WORK'; prm -Force missing.txt also-missing.txt")
assert_contains "pwsh/prm counts the errors" "prm: 2 error(s)" "$err"
actual=$(run_pwsh "$PARALLEL_PS1" "Set-Location '$WORK'; try { prm -Force missing.txt 2>\$null } catch { 'caught' }" 2>/dev/null | tr -d '\r' | tail -1)
assert_eq "pwsh/prm failure is a terminating error" "caught" "$actual"

echo "[pwsh] pcp/pmv/prm/ptar: a refusal is a failure"
# Each refusal was a plain Write-Error and return, which leaves $? true and
# `pwsh -Command` exiting 0: `pcp a b nodir && prm -Force a b` removed both
# files after pcp had refused the destination and copied nothing.
setup_fixtures
run_pwsh "$PARALLEL_PS1" "Set-Location '$WORK/src'; pcp file1.txt file2.txt nodir && prm -Force file1.txt file2.txt" >/dev/null 2>&1
assert_failure "pwsh/pcp into a destination that is not a directory exits nonzero" "$?"
assert_exists "pwsh/pcp refusal stops a && chain" "$WORK/src/file1.txt"
# The cases below start from a full tree again: where the chain above went
# on and removed both files, each of them must still pass or fail for its
# own reason.
setup_fixtures
mkdir -p "$WORK/nobin"
while IFS='|' read -r _label _call; do
    actual=$(run_pwsh "$PARALLEL_PS1" "Set-Location '$WORK/src'; try { $_call 2>\$null } catch { 'caught' }" 2>/dev/null | tr -d '\r' | tail -1)
    assert_eq "pwsh/$_label is a terminating error" "caught" "$actual"
done <<CALLS
pcp without arguments|pcp
pcp with one argument|pcp file1.txt
pmv without arguments|pmv
pmv into a destination that is not a directory|pmv file1.txt file2.txt nodir
prm without paths|prm --force
prm declined|function Read-Host { 'n' }; prm file1.txt
ptar without arguments|ptar
ptar with an unsupported format|ptar out.zip file1.txt
ptar without tar|\$env:PATH = '$WORK/nobin'; ptar out.tar file1.txt
CALLS
# A declined prm and a refused pmv stop a && chain as well, and touch nothing
# themselves.
run_pwsh "$PARALLEL_PS1" "Set-Location '$WORK/src'; function Read-Host { 'n' }; prm file1.txt && Remove-Item -LiteralPath file1.txt" >/dev/null 2>&1
assert_failure "pwsh/declined prm exits nonzero" "$?"
assert_exists "pwsh/declined prm stops a && chain and keeps the file" "$WORK/src/file1.txt"
run_pwsh "$PARALLEL_PS1" "Set-Location '$WORK/src'; pmv file1.txt file2.txt nodir && Remove-Item -LiteralPath file2.txt" >/dev/null 2>&1
assert_failure "pwsh/refused pmv exits nonzero" "$?"
assert_exists "pwsh/refused pmv stops a && chain and moved nothing" "$WORK/src/file2.txt"
rm -rf "$WORK/nobin"

echo "[pwsh] prm: a confirmed removal takes hidden entries too"
# Remove-Item without -Force refuses hidden items, so a confirmed prm removed
# every visible file in the tree and left the dotfiles and .git behind.
# Read-Host is stubbed to answer y and echo the prompt it was asked.
setup_fixtures
mkdir -p "$WORK/src/.git"
echo cfg > "$WORK/src/.git/config"
echo env > "$WORK/src/.env"
actual=$(cd / && run_pwsh "$PARALLEL_PS1" "function Read-Host { param([string]\$Prompt) Write-Host \$Prompt; 'y' }; Set-Location '$WORK'; prm src" 2>&1 | tr -d '\r')
assert_not_exists "pwsh/prm confirmed removed the whole tree" "$WORK/src"
assert_not_contains "pwsh/prm confirmed raised no hidden-item error" "hidden" "$actual"
# The count in that prompt came from .NET, which resolved 'src' against the
# directory pwsh started in (/ here), not the PowerShell location: 1 entry.
assert_contains "pwsh/prm prompt counts the relative directory" "remove 1 paths (8 entries)?" "$actual"

echo "[pwsh] _CountEntries resolves a relative path against the PowerShell location"
setup_fixtures
actual=$(cd / && run_pwsh "$PARALLEL_PS1" "Set-Location '$WORK'; _CountEntries 'src'" | tr -d '\r')
assert_eq "pwsh/_CountEntries relative dir" "5" "$actual"

echo "[pwsh] pcp/pmv/prm hand each parallel item a batch of paths"
# One ForEach-Object -Parallel item per path made pcp 4x slower than a plain
# Copy-Item over many small files; each item now takes one round-robin list.
actual=$(run_pwsh "$PARALLEL_PS1" "_Batches @('a','b','c','d','e') 2 | ForEach-Object { \$_ -join ',' }" | tr -d '\r')
assert_eq "pwsh/_Batches round-robin" "a,c,e
b,d" "$actual"
actual=$(run_pwsh "$PARALLEL_PS1" "@(_Batches @('a','b') 8).Count; @(_Batches @() 8).Count" | tr -d '\r')
assert_eq "pwsh/_Batches never makes an empty list" "2
0" "$actual"
setup_fixtures
rm -rf "$WORK/many" && mkdir -p "$WORK/many" "$WORK/copied" "$WORK/moved"
_n=$(( $(nproc 2>/dev/null || echo 4) * 4 ))
_i=1
while [ "$_i" -le "$_n" ]; do echo x > "$WORK/many/f$_i"; _i=$((_i + 1)); done
run_pwsh "$PARALLEL_PS1" "Set-Location '$WORK/many'; pcp * '$WORK/copied'" >/dev/null 2>&1
assert_eq "pwsh/pcp batched copied every file" "$_n" "$(ls "$WORK/copied" | wc -l | tr -d ' ')"
run_pwsh "$PARALLEL_PS1" "Set-Location '$WORK/many'; pmv * '$WORK/moved'" >/dev/null 2>&1
assert_eq "pwsh/pmv batched moved every file" "$_n" "$(ls "$WORK/moved" | wc -l | tr -d ' ')"
assert_eq "pwsh/pmv batched emptied the source" "0" "$(ls "$WORK/many" | wc -l | tr -d ' ')"
run_pwsh "$PARALLEL_PS1" "Set-Location '$WORK/moved'; prm -Force *" >/dev/null 2>&1
assert_eq "pwsh/prm batched removed every file" "0" "$(ls "$WORK/moved" | wc -l | tr -d ' ')"
# The call sites: copying, moving and removing every file says nothing about
# how the paths were dispatched, so _Batches is wrapped to log each call (its
# list count and path count). pcp, pmv and prm must each go through it once,
# with min(ProcessorCount, files) lists that hold every path.
_spy=$(cat <<'PS1'
$global:batchLog = [System.Collections.Generic.List[string]]::new()
$global:realBatches = ${function:_Batches}
function _Batches {
    $lists = @(& $global:realBatches @args)
    $sum = 0
    foreach ($l in $lists) { $sum += $l.Count }
    $global:batchLog.Add("$($lists.Count) $sum")
    foreach ($l in $lists) { , $l }
}
PS1
)
mkdir -p "$WORK/many" "$WORK/copied2" "$WORK/moved"
_i=1
while [ "$_i" -le "$_n" ]; do echo x > "$WORK/many/f$_i"; _i=$((_i + 1)); done
actual=$(run_pwsh "$PARALLEL_PS1" "$_spy
Set-Location '$WORK/many'; pcp * '$WORK/copied2' *>\$null; pmv * '$WORK/moved' *>\$null
Set-Location '$WORK/moved'; prm -Force * *>\$null
[Environment]::ProcessorCount; \$global:batchLog" 2>/dev/null | tr -d '\r')
_p=$(printf '%s\n' "$actual" | head -1)
_k=$_n
[ -n "$_p" ] && [ "$_p" -lt "$_n" ] && _k=$_p
assert_eq "pwsh/pcp pmv prm each dispatched their paths through _Batches" "$_k $_n
$_k $_n
$_k $_n" "$(printf '%s\n' "$actual" | tail -n +2)"
assert_eq "pwsh/pcp through _Batches copied every file" "$_n" "$(ls "$WORK/copied2" | wc -l | tr -d ' ')"
assert_eq "pwsh/prm through _Batches removed every file" "0" "$(ls "$WORK/moved" | wc -l | tr -d ' ')"
rm -rf "$WORK/many" "$WORK/copied" "$WORK/copied2" "$WORK/moved"

# =============================================================================
# Summary
# =============================================================================
print_summary "test_parallel"
[ "$FAIL" -eq 0 ]
