#!/usr/bin/env bash
# test_harness.sh - Tests for helpers.sh itself: the temp workspace every suite
# works in, and what happens when it cannot be made.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

HARNESS_HELPERS="$SCRIPT_DIR/helpers.sh"

echo "================================================"
echo "  Testing the shell test harness (helpers.sh)"
echo "================================================"

# source_helpers_with <setup> - source helpers.sh in a child bash after running
# <setup> there, then reset the fixtures the way every suite does and print
# SUITE CONTINUED. rm and mkdir are functions that print what they were asked
# to run, so a reset of an empty WORK (rm -rf /*) shows up in the output
# instead of running. The child's TMPDIR is under WORK, so the temp directory
# a working mktemp makes there (which the stubbed rm cannot remove) goes when
# this suite's does.
CHILD_TMP="$WORK/child-tmp"
mkdir -p "$CHILD_TMP"
source_helpers_with() {
    TMPDIR="$CHILD_TMP" bash -c '
        rm() { echo "WOULD RUN: rm $*"; }
        mkdir() { echo "WOULD RUN: mkdir $*"; }
        eval "$1"
        source "$2"
        setup_fixtures
        echo "SUITE CONTINUED"
    ' _ "$1" "$HARNESS_HELPERS" 2>&1
}

echo "[harness] mktemp that fails stops the suite before any fixture reset"
actual=$(source_helpers_with "export TMPDIR='$WORK/no-such-dir'")
rc=$?
assert_eq "harness/failed mktemp exits 1" "1" "$rc"
assert_contains "harness/failed mktemp says why" "helpers.sh: mktemp -d failed; stopping the suite" "$actual"
assert_not_contains "harness/failed mktemp runs no rm" "WOULD RUN: rm" "$actual"
assert_not_contains "harness/failed mktemp stops the suite" "SUITE CONTINUED" "$actual"

echo "[harness] mktemp that prints nothing stops the suite too"
actual=$(source_helpers_with "mktemp() { :; }")
rc=$?
assert_eq "harness/empty mktemp exits 1" "1" "$rc"
assert_contains "harness/empty mktemp says why" "helpers.sh: mktemp -d failed; stopping the suite" "$actual"
assert_not_contains "harness/empty mktemp runs no rm" "WOULD RUN: rm" "$actual"
assert_not_contains "harness/empty mktemp stops the suite" "SUITE CONTINUED" "$actual"

echo "[harness] a working mktemp resets the fixtures inside WORK"
actual=$(source_helpers_with ":")
assert_contains "harness/reset runs" "SUITE CONTINUED" "$actual"
assert_match "harness/reset stays in WORK" "^WOULD RUN: rm -rf /.+/\*$" "$(printf '%s\n' "$actual" | grep '^WOULD RUN: rm -rf' | head -n 1)"

# A suite's own reset of WORK carries the same risk as setup_fixtures, so each
# one spells "${WORK:?}": should WORK ever be empty there, it stops instead of
# wiping /.
echo "[harness] every wipe of WORK in the suites stops on an empty WORK"
actual=$(cd "$SCRIPT_DIR" && grep -nE '^[^#]*rm -rf "\$WORK"/\*' -- *.sh)
assert_eq "harness/no unguarded wipe of WORK" "" "$actual"

# The scripts a suite generates from shell/ and then sources live in TESTTMP:
# inside the mktemp directory, where another user cannot put a file first, and
# beside WORK, so a fixture reset does not delete them.
echo "[harness] TESTTMP is private, survives a fixture reset, and goes at exit"
actual=$(TMPDIR="$CHILD_TMP" bash -c '
    source "$1"
    echo "root=$TEST_ROOT"
    echo "mode=$(stat -c %a "$TEST_ROOT")"
    case "$TESTTMP" in "$TEST_ROOT"/*) echo "gen in root" ;; esac
    case "$TESTTMP" in "$WORK"|"$WORK"/*) echo "gen in WORK" ;; esac
    echo generated > "$TESTTMP/gen.sh"
    setup_fixtures
    echo "after reset: $(cat "$TESTTMP/gen.sh" 2>&1)"
' _ "$HARNESS_HELPERS" 2>&1)
child_root=$(printf '%s\n' "$actual" | sed -n 's/^root=//p')
assert_eq "harness/root is a private directory" "mode=700" "$(printf '%s\n' "$actual" | grep '^mode=')"
assert_contains "harness/TESTTMP is in the root" "gen in root" "$actual"
assert_not_contains "harness/TESTTMP is not in WORK" "gen in WORK" "$actual"
assert_contains "harness/TESTTMP survives a fixture reset" "after reset: generated" "$actual"
assert_match "harness/root came from mktemp" "^$CHILD_TMP/tmp\..+" "$child_root"
assert_not_exists "harness/root removed at exit" "${child_root:-$CHILD_TMP/no-root-reported}"

echo "[harness] a generated script that cannot be written stops the suite"
actual=$(TMPDIR="$CHILD_TMP" bash -c '
    source "$1"
    make_noninteractive_source_copy "$1" "$WORK/no-such-dir/copy.sh"
    echo "SUITE CONTINUED"
' _ "$HARNESS_HELPERS" 2>&1)
rc=$?
assert_eq "harness/unwritable copy exits 1" "1" "$rc"
assert_contains "harness/unwritable copy says why" "cannot write" "$actual"
assert_not_contains "harness/unwritable copy stops the suite" "SUITE CONTINUED" "$actual"

echo "[harness] no suite writes a script to a predictable /tmp path"
actual=$(cd "$SCRIPT_DIR" && grep -nE '/tmp/[A-Za-z0-9_.-]*\$\$' -- *.sh)
assert_eq "harness/no /tmp/<name>_\$\$ paths" "" "$actual"

echo "[harness] no suite replaces the EXIT trap that removes the workspace"
actual=$(cd "$SCRIPT_DIR" && grep -nE '^[[:space:]]*trap .*EXIT' -- test_*.sh)
assert_eq "harness/no suite EXIT trap" "" "$actual"

# A real suite, run with a TMPDIR of its own: whatever it made there, and
# whatever its own EXIT trap would have left, shows up as a leftover entry.
echo "[harness] a suite leaves nothing behind in TMPDIR"
LEAK_TMP="$WORK/leak-tmp"
mkdir -p "$LEAK_TMP"
DOTFILES="$DOTFILES" TMPDIR="$LEAK_TMP" bash "$SCRIPT_DIR/test_cheat.sh" >/dev/null 2>&1
assert_success "harness/test_cheat passes" "$?"
assert_eq "harness/test_cheat leaves TMPDIR empty" "" "$(ls -A "$LEAK_TMP")"

print_summary "test_harness"
[ "$FAIL" -eq 0 ]
