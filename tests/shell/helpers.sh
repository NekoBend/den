#!/usr/bin/env bash
# helpers.sh — Shared test helpers for shell test suite.
# Sourced by each test_*.sh file.
set -uo pipefail

DOTFILES="/root/.dotfiles"
PASS=0
FAIL=0
ERRORS=()

# ===== Assertion helpers =====

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $label"
        ((PASS++)) || true
    else
        echo "  FAIL: $label (expected='$expected', actual='$actual')"
        ERRORS+=("$label")
        ((FAIL++)) || true
    fi
}

assert_exists() {
    local label="$1" fpath="$2"
    if [ -e "$fpath" ]; then
        echo "  PASS: $label"
        ((PASS++)) || true
    else
        echo "  FAIL: $label ('$fpath' does not exist)"
        ERRORS+=("$label")
        ((FAIL++)) || true
    fi
}

assert_not_exists() {
    local label="$1" fpath="$2"
    if [ ! -e "$fpath" ]; then
        echo "  PASS: $label"
        ((PASS++)) || true
    else
        echo "  FAIL: $label ('$fpath' still exists)"
        ERRORS+=("$label")
        ((FAIL++)) || true
    fi
}

assert_match() {
    local label="$1" pattern="$2" actual="$3"
    if printf '%s\n' "$actual" | grep -qE "$pattern"; then
        echo "  PASS: $label"
        ((PASS++)) || true
    else
        echo "  FAIL: $label (pattern='$pattern', actual='$actual')"
        ERRORS+=("$label")
        ((FAIL++)) || true
    fi
}

assert_contains() {
    local label="$1" substring="$2" actual="$3"
    if printf '%s\n' "$actual" | grep -qF -- "$substring"; then
        echo "  PASS: $label"
        ((PASS++)) || true
    else
        echo "  FAIL: $label (expected to contain '$substring', actual='$actual')"
        ERRORS+=("$label")
        ((FAIL++)) || true
    fi
}

assert_success() {
    local label="$1" exit_code="$2"
    if [ "$exit_code" -eq 0 ]; then
        echo "  PASS: $label"
        ((PASS++)) || true
    else
        echo "  FAIL: $label (exit_code=$exit_code)"
        ERRORS+=("$label")
        ((FAIL++)) || true
    fi
}

# ===== Shell runner wrappers =====

run_bash() {
    bash -c "source '$1' && $2"
}

run_zsh() {
    zsh -c "source '$1' && $2"
}

make_noninteractive_source_copy() {
    local src="$1" dest="$2"
    awk '
        $0 == "# Skip in non-interactive shells" {
            getline
            next
        }
        { print }
    ' "$src" > "$dest"
}

run_pwsh() {
    pwsh -NoProfile -NonInteractive -Command "
        . '$1'
        $2
    "
}

# ===== Stderr helpers =====

assert_not_contains() {
    local label="$1" substring="$2" actual="$3"
    if printf '%s\n' "$actual" | grep -qF -- "$substring"; then
        echo "  FAIL: $label (should NOT contain '$substring')"
        ERRORS+=("$label")
        ((FAIL++)) || true
    else
        echo "  PASS: $label"
        ((PASS++)) || true
    fi
}

# Run PowerShell command and capture stderr only (strips ANSI codes)
run_pwsh_stderr() {
    local script="$1" cmd="$2"
    pwsh -NoProfile -NonInteractive -Command "
        . '$script'
        $cmd
    " 2>&1 1>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r'
}

# Run bash command and capture stderr only
run_bash_stderr() {
    bash -c "source '$1' && $2" 2>&1 1>/dev/null | tr -d '\r'
}

# Run zsh command and capture stderr only
run_zsh_stderr() {
    zsh -c "source '$1' && $2" 2>&1 1>/dev/null | tr -d '\r'
}

# ===== Temp workspace =====

WORK="$(mktemp -d)"
trap '[ "${BASH_SUBSHELL:-0}" -eq 0 ] && rm -rf "$WORK"' EXIT

setup_fixtures() {
    rm -rf "$WORK"/*
    mkdir -p "$WORK/src/subdir" "$WORK/dest"
    echo "hello" > "$WORK/src/file1.txt"
    echo "world" > "$WORK/src/file2.txt"
    echo "nested" > "$WORK/src/subdir/file3.txt"
}

# ===== Summary helper =====

print_summary() {
    local test_name="${1:-tests}"
    echo ""
    echo "--- $test_name: $PASS passed, $FAIL failed ---"
    if [ "$FAIL" -gt 0 ]; then
        for err in "${ERRORS[@]}"; do
            echo "  - $err"
        done
    fi
}
