#!/usr/bin/env bash
# test_snippet.sh — Tests for snippet.sh (save / list / run named command snippets).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

SNIPPET_SH_GUARDED="$DOTFILES/shell/posix/snippet.sh"
SNIPPET_SH="/tmp/snippet_test_$$.sh"
make_noninteractive_source_copy "$SNIPPET_SH_GUARDED" "$SNIPPET_SH"

# Isolate the snippet store under WORK so tests never touch the real ~/.config.
export XDG_CONFIG_HOME="$WORK/xdg"
SNIPPET_FILE="$XDG_CONFIG_HOME/den/snippets"

_cleanup_snippet() { rm -f "$SNIPPET_SH"; }
trap '_cleanup_snippet' EXIT

reset_store() { rm -f "$SNIPPET_FILE"; }

# snippet_suite <shell> — same checks under bash and zsh.
snippet_suite() {
    local sh="$1"
    local run="run_${sh}"

    echo "================================================"
    echo "  Testing snippet.sh with ${sh}"
    echo "================================================"

    echo "[$sh] guard: non-interactive source skips snippet"
    actual=$("$sh" -c "source '$SNIPPET_SH_GUARDED'; type snippet >/dev/null 2>&1 && echo DEFINED || echo UNDEFINED" | tr -d '\r')
    assert_eq "$sh/guard non-interactive" "UNDEFINED" "$actual"

    echo "[$sh] alias snip is defined"
    actual=$("$run" "$SNIPPET_SH" "alias snip 2>/dev/null" | tr -d '\r')
    assert_contains "$sh/snip alias" "snippet" "$actual"

    reset_store
    echo "[$sh] save + ls"
    actual=$("$run" "$SNIPPET_SH" "snippet save greet 'echo hi there' >/dev/null 2>&1; snippet ls" | tr -d '\r')
    assert_contains "$sh/ls name" "greet" "$actual"
    assert_contains "$sh/ls command" "echo hi there" "$actual"

    reset_store
    echo "[$sh] show prints the command only"
    actual=$("$run" "$SNIPPET_SH" "snippet save greet 'echo hi there' >/dev/null 2>&1; snippet show greet" | tr -d '\r')
    assert_eq "$sh/show command" "echo hi there" "$actual"

    reset_store
    echo "[$sh] run evaluates the command"
    actual=$("$run" "$SNIPPET_SH" "snippet save g 'echo hello' >/dev/null 2>&1; snippet run g 2>/dev/null" | tr -d '\r')
    assert_eq "$sh/run output" "hello" "$actual"

    reset_store
    echo "[$sh] save from stdin"
    actual=$("$run" "$SNIPPET_SH" "printf 'echo piped\n' | snippet save p >/dev/null 2>&1; snippet show p" | tr -d '\r')
    assert_eq "$sh/stdin save" "echo piped" "$actual"

    reset_store
    echo "[$sh] save overwrites an existing name (no duplicate)"
    actual=$("$run" "$SNIPPET_SH" "snippet save g 'echo old' >/dev/null 2>&1; snippet save g 'echo new' >/dev/null 2>&1; snippet ls" | tr -d '\r')
    assert_contains "$sh/overwrite new" "echo new" "$actual"
    assert_not_contains "$sh/overwrite drops old" "echo old" "$actual"

    reset_store
    echo "[$sh] rm removes a snippet"
    actual=$("$run" "$SNIPPET_SH" "snippet save g 'echo hello' >/dev/null 2>&1; snippet rm g >/dev/null 2>&1; snippet ls 2>&1" | tr -d '\r')
    assert_not_contains "$sh/rm gone" "echo hello" "$actual"

    reset_store
    echo "[$sh] command may contain a pipe (run still works)"
    actual=$("$run" "$SNIPPET_SH" "snippet save pp 'printf \"a\nb\nc\n\" | grep b' >/dev/null 2>&1; snippet run pp 2>/dev/null" | tr -d '\r')
    assert_eq "$sh/pipe command" "b" "$actual"

    reset_store
    echo "[$sh] run a missing snippet fails"
    actual=$("$run" "$SNIPPET_SH" "snippet run nope 2>&1; echo rc=\$?" | tr -d '\r')
    assert_contains "$sh/run missing msg" "no such snippet" "$actual"
    assert_contains "$sh/run missing rc" "rc=1" "$actual"

    reset_store
    echo "[$sh] save rejects an invalid name"
    actual=$("$run" "$SNIPPET_SH" "snippet save 'bad name' 'echo x' 2>&1; echo rc=\$?" | tr -d '\r')
    assert_contains "$sh/save invalid name msg" "must match" "$actual"
    assert_contains "$sh/save invalid name rc" "rc=1" "$actual"

    echo "[$sh] unknown command fails with usage"
    actual=$("$run" "$SNIPPET_SH" "snippet frobnicate 2>&1; echo rc=\$?" | tr -d '\r')
    assert_contains "$sh/unknown cmd msg" "unknown command" "$actual"
    assert_contains "$sh/unknown cmd rc" "rc=1" "$actual"

    echo "[$sh] pick without fzf falls back gracefully"
    if ! command -v fzf >/dev/null 2>&1; then
        actual=$("$run" "$SNIPPET_SH" "snippet pick 2>&1; echo rc=\$?" | tr -d '\r')
        assert_contains "$sh/pick no fzf msg" "fzf not found" "$actual"
        assert_contains "$sh/pick no fzf rc" "rc=1" "$actual"
    else
        echo "  SKIP: fzf present, cannot test the no-fzf fallback non-interactively"
    fi
}

snippet_suite bash
if command -v zsh >/dev/null 2>&1; then
    snippet_suite zsh
else
    echo "zsh not found; skipping zsh snippet tests"
fi

# =============================================================================
# Summary
# =============================================================================
print_summary "test_snippet"
[ "$FAIL" -eq 0 ]
