#!/usr/bin/env bash
# test_histguard.sh - Tests for den's bash, zsh, sh and dash (functions.sh) and
# pwsh's bash, zsh and sh (functions.ps1), which refuse to run a shell history
# file as a script.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

FUNCTIONS_SH_GUARDED="$DOTFILES/shell/posix/functions.sh"
FUNCTIONS_SH="$TESTTMP/functions_histguard.sh"
make_noninteractive_source_copy "$FUNCTIONS_SH_GUARDED" "$FUNCTIONS_SH"

# Each history file below holds lines that only append a word to MARK, so a
# file that ran leaves its word there. HG_HOME is HOME in every shell these
# tests start, and pwsh's is den-home (run_pwsh_den): never the real one,
# whose history must not run.
HG_HOME="$WORK/home"
MARK="$WORK/marker"
PS_HOME="$TESTTMP/den-home"

# write_hist <file> <word> - a history file in bash's format, a #<epoch> line
# before each command.
write_hist() {
    mkdir -p "$(dirname "$1")" && printf "#1762480000\necho %s >> '%s'\n" "$2" "$MARK" > "$1"
}

setup_hist() {
    rm -rf "${WORK:?}"/*
    mkdir -p "$HG_HOME" "$WORK/proj" "$WORK/custom" "$WORK/odd dir" "$WORK/stub" "$WORK/xdg"
    write_hist "$HG_HOME/.bash_history" bash_history
    # zsh's extended format: : is the null command, and the command after the
    # ; runs.
    printf ": 1762480000:0;echo zsh_history >> '%s'\n" "$MARK" > "$HG_HOME/.zsh_history"
    write_hist "$HG_HOME/.zhistory" zhistory
    write_hist "$HG_HOME/.histfile" histfile
    write_hist "$HG_HOME/.local/share/powershell/PSReadLine/ConsoleHost_history.txt" psreadline
    write_hist "$WORK/xdg/powershell/PSReadLine/ConsoleHost_history.txt" psreadline_xdg
    write_hist "$WORK/xdg/powershell/PSReadLine/Visual Studio Code Host_history.txt" psreadline_vscode
    write_hist "$WORK/custom/hist.log" histfile_var
    write_hist "$WORK/proj/.python_history" python_history
    write_hist "$WORK/odd dir/.it's_history" odd
    ln -s "$HG_HOME/.bash_history" "$WORK/notes.txt"
    ln "$HG_HOME/.bash_history" "$WORK/hard.txt"
    ln -s "$HG_HOME/.local/share/powershell/PSReadLine/ConsoleHost_history.txt" "$WORK/ps.txt"
    ln -s "$WORK/xdg/powershell/PSReadLine/ConsoleHost_history.txt" "$WORK/psxdg.txt"
    printf 'echo "ok $*"\n' > "$WORK/ok.sh"
    printf 'echo history.sh ran\n' > "$WORK/history.sh"
    printf 'echo rc file ran\n' > "$WORK/ok.rc"
    # A stand-in bash, first on PATH in the shadow cases.
    printf '#!/bin/sh\necho "stub bash $*"\n' > "$WORK/stub/bash"
    chmod +x "$WORK/stub/bash"
}

# hg_run <sh> <cmd> - <cmd> in <sh> -c with functions.sh loaded, in WORK, with
# HOME at HG_HOME and HISTFILE and XDG_DATA_HOME unset (<cmd> may set them);
# prints what it wrote to stdout and stderr, then rc=<its status>.
hg_run() {
    (cd "$WORK" && HOME="$HG_HOME" "$1" -c "unset HISTFILE XDG_DATA_HOME; . '$FUNCTIONS_SH' || exit 99
{ $2
}; echo \"rc=\$?\"" 2>&1 | tr -d '\r')
}

# refused <label> <sh> <cmd> <bypass> - <cmd> in <sh> ran no history file,
# said why, named <bypass> as the line that runs it anyway, and returned 2.
refused() {
    local out
    rm -f "$MARK"
    out=$(hg_run "$2" "$3")
    assert_contains "$1 says it is a history file" \
        "is a shell history file; running it would replay every command in it. Did you mean cat?" "$out"
    assert_contains "$1 names the line that runs it anyway" ": to run it anyway: $4" "$out"
    assert_contains "$1 returns 2" "rc=2" "$out"
    assert_not_exists "$1 ran nothing" "$MARK"
}

# allowed <label> <sh> <cmd> <expected> - <cmd> in <sh> printed <expected>
# (rc=<status> last) and ran no history file.
allowed() {
    local out
    rm -f "$MARK"
    out=$(hg_run "$2" "$3")
    assert_eq "$1" "$4" "$out"
    assert_not_exists "$1 ran no history file" "$MARK"
}

hist_suite() {
    local sh="$1"

    echo "================================================"
    echo "  Testing the history-file guard with ${sh}"
    echo "================================================"
    setup_hist

    echo "[$sh] guard: a non-interactive shell gets no wrapper"
    actual=$(HOME="$HG_HOME" "$sh" -c ". '$FUNCTIONS_SH_GUARDED'; type bash" 2>&1 | tr -d '\r')
    assert_not_contains "$sh/non-interactive: bash is no function" "function" "$actual"

    echo "[$sh] refuses the history files it knows by name"
    refused "$sh/\$HISTFILE" "$sh" "HISTFILE='$WORK/custom/hist.log'; bash \"\$HISTFILE\"" \
        "command bash $WORK/custom/hist.log"
    refused "$sh/bash ~/.bash_history" "$sh" "bash ~/.bash_history" "command bash $HG_HOME/.bash_history"
    refused "$sh/zsh ~/.zsh_history (extended format)" "$sh" "zsh ~/.zsh_history" "command zsh $HG_HOME/.zsh_history"
    refused "$sh/sh ~/.zhistory" "$sh" "sh ~/.zhistory" "command sh $HG_HOME/.zhistory"
    if command -v dash >/dev/null 2>&1; then
        refused "$sh/dash ~/.histfile" "$sh" "dash ~/.histfile" "command dash $HG_HOME/.histfile"
    else
        echo "  SKIP: $sh/dash ~/.histfile (dash not installed)"
    fi
    refused "$sh/PSReadLine's history under ~/.local/share" "$sh" "bash '$WORK/ps.txt'" "command bash $WORK/ps.txt"
    refused "$sh/PSReadLine's history under XDG_DATA_HOME" "$sh" \
        "XDG_DATA_HOME='$WORK/xdg'; bash '$WORK/psxdg.txt'" "command bash $WORK/psxdg.txt"
    refused "$sh/another PSReadLine host's history, quoted in the line" "$sh" \
        "bash '$WORK/xdg/powershell/PSReadLine/Visual Studio Code Host_history.txt'" \
        "command bash '$WORK/xdg/powershell/PSReadLine/Visual Studio Code Host_history.txt'"
    refused "$sh/a .python_history" "$sh" "sh '$WORK/proj/.python_history'" "command sh $WORK/proj/.python_history"

    echo "[$sh] refuses one through another name"
    refused "$sh/a symlink to it" "$sh" "bash '$WORK/notes.txt'" "command bash $WORK/notes.txt"
    refused "$sh/a hard link to it" "$sh" "bash '$WORK/hard.txt'" "command bash $WORK/hard.txt"
    refused "$sh/a relative path" "$sh" "cd ~ && bash .bash_history" "command bash .bash_history"

    echo "[$sh] refuses it as standard input when the shell reads its commands there"
    refused "$sh/bash < history" "$sh" "bash < ~/.bash_history" "command bash < $HG_HOME/.bash_history"
    refused "$sh/sh -s one < history" "$sh" "sh -s one < ~/.bash_history" "command sh -s one < $HG_HOME/.bash_history"
    refused "$sh/bash - < history" "$sh" "bash - < ~/.zsh_history" "command bash - < $HG_HOME/.zsh_history"

    echo "[$sh] finds the script past options and their values"
    refused "$sh/options before it" "$sh" "bash --norc -x -o pipefail -O extglob -- ~/.bash_history one" \
        "command bash --norc -x -o pipefail -O extglob -- $HG_HOME/.bash_history one"
    refused "$sh/--rcfile and its value before it" "$sh" "bash --rcfile '$WORK/ok.rc' ~/.bash_history" \
        "command bash --rcfile $WORK/ok.rc $HG_HOME/.bash_history"
    # bash reads its long options after one - too: -norc is not -n -o rc -c.
    refused "$sh/bash's long options after one -" "$sh" "bash -norc -login ~/.bash_history" \
        "command bash -norc -login $HG_HOME/.bash_history"
    refused "$sh/zsh's -o with its name in the same word" "$sh" "zsh -onoglob ~/.zsh_history" \
        "command zsh -onoglob $HG_HOME/.zsh_history"
    refused "$sh/zsh's --emulate and its value" "$sh" "zsh --emulate sh ~/.zsh_history" \
        "command zsh --emulate sh $HG_HOME/.zsh_history"

    echo "[$sh] the line it names runs the file as it is"
    rm -f "$MARK"
    out=$(hg_run "$sh" "bash '$WORK/odd dir/.it'\\''s_history'")
    assert_contains "$sh/a name with a blank and a quote is quoted" \
        "to run it anyway: command bash '$WORK/odd dir/.it'\\''s_history'" "$out"
    assert_not_exists "$sh/a name with a blank and a quote ran nothing" "$MARK"
    line=$(printf '%s\n' "$out" | sed -n 's/^bash: to run it anyway: //p')
    out=$(hg_run "$sh" "$line")
    assert_eq "$sh/the line it names runs the file" "rc=0" "$out"
    assert_eq "$sh/the line it names ran the file" "odd" "$(cat "$MARK" 2>/dev/null)"

    echo "[$sh] command bash runs the history file anyway"
    rm -f "$MARK"
    out=$(hg_run "$sh" "command bash ~/.bash_history")
    assert_eq "$sh/command bash runs it" "rc=0" "$out"
    assert_eq "$sh/command bash ran it" "bash_history" "$(cat "$MARK" 2>/dev/null)"

    echo "[$sh] runs everything else"
    allowed "$sh/a script" "$sh" "bash '$WORK/ok.sh' a b" "ok a b
rc=0"
    allowed "$sh/a script named history.sh" "$sh" "sh '$WORK/history.sh'" "history.sh ran
rc=0"
    allowed "$sh/bash -c" "$sh" "bash -c 'echo ok'" "ok
rc=0"
    allowed "$sh/bash -c that reads the history file" "$sh" "bash -c 'cat ~/.bash_history'" "#1762480000
echo bash_history >> '$MARK'
rc=0"
    allowed "$sh/the status passes through" "$sh" "zsh -c 'exit 3'" "rc=3"
    allowed "$sh/a script, its stdin the history file" "$sh" "bash '$WORK/ok.sh' x < ~/.bash_history" "ok x
rc=0"
    allowed "$sh/sh -c, its stdin the history file" "$sh" "sh -c 'wc -l' < ~/.bash_history" "2
rc=0"
    allowed "$sh/--rcfile's value is no script" "$sh" "bash --rcfile ~/.bash_history '$WORK/ok.sh' x" "ok x
rc=0"
    allowed "$sh/-o's value is no script" "$sh" "bash -o pipefail '$WORK/ok.sh' x" "ok x
rc=0"
    allowed "$sh/zsh's -oNAME takes no word" "$sh" "zsh -oerrexit '$WORK/ok.sh' x" "ok x
rc=0"
    allowed "$sh/zsh's --emulate takes one" "$sh" "zsh --emulate sh '$WORK/ok.sh' x" "ok x
rc=0"

    # The wrapper runs the program (command bash), not itself and not
    # another function: here the program is a stand-in first on PATH.
    echo "[$sh] shadow: the wrapper runs the bash on PATH"
    allowed "$sh/shadow: the program on PATH runs" "$sh" "PATH='$WORK/stub':\$PATH; bash '$WORK/ok.sh'" \
        "stub bash $WORK/ok.sh
rc=0"
    refused "$sh/shadow: refused, the program on PATH does not run" "$sh" \
        "PATH='$WORK/stub':\$PATH; bash ~/.bash_history" "command bash $HG_HOME/.bash_history"
}

hist_suite bash
hist_suite zsh

# =============================================================================
# pwsh
# =============================================================================
# Each line runs typed at the prompt (run_pwsh_den), in a try so that a refusal,
# a terminating error, does not end the lines after it.
if command -v pwsh >/dev/null 2>&1; then
    echo "================================================"
    echo "  Testing the history-file guard with pwsh"
    echo "================================================"
    setup_hist
    rm -rf "$PS_HOME"
    mkdir -p "$PS_HOME/.local/share"
    write_hist "$PS_HOME/.bash_history" ps_bash_history
    printf ": 1762480000:0;echo ps_zsh_history >> '%s'\n" "$MARK" > "$PS_HOME/.zsh_history"
    ln -s "$PS_HOME/.bash_history" "$WORK/psnotes.txt"
    BASH_BIN=$(command -v bash)
    SH_BIN=$(command -v sh)
    ZSH_BIN=$(command -v zsh)

    echo "[pwsh] refuses a history file as the script"
    actual=$(run_pwsh_den "Set-Location -LiteralPath '$WORK'" "
        try { bash ~/.bash_history; 'NOT-REFUSED' } catch { 'P1: ' + \$_.Exception.Message; 'P1 code: ' + \$LASTEXITCODE }
        try { zsh ~/.zsh_history; 'NOT-REFUSED' } catch { 'P2: ' + \$_.Exception.Message }
        try { sh '$WORK/proj/.python_history'; 'NOT-REFUSED' } catch { 'P3: ' + \$_.Exception.Message }
        try { bash --norc -x psnotes.txt; 'NOT-REFUSED' } catch { 'P4: ' + \$_.Exception.Message }
        try { sh -o noglob ~/.bash_history; 'NOT-REFUSED' } catch { 'P5: ' + \$_.Exception.Message }
        try { bash -norc ~/.bash_history; 'NOT-REFUSED' } catch { 'P6: ' + \$_.Exception.Message }
    " 2>&1 | tr -d '\r')
    assert_contains "pwsh/bash ~/.bash_history: says it is a history file" \
        "P1: ~/.bash_history is a shell history file; running it would replay every command in it. Did you mean cat?" "$actual"
    assert_contains "pwsh/bash ~/.bash_history: names the program's full path" \
        "To run it anyway: $BASH_BIN ~/.bash_history" "$actual"
    assert_contains "pwsh/bash ~/.bash_history: \$LASTEXITCODE is 2" "P1 code: 2" "$actual"
    assert_contains "pwsh/zsh ~/.zsh_history" "To run it anyway: $ZSH_BIN ~/.zsh_history" "$actual"
    assert_contains "pwsh/a .python_history" "To run it anyway: $SH_BIN $WORK/proj/.python_history" "$actual"
    assert_contains "pwsh/a symlink, past options" "To run it anyway: $BASH_BIN --norc -x psnotes.txt" "$actual"
    assert_contains "pwsh/past -o and its value" "To run it anyway: $SH_BIN -o noglob ~/.bash_history" "$actual"
    assert_contains "pwsh/past bash's long option after one -" "To run it anyway: $BASH_BIN -norc ~/.bash_history" "$actual"
    assert_not_contains "pwsh/refused calls do not go on" "NOT-REFUSED" "$actual"
    assert_not_exists "pwsh/refused calls ran nothing" "$MARK"

    echo "[pwsh] runs everything else"
    rm -f "$MARK"
    actual=$(run_pwsh_den "Set-Location -LiteralPath '$WORK'" "
        bash -c 'echo ok'
        bash '$WORK/ok.sh' a
        sh history.sh
        'echo piped' | bash
        bash -c 'cat ~/.bash_history'
        zsh -c 'exit 3'; 'code: ' + \$LASTEXITCODE
    " 2>&1 | tr -d '\r')
    assert_eq "pwsh/everything else runs" "ok
ok a
history.sh ran
piped
#1762480000
echo ps_bash_history >> '$MARK'
code: 3" "$actual"
    assert_not_exists "pwsh/everything else ran no history file" "$MARK"

    echo "[pwsh] the program's full path runs the history file anyway"
    rm -f "$MARK"
    actual=$(run_pwsh_den "" "$BASH_BIN ~/.bash_history; 'code: ' + \$LASTEXITCODE" 2>&1 | tr -d '\r')
    assert_eq "pwsh/the full path runs it" "code: 0" "$actual"
    assert_eq "pwsh/the full path ran it" "ps_bash_history" "$(cat "$MARK" 2>/dev/null)"
else
    echo "pwsh not found; skipping pwsh history-file guard tests"
fi

# =============================================================================
# Summary
# =============================================================================
print_summary "test_histguard"
[ "$FAIL" -eq 0 ]
