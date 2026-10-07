#!/usr/bin/env bash
# helpers.sh — Shared test helpers for shell test suite.
# Sourced by each test_*.sh file.
set -uo pipefail

# Override to run the suite against a checkout: DOTFILES=/path/to/repo bash test_x.sh
DOTFILES="${DOTFILES:-/root/.dotfiles}"
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

# The assertions feed grep from a here-string, not from `printf | grep -q`:
# grep -q exits at the first match, printf then dies of SIGPIPE, and pipefail
# (above) turns that into a failed match. assert_contains and assert_match
# then FAILed, and assert_not_contains PASSed, on a long actual that matched
# early.
assert_match() {
    local label="$1" pattern="$2" actual="$3"
    if grep -qE -- "$pattern" <<<"$actual"; then
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
    if grep -qF -- "$substring" <<<"$actual"; then
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

assert_failure() {
    local label="$1" exit_code="$2"
    if [ "$exit_code" -ne 0 ]; then
        echo "  PASS: $label"
        ((PASS++)) || true
    else
        echo "  FAIL: $label (expected a nonzero exit code, got 0)"
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
    ' "$src" > "$dest" || abort_suite "cannot write $dest"
}

run_pwsh() {
    pwsh -NoProfile -NonInteractive -Command "
        . '$1'
        $2
    "
}

# run_pwsh_den <prelude> <cmd> - load den the way $PROFILE does (init.ps1, from
# DOTFILES) in an interactive session (_DEN_FORCE_INTERACTIVE=1), after the
# PowerShell code <prelude> (stock aliases to stand in for Windows', a PATH),
# then run <cmd>. pwsh counts <cmd> as typed at the prompt: a command at the top
# level of -Command has CommandOrigin Runspace. A script <cmd> runs with & runs
# as a user's script does. HOME and the XDG directories are TESTTMP/den-home,
# so den's caches stay out of the real ones; stdin is /dev/null. Expand the
# PowerShell variables in both arguments (\$) as for run_pwsh.
run_pwsh_den() {
    local home="$TESTTMP/den-home"
    mkdir -p "$home/.local/share" "$home/.cache" "$home/.config" || return 1
    HOME="$home" XDG_DATA_HOME="$home/.local/share" XDG_CACHE_HOME="$home/.cache" \
        XDG_CONFIG_HOME="$home/.config" _DEN_FORCE_INTERACTIVE=1 \
        pwsh -NoProfile -NonInteractive -Command "
            $1
            . '$DOTFILES/shell/pwsh/init.ps1'
            $2
        " < /dev/null
}

# ===== Streaming through pwsh functions =====

# STREAM_PRODUCER is PowerShell that outputs "one", waits 1.5 s, then outputs
# "two". make_stamp_stub <path> writes a stub program there: when its stdin is
# a pipe it prints "<nanoseconds since the epoch> <line>" for each line as it
# reads it, otherwise "stdin: not a pipe".
STREAM_PRODUCER="& { 'one'; Start-Sleep -Milliseconds 1500; 'two' }"
make_stamp_stub() {
    cat > "$1" <<'STUB' && chmod +x "$1"
#!/bin/sh
if [ -p /dev/stdin ]; then
    while IFS= read -r l; do echo "$(date +%s%N) $l"; done
else
    echo "stdin: not a pipe"
fi
STUB
}

# assert_streams <label> <output> - pass when the stamp stub read STREAM_PRODUCER's
# second line a second or more after its first, as it does when each line
# reaches it as it comes; a function that holds its input until the producer
# ends hands both over at once.
assert_streams() {
    local label="$1" first second gap
    first=$(printf '%s\n' "$2" | sed -n 's/^\([0-9]\{10,\}\) one$/\1/p')
    second=$(printf '%s\n' "$2" | sed -n 's/^\([0-9]\{10,\}\) two$/\1/p')
    if [ -z "$first" ] || [ -z "$second" ]; then
        assert_eq "$label" "two stamped lines" "$2"
        return
    fi
    gap=$(((second - first) / 1000000))
    if [ "$gap" -ge 1000 ]; then
        assert_eq "$label" "ok" "ok"
    else
        assert_eq "$label" "1000 ms or more between the lines" "$gap ms"
    fi
}

# make_tty_stub <path> writes a stub program that copies its stdin to stdout
# the way rg prints: each line as it reads it when stdout is a terminal, and
# everything at the end of its input when stdout is a pipe (block buffering).
make_tty_stub() {
    cat > "$1" <<'STUB' && chmod +x "$1"
#!/bin/sh
if [ -t 1 ]; then
    while IFS= read -r l; do echo "$l"; done
else
    all=$(cat)
    printf '%s\n' "$all"
fi
STUB
}

# run_pty_stamped <command...> - run the command in a terminal of its own
# (script(1), through /bin/sh: no newline in the arguments), its stdin
# /dev/null, and print each line it writes there as
# "<nanoseconds since the epoch> <line>", stamped when the line reaches the
# terminal, without the terminal's control sequences and carriage returns.
# With STREAM_PRODUCER's lines, assert_streams then tells whether each one
# reached the terminal as it came.
run_pty_stamped() {
    local script_bin cmd
    script_bin=$(command -v script) || {
        echo "script(1) is not installed"
        return 1
    }
    cmd=$(printf '%q ' "$@")
    SHELL=/bin/sh "$script_bin" -qfec "$cmd" /dev/null < /dev/null | while IFS= read -r l; do
        printf '%s %s\n' "$(date +%s%N)" "$l"
    done | sed -e 's/\x1b\][^\x07]*\x07//g' -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\x1b[=>]//g' -e 's/\r//g'
}

# make_pid_stub <path> writes a stub program that writes its process id to the
# file named by $PIDSTUB_FILE, then copies its stdin to stdout line by line until
# its stdin ends.
make_pid_stub() {
    cat > "$1" <<'STUB' && chmod +x "$1"
#!/bin/sh
echo $$ > "$PIDSTUB_FILE"
while IFS= read -r l; do echo "$l"; done
STUB
}

# make_stub_state_ps1 <path> writes PowerShell functions for the pid stub:
# Get-StubState <pid file> tells whether the stub that wrote it is still running
# half a second after a line ended ("running" or "gone");
# Test-StubStopped <setup> <line> runs the setup and the line in a runspace of
# its own, stops it (as a host does for Ctrl+C) once the stub has written
# $env:PIDSTUB_FILE, and tells the same; Test-CleanBlock <function> tells whether
# the function has a clean block.
make_stub_state_ps1() {
    cat > "$1" <<'PS1'
function Wait-Stub([string]$File) {
    for ($i = 0; $i -lt 150; $i++) {
        if (Test-Path -LiteralPath $File) {
            $t = Get-Content -LiteralPath $File -TotalCount 1
            if ($t) { return [int]$t }
        }
        Start-Sleep -Milliseconds 100
    }
    return 0
}
function Get-PidState([int]$StubPid) {
    if ($StubPid -eq 0) { return 'never started' }
    Start-Sleep -Milliseconds 500
    if (Get-Process -Id $StubPid -ErrorAction SilentlyContinue) { 'running' } else { 'gone' }
}
function Get-StubState([string]$File) { Get-PidState (Wait-Stub $File) }
function Test-StubStopped([string]$Setup, [string]$Line) {
    $ps = [powershell]::Create()
    $null = $ps.AddScript("$Setup`n$Line")
    $null = $ps.BeginInvoke()
    $p = Wait-Stub $env:PIDSTUB_FILE
    $ps.Stop()
    Get-PidState $p
}
function Test-CleanBlock([string]$Name) {
    $ast = (Get-Item -LiteralPath "Function:\$Name").ScriptBlock.Ast
    if ($ast -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $ast = $ast.Body }
    $null -ne $ast.CleanBlock
}
PS1
}

# ===== Stderr helpers =====

assert_not_contains() {
    local label="$1" substring="$2" actual="$3"
    if grep -qF -- "$substring" <<<"$actual"; then
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

# Same, but with the command on ONE line. PowerShell's ConciseView only
# renders the compact "<function>: <message>" form when the failing command
# occupies a single line; the multi-line -Command that run_pwsh_stderr builds
# gets the "Line | ..." block instead, and there the prefix PowerShell adds and
# the message itself land on SEPARATE lines -- so a hand-written prefix that
# doubles it is not visible as one substring. Use this runner for the
# no-double-prefix assertions; use run_pwsh_stderr for message content.
run_pwsh_stderr_oneline() {
    local script="$1" cmd="$2"
    pwsh -NoProfile -NonInteractive -Command ". '$script'; $cmd" 2>&1 1>/dev/null |
        sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r'
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

# abort_suite <message>: stop the whole suite, for a setup step (the temp
# workspace, a generated script) that no test can run without. Call it at the
# top level of a suite: inside $( ) it would only end that subshell.
abort_suite() {
    echo "helpers.sh: $*; stopping the suite" >&2
    exit 1
}

# WORK holds the fixtures, and the resets below wipe it. TESTTMP holds the
# scripts a suite generates and keeps for its tests (non-interactive copies of
# shell/ files, combined .ps1 files, scans), out of reach of those wipes
# (test_harness.sh checks that no suite keeps one in WORK). Both sit in one
# directory from mktemp, which another user can neither predict nor create
# first, as they could a fixed /tmp/<name>_$$ path (the suite would then
# source what they put there). The one EXIT trap below removes it, so a suite
# must not set an EXIT trap of its own: that would replace this one.
#
# The suites run without `set -e`, and each fixture reset is `rm -rf` under
# WORK: were mktemp to fail (TMPDIR missing, /tmp full or read-only) and leave
# WORK empty, `rm -rf "$WORK"/*` would be `rm -rf /*`. So a failed mktemp stops
# the suite here, before any test runs, and the resets spell "${WORK:?}".
TEST_ROOT="$(mktemp -d)" && [ -d "$TEST_ROOT" ] || abort_suite "mktemp -d failed"
trap '[ "${BASH_SUBSHELL:-0}" -eq 0 ] && rm -rf "${TEST_ROOT:?}"' EXIT
WORK="$TEST_ROOT/work"
TESTTMP="$TEST_ROOT/gen"
mkdir "$WORK" "$TESTTMP" || abort_suite "cannot create $WORK and $TESTTMP"

setup_fixtures() {
    rm -rf "${WORK:?}"/*
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
