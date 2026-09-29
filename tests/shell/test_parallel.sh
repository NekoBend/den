#!/usr/bin/env bash
# test_parallel.sh — Tests for parallel.sh (bash/zsh) and parallel.ps1 (pwsh).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

PARALLEL_SH_GUARDED="$DOTFILES/shell/posix/parallel.sh"
PARALLEL_SH="$TESTTMP/parallel_test.sh"
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
    for _out in out.tar.xz out.tgz out.tbz2 keep.tgz; do
        $runner "$PARALLEL_SH" "cd '$WORK' && ptar '$WORK/$_out' src missing-src" >/dev/null 2>&1
        assert_failure "$sh/ptar $_out with a missing source fails" "$?"
    done
    assert_not_exists "$sh/ptar failed .tar.xz leaves no archive" "$WORK/out.tar.xz"
    assert_not_exists "$sh/ptar failed .tgz leaves no archive" "$WORK/out.tgz"
    assert_eq "$sh/ptar failed run keeps an existing output" "PRECIOUS" "$(cat "$WORK/keep.tgz")"
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
