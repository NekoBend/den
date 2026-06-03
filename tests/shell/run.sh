#!/usr/bin/env bash
# run.sh — Run all shell tests and display aggregated results.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TOTAL_PASS=0
TOTAL_FAIL=0
ALL_ERRORS=()
SUITE_RESULTS=()

for test_file in "$SCRIPT_DIR"/test_*.sh; do
    [ -f "$test_file" ] || continue
    suite_name="$(basename "$test_file" .sh)"
    echo ""
    echo "================================================"
    echo "  Running: $suite_name"
    echo "================================================"

    # Run in subshell so PASS/FAIL don't leak
    output=$( bash "$test_file" 2>&1 )
    rc=$?
    echo "$output"

    # Extract pass/fail from the summary line ("--- ...: N passed, M failed ---")
    pass=$(echo "$output" | grep -oP '\d+(?= passed)' | tail -1)
    fail=$(echo "$output" | grep -oP '\d+(?= failed)' | tail -1)

    pass=${pass:-0}
    fail=${fail:-0}

    # A suite that aborts under `set -e` prints no summary line, so the greps
    # above yield 0/0. Honor the exit code: a non-zero rc with no reported
    # failures means the suite crashed; count it as a failure instead of OK.
    if [ "$rc" -ne 0 ] && [ "$fail" -eq 0 ]; then
        fail=1
        ALL_ERRORS+=("$suite_name crashed (rc=$rc, no summary line emitted)")
    fi

    TOTAL_PASS=$((TOTAL_PASS + pass))
    TOTAL_FAIL=$((TOTAL_FAIL + fail))

    if [ "$fail" -gt 0 ]; then
        SUITE_RESULTS+=("  FAIL: $suite_name ($pass passed, $fail failed)")
    else
        SUITE_RESULTS+=("  OK:   $suite_name ($pass passed)")
    fi
done

echo ""
echo "================================================"
echo "  TOTAL: $TOTAL_PASS passed, $TOTAL_FAIL failed"
echo "================================================"
for line in "${SUITE_RESULTS[@]}"; do
    echo "$line"
done

if [ "${#ALL_ERRORS[@]}" -gt 0 ]; then
    echo ""
    echo "Crashed suites:"
    for err in "${ALL_ERRORS[@]}"; do
        echo "  $err"
    done
fi

if [ "$TOTAL_FAIL" -gt 0 ]; then
    exit 1
fi

echo ""
echo "All tests passed."
exit 0
