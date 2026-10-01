#!/usr/bin/env bash
# test_snippet.sh — Tests for snippet.sh (save / list / run named command snippets).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

SNIPPET_SH_GUARDED="$DOTFILES/shell/posix/snippet.sh"
SNIPPET_SH="$TESTTMP/snippet_test.sh"
make_noninteractive_source_copy "$SNIPPET_SH_GUARDED" "$SNIPPET_SH"

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
    assert_eq "$sh/rm gives the store 0600" "600" "$(stat -c '%a' "$SNIPPET_FILE")"
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

    echo "[$sh] a write through the symlink that fails part way keeps the whole new store"
    link_store snippets
    printf 'a\techo a\nb\techo b\n' > "$DOTS/snippets"
    # A cat that writes 5 bytes and fails, as on a full disk.
    actual=$("$run" "$SNIPPET_SH" "cat() { command head -c 5 \"\$1\"; return 1; }; snippet save c 'echo c' 2>&1; echo rc=\$?" | tr -d '\r')
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
    # snippet.ps1 writes its store with _DenWritePrivate from _helpers.ps1, which
    # init.ps1 loads first; this file loads both in that order.
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
    actual=$(run_pwsh "$SNIPPET_PS1" "'Write-Output piped' | snippet save p; snippet show p" | tr -d '\r')
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
else
    echo "pwsh not found; skipping pwsh snippet tests"
fi

# =============================================================================
# Summary
# =============================================================================
print_summary "test_snippet"
[ "$FAIL" -eq 0 ]
