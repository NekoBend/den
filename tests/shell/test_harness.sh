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

print_summary "test_harness"
[ "$FAIL" -eq 0 ]
