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

    # zsh names an option in a word of its own, off with +-: no value follows,
    # also when the name ends in o (bsd_echo), which -o's letter loop read as
    # an -o taking the next word, the script.
    refused "$sh/zsh's +-name, ending in o" "$sh" "zsh +-bsd-echo ~/.zsh_history" \
        "command zsh +-bsd-echo $HG_HOME/.zsh_history"
    # zsh ends its options after a word of them with b in it: the word after
    # it is the script, even one that starts with -.
    rm -f "$WORK/-n"
    ln -s "$HG_HOME/.zsh_history" "$WORK/-n"
    refused "$sh/zsh -b, then a script named like an option" "$sh" "zsh -b -n" "command zsh -b -n"
    rm -f "$WORK/-n"

    echo "[$sh] runs a syntax check: no-exec reads the commands and runs none"
    allowed "$sh/bash -n" "$sh" "bash -n ~/.bash_history" "rc=0"
    allowed "$sh/bash -xn, -n in a word of options" "$sh" "bash -O extglob -xn ~/.bash_history" "rc=0"
    allowed "$sh/sh -o noexec" "$sh" "sh -o noexec ~/.zhistory" "rc=0"
    allowed "$sh/bash -n, standard input" "$sh" "bash -n < ~/.bash_history" "rc=0"
    allowed "$sh/sh -s -n, standard input" "$sh" "sh -s -n one < ~/.bash_history" "rc=0"
    allowed "$sh/zsh -n" "$sh" "zsh -n ~/.zsh_history" "rc=0"
    allowed "$sh/zsh -o NO_EXEC, any case and _" "$sh" "zsh -o NO_EXEC ~/.zsh_history" "rc=0"
    allowed "$sh/zsh +o exec" "$sh" "zsh +o exec ~/.zsh_history" "rc=0"
    allowed "$sh/zsh -onoexec, the name in the same word" "$sh" "zsh -onoexec ~/.zsh_history" "rc=0"
    allowed "$sh/zsh --no-exec" "$sh" "zsh --no-exec ~/.zsh_history" "rc=0"
    allowed "$sh/zsh +-exec" "$sh" "zsh +-exec ~/.zsh_history" "rc=0"
    if command -v dash >/dev/null 2>&1; then
        allowed "$sh/dash -n" "$sh" "dash -n ~/.histfile" "rc=0"
    fi

    echo "[$sh] refuses it when no-exec is turned off again before the script"
    refused "$sh/bash -n +n" "$sh" "bash -n +n ~/.bash_history" "command bash -n +n $HG_HOME/.bash_history"
    refused "$sh/bash -n +o noexec" "$sh" "bash -n +o noexec ~/.bash_history" \
        "command bash -n +o noexec $HG_HOME/.bash_history"
    # Only zsh reads an option's name in any case.
    refused "$sh/bash -o NOEXEC, no noexec to bash" "$sh" "bash -o NOEXEC ~/.bash_history" \
        "command bash -o NOEXEC $HG_HOME/.bash_history"
    refused "$sh/sh -s -n +n, standard input" "$sh" "sh -s -n +n < ~/.bash_history" \
        "command sh -s -n +n < $HG_HOME/.bash_history"
    refused "$sh/zsh -n -o exec" "$sh" "zsh -n -o exec ~/.zsh_history" "command zsh -n -o exec $HG_HOME/.zsh_history"
    refused "$sh/zsh -no exec, -o's value the next word" "$sh" "zsh -no exec ~/.zsh_history" \
        "command zsh -no exec $HG_HOME/.zsh_history"
    refused "$sh/zsh -n +onoexec" "$sh" "zsh -n +onoexec ~/.zsh_history" "command zsh -n +onoexec $HG_HOME/.zsh_history"
    refused "$sh/zsh -n --EXEC" "$sh" "zsh -n --EXEC ~/.zsh_history" "command zsh -n --EXEC $HG_HOME/.zsh_history"
    refused "$sh/zsh -n +-no_exec" "$sh" "zsh -n +-no_exec ~/.zsh_history" "command zsh -n +-no_exec $HG_HOME/.zsh_history"

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
    # Only a regular file on stdin is checked: with history off
    # (HISTFILE=/dev/null), /dev/null on stdin is no history file.
    allowed "$sh/HISTFILE=/dev/null, /dev/null on stdin" "$sh" "HISTFILE=/dev/null; bash < /dev/null" "rc=0"
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

# alias_suite <sh> - functions.sh loads in an interactive <sh> (aliases on)
# where the user's alias of each wrapped name was defined first, and the
# alias stays. Each alias calls its name again, so the call goes on to den's
# function; one that names `command` goes around it. A name() definition was a
# syntax error under such an alias (bash: status 2, zsh: 126), and nothing
# after it in functions.sh loaded.
alias_suite() {
    local sh="$1" name out
    local -a run
    case $sh in
        bash) run=(bash --noprofile --norc -i -c) ;;
        zsh) run=(zsh -f -i -c) ;;
    esac
    echo "[$sh] an alias of each wrapped name, defined before functions.sh"
    setup_hist
    for name in bash zsh sh dash; do
        rm -f "$MARK"
        # eval: zsh reads all of -c's string before it runs any, so a call
        # written there would not see the alias.
        out=$(cd "$WORK" && HOME="$HG_HOME" "${run[@]}" "alias $name='$name -x'
. '$FUNCTIONS_SH_GUARDED'; echo \"load=\$?\"
typeset -f fwd zdi >/dev/null && echo later=loaded
typeset -f $name >/dev/null && echo guard=defined
alias $name >/dev/null && echo alias=kept
eval '$name ~/.bash_history'; echo \"rc=\$?\"" 2>&1 </dev/null | tr -d '\r')
        assert_contains "$sh/alias $name: functions.sh loads" "load=0" "$out"
        assert_contains "$sh/alias $name: what comes after the guard loads" "later=loaded" "$out"
        assert_contains "$sh/alias $name: the guard is defined" "guard=defined" "$out"
        assert_contains "$sh/alias $name: the alias stays" "alias=kept" "$out"
        assert_contains "$sh/alias $name: through the alias, refused" \
            "$name: to run it anyway: command $name -x $HG_HOME/.bash_history" "$out"
        assert_contains "$sh/alias $name: through the alias, status 2" "rc=2" "$out"
        assert_not_exists "$sh/alias $name: through the alias, nothing ran" "$MARK"
    done
    rm -f "$MARK"
    out=$(cd "$WORK" && HOME="$HG_HOME" "${run[@]}" "alias bash='command bash'
. '$FUNCTIONS_SH_GUARDED'; echo \"load=\$?\"
eval 'bash ~/.bash_history'; echo \"rc=\$?\"" 2>&1 </dev/null | tr -d '\r')
    assert_contains "$sh/alias bash='command bash': functions.sh loads" "load=0" "$out"
    assert_contains "$sh/alias bash='command bash': goes around the guard" "rc=0" "$out"
    assert_eq "$sh/alias bash='command bash': the file ran" "bash_history" "$(cat "$MARK" 2>/dev/null)"
}

hist_suite bash
hist_suite zsh
alias_suite bash
alias_suite zsh

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

    echo "[pwsh] runs a syntax check, and refuses it when no-exec is turned off again"
    rm -f "$MARK"
    actual=$(run_pwsh_den "Set-Location -LiteralPath '$WORK'" "
        bash -n ~/.bash_history; 'N1 code: ' + \$LASTEXITCODE
        zsh +o exec ~/.zsh_history; 'N2 code: ' + \$LASTEXITCODE
        sh -o noexec ~/.bash_history; 'N3 code: ' + \$LASTEXITCODE
        try { bash -n +n ~/.bash_history; 'NOT-REFUSED' } catch { 'N4: ' + \$_.Exception.Message }
        try { zsh -n -o exec ~/.zsh_history; 'NOT-REFUSED' } catch { 'N5: ' + \$_.Exception.Message }
        try { zsh +-bsd-echo ~/.zsh_history; 'NOT-REFUSED' } catch { 'N6: ' + \$_.Exception.Message }
    " 2>&1 | tr -d '\r')
    assert_contains "pwsh/bash -n runs" "N1 code: 0" "$actual"
    assert_contains "pwsh/zsh +o exec runs" "N2 code: 0" "$actual"
    assert_contains "pwsh/sh -o noexec runs" "N3 code: 0" "$actual"
    assert_contains "pwsh/bash -n +n refused" "To run it anyway: $BASH_BIN -n +n ~/.bash_history" "$actual"
    assert_contains "pwsh/zsh -n -o exec refused" "To run it anyway: $ZSH_BIN -n -o exec ~/.zsh_history" "$actual"
    assert_contains "pwsh/zsh +-bsd-echo refused" "To run it anyway: $ZSH_BIN +-bsd-echo ~/.zsh_history" "$actual"
    assert_not_contains "pwsh/no-exec turned off again: refused" "NOT-REFUSED" "$actual"
    assert_not_exists "pwsh/syntax checks ran nothing" "$MARK"

    # A wildcard stands for several names: the first is the script, and the
    # others are its arguments, a history file among them too.
    echo "[pwsh] of a wildcard, only the first name is the script"
    mkdir -p "$WORK/glob" "$WORK/glob2"
    printf 'echo "run-1 $*"\n' > "$WORK/glob/run-1.sh"
    write_hist "$WORK/glob/run-2.log" glob_later
    write_hist "$WORK/glob2/a.log" glob_first
    printf 'echo "b $*"\n' > "$WORK/glob2/b.sh"
    rm -f "$MARK"
    actual=$(run_pwsh_den "Set-Location -LiteralPath '$WORK'" "
        \$env:HISTFILE = '$WORK/glob/run-2.log'
        bash glob/run-*; 'G1 code: ' + \$LASTEXITCODE
        \$env:HISTFILE = '$WORK/glob2/a.log'
        try { bash glob2/*; 'NOT-REFUSED' } catch { 'G2: ' + \$_.Exception.Message }
    " 2>&1 | tr -d '\r')
    assert_contains "pwsh/a history file after the first name is an argument" "run-1 glob/run-2.log
G1 code: 0" "$actual"
    assert_contains "pwsh/the first name a history file: refused, named" \
        "G2: glob2/a.log is a shell history file; running it would replay every command in it." "$actual"
    assert_contains "pwsh/the first name a history file: the line as typed" "To run it anyway: $BASH_BIN glob2/*" "$actual"
    assert_not_contains "pwsh/the first name a history file: not run" "NOT-REFUSED" "$actual"
    assert_not_exists "pwsh/wildcards ran no history file" "$MARK"

    # A program's exit status reaches the line it is called in, as when it is
    # typed by its path: $? false after a non-zero exit, so && and || go by it.
    echo "[pwsh] a non-zero exit leaves \$? false, and \$LASTEXITCODE its code"
    actual=$(run_pwsh_den "" "
        bash -c 'exit 3'; 'S1: ' + \$? + ' ' + \$LASTEXITCODE
        bash -c 'exit 3' && 'S2: && went on'
        bash -c 'exit 3' || 'S3: || went on'
        'x' | bash -c 'cat >/dev/null; exit 4'; 'S4: ' + \$? + ' ' + \$LASTEXITCODE
        'x' | sh -c 'cat >/dev/null; exit 5' || 'S5: piped || went on'
        zsh -c 'exit 0'; 'S6: ' + \$? + ' ' + \$LASTEXITCODE
        bash -c 'exit 0' && 'S7: && went on'
        'x' | bash -c 'cat >/dev/null' && 'S8: piped && went on'
    " 2>&1 | tr -d '\r')
    assert_eq "pwsh/\$? and \$LASTEXITCODE after the call" "S1: False 3
S3: || went on
S4: False 4
S5: piped || went on
S6: True 0
S7: && went on
S8: piped && went on" "$actual"

    # Set-StrictMode makes reading a variable that was never set an error, and
    # \$LASTEXITCODE does not exist before the first program a session runs.
    echo "[pwsh] under Set-StrictMode, before any program has run"
    rm -f "$MARK"
    actual=$(run_pwsh_den "" "
        Set-StrictMode -Version Latest
        Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        \$null = _DenHistFile '$WORK/ok.sh'
        'T1 exists: ' + (Test-Path -LiteralPath Variable:global:LASTEXITCODE)
        bash '$WORK/ok.sh' a; 'T2: ' + \$? + ' ' + \$LASTEXITCODE
        try { bash ~/.bash_history; 'NOT-REFUSED' } catch { 'T3 code: ' + \$LASTEXITCODE }
    " 2>&1 | tr -d '\r')
    assert_eq "pwsh/strict mode: no error, and \$LASTEXITCODE put back as it was" "T1 exists: False
ok a
T2: True 0
T3 code: 2" "$actual"
    assert_not_exists "pwsh/strict mode: ran no history file" "$MARK"
else
    echo "pwsh not found; skipping pwsh history-file guard tests"
fi

# =============================================================================
# Summary
# =============================================================================
print_summary "test_histguard"
[ "$FAIL" -eq 0 ]
