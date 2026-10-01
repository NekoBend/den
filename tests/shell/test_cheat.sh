#!/usr/bin/env bash
# test_cheat.sh — Tests for cheat.sh (browse den's bundled cheatsheets).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

CHEAT_SH_GUARDED="$DOTFILES/shell/posix/cheat.sh"
CHEAT_SH="$TESTTMP/cheat_test.sh"
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

# Sheets whose names only look like den's <sheet>.den.bak[.N] backups, plus two
# real backups that must stay hidden; LOOKALIKES is what `cheat ls` lists of them.
LOOKALIKES='lookalike/UPPER.DEN.BAK
lookalike/notes.den.bak.1.md
lookalike/notes.den.bak.1draft.md
lookalike/notes.den.bak.md
lookalike/notes.den.bak.x'
setup_lookalikes() {
    mkdir -p "$CHEAT_ROOT/lookalike"
    for f in notes.den.bak.1draft.md notes.den.bak.1.md notes.den.bak.md \
        notes.den.bak.x UPPER.DEN.BAK notes.md.den.bak notes.md.den.bak.12; do
        printf 'LOOKALIKE\n' > "$CHEAT_ROOT/lookalike/$f"
    done
}

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

    # `den install cheatsheets --force` copies a sheet it replaces to
    # <sheet>.den.bak (or .den.bak.N); listed, they made `cheat <name>` ambiguous.
    echo "[$sh] den install's --force backups are not listed or matched"
    printf 'OLD ONELINER\n' > "$CHEAT_ROOT/shell/one-liners.md.den.bak"
    printf 'OLDER ONELINER\n' > "$CHEAT_ROOT/shell/one-liners.md.den.bak.1"
    actual=$("$run" "$CHEAT_SH" "cheat ls" | tr -d '\r')
    assert_not_contains "$sh/ls no backups" ".den.bak" "$actual"
    actual=$("$run" "$CHEAT_SH" "fzf() { return 1; }; cheat one-liners 2>&1" | tr -d '\r')
    assert_contains "$sh/backup not ambiguous" "ONELINER_MARKER" "$actual"
    rm -f "$CHEAT_ROOT/shell/one-liners.md.den.bak" "$CHEAT_ROOT/shell/one-liners.md.den.bak.1"

    # Only .den.bak and .den.bak.<digits> are backups: the find glob
    # '*.den.bak.[0-9]*' also hid sheets like these, which cheat.ps1 lists.
    echo "[$sh] a sheet merely named like a backup is listed"
    setup_lookalikes
    actual=$("$run" "$CHEAT_SH" "cheat ls" | tr -d '\r')
    assert_eq "$sh/lookalikes listed" "$LOOKALIKES" "$(printf '%s\n' "$actual" | command grep '^lookalike/')"
    rm -rf "$CHEAT_ROOT/lookalike"

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
# The no-double-prefix checks go through run_pwsh_stderr_oneline instead: PowerShell
# adds its own "cheat: " to every one of these, and only ConciseView's single-line
# form puts that prefix and the message on the same line, where a hand-written
# second one is visible as a substring (see the runner's comment in helpers.sh).
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

    echo "[pwsh] den install's --force backups are not listed or matched"
    printf 'OLD ONELINER\n' > "$CHEAT_ROOT/shell/one-liners.md.den.bak"
    printf 'OLDER ONELINER\n' > "$CHEAT_ROOT/shell/one-liners.md.den.bak.1"
    actual=$(run_pwsh "$CHEAT_PS1" "cheat ls" | tr -d '\r')
    assert_not_contains "pwsh/ls no backups" ".den.bak" "$actual"
    actual=$(run_pwsh "$CHEAT_PS1" "function fzf { }; cheat one-liners" 2>&1 | tr -d '\r')
    assert_contains "pwsh/backup not ambiguous" "ONELINER_MARKER" "$actual"
    rm -f "$CHEAT_ROOT/shell/one-liners.md.den.bak" "$CHEAT_ROOT/shell/one-liners.md.den.bak.1"

    echo "[pwsh] a sheet merely named like a backup is listed"
    setup_lookalikes
    actual=$(run_pwsh "$CHEAT_PS1" "cheat ls" | tr -d '\r')
    # Sort-Object orders by culture, not bytes: compare as a C-sorted set
    assert_eq "pwsh/lookalikes listed" "$LOOKALIKES" "$(printf '%s\n' "$actual" | command grep '^lookalike/' | LC_ALL=C sort)"
    rm -rf "$CHEAT_ROOT/lookalike"

    echo "[pwsh] a missing name fails with a message"
    actual=$(run_pwsh "$CHEAT_PS1" "cheat no-such-sheet-xyz" 2>&1 | tr -d '\r')
    assert_contains "pwsh/missing msg" "no cheatsheet matching" "$actual"
    assert_not_contains "pwsh/missing no double prefix" "cheat: cheat:" "$(run_pwsh_stderr_oneline "$CHEAT_PS1" "cheat no-such-sheet-xyz")"

    echo "[pwsh] no cheatsheets installed fails with a hint"
    actual=$(run_pwsh "$CHEAT_PS1" "\$env:XDG_DATA_HOME='$EMPTY_XDG'; cheat ls" 2>&1 | tr -d '\r')
    assert_contains "pwsh/no-store msg" "no cheatsheets installed" "$actual"
    assert_not_contains "pwsh/no-store no double prefix" "cheat: cheat:" "$(run_pwsh_stderr_oneline "$CHEAT_PS1" "\$env:XDG_DATA_HOME='$EMPTY_XDG'; cheat ls")"

    if ! command -v fzf >/dev/null 2>&1; then
        echo "[pwsh] an ambiguous name without fzf lists candidates"
        actual=$(run_pwsh "$CHEAT_PS1" "cheat regex" 2>&1 | tr -d '\r')
        assert_contains "pwsh/ambiguous msg" "is ambiguous" "$actual"
        assert_not_contains "pwsh/ambiguous no double prefix" "cheat: cheat:" "$(run_pwsh_stderr_oneline "$CHEAT_PS1" "cheat regex")"

        echo "[pwsh] no-arg cheat without fzf falls back gracefully"
        actual=$(run_pwsh "$CHEAT_PS1" "cheat" 2>&1 | tr -d '\r')
        assert_contains "pwsh/no-fzf msg" "fzf not found" "$actual"
        assert_not_contains "pwsh/no-fzf no double prefix" "cheat: cheat:" "$(run_pwsh_stderr_oneline "$CHEAT_PS1" "cheat")"
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
