#!/usr/bin/env bash
# test_snippet.sh — Tests for snippet.sh (save / list / run named command snippets).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

SNIPPET_SH_GUARDED="$DOTFILES/shell/posix/snippet.sh"
SNIPPET_SH="$TESTTMP/snippet_test.sh"
# snippet.sh puts its store in place with _den_put from _helpers.sh, which
# init.bash and init.zsh load first; the file the tests source loads both.
make_noninteractive_source_copy "$SNIPPET_SH_GUARDED" "$TESTTMP/snippet_only.sh"
printf ". '%s'\n. '%s'\n" "$DOTFILES/shell/posix/_helpers.sh" "$TESTTMP/snippet_only.sh" > "$SNIPPET_SH" ||
    abort_suite "cannot write $SNIPPET_SH"

# Isolate the snippet store under WORK so tests never touch the real ~/.config.
export XDG_CONFIG_HOME="$WORK/xdg"
SNIPPET_FILE="$XDG_CONFIG_HOME/den/snippets"

SNIPPET_DIR="$XDG_CONFIG_HOME/den"
DOTS="$WORK/dots"

reset_store() { rm -f "$SNIPPET_FILE"; }

# modes - the octal modes of the store's directory and of the store.
modes() { stat -c '%a' "$SNIPPET_DIR" "$SNIPPET_FILE" | paste -sd' ' -; }

# link_store <target> - make the store a symlink to <target> under $DOTS, as a
# dotfiles repo would.
link_store() {
    rm -rf "${DOTS:?}"
    mkdir -p "$DOTS" "$SNIPPET_DIR"
    rm -f "$SNIPPET_FILE"
    ln -s "$DOTS/$1" "$SNIPPET_FILE"
}

TAB=$(printf '\t')

# _den_put copies a store through a symlink with `command cat`, the program
# on PATH. FAILCAT is a directory whose cat writes 5 bytes and fails, as on a
# full disk; put it first on PATH to make that copy fail part way.
FAILCAT="$TESTTMP/failcat"
mkdir -p "$FAILCAT" && printf '#!/bin/sh\nhead -c 5 "$1"\nexit 1\n' > "$FAILCAT/cat" &&
    chmod 755 "$FAILCAT/cat" || abort_suite "cannot write $FAILCAT/cat"

# A write into the temporary store that fails, as on a full disk or past a
# quota. ulimit -f caps the size of the files the shell writes (in 1024-byte
# blocks in bash, 512-byte ones in zsh), and with SIGXFSZ ignored a write past
# the cap fails (EFBIG) instead of ending the shell. A cap of 0 fails every
# write; under a cap of 1, a record holding PAD (under 512 bytes) fits and one
# holding LONG (over 600 bytes) after it is cut short, in either shell.
PAD=$(printf '%0480d' 0)
LONG=$(printf '%0600d' 0)
NL='
'
STORE_BEFORE="$WORK/store.before"

# store_sum <file> - its size and its names (field 1), and ", changed" when its
# bytes differ from STORE_BEFORE's.
store_sum() {
    printf '%s bytes, names: %s' "$(wc -c < "$1")" "$(cut -f1 "$1" | paste -sd' ' -)"
    cmp -s "$1" "$STORE_BEFORE" || printf ', changed'
}

# capped_case <shell> <label> <cap> <store text> <command> - put the store text
# in place, run the snippet command under the cap in a subshell, and check that
# it failed with "cannot write ...; it is left as it was", left the store as it
# was, and took its temporary file with it. The shell's own "write error" line
# is left out of what it printed.
capped_case() {
    local sh=$1 label=$2 cap=$3 store=$4 cmd=$5 who actual
    # The message starts with the command's first two words: snippet save.
    who=$(printf '%s\n' "$cmd" | cut -d' ' -f1,2)
    mkdir -p "$SNIPPET_DIR"
    printf '%s' "$store" > "$SNIPPET_FILE" && cp "$SNIPPET_FILE" "$STORE_BEFORE" ||
        abort_suite "cannot write $SNIPPET_FILE"
    actual=$("run_$sh" "$SNIPPET_SH" "(trap '' XFSZ; ulimit -f $cap; $cmd) 2>&1; echo rc=\$?" |
        grep -v 'write error' | tr -d '\r')
    assert_eq "$sh/$label: message and status" "$who: cannot write $SNIPPET_FILE; it is left as it was
rc=1" "$actual"
    assert_eq "$sh/$label: store kept" "$(store_sum "$STORE_BEFORE")" "$(store_sum "$SNIPPET_FILE")"
    assert_eq "$sh/$label: no temporary file left" "" "$(cd "$SNIPPET_DIR" && ls -A | grep -v '^snippets$')"
}

# The several-words form of save: the shell takes the quotes off each word
# before snippet sees it, and run evals the saved line, so the words that need
# quotes must get them back. sq_fixture makes a directory holding "My File.txt"
# next to "My" and "File.txt", and a FASTA file with two headers.
SQ="$WORK/sq"
sq_fixture() {
    rm -rf "${SQ:?}"
    mkdir -p "$SQ"
    touch "$SQ/My File.txt" "$SQ/My" "$SQ/File.txt"
    printf '>a\nAC\n>b\nGT\n' > "$SQ/seqs.fa"
}
SQ_WORDS="$TESTTMP/sq_words.sh"
cat > "$SQ_WORDS" <<'SH'
snippet save q printf '[%s]\n' "it's; here" '$HOME $(id)' '' '*' '=ls' 'a\b' 2>/dev/null
snippet show q
snippet run q 2>/dev/null
snippet save s git status -sb x@y k=v ./p:q 2>/dev/null
snippet show s
SH
# zsh's globsubst gives an unquoted expansion's ~ and = their meaning again,
# so a quoted ~ or = word must stay quoted on the way into the store.
SQ_GLOBSUBST="$TESTTMP/sq_globsubst.zsh"
cat > "$SQ_GLOBSUBST" <<'SH'
setopt globsubst
snippet save w printf '<%s>\n' '~/x' '~' '=foo' "x'~/y" 2>/dev/null
snippet show w
snippet run w 2>/dev/null
snippet save o '~/bin/t =x' 2>/dev/null
snippet show o
SH

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
    echo "[$sh] save from stdin keeps the first line only"
    actual=$("$run" "$SNIPPET_SH" "printf 'echo first\necho second\n' | snippet save f 2>&1; snippet show f" | tr -d '\r')
    assert_eq "$sh/stdin save first line" "snippet: saved 'f'
echo first" "$actual"

    reset_store
    echo "[$sh] save from stdin without a trailing newline"
    actual=$("$run" "$SNIPPET_SH" "printf 'echo nonl' | snippet save b >/dev/null 2>&1; snippet show b" | tr -d '\r')
    assert_eq "$sh/stdin save no-newline" "echo nonl" "$actual"

    reset_store
    echo "[$sh] save from newline-less stdin does not abort under set -e"
    actual=$("$sh" -c "set -e; source '$SNIPPET_SH'; printf 'echo errx' | snippet save e >/dev/null 2>&1; snippet show e" | tr -d '\r')
    assert_eq "$sh/errexit stdin save" "echo errx" "$actual"

    reset_store
    echo "[$sh] save rejects a multi-line command"
    actual=$("$run" "$SNIPPET_SH" "snippet save m \"\$(printf 'echo a\\necho b')\" 2>&1; echo rc=\$?; snippet ls 2>&1" | tr -d '\r')
    assert_contains "$sh/multiline msg" "single line" "$actual"
    assert_contains "$sh/multiline rc" "rc=1" "$actual"
    assert_not_contains "$sh/multiline not saved" "echo a" "$actual"

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

    reset_store
    echo "[$sh] save prints the line it saved for several words only, not for one argument or stdin"
    actual=$("$run" "$SNIPPET_SH" "snippet save o 'echo tok' 2>&1; printf 'echo tok\n' | snippet save i 2>&1" | tr -d '\r')
    assert_eq "$sh/save message: one argument and stdin" "snippet: saved 'o'
snippet: saved 'i'" "$actual"

    reset_store
    sq_fixture
    echo "[$sh] save <word...> quotes a word with a blank again, so run removes that file only"
    actual=$(cd "$SQ" && "$run" "$SNIPPET_SH" "snippet save clean rm 'My File.txt' 2>&1; snippet run clean 2>/dev/null; ls" | tr -d '\r')
    assert_eq "$sh/save words: spaced path" "snippet: saved 'clean' -> rm 'My File.txt'
File.txt
My
seqs.fa" "$actual"

    echo "[$sh] save <word...> keeps a quoted > an argument, so run does not truncate the input"
    actual=$(cd "$SQ" && "$run" "$SNIPPET_SH" "snippet save nseq grep -c '>' seqs.fa 2>/dev/null; snippet run nseq 2>/dev/null; wc -c < seqs.fa" | tr -d '\r ')
    assert_eq "$sh/save words: quoted >" "2
12" "$actual"

    reset_store
    echo "[$sh] save <word...> quotes ; ' \$ glob = \\ and an empty word, and leaves plain words bare"
    actual=$(cd "$SQ" && "$run" "$SNIPPET_SH" ". '$SQ_WORDS'" | tr -d '\r')
    assert_eq "$sh/save words: special characters" "printf '[%s]\n' 'it'\\''s; here' '\$HOME \$(id)' '' '*' '=ls' 'a\\b'
[it's; here]
[\$HOME \$(id)]
[]
[*]
[=ls]
[a\\b]
git status -sb x@y k=v ./p:q" "$actual"

    if [ "$sh" = zsh ]; then
        echo "[zsh] save keeps a quoted ~ or = word, and a one-argument command, as given under globsubst"
        actual=$(cd "$SQ" && run_zsh "$SNIPPET_SH" ". '$SQ_GLOBSUBST'" | tr -d '\r')
        assert_eq "zsh/save under globsubst" "printf '<%s>\\n' '~/x' '~' '=foo' 'x'\\''~/y'
<~/x>
<~>
<=foo>
<x'~/y>
~/bin/t =x" "$actual"
    fi

    echo "[$sh] save makes the store 0600 in a 0700 directory, under umask 022"
    rm -rf "${SNIPPET_DIR:?}"
    "$run" "$SNIPPET_SH" "umask 022; snippet save t 'echo tok' 2>/dev/null"
    assert_eq "$sh/new store modes" "700 600" "$(modes)"

    echo "[$sh] rm and save tighten an older den's 0644 store and 0755 directory"
    printf 'a\techo a\nb\techo b\n' > "$SNIPPET_FILE"
    chmod 755 "$SNIPPET_DIR"
    chmod 644 "$SNIPPET_FILE"
    "$run" "$SNIPPET_SH" "umask 022; snippet rm b 2>/dev/null"
    assert_eq "$sh/rm tightens both" "700 600" "$(modes)"
    chmod 755 "$SNIPPET_DIR"
    chmod 644 "$SNIPPET_FILE"
    "$run" "$SNIPPET_SH" "umask 022; snippet save c 'echo c' 2>/dev/null"
    assert_eq "$sh/save tightens both" "700 600" "$(modes)"

    echo "[$sh] save and rm write through a symlinked store"
    link_store snippets
    printf 'a\techo a\n' > "$DOTS/snippets"
    chmod 644 "$DOTS/snippets"
    "$run" "$SNIPPET_SH" "umask 022; snippet save b 'echo b' 2>/dev/null; snippet save c 'echo c' 2>/dev/null; snippet rm a 2>/dev/null"
    assert_eq "$sh/symlink kept" "link" "$([ -L "$SNIPPET_FILE" ] && echo link || echo replaced)"
    assert_eq "$sh/symlink target updated" "b${TAB}echo b
c${TAB}echo c" "$(cat "$DOTS/snippets")"
    assert_eq "$sh/symlink target 0600" "600" "$(stat -c '%a' "$DOTS/snippets")"
    assert_eq "$sh/no temporary file left" "" "$(cd "$SNIPPET_DIR" && ls -A | grep -v '^snippets$')"

    echo "[$sh] save through a symlink whose target does not exist yet creates it"
    link_store new-snippets
    "$run" "$SNIPPET_SH" "umask 022; snippet save n 'echo n' 2>/dev/null"
    assert_eq "$sh/dangling symlink kept" "link" "$([ -L "$SNIPPET_FILE" ] && echo link || echo replaced)"
    assert_eq "$sh/dangling symlink target created" "n${TAB}echo n 600" \
        "$(cat "$DOTS/new-snippets") $(stat -c '%a' "$DOTS/new-snippets")"
    rm -f "$SNIPPET_FILE"

    echo "[$sh] save and rm write through a symlinked store under noclobber (set -C)"
    link_store snippets
    printf 'a\techo a\n' > "$DOTS/snippets"
    actual=$("$run" "$SNIPPET_SH" "set -C; snippet save b 'echo b' 2>&1; snippet rm a 2>&1" | tr -d '\r')
    assert_eq "$sh/noclobber: messages" "snippet: saved 'b'
snippet: removed 'a'" "$actual"
    assert_eq "$sh/noclobber: target updated" "b${TAB}echo b" "$(cat "$DOTS/snippets")"
    link_store new-snippets
    "$run" "$SNIPPET_SH" "set -C; snippet save n 'echo n' 2>/dev/null"
    assert_eq "$sh/noclobber: dangling target created" "n${TAB}echo n" "$(cat "$DOTS/new-snippets" 2>&1)"
    assert_eq "$sh/noclobber: symlink kept" "link" "$([ -L "$SNIPPET_FILE" ] && echo link || echo replaced)"

    # An interactive shell has den's cat wrapper (wrappers.sh), a function
    # that runs bat with the user's bat config and prints a notice. The copy
    # through the symlink must not go through it.
    echo "[$sh] save and rm write through a symlinked store with the native cat, not a cat function"
    link_store snippets
    printf 'a\techo a\n' > "$DOTS/snippets"
    actual=$("$run" "$SNIPPET_SH" "cat() { echo '[den] cat -> bat' >&2; echo WRAPPED; }; snippet save b 'echo b' 2>&1; snippet rm a 2>&1" | tr -d '\r')
    assert_eq "$sh/cat function: messages" "snippet: saved 'b'
snippet: removed 'a'" "$actual"
    assert_eq "$sh/cat function: target updated" "b${TAB}echo b" "$(cat "$DOTS/snippets")"

    echo "[$sh] a write through the symlink that fails part way keeps the whole new store"
    link_store snippets
    printf 'a\techo a\nb\techo b\n' > "$DOTS/snippets"
    actual=$("$run" "$SNIPPET_SH" "PATH='$FAILCAT':\$PATH; snippet save c 'echo c' 2>&1; echo rc=\$?" | tr -d '\r')
    left=$(cd "$SNIPPET_DIR" && ls -A | grep -v '^snippets$')
    assert_eq "$sh/failed write: messages" "snippet save: cannot write $SNIPPET_FILE
snippet save: the whole new store is in $SNIPPET_DIR/$left
rc=1" "$actual"
    assert_eq "$sh/failed write: new store kept" "a${TAB}echo a
b${TAB}echo b
c${TAB}echo c" "$(cat "$SNIPPET_DIR/$left" 2>&1)"
    rm -f "$SNIPPET_FILE" "${SNIPPET_DIR:?}/$left"

    # Mode 0200: the store can be written but not read. root reads it anyway,
    # so there the case is skipped.
    echo "[$sh] save leaves a store it cannot read as it was"
    printf 'a\techo a\n' > "$SNIPPET_FILE"
    if [ "$(id -u)" -ne 0 ] && chmod 200 "$SNIPPET_FILE" 2>/dev/null && [ ! -r "$SNIPPET_FILE" ]; then
        actual=$("$run" "$SNIPPET_SH" "snippet save n 'echo n' 2>&1; echo rc=\$?" | tr -d '\r')
        chmod 600 "$SNIPPET_FILE"
        assert_contains "$sh/unreadable store: message" "snippet save: cannot read $SNIPPET_FILE; it is left as it was" "$actual"
        assert_contains "$sh/unreadable store: rc" "rc=1" "$actual"
        assert_eq "$sh/unreadable store: kept" "a${TAB}echo a" "$(cat "$SNIPPET_FILE")"
    else
        echo "  SKIP: $sh/unreadable store (running as root)"
    fi
    reset_store

    # rm said there was no such snippet.
    echo "[$sh] rm leaves a store it cannot read as it was, and says so"
    printf 'a\techo a\n' > "$SNIPPET_FILE"
    if [ "$(id -u)" -ne 0 ] && chmod 200 "$SNIPPET_FILE" 2>/dev/null && [ ! -r "$SNIPPET_FILE" ]; then
        actual=$("$run" "$SNIPPET_SH" "snippet rm a 2>&1; echo rc=\$?" | tr -d '\r')
        chmod 600 "$SNIPPET_FILE"
        assert_contains "$sh/unreadable store, rm: message" "snippet rm: cannot read $SNIPPET_FILE; it is left as it was" "$actual"
        assert_contains "$sh/unreadable store, rm: rc" "rc=1" "$actual"
        assert_eq "$sh/unreadable store, rm: kept" "a${TAB}echo a" "$(cat "$SNIPPET_FILE")"
    else
        echo "  SKIP: $sh/unreadable store, rm (running as root)"
    fi
    reset_store

    # A write into the temporary store that fails (capped_case, above): save
    # and rm put what they had written, or an empty file, in place of the
    # store and said they had saved or removed the snippet, with status 0. A
    # save whose last copy failed kept the store but said it could not read it.
    echo "[$sh] save and rm leave the store as it was when a write into the new one fails"
    capped_case "$sh" "save, the new line cut short" 1 \
        "a${TAB}echo $PAD${NL}last${TAB}echo old${NL}" "snippet save last 'echo $LONG'"
    capped_case "$sh" "save, a copied line cut short" 1 \
        "a${TAB}echo $PAD${NL}b${TAB}echo $LONG${NL}c${TAB}echo c${NL}" "snippet save c 'echo new'"
    capped_case "$sh" "save, every write fails" 0 \
        "a${TAB}echo a${NL}b${TAB}echo b${NL}last${TAB}echo old${NL}" "snippet save last 'echo new'"
    capped_case "$sh" "save, the last copy fails" 0 \
        "a${TAB}echo a${NL}b${TAB}echo b${NL}" "snippet save a 'echo new'"
    capped_case "$sh" "rm, a copied line cut short" 1 \
        "a${TAB}echo $PAD${NL}b${TAB}echo b${NL}c${TAB}echo $LONG${NL}" "snippet rm b"
    capped_case "$sh" "rm, every write fails" 0 \
        "a${TAB}echo a${NL}b${TAB}echo b${NL}" "snippet rm a"
    reset_store

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

# pwsh port: same store (XDG_CONFIG_HOME), same TAB format. Messages go to the
# process stderr (bash's $(...) captures stdout only), so data reads stay clean.
if command -v pwsh >/dev/null 2>&1; then
    # snippet.ps1 writes its store with _DenWritePrivate and replays through
    # _DenReplay, both from _helpers.ps1, which init.ps1 loads first; this file
    # loads both in that order.
    SNIPPET_PS1="$TESTTMP/snippet_test.ps1"
    printf ". '%s'\n. '%s'\n" "$DOTFILES/shell/pwsh/_helpers.ps1" "$DOTFILES/shell/pwsh/snippet.ps1" > "$SNIPPET_PS1" ||
        abort_suite "cannot write $SNIPPET_PS1"

    reset_store
    echo "[pwsh] save + show"
    actual=$(run_pwsh "$SNIPPET_PS1" "snippet save greet 'Write-Output hi'; snippet show greet" | tr -d '\r')
    assert_eq "pwsh/snippet show" "Write-Output hi" "$actual"

    reset_store
    echo "[pwsh] run evaluates the command"
    actual=$(run_pwsh "$SNIPPET_PS1" "snippet save g 'Write-Output hello'; snippet run g" | tr -d '\r')
    assert_eq "pwsh/snippet run output" "hello" "$actual"

    reset_store
    echo "[pwsh] alias snip saves; rm then show is empty"
    actual=$(run_pwsh "$SNIPPET_PS1" "snip save z 'Write-Output q'; snippet rm z; snippet show z" | tr -d '\r')
    assert_eq "pwsh/snip alias + rm" "" "$actual"

    reset_store
    echo "[pwsh] save from stdin takes the first line"
    actual=$(run_pwsh "$SNIPPET_PS1" "'Write-Output piped', 'Write-Output dropped' | snippet save p; snippet show p" | tr -d '\r')
    assert_eq "pwsh/snippet stdin save" "Write-Output piped" "$actual"

    reset_store
    echo "[pwsh] save prints the line it saved for several words only, not for one argument or stdin"
    actual=$(run_pwsh_stderr "$SNIPPET_PS1" "snippet save o 'echo tok'; 'echo tok' | snippet save i")
    assert_eq "pwsh/snippet save message: one argument and stdin" "snippet: saved 'o'
snippet: saved 'i'" "$actual"

    reset_store
    echo "[pwsh] save <word...> quotes a path with a blank again, so run removes that one only"
    rm -rf "${SQ:?}"
    mkdir -p "$SQ/My Stuff/tmp" "$SQ/My" "$SQ/Stuff/tmp"
    touch "$SQ/My Stuff/tmp/x" "$SQ/My/keep.txt" "$SQ/Stuff/tmp/keep2.txt"
    actual=$(cd "$SQ" && run_pwsh_stderr "$SNIPPET_PS1" "snippet save cleantmp Remove-Item -Recurse -Force 'My Stuff/tmp'")
    assert_eq "pwsh/snippet save words: prints the saved line" "snippet: saved 'cleantmp' -> Remove-Item -Recurse -Force 'My Stuff/tmp'" "$actual"
    actual=$(cd "$SQ" && run_pwsh "$SNIPPET_PS1" "snippet run cleantmp 2>\$null; (Get-ChildItem -Recurse -Name | Sort-Object) -join ' | '" 2>/dev/null | tr -d '\r')
    assert_eq "pwsh/snippet save words: spaced path" "My | My Stuff | My/keep.txt | Stuff | Stuff/tmp | Stuff/tmp/keep2.txt" "$actual"

    reset_store
    echo "[pwsh] save <word...> quotes \$(...) ' \" # ; an empty word, an array and a first word, and leaves plain words bare"
    mkdir -p "$SQ/my dir"
    printf 'param($a) "hello $a"\n' > "$SQ/my dir/hello.ps1"
    cat > "$TESTTMP/sq_words.ps1" <<'PS1'
snippet save lit Write-Output 'literal $(whoami) text' "it's" "x`"y" '#c' 'a;b' '' a,'b c' 2>$null
snippet show lit
snippet run lit 2>$null
snippet save h './my dir/hello.ps1' arg2 2>$null
snippet show h
snippet run h 2>$null
snippet save s Get-ChildItem -Name ./x:y a=b +1 C:\p\q 2>$null
snippet show s
PS1
    actual=$(cd "$SQ" && run_pwsh "$SNIPPET_PS1" ". '$TESTTMP/sq_words.ps1'" 2>/dev/null | tr -d '\r')
    assert_eq "pwsh/snippet save words: special characters" "Write-Output 'literal \$(whoami) text' 'it''s' 'x\"y' '#c' 'a;b' '' a,'b c'
literal \$(whoami) text
it's
x\"y
#c
a;b

a
b c
& './my dir/hello.ps1' arg2
hello arg2
Get-ChildItem -Name ./x:y a=b +1 C:\\p\\q" "$actual"

    reset_store
    echo "[pwsh] save <word...> keeps values: a quoted number stays a string, a bare one a number, \$true and a { } block themselves"
    cat > "$TESTTMP/sq_values.ps1" <<'PS1'
function show { ($args | ForEach-Object { "$_" + ':' + $_.GetType().Name }) -join ' ' }
snippet save v show '007' '1kb' '.5' '0x10' 007 1kb $true $false { $_ } 2>$null
snippet show v
snippet run v 2>$null
PS1
    actual=$(run_pwsh "$SNIPPET_PS1" ". '$TESTTMP/sq_values.ps1'" 2>/dev/null | tr -d '\r')
    assert_eq "pwsh/snippet save words: values" "show '007' '1kb' '.5' '0x10' 007 1kb \$true \$false { \$_ }
007:String 1kb:String .5:String 0x10:String 7:Int32 1024:Int32 True:Boolean False:Boolean  \$_ :ScriptBlock" "$actual"

    reset_store
    echo "[pwsh] save <word...> quotes a string that starts with a dash, and keeps a parameter typed bare"
    # sw tells a bound -Flag from a string '-Flag'. The en dash parameter is
    # built from [char]0x2013 and shown as <U+2013>.
    cat > "$TESTTMP/sq_dash.ps1" <<'PS1'
function sw { param([switch]$Flag, [Parameter(ValueFromRemainingArguments)]$Rest) "flag=$Flag rest=$($Rest -join ',')" }
snippet save q sw '-Flag' '--' '-x:1' '-' x 2>$null
snippet show q
snippet run q 2>$null
snippet save b sw -Flag y 2>$null
snippet show b
snippet run b 2>$null
$d = [char]0x2013
Invoke-Expression "snippet save e sw ${d}Flag z 2>`$null"
(snippet show e).Replace([string]$d, '<U+2013>')
snippet run e 2>$null
PS1
    actual=$(run_pwsh "$SNIPPET_PS1" ". '$TESTTMP/sq_dash.ps1'" 2>/dev/null | tr -d '\r')
    assert_eq "pwsh/snippet save words: dash-leading strings and parameters" "sw '-Flag' '--' '-x:1' '-' x
flag=False rest=-Flag,--,-x:1,-,x
sw -Flag y
flag=True rest=y
sw <U+2013>Flag z
flag=True rest=z" "$actual"

    echo "[pwsh] save makes the store 0600 in a 0700 directory, under umask 022"
    rm -rf "${SNIPPET_DIR:?}"
    (umask 022; run_pwsh "$SNIPPET_PS1" "snippet save t 'Write-Output tok'" 2>/dev/null)
    assert_eq "pwsh/snippet new store modes" "700 600" "$(modes)"

    echo "[pwsh] rm tightens an older den's 0644 store and 0755 directory"
    printf 'a\techo a\nb\techo b\n' > "$SNIPPET_FILE"
    chmod 755 "$SNIPPET_DIR"
    chmod 644 "$SNIPPET_FILE"
    (umask 022; run_pwsh "$SNIPPET_PS1" "snippet rm b" 2>/dev/null)
    assert_eq "pwsh/snippet rm tightens both" "700 600" "$(modes)"

    echo "[pwsh] save and rm write through a symlinked store"
    link_store snippets
    printf 'a\techo a\n' > "$DOTS/snippets"
    chmod 644 "$DOTS/snippets"
    (umask 022; run_pwsh "$SNIPPET_PS1" "snippet save b 'echo b'; snippet rm a" 2>/dev/null)
    assert_eq "pwsh/snippet symlink kept" "link" "$([ -L "$SNIPPET_FILE" ] && echo link || echo replaced)"
    assert_eq "pwsh/snippet symlink target updated, 0600" "b${TAB}echo b 600" \
        "$(cat "$DOTS/snippets") $(stat -c '%a' "$DOTS/snippets")"
    rm -f "$SNIPPET_FILE"

    echo "[pwsh] save through a symlink whose target does not exist yet creates it"
    link_store new-snippets
    actual=$( (umask 022; run_pwsh "$SNIPPET_PS1" "snippet save n 'echo n'; 'after'" 2>/dev/null) | tr -d '\r')
    assert_eq "pwsh/snippet dangling symlink: save returns" "after" "$actual"
    assert_eq "pwsh/snippet dangling symlink kept" "link" "$([ -L "$SNIPPET_FILE" ] && echo link || echo replaced)"
    assert_eq "pwsh/snippet dangling symlink target created" "n${TAB}echo n 600" \
        "$(cat "$DOTS/new-snippets" 2>&1) $(stat -c '%a' "$DOTS/new-snippets" 2>&1)"
    rm -f "$SNIPPET_FILE"

    echo "[pwsh] save leaves a store it cannot read as it was"
    printf 'a\techo a\n' > "$SNIPPET_FILE"
    if [ "$(id -u)" -ne 0 ] && chmod 200 "$SNIPPET_FILE" 2>/dev/null && [ ! -r "$SNIPPET_FILE" ]; then
        actual=$(run_pwsh "$SNIPPET_PS1" "snippet save n 'echo n'; 'after'" 2>/dev/null | tr -d '\r')
        chmod 600 "$SNIPPET_FILE"
        assert_eq "pwsh/snippet unreadable store: save ends" "" "$actual"
        assert_eq "pwsh/snippet unreadable store: kept" "a${TAB}echo a" "$(cat "$SNIPPET_FILE")"
    else
        echo "  SKIP: pwsh/snippet unreadable store (running as root)"
    fi
    reset_store

    reset_store
    echo "[pwsh] unknown command fails with usage"
    actual=$(run_pwsh "$SNIPPET_PS1" "snippet frobnicate" 2>&1 | tr -d '\r')
    assert_contains "pwsh/snippet unknown cmd" "unknown command" "$actual"

    # snippet run replays its line as typed when snippet is typed: gl there is
    # den's git log, as it was when the line was saved. Run from a script, the
    # line gets what gl means in a script, Get-Location. den loads as $PROFILE
    # loads it, with a stub git (see run_pwsh_den in helpers.sh).
    echo "[pwsh] snippet run replays as typed; a script's snippet run gets the cmdlet"
    SNIP_BIN="$WORK/snip-bin"
    mkdir -p "$SNIP_BIN"
    printf '#!/bin/sh\necho "STUB-GIT $*"\n' > "$SNIP_BIN/git"
    chmod +x "$SNIP_BIN/git"
    printf '%s\n' '"script: $((snippet run where).GetType().Name)"' > "$WORK/runsnip.ps1"
    actual=$(run_pwsh_den "\$env:PATH = '$SNIP_BIN:/usr/bin:/bin'" "
        snippet save where gl
        snippet run where
        & '$WORK/runsnip.ps1'
    " 2>/dev/null | tr -d '\r')
    assert_eq "pwsh/snippet run typed, then from a script" "STUB-GIT log --oneline --graph
script: PathInfo" "$actual"

    # snippet pick runs the command saved under the name it picked, not the
    # line fzf prints back. Windows PowerShell 5.1 pipes text into a program as
    # ASCII ($OutputEncoding), so each character outside ASCII reached fzf as ?,
    # and Remove-Item '資料' came back as Remove-Item '??', a wildcard that
    # removed ab too. pwsh 7 pipes UTF-8, but on Windows it reads what fzf
    # prints in the console's code page (932 on Japanese Windows), and the
    # command came back garbled. Each case starts with ab and 資料 and prints
    # whether each is still there; the encodings must be the same after pick.
    # The stub fzf logs the lines it reads and prints the first, or FZF_PRINT.
    PICK_BIN="$WORK/pick-bin"
    mkdir -p "$PICK_BIN"
    cat > "$PICK_BIN/fzf" <<'STUB'
#!/bin/sh
n=0
while IFS= read -r l || [ -n "$l" ]; do
    printf '%s\n' "$l" >> "$FZF_LOG"
    n=$((n + 1))
    [ "$n" -eq 1 ] && f=$l
done
[ "$n" -gt 0 ] && printf '%s\n' "${FZF_PRINT:-$f}"
exit 0
STUB
    chmod +x "$PICK_BIN/fzf"
    export FZF_LOG="$WORK/fzf.log"

    reset_store
    echo "[pwsh] pick runs 資料's snippet under an ASCII \$OutputEncoding and a 932 console, and leaves both"
    rm -rf "${SQ:?}" "$FZF_LOG"
    mkdir -p "$SQ"
    actual=$(cd "$SQ" && PATH="$PICK_BIN:$PATH" run_pwsh "$SNIPPET_PS1" "
        function left { (Test-Path -LiteralPath ab).ToString() + ' ' + (Test-Path -LiteralPath '資料') }
        snippet save del \"Remove-Item '資料'\"
        \$null = New-Item -ItemType File ab, '資料'
        \$OutputEncoding = [Text.Encoding]::ASCII
        snippet pick
        'pipe ASCII: ' + (left) + ' ' + \$OutputEncoding.WebName
        \$OutputEncoding = [Text.UTF8Encoding]::new(\$false)
        [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
        \$null = New-Item -ItemType File -Force ab, '資料'
        [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(932)
        snippet pick
        'console 932: ' + (left) + ' ' + [Console]::OutputEncoding.CodePage
    " 2>/dev/null | tr -d '\r')
    assert_eq "pwsh/snippet pick: 資料's snippet ran, and only it" "pipe ASCII: True False us-ascii
console 932: True False 932" "$actual"
    assert_eq "pwsh/snippet pick: fzf read the list as saved" "del${TAB}Remove-Item '資料'
del${TAB}Remove-Item '資料'" "$(cat "$FZF_LOG" 2>&1)"
    # save takes no such name, but the store is a file, which bash, zsh and an
    # editor share: a name too comes back from fzf as it was saved.
    reset_store
    printf '資料\tWrite-Output picked\n' > "$SNIPPET_FILE"
    actual=$(PATH="$PICK_BIN:$PATH" run_pwsh "$SNIPPET_PS1" "
        [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
        [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(932)
        snippet pick
    " 2>/dev/null | tr -d '\r')
    assert_eq "pwsh/snippet pick: a name fzf prints reads as UTF-8 under a 932 console" "picked" "$actual"

    # The command comes from the store even when fzf prints something else, and
    # by the exact name: bash/zsh tell Pk from pk. It runs with the session's
    # $OutputEncoding, not pick's. A name no longer in the store runs nothing.
    reset_store
    echo "[pwsh] pick takes only the name from fzf's line, matched exactly, and runs it with the session's \$OutputEncoding"
    printf 'Pk\tWrite-Output upper\npk\tWrite-Output lower\n' > "$SNIPPET_FILE"
    cat > "$TESTTMP/pick_name.ps1" <<'PS1'
$OutputEncoding = [Text.Encoding]::ASCII
snippet save show-it "Write-Output 'from the store'"
snippet save enc '$OutputEncoding.WebName'
$env:FZF_PRINT = "show-it`tWrite-Output 'from fzf'"
snippet pick
$env:FZF_PRINT = "pk`tWrite-Output lower"
snippet pick
$env:FZF_PRINT = "enc`tWrite-Output 'from fzf'"
snippet pick
$env:FZF_PRINT = "gone`tWrite-Output 'from fzf'"
snippet pick
PS1
    actual=$(PATH="$PICK_BIN:$PATH" run_pwsh "$SNIPPET_PS1" ". '$TESTTMP/pick_name.ps1'" 2>"$WORK/pick.err" | tr -d '\r')
    assert_eq "pwsh/snippet pick: by name, exactly" "from the store
lower
us-ascii" "$actual"
    assert_eq "pwsh/snippet pick: by name, messages" "snippet: saved 'show-it'
snippet: saved 'enc'
+ Write-Output 'from the store'
+ Write-Output lower
+ \$OutputEncoding.WebName
snippet pick: no such snippet 'gone' (snippet ls)" "$(tr -d '\r' < "$WORK/pick.err")"

    # A replayed line looks a variable up in the scopes of snippet,
    # _SnippetExec and _DenReplay before the session's, so a variable of
    # theirs hid the session's of that name: a picked line read the picked
    # name as $name. Each name below was one of theirs. A line that set $outer
    # also set the replay depth _DenReplay puts back.
    reset_store
    echo "[pwsh] run and pick: the line reads the session's \$name and the others, not snippet's"
    cat > "$TESTTMP/pick_scope.ps1" <<'PS1'
$name = 'my-name'; $c = 'my-c'; $lines = 'my-lines'; $sel = 'my-sel'; $i = 'my-i'; $rest = 'my-rest'
$sub = 'my-sub'; $stdin = 'my-stdin'; $cmd = 'my-cmd'; $typed = 'my-typed'; $line = 'my-line'; $outer = 'my-outer'
snippet save probe '"$name $c $lines $sel $i $rest $sub $stdin $cmd $typed $line $outer"'
snippet run probe
$env:FZF_PRINT = "probe`tWrite-Output 'from fzf'"
snippet pick
snippet save depth '$outer = 7'
snippet run depth
"replay depth after: $global:_DenReplayDepth"
PS1
    actual=$(PATH="$PICK_BIN:$PATH" run_pwsh "$SNIPPET_PS1" ". '$TESTTMP/pick_scope.ps1'" 2>/dev/null | tr -d '\r')
    assert_eq "pwsh/snippet run and pick: the session's variables" "my-name my-c my-lines my-sel my-i my-rest my-sub my-stdin my-cmd my-typed my-line my-outer
my-name my-c my-lines my-sel my-i my-rest my-sub my-stdin my-cmd my-typed my-line my-outer
replay depth after: 0" "$actual"

    unset FZF_LOG

    # run and pick replay the line inside a function (_DenReplay). Unlike
    # bash/zsh's eval, which sets the shell's own variables, that keeps what
    # the line makes global, $env: and the location, but not a plain variable,
    # function or alias, whether the line or a script it dot-sources makes it.
    # The line still reads the session's variables. The docs say so.
    reset_store
    echo "[pwsh] a snippet runs inside a function: it reads the session's variables; global, \$env: and cd stay, plain variables, functions and aliases do not"
    rm -rf "${WORK:?}/scope"
    mkdir -p "$WORK/scope/to"
    printf '%s\n' '$dotVar = 1' 'function Dot-Fn { }' > "$WORK/scope/env.ps1"
    cat > "$TESTTMP/scope.ps1" <<'PS1'
$v = 'old'
snippet save plain '"read=$v"; $v = ''new''; $made = 1; function Plain-Fn { }; Set-Alias plain-al Get-Date'
snippet save dot '. ./env.ps1'
snippet save glob '$global:g = ''set''; function global:Global-Fn { }; Set-Alias global-al Get-Date -Scope Global'
snippet save envcd '$env:DEN_SCOPE_PROBE = ''set''; Set-Location ./to'
foreach ($n in 'plain', 'dot', 'glob', 'envcd') { snippet run $n }
"v=$v made=$(Test-Path Variable:made) Plain-Fn=$(Test-Path Function:Plain-Fn) plain-al=$(Test-Path Alias:plain-al)"
"dotVar=$(Test-Path Variable:dotVar) Dot-Fn=$(Test-Path Function:Dot-Fn)"
"g=$g Global-Fn=$(Test-Path Function:Global-Fn) global-al=$(Test-Path Alias:global-al)"
"env=$env:DEN_SCOPE_PROBE location=$(Split-Path -Leaf (Get-Location).Path)"
PS1
    actual=$(cd "$WORK/scope" && run_pwsh "$SNIPPET_PS1" ". '$TESTTMP/scope.ps1'" 2>/dev/null | tr -d '\r')
    assert_eq "pwsh/snippet run: what stays in the session" "read=old
v=old made=False Plain-Fn=False plain-al=False
dotVar=False Dot-Fn=False
g=set Global-Fn=True global-al=True
env=set location=to" "$actual"
    assert_eq "docs/README: a pwsh snippet runs inside a function" 'PowerShell runs it with `Invoke-Expression` inside a function' \
        "$(grep -oF -- 'PowerShell runs it with `Invoke-Expression` inside a function' "$DOTFILES/shell/README.md" | head -n 1)"
    # The shell test image copies only shell/ and tests/shell/, not COMMANDS.md.
    if [ -f "$DOTFILES/COMMANDS.md" ]; then
        row=$(grep -F '| `snippet` / `snip` |' "$DOTFILES/COMMANDS.md" | head -n 1)
        assert_contains "docs/COMMANDS: a pwsh snippet runs inside a function" 'on pwsh a snippet runs inside a function' "$row"
    else
        echo "  SKIP: docs/COMMANDS snippet row (no COMMANDS.md in $DOTFILES)"
    fi
else
    echo "pwsh not found; skipping pwsh snippet tests"
fi

# =============================================================================
# Summary
# =============================================================================
print_summary "test_snippet"
[ "$FAIL" -eq 0 ]
