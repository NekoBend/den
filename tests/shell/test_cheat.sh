#!/usr/bin/env bash
# test_cheat.sh — Tests for cheat.sh (browse den's bundled cheatsheets).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

CHEAT_SH_GUARDED="$DOTFILES/shell/posix/cheat.sh"
CHEAT_SH="/tmp/cheat_test_$$.sh"
make_noninteractive_source_copy "$CHEAT_SH_GUARDED" "$CHEAT_SH"

# Isolate the cheatsheet store under WORK so tests never touch the real data dir.
export XDG_DATA_HOME="$WORK/xdg"
CHEAT_ROOT="$XDG_DATA_HOME/den/cheatsheets"
EMPTY_XDG="$WORK/empty"

setup_store() {
    rm -rf "$CHEAT_ROOT"
    mkdir -p "$CHEAT_ROOT/shell" "$CHEAT_ROOT/python/regex"
    printf 'ONELINER_MARKER\n' > "$CHEAT_ROOT/shell/one-liners.md"
    printf 'regex syntax\n' > "$CHEAT_ROOT/python/regex/syntax.md"
    printf 'regex basics\n' > "$CHEAT_ROOT/python/regex/basics.py"
}

_cleanup_cheat() { rm -f "$CHEAT_SH"; }
trap '_cleanup_cheat' EXIT

# cheat_suite <shell> — same checks under bash and zsh.
cheat_suite() {
    local sh="$1"
    local run="run_${sh}"

    echo "================================================"
    echo "  Testing cheat.sh with ${sh}"
    echo "================================================"

    setup_store

    echo "[$sh] guard: non-interactive source skips cheat"
    actual=$("$sh" -c "source '$CHEAT_SH_GUARDED'; type cheat >/dev/null 2>&1 && echo DEFINED || echo UNDEFINED" | tr -d '\r')
    assert_eq "$sh/guard non-interactive" "UNDEFINED" "$actual"

    echo "[$sh] ls lists the relative cheatsheet paths"
    actual=$("$run" "$CHEAT_SH" "cheat ls" | tr -d '\r')
    assert_contains "$sh/ls shell" "shell/one-liners.md" "$actual"
    assert_contains "$sh/ls regex" "python/regex/syntax.md" "$actual"

    echo "[$sh] a unique name substring renders the sheet"
    actual=$("$run" "$CHEAT_SH" "cheat one-liners" | tr -d '\r')
    assert_contains "$sh/render content" "ONELINER_MARKER" "$actual"

    echo "[$sh] cheat bypasses find/grep/cat wrapper functions (uses command)"
    actual=$("$run" "$CHEAT_SH" "find() { echo WRAPPED; }; grep() { echo WRAPPED; }; cat() { echo WRAPPED; }; cheat one-liners 2>&1" | tr -d '\r')
    assert_contains "$sh/wrapper bypass renders" "ONELINER_MARKER" "$actual"
    assert_not_contains "$sh/wrapper not used" "WRAPPED" "$actual"

    echo "[$sh] a nested path substring renders the sheet"
    actual=$("$run" "$CHEAT_SH" "cheat regex/syntax" | tr -d '\r')
    assert_contains "$sh/render nested" "regex syntax" "$actual"

    echo "[$sh] a missing name fails with a message"
    actual=$("$run" "$CHEAT_SH" "cheat no-such-sheet-xyz 2>&1; echo rc=\$?" | tr -d '\r')
    assert_contains "$sh/missing msg" "no cheatsheet matching" "$actual"
    assert_contains "$sh/missing rc" "rc=1" "$actual"

    echo "[$sh] no cheatsheets installed fails with a hint"
    actual=$("$run" "$CHEAT_SH" "XDG_DATA_HOME='$EMPTY_XDG' cheat ls 2>&1; echo rc=\$?" | tr -d '\r')
    assert_contains "$sh/no-store msg" "no cheatsheets installed" "$actual"
    assert_contains "$sh/no-store rc" "rc=1" "$actual"

    if ! command -v fzf >/dev/null 2>&1; then
        echo "[$sh] an ambiguous name without fzf lists candidates"
        actual=$("$run" "$CHEAT_SH" "cheat regex 2>&1; echo rc=\$?" | tr -d '\r')
        assert_contains "$sh/ambiguous msg" "is ambiguous" "$actual"
        assert_contains "$sh/ambiguous rc" "rc=1" "$actual"

        echo "[$sh] no-arg cheat without fzf falls back gracefully"
        actual=$("$run" "$CHEAT_SH" "cheat 2>&1; echo rc=\$?" | tr -d '\r')
        assert_contains "$sh/no-fzf msg" "fzf not found" "$actual"
        assert_contains "$sh/no-fzf rc" "rc=1" "$actual"
    else
        echo "  SKIP: fzf present, cannot test the no-fzf fallbacks non-interactively"
    fi
}

cheat_suite bash
if command -v zsh >/dev/null 2>&1; then
    cheat_suite zsh
else
    echo "zsh not found; skipping zsh cheat tests"
fi

# pwsh port: same $XDG_DATA_HOME/den/cheatsheets store and same ls/render/missing/
# no-store/ambiguous logic as cheat.sh. cheat.ps1's diagnostics use Write-Error, so
# those cases capture the error stream with a bash-side 2>&1 (as test_snippet.sh does).
if command -v pwsh >/dev/null 2>&1; then
    echo "================================================"
    echo "  Testing cheat.ps1 with pwsh"
    echo "================================================"
    CHEAT_PS1="$DOTFILES/shell/pwsh/cheat.ps1"
    setup_store

    echo "[pwsh] ls lists the relative cheatsheet paths"
    actual=$(run_pwsh "$CHEAT_PS1" "cheat ls" | tr -d '\r')
    assert_contains "pwsh/ls shell" "shell/one-liners.md" "$actual"
    assert_contains "pwsh/ls regex" "python/regex/syntax.md" "$actual"

    echo "[pwsh] a unique name substring renders the sheet"
    actual=$(run_pwsh "$CHEAT_PS1" "cheat one-liners" | tr -d '\r')
    assert_contains "pwsh/render content" "ONELINER_MARKER" "$actual"

    echo "[pwsh] a nested path substring renders the sheet"
    actual=$(run_pwsh "$CHEAT_PS1" "cheat regex/syntax" | tr -d '\r')
    assert_contains "pwsh/render nested" "regex syntax" "$actual"

    echo "[pwsh] a missing name fails with a message"
    actual=$(run_pwsh "$CHEAT_PS1" "cheat no-such-sheet-xyz" 2>&1 | tr -d '\r')
    assert_contains "pwsh/missing msg" "no cheatsheet matching" "$actual"

    echo "[pwsh] no cheatsheets installed fails with a hint"
    actual=$(run_pwsh "$CHEAT_PS1" "\$env:XDG_DATA_HOME='$EMPTY_XDG'; cheat ls" 2>&1 | tr -d '\r')
    assert_contains "pwsh/no-store msg" "no cheatsheets installed" "$actual"

    if ! command -v fzf >/dev/null 2>&1; then
        echo "[pwsh] an ambiguous name without fzf lists candidates"
        actual=$(run_pwsh "$CHEAT_PS1" "cheat regex" 2>&1 | tr -d '\r')
        assert_contains "pwsh/ambiguous msg" "is ambiguous" "$actual"

        echo "[pwsh] no-arg cheat without fzf falls back gracefully"
        actual=$(run_pwsh "$CHEAT_PS1" "cheat" 2>&1 | tr -d '\r')
        assert_contains "pwsh/no-fzf msg" "fzf not found" "$actual"
    else
        echo "  SKIP: fzf present, cannot test the pwsh no-fzf fallbacks non-interactively"
    fi
else
    echo "pwsh not found; skipping pwsh cheat tests"
fi

# =============================================================================
# Summary
# =============================================================================
print_summary "test_cheat"
[ "$FAIL" -eq 0 ]
