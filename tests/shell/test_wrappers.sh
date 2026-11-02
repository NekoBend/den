#!/usr/bin/env bash
# test_wrappers.sh — Tests for wrappers.sh (bash/zsh) and wrappers.ps1 (pwsh).
# Tests fallback paths (bat/fd/rg/lsd hidden from PATH), then the wrapper notice
# with stub lsd/bat on PATH.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

HELPERS_SH="$DOTFILES/shell/posix/_helpers.sh"
WRAPPERS_SH="$DOTFILES/shell/posix/wrappers.sh"
HELPERS_PS1="$DOTFILES/shell/pwsh/_helpers.ps1"
WRAPPERS_PS1="$DOTFILES/shell/pwsh/wrappers.ps1"

# wrappers.sh has an interactive guard (case $- in *i*).
# Use bash --norc -ic / zsh -f -ic to bypass it. --norc and -f skip the rc
# files, whose aliases (oh-my-zsh's ll, say) would replace the wrapper under
# test; -f also skips the global zshrc, whose compinit writes ~/.zcompdump.
# _helpers.sh must be sourced first (provides _wrap/_wsfx).
run_bash_i() {
    bash --norc -ic "source '$HELPERS_SH' && source '$1' && $2" 2>/dev/null
}

run_zsh_i() {
    zsh -f -ic "source '$HELPERS_SH' && source '$1' && $2" 2>/dev/null
}

# wrappers.ps1 has a `_DenInteractive` guard (returns early under pwsh -Command).
# Strip the guard line before dot-sourcing so the wrappers load in the test host.
# Prepend _helpers.ps1 so New-Wrapper/New-WrapperSuffix are available.
# In TESTTMP, out of reach of the fixture resets that wipe WORK.
WRAPPERS_PS1_STRIPPED="$TESTTMP/wrappers_stripped.ps1"
{
    echo ". '$HELPERS_PS1'"
    grep -v '_DenInteractive' "$WRAPPERS_PS1" | sed '/Remove-Item alias:ls/d'
} > "$WRAPPERS_PS1_STRIPPED" || abort_suite "cannot write $WRAPPERS_PS1_STRIPPED"
# Combined wrappers + coreutils for pipe chain tests. coreutils.ps1 defines its
# commands on Windows only, so its _OnWindows line goes too: these run on Linux.
COREUTILS_PS1="$DOTFILES/shell/pwsh/coreutils.ps1"
COMBINED_PS1="$TESTTMP/wrappers_combined.ps1"
{
    cat "$WRAPPERS_PS1_STRIPPED"
    grep -v '_DenInteractive' "$COREUTILS_PS1" | grep -vF 'if (-not (_OnWindows)) { return }'
} > "$COMBINED_PS1" || abort_suite "cannot write $COMBINED_PS1"
grep -qxF 'if (-not (_OnWindows)) { return }' "$COREUTILS_PS1" ||
    abort_suite "coreutils.ps1 no longer has the _OnWindows line this suite strips"

# The same wrappers with the edition check reading "Desktop", standing in for
# Windows PowerShell 5.1 (no 5.1 host runs here).
WRAPPERS_PS1_DESKTOP="$TESTTMP/wrappers_desktop.ps1"
sed "s/[\$]PSVersionTable[.]PSEdition/'Desktop'/g" "$WRAPPERS_PS1_STRIPPED" > "$WRAPPERS_PS1_DESKTOP" ||
    abort_suite "cannot write $WRAPPERS_PS1_DESKTOP"

# =============================================================================
# A PATH without the modern tools
# =============================================================================
# The fallback cases need the modern tools the wrappers prefer to be absent.
# The CI image lacks them, but a developer machine or den's own dev image
# (docker/ubuntu, with ~/.cargo/bin on PATH) has them, and there the wrappers
# took the modern branch: 16 fallback assertions failed on a correct tree. So
# the rest of this suite runs on a PATH of one directory, FALLBACK_BIN, which
# links every command on the real PATH (the first of each name, as a lookup
# finds it) except MODERN_TOOLS. A stand-in for each of those tools goes on the
# PATH the links are made from, so the checks below prove the tools are hidden
# on a machine that does not have them too.
MODERN_TOOLS="bat fd rg lsd"
FALLBACK_BIN="$TESTTMP/fallback-bin"
MODERN_STANDINS="$TESTTMP/modern-standins"
mkdir "$FALLBACK_BIN" "$MODERN_STANDINS" || abort_suite "cannot create $FALLBACK_BIN"
for _t in $MODERN_TOOLS; do
    { printf '#!/bin/sh\necho "modern %s $*"\n' "$_t" > "$MODERN_STANDINS/$_t" &&
        chmod +x "$MODERN_STANDINS/$_t"; } || abort_suite "cannot write $MODERN_STANDINS/$_t"
done
IFS=: read -r -a _path_dirs <<< "$MODERN_STANDINS:$PATH"
for _d in "${_path_dirs[@]}"; do
    case "$_d" in /*) ;; *) continue ;; esac
    _links=()
    for _f in "$_d"/*; do
        case " $MODERN_TOOLS " in *" ${_f##*/} "*) continue ;; esac
        [ -f "$_f" ] && [ -x "$_f" ] && [ ! -e "$FALLBACK_BIN/${_f##*/}" ] && _links+=("$_f")
    done
    [ "${#_links[@]}" -eq 0 ] || ln -s -- "${_links[@]}" "$FALLBACK_BIN/" ||
        abort_suite "cannot link the commands of $_d into $FALLBACK_BIN"
done
unset _t _d _f _links _path_dirs
export PATH="$FALLBACK_BIN"

# A modern tool added to the wrappers must be added to MODERN_TOOLS too.
echo "[setup] MODERN_TOOLS names the modern tools the wrappers prefer"
actual=$(
    {
        awk '$1 == "_wrap" || $1 == "_wsfx" { print $3 }' "$WRAPPERS_SH"
        sed -n "s/^New-Wrapper[A-Za-z]* *'[^']*' *'\([^']*\)'.*/\1/p" "$WRAPPERS_PS1"
    } | sort -u | tr '\n' ' '
)
assert_eq "setup/MODERN_TOOLS matches the wrappers" "$(tr ' ' '\n' <<< "$MODERN_TOOLS" | sort -u | tr '\n' ' ')" "$actual"

echo "[setup] no modern tool resolves on the fallback PATH"
actual=$(bash --norc -c "for t in $MODERN_TOOLS; do command -v \$t; done")
assert_eq "setup/bash finds none" "" "$actual"
actual=$(zsh -f -c "for t in $MODERN_TOOLS; do command -v \$t; done")
assert_eq "setup/zsh finds none" "" "$actual"
actual=$(pwsh -NoProfile -NonInteractive -Command "@(Get-Command ${MODERN_TOOLS// /,} -CommandType Application -ErrorAction SilentlyContinue).Count" | tr -d '\r')
assert_eq "setup/pwsh finds none" "0" "$actual"
actual=$(for _t in bash zsh pwsh sort grep find ls cat; do command -v "$_t" >/dev/null || echo "$_t"; done)
assert_eq "setup/the rest still resolves" "" "$actual"

# =============================================================================
# Bash tests (fallback paths: bat/fd/rg/lsd hidden from PATH)
# =============================================================================
echo "================================================"
echo "  Testing wrappers.sh with BASH (fallback)"
echo "================================================"

# --- cat fallback → command cat ---
echo "[bash] cat fallback"
echo "hello wrapper" > "$WORK/wrap_test.txt"
actual=$(run_bash_i "$WRAPPERS_SH" "cat '$WORK/wrap_test.txt'")
assert_eq "bash/cat fallback" "hello wrapper" "$actual"

# --- find fallback → command find ---
echo "[bash] find fallback"
setup_fixtures
actual=$(run_bash_i "$WRAPPERS_SH" "find '$WORK/src' -name '*.txt' -type f | sort")
assert_contains "bash/find fallback file1" "file1.txt" "$actual"
assert_contains "bash/find fallback file3" "file3.txt" "$actual"

# --- grep fallback → command grep ---
echo "[bash] grep fallback"
echo -e "apple\nbanana\ncherry" > "$WORK/grep_test.txt"
actual=$(run_bash_i "$WRAPPERS_SH" "grep 'banana' '$WORK/grep_test.txt'")
assert_eq "bash/grep fallback" "banana" "$actual"

# --- ls fallback → command ls ---
echo "[bash] ls fallback"
setup_fixtures
actual=$(run_bash_i "$WRAPPERS_SH" "ls '$WORK/src'")
assert_contains "bash/ls fallback" "file1.txt" "$actual"

# --- la fallback → command ls -A ---
echo "[bash] la fallback"
mkdir -p "$WORK/la_test"
echo "visible" > "$WORK/la_test/visible.txt"
echo "hidden" > "$WORK/la_test/.hidden"
actual=$(run_bash_i "$WRAPPERS_SH" "la '$WORK/la_test'")
assert_contains "bash/la shows hidden" ".hidden" "$actual"
assert_contains "bash/la shows visible" "visible.txt" "$actual"
rm -rf "$WORK/la_test"

# --- ll fallback → command ls -lF ---
echo "[bash] ll fallback"
setup_fixtures
actual=$(run_bash_i "$WRAPPERS_SH" "ll '$WORK/src'")
assert_contains "bash/ll long format" "file1.txt" "$actual"

# =============================================================================
# Zsh tests (fallback paths)
# =============================================================================
echo ""
echo "================================================"
echo "  Testing wrappers.sh with ZSH (fallback)"
echo "================================================"

echo "[zsh] cat fallback"
echo "hello wrapper" > "$WORK/wrap_test.txt"
actual=$(run_zsh_i "$WRAPPERS_SH" "cat '$WORK/wrap_test.txt'")
assert_eq "zsh/cat fallback" "hello wrapper" "$actual"

echo "[zsh] the runner reads no ~/.zshrc"
ZSHRC_HOME="$WORK/zshrc_home"
mkdir -p "$ZSHRC_HOME"
echo "alias cat='echo HIJACKED-BY-ZSHRC'" > "$ZSHRC_HOME/.zshrc"
actual=$(HOME="$ZSHRC_HOME" run_zsh_i "$WRAPPERS_SH" "cat '$WORK/wrap_test.txt'")
assert_eq "zsh/runner ignores ~/.zshrc aliases" "hello wrapper" "$actual"
assert_not_exists "zsh/runner writes no ~/.zcompdump" "$ZSHRC_HOME/.zcompdump"
rm -rf "$ZSHRC_HOME"

echo "[zsh] find fallback"
setup_fixtures
actual=$(run_zsh_i "$WRAPPERS_SH" "find '$WORK/src' -name '*.txt' -type f | sort")
assert_contains "zsh/find fallback file1" "file1.txt" "$actual"

echo "[zsh] grep fallback"
echo -e "apple\nbanana\ncherry" > "$WORK/grep_test.txt"
actual=$(run_zsh_i "$WRAPPERS_SH" "grep 'banana' '$WORK/grep_test.txt'")
assert_eq "zsh/grep fallback" "banana" "$actual"

echo "[zsh] ls fallback"
setup_fixtures
actual=$(run_zsh_i "$WRAPPERS_SH" "ls '$WORK/src'")
assert_contains "zsh/ls fallback" "file1.txt" "$actual"

echo "[zsh] la fallback"
mkdir -p "$WORK/la_test"
echo "visible" > "$WORK/la_test/visible.txt"
echo "hidden" > "$WORK/la_test/.hidden"
actual=$(run_zsh_i "$WRAPPERS_SH" "la '$WORK/la_test'")
assert_contains "zsh/la shows hidden" ".hidden" "$actual"
assert_contains "zsh/la shows visible" "visible.txt" "$actual"
rm -rf "$WORK/la_test"

echo "[zsh] ll fallback"
setup_fixtures
actual=$(run_zsh_i "$WRAPPERS_SH" "ll '$WORK/src'")
assert_contains "zsh/ll long format" "file1.txt" "$actual"

# =============================================================================
# PowerShell tests (fallback paths)
# =============================================================================
echo ""
echo "================================================"
echo "  Testing wrappers.ps1 with PWSH (fallback)"
echo "================================================"

echo "[pwsh] cat fallback → Get-Content"
echo "hello wrapper" > "$WORK/wrap_test.txt"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "cat '$WORK/wrap_test.txt' | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_eq "pwsh/cat fallback" "hello wrapper" "$actual"

echo "[pwsh] grep fallback → Select-String"
echo -e "apple\nbanana\ncherry" > "$WORK/grep_test.txt"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "grep 'banana' '$WORK/grep_test.txt'")
assert_eq "pwsh/grep fallback" "banana" "$actual"

echo "[pwsh] ls fallback → Get-ChildItem"
setup_fixtures
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "ls '$WORK/src'")
assert_contains "pwsh/ls fallback" "file1.txt" "$actual"

echo "[pwsh] la fallback → Get-ChildItem -Force"
mkdir -p "$WORK/la_test"
echo "visible" > "$WORK/la_test/visible.txt"
echo "hidden" > "$WORK/la_test/.hidden"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "la '$WORK/la_test'")
assert_contains "pwsh/la shows hidden" ".hidden" "$actual"
rm -rf "$WORK/la_test"

echo "[pwsh] find fallback → Get-ChildItem -Recurse"
setup_fixtures
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "find '$WORK/src' | Out-String")
assert_contains "pwsh/find fallback file1" "file1.txt" "$actual"

echo "[pwsh] ll fallback → Format-List"
setup_fixtures
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "ll '$WORK/src' | Out-String")
assert_contains "pwsh/ll fallback" "file1.txt" "$actual"

echo "[pwsh] lt fallback uses relative paths"
setup_fixtures
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "Set-Location '$WORK'; lt 'src' | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/lt relative path" "src/file1.txt" "$actual"
assert_not_contains "pwsh/lt not absolute" "$WORK" "$actual"

echo "[pwsh] llt fallback uses relative paths"
setup_fixtures
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "Set-Location '$WORK'; llt 'src' | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/llt relative path" "src/file1.txt" "$actual"
assert_not_contains "pwsh/llt not absolute" "$WORK" "$actual"

# =============================================================================
# PowerShell extended tests — grep (Select-String) arguments
# =============================================================================
echo ""
echo "[pwsh] grep argument tests"
printf 'apple\nbanana\ncherry\navocado\n' > "$WORK/fruits.txt"

# grep multiple matches
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "grep 'a' '$WORK/fruits.txt'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/grep multi apple" "apple" "$actual"
assert_contains "pwsh/grep multi banana" "banana" "$actual"
assert_contains "pwsh/grep multi avocado" "avocado" "$actual"

# grep case-insensitive (-i flag required since fallback is now case-sensitive)
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "grep -i 'BANANA' '$WORK/fruits.txt'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_eq "pwsh/grep case-insensitive" "banana" "$actual"

# grep regex pattern
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "grep 'a..le' '$WORK/fruits.txt'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_eq "pwsh/grep regex" "apple" "$actual"

# grep no match → empty
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "grep 'xyz' '$WORK/fruits.txt'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_eq "pwsh/grep no match" "" "$actual"

# grep multi-file
echo "hello world" > "$WORK/gm1.txt"
echo "goodbye world" > "$WORK/gm2.txt"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "grep 'world' '$WORK/gm1.txt' '$WORK/gm2.txt'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/grep multi-file hello" "hello world" "$actual"
assert_contains "pwsh/grep multi-file goodbye" "goodbye world" "$actual"

# =============================================================================
# PowerShell extended tests — cat (Get-Content)
# =============================================================================
echo ""
echo "[pwsh] cat argument tests"
echo "content-one" > "$WORK/cat1.txt"
echo "content-two" > "$WORK/cat2.txt"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "cat '$WORK/cat1.txt','$WORK/cat2.txt' | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/cat multi-file one" "content-one" "$actual"
assert_contains "pwsh/cat multi-file two" "content-two" "$actual"

# =============================================================================
# PowerShell extended tests — lla (Get-ChildItem -Force | Format-Table)
# =============================================================================
echo ""
echo "[pwsh] lla fallback → table format"
setup_fixtures
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "lla '$WORK/src' | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/lla table file1" "file1.txt" "$actual"

# =============================================================================
# PowerShell pipe chain tests (wrappers + coreutils)
# =============================================================================
echo ""
echo "[pwsh] pipe chain tests"
seq 1 20 | while read i; do echo "line$i"; done > "$WORK/lines20.txt"
printf 'apple\nbanana\ncherry\navocado\n' > "$WORK/fruits.txt"

# cat | head → first 5 lines
actual=$(run_pwsh "$COMBINED_PS1" "cat '$WORK/lines20.txt' | head -n 5 | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
line_count=$(echo "$actual" | wc -l | tr -d ' ')
assert_eq "pwsh/cat|head count" "5" "$line_count"
assert_contains "pwsh/cat|head first" "line1" "$actual"

# cat | grep → filter lines
actual=$(run_pwsh "$COMBINED_PS1" "cat '$WORK/fruits.txt' | grep 'an'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/cat|grep banana" "banana" "$actual"

# head | tail → lines 8-10
actual=$(run_pwsh "$COMBINED_PS1" "head -n 10 '$WORK/lines20.txt' | tail -n 3 | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/head|tail line8" "line8" "$actual"
assert_contains "pwsh/head|tail line10" "line10" "$actual"

# cat | tail → last 3 lines
actual=$(run_pwsh "$COMBINED_PS1" "cat '$WORK/lines20.txt' | tail -n 3 | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/cat|tail line20" "line20" "$actual"

# cat | head | wc → 3-stage pipe
actual=$(run_pwsh "$COMBINED_PS1" "(cat '$WORK/lines20.txt' | head -n 5 | wc -l).Lines")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_eq "pwsh/cat|head|wc" "5" "$actual"

# =============================================================================
# PowerShell: a wrapper is den's only when typed at the prompt
# =============================================================================
# A user's script run from the session gets what the name meant before den
# loaded: here the native cat and grep (on Windows, the ls and cat aliases'
# Get-ChildItem and Get-Content). The w-suffix names, which name nothing else,
# stay den's there. A stub bat stands in for the modern tool. den's commands
# keep their command cache in $global:, since a function's $script: is the
# scope of the script running it, where a cache was $null: catw resolves bat
# from the script.
SCRIPT_BIN="$TESTTMP/script-bin"
mkdir -p "$SCRIPT_BIN"
printf '#!/bin/sh\necho "STUB-BAT $*"\n' > "$SCRIPT_BIN/bat"
chmod +x "$SCRIPT_BIN/bat"
SCRIPT_PATH="$SCRIPT_BIN:/usr/bin:/bin"
cat > "$WORK/usewrap.ps1" <<EOF
cat '$WORK/fruits.txt' | grep 'an'
function Get-FirstLine { cat '$WORK/lines20.txt' | Select-Object -First 2 }
Get-FirstLine
catw '$WORK/fruits.txt'
EOF
echo ""
echo "[pwsh] a user script gets the native cat and grep, and den's catw"
actual=$(run_pwsh_den "\$env:PATH = '$SCRIPT_PATH'; \$env:_DEN_WRAPPER_LOG = '0'" \
    "& '$WORK/usewrap.ps1'; cat '$WORK/fruits.txt'" 2>&1 | tr -d '\r')
assert_eq "pwsh/a script's cat and grep, then a typed cat" "banana
line1
line2
STUB-BAT --style=plain --paging=never $WORK/fruits.txt
STUB-BAT --style=plain --paging=never $WORK/fruits.txt --paging=never" "$actual"

# On Windows ls and cat are aliases of Get-ChildItem and Get-Content, which den
# removes so that its wrappers win at the prompt. A script then got den's ls,
# which prints names: `ls dist | Remove-Item -Recurse` removed the items of those
# names in the current directory and left dist's. Stock aliases stand in for
# Windows' here.
echo "[pwsh] ls and cat in a script are Windows' Get-ChildItem and Get-Content"
rm -rf "$WORK/vite" && mkdir -p "$WORK/vite/dist/assets"
echo src > "$WORK/vite/index.html"
echo built > "$WORK/vite/dist/index.html"
echo js > "$WORK/vite/dist/assets/a.js"
cat > "$WORK/clean-dist.ps1" <<'EOF'
ls dist | Remove-Item -Recurse -Force
"index.html kept: $(Test-Path index.html); dist: [$((Get-ChildItem dist -Name) -join ',')]"
"cat -Raw: $((cat index.html -Raw).Trim())"
"sizes: $(ls -File | ForEach-Object { '{0}={1}' -f $_.Name, $_.Length })"
EOF
actual=$(cd "$WORK/vite" && run_pwsh_den "
    Set-Alias -Name ls -Value Get-ChildItem; Set-Alias -Name cat -Value Get-Content
    \$env:PATH = '$SCRIPT_PATH'; \$env:_DEN_WRAPPER_LOG = '0'
" "ls; & '$WORK/clean-dist.ps1'" 2>&1 | tr -d '\r')
assert_eq "pwsh/typed ls lists names, a script's ls and cat are the cmdlets" "dist
index.html
index.html kept: True; dist: []
cat -Raw: src
sizes: index.html=4" "$actual"

# =============================================================================
# PowerShell: what is piped into a wrapper streams through; nothing piped, no pipe
# =============================================================================
# The generated wrappers handed the tool `$input`, which a function collects in
# full first: nothing reached the tool before the producer ended, so
# `tail -f log | grep x` never printed. With nothing piped in, `$input |` still
# made the tool's stdin an empty pipe: rg searched that instead of the current
# directory, and rm -i read EOF for its answer. See make_stamp_stub and
# assert_streams in helpers.sh.
STREAM_BIN="$TESTTMP/stream-bin"
mkdir -p "$STREAM_BIN"
make_stamp_stub "$STREAM_BIN/stamp" || abort_suite "cannot write $STREAM_BIN/stamp"
cp "$STREAM_BIN/stamp" "$STREAM_BIN/rg"
STREAM_SETUP="
    \$env:_DEN_WRAPPER_LOG = '0'
    New-Wrapper 'stampn' 'nonexistent-modern' '' 'stamp' '' ''
    New-WrapperSuffix 'stampw' 'stamp' ''
"

echo "[pwsh] grep (rg), a native tier and a w-suffix wrapper stream piped input"
actual=$(PATH="$STREAM_BIN:$PATH" run_pwsh "$WRAPPERS_PS1_STRIPPED" "$STREAM_SETUP; $STREAM_PRODUCER | grep x" < /dev/null 2>&1 | tr -d '\r')
assert_streams "pwsh/grep (rg) streams" "$actual"
actual=$(PATH="$STREAM_BIN:$PATH" run_pwsh "$WRAPPERS_PS1_STRIPPED" "$STREAM_SETUP; $STREAM_PRODUCER | stampn" < /dev/null 2>&1 | tr -d '\r')
assert_streams "pwsh/a native tier streams" "$actual"
actual=$(PATH="$STREAM_BIN:$PATH" run_pwsh "$WRAPPERS_PS1_STRIPPED" "$STREAM_SETUP; $STREAM_PRODUCER | stampw" < /dev/null 2>&1 | tr -d '\r')
assert_streams "pwsh/a w-suffix wrapper streams" "$actual"

echo "[pwsh] with nothing piped in, a wrapper's tool gets no pipe for stdin"
actual=$(PATH="$STREAM_BIN:$PATH" run_pwsh "$WRAPPERS_PS1_STRIPPED" "$STREAM_SETUP; grep x; stampn; stampw" < /dev/null 2>&1 | tr -d '\r')
assert_eq "pwsh/no stdin pipe for grep (rg), a native tier, a w-suffix wrapper" "stdin: not a pipe
stdin: not a pipe
stdin: not a pipe" "$actual"

# The Windows coreutils tier: rm/cp/... hand microsoft/coreutils the same way.
# $IsWindows is a constant, set with -Force; the stub stands in for coreutils.
WIN_SETUP="
    Set-Variable -Name IsWindows -Value \$true -Scope Global -Force
    \$env:_DEN_COREUTILS = '$STREAM_BIN/stamp'
    New-CoreutilsWrapper 'stampc' 'stamp-sub' 'Copy-Item'
"
echo "[pwsh] a coreutils wrapper streams piped input, and gets no pipe with none"
actual=$(run_pwsh "$HELPERS_PS1" "$WIN_SETUP; $STREAM_PRODUCER | stampc" < /dev/null 2>&1 | tr -d '\r')
assert_streams "pwsh/a coreutils wrapper streams" "$actual"
actual=$(run_pwsh "$HELPERS_PS1" "$WIN_SETUP; stampc" < /dev/null 2>&1 | tr -d '\r')
assert_eq "pwsh/no stdin pipe for a coreutils wrapper" "stdin: not a pipe" "$actual"

# At the end of a line typed at the prompt, the tool writes to the console itself.
# The steppable pipeline used to hand the tool's output back to the function, so
# its stdout was a pipe there too: rg held its output (block buffering) and
# dropped its colors, and what it did print showed up only when the next line
# went in, or at the end; `Get-Content -Wait log | grep x` showed nothing. The
# stub prints as rg does (see make_tty_stub), and each line is timed when it
# reaches the terminal. One session runs three lines, one per generator; the
# PATH has the stub as rg and as microsoft/coreutils.
TTY_BIN="$TESTTMP/tty-bin"
mkdir -p "$TTY_BIN"
make_tty_stub "$TTY_BIN/rg" || abort_suite "cannot write $TTY_BIN/rg"
echo "[pwsh] grep, a w-suffix wrapper and a coreutils wrapper at the end of a typed line write to the terminal as the tool prints"
# One line of statements: the pipelines run at the top level of -Command, as
# typed at the prompt.
actual=$(run_pty_stamped env PATH="$TTY_BIN:$PATH" pwsh -NoProfile -NonInteractive -Command "\
. '$WRAPPERS_PS1_STRIPPED'; \$env:_DEN_WRAPPER_LOG = '0'; New-WrapperSuffix 'ttyw' 'rg' ''; \
$STREAM_PRODUCER | grep x; 'next'; $STREAM_PRODUCER | ttyw; 'next'; \
Set-Variable -Name IsWindows -Value \$true -Scope Global -Force; \$env:_DEN_COREUTILS = '$TTY_BIN/rg'; \
New-CoreutilsWrapper 'ttyc' 'tty-sub' 'Copy-Item'; $STREAM_PRODUCER | ttyc" 2>&1)
for i in 1 2 3; do
    part=$(printf '%s\n' "$actual" | awk -v want="$i" '/ next$/ { n++; next } n + 1 == want')
    case $i in 1) what="grep (rg)" ;; 2) what="a w-suffix wrapper" ;; 3) what="a coreutils wrapper" ;; esac
    assert_streams "pwsh/$what at the end of a typed line writes to the terminal" "$part"
done

# A line that stops before its end, through Select-Object -First further down
# or a host stopping it (as for Ctrl+C), left the tool waiting on its stdin, a
# process that lived until PowerShell exited. See make_pid_stub and
# make_stub_state_ps1 in helpers.sh. The stopped case needs PowerShell 7.3 or
# later (a clean block).
PID_BIN="$TESTTMP/pid-bin"
mkdir -p "$PID_BIN"
make_pid_stub "$PID_BIN/rg" || abort_suite "cannot write $PID_BIN/rg"
STUB_STATE_PS1="$TESTTMP/stub-state.ps1"
make_stub_state_ps1 "$STUB_STATE_PS1" || abort_suite "cannot write $STUB_STATE_PS1"
echo "[pwsh] a line that stops early leaves no tool behind"
actual=$(PATH="$PID_BIN:$PATH" run_pwsh "$WRAPPERS_PS1_STRIPPED" "
    . '$STUB_STATE_PS1'
    \$env:_DEN_WRAPPER_LOG = '0'
    New-WrapperSuffix 'pidw' 'rg' ''
    \$env:PIDSTUB_FILE = '$TESTTMP/sel-grep.pid'
    \$null = 1..5000 | ForEach-Object { \"l\$_\" } | grep l | Select-Object -First 1
    'grep | Select-Object -First 1: ' + (Get-StubState \$env:PIDSTUB_FILE)
    \$env:PIDSTUB_FILE = '$TESTTMP/sel-w.pid'
    \$null = 1..5000 | ForEach-Object { \"l\$_\" } | pidw l | Select-Object -First 1
    'w-suffix | Select-Object -First 1: ' + (Get-StubState \$env:PIDSTUB_FILE)
    \$env:PIDSTUB_FILE = '$TESTTMP/stop-grep.pid'
    'grep, stopped: ' + (Test-StubStopped \". '$WRAPPERS_PS1_STRIPPED'; \`\$env:_DEN_WRAPPER_LOG = '0'\" \"& { 'l1'; Start-Sleep 60 } | grep l\")
    Set-Variable -Name IsWindows -Value \$true -Scope Global -Force
    \$env:_DEN_COREUTILS = '$PID_BIN/rg'
    New-CoreutilsWrapper 'pidc' 'pid-sub' 'Copy-Item'
    \$env:PIDSTUB_FILE = '$TESTTMP/sel-c.pid'
    \$null = 1..5000 | ForEach-Object { \"l\$_\" } | pidc | Select-Object -First 1
    'coreutils wrapper | Select-Object -First 1: ' + (Get-StubState \$env:PIDSTUB_FILE)
" < /dev/null 2>&1 | tr -d '\r')
assert_eq "pwsh/a stopped line leaves no tool running" "grep | Select-Object -First 1: gone
w-suffix | Select-Object -First 1: gone
grep, stopped: gone
coreutils wrapper | Select-Object -First 1: gone" "$actual"

# =============================================================================
# PowerShell: rm/cp/mv/mkdir/rmdir on Windows
# =============================================================================
# Without microsoft/coreutils, rm/cp/mv run the builtin cmdlet, which never got
# what was piped in: `Get-ChildItem *.tmp | rm` stopped at "missing mandatory
# parameters: Path" and removed nothing.
echo "[pwsh] Windows without coreutils: rm, cp and mv take piped items"
rm -rf "$WORK/pipe" && mkdir -p "$WORK/pipe/dest"
touch "$WORK/pipe/a.tmp" "$WORK/pipe/b.tmp" "$WORK/pipe/c.txt" "$WORK/pipe/d.txt"
actual=$(cd "$WORK/pipe" && run_pwsh "$HELPERS_PS1" "
    \$env:_DEN_FORCE_INTERACTIVE = '1'; \$env:_DEN_COREUTILS = '0'
    Set-Variable -Name IsWindows -Value \$true -Scope Global -Force
    . '$WRAPPERS_PS1'
    Get-ChildItem -Filter *.tmp | rm
    Get-ChildItem -Filter c.txt | cp -Destination dest
    Get-ChildItem -Filter d.txt | mv -Destination dest
    (Get-ChildItem -Recurse -File -Name | Sort-Object) -join ','
" < /dev/null 2>&1 | tr -d '\r')
assert_eq "pwsh/piped rm, cp, mv without coreutils" "c.txt,dest/c.txt,dest/d.txt" "$actual"

# With coreutils, a script got rm/cp/mkdir handing PowerShell parameters to it
# (`rm -Recurse -Force` failed on -e, and the script went on). A script gets the
# cmdlets of the stock aliases now, and Windows' mkdir function; typed, rm is
# coreutils' rm. Stock aliases and a mkdir function stand in for Windows' (with
# $env:OS and $IsLinux set too, as on Windows), and a stub for coreutils. Only
# the script's report line is kept: den's load warns here about caches it
# cannot check off Windows.
echo "[pwsh] Windows with coreutils: a script's rm, cp, mkdir are the cmdlets"
rm -rf "$WORK/wincu" && mkdir -p "$WORK/wincu/old/sub"
echo old > "$WORK/wincu/t.txt"; echo new > "$WORK/wincu/s.txt"; : > "$WORK/wincu/a.tmp"
cat > "$TESTTMP/coreutils-log" <<EOF
#!/bin/sh
echo "coreutils \$*" >> '$WORK/wincu-calls.log'
EOF
chmod +x "$TESTTMP/coreutils-log"
cat > "$WORK/cleanup.ps1" <<'EOF'
rm -Recurse -Force old
$d = mkdir -Force out
cp s.txt t.txt -Force
Get-ChildItem -Filter *.tmp | rm
"old removed: $(-not (Test-Path old)); made: $($d.Name); t.txt: $(Get-Content t.txt); a.tmp removed: $(-not (Test-Path a.tmp))"
EOF
rm -f "$WORK/wincu-calls.log"
actual=$(cd "$WORK/wincu" && run_pwsh_den "
    \$env:OS = 'Windows_NT'
    Set-Variable -Name IsWindows -Value \$true -Scope Global -Force
    Set-Variable -Name IsLinux -Value \$false -Scope Global -Force
    \$env:_DEN_COREUTILS = '$TESTTMP/coreutils-log'
    foreach (\$a in @{ cp = 'Copy-Item'; mv = 'Move-Item'; rm = 'Remove-Item'; rmdir = 'Remove-Item' }.GetEnumerator()) {
        Set-Alias -Name \$a.Key -Value \$a.Value -Scope Global
    }
    function global:mkdir { New-Item -ItemType Directory @args }
    \$env:PATH = '/usr/bin:/bin'
" "& '$WORK/cleanup.ps1'; rm -rf typed" 2>/dev/null | tr -d '\r' | grep -F 'old removed')
assert_eq "pwsh/a script's rm, mkdir, cp on Windows with coreutils" \
    "old removed: True; made: out; t.txt: new; a.tmp removed: True" "$actual"
assert_eq "pwsh/only the typed rm reached coreutils" "coreutils rm -rf typed" "$(cat "$WORK/wincu-calls.log" 2>/dev/null)"

# =============================================================================
# PowerShell extended tests — grep additional flags
# =============================================================================
echo ""
echo "[pwsh] grep additional flag tests"
printf 'apple\nbanana\ncherry\navocado\n' > "$WORK/fruits.txt"

# grep -v (invert match)
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "grep -v 'banana' '$WORK/fruits.txt'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/grep -v has apple" "apple" "$actual"
assert_contains "pwsh/grep -v has cherry" "cherry" "$actual"
if echo "$actual" | grep -qF 'banana'; then
    echo "  FAIL: pwsh/grep -v should exclude banana"
    ERRORS+=("pwsh/grep -v exclude banana")
    ((FAIL++)) || true
else
    echo "  PASS: pwsh/grep -v exclude banana"
    ((PASS++)) || true
fi

# grep -c (count)
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "grep -c 'a' '$WORK/fruits.txt'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/grep -c count" "3" "$actual"

# grep -l (filenames only)
echo "hello world" > "$WORK/gm1.txt"
echo "goodbye world" > "$WORK/gm2.txt"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "grep -l 'hello' '$WORK/gm1.txt' '$WORK/gm2.txt'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/grep -l filename" "gm1.txt" "$actual"

# grep pipe input
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "'hello world' | grep 'hello'")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/grep pipe" "hello" "$actual"

# =============================================================================
# PowerShell extended tests — find additional flags
# =============================================================================
echo ""
echo "[pwsh] find additional flag tests"
setup_fixtures

# find -name
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "find '$WORK/src' -name '*.txt' | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/find -name file1" "file1.txt" "$actual"

# find -type f
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "find '$WORK/src' -type f | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/find -type f file1" "file1.txt" "$actual"

# find -type d
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "find '$WORK/src' -type d | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/find -type d subdir" "subdir" "$actual"

# =============================================================================
# PowerShell extended tests — lt / llt
# =============================================================================
echo ""
echo "[pwsh] lt / llt fallback tests"
setup_fixtures

# lt fallback
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "lt '$WORK/src' | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/lt fallback file1" "file1.txt" "$actual"

# llt fallback. Its Name column holds the path relative to the current
# directory, which for $WORK can be longer than the table's default width, and
# the table would then cut the name off: -Width keeps it whole.
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "llt '$WORK/src' | Out-String -Width 4096")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_contains "pwsh/llt fallback file1" "file1.txt" "$actual"

# =============================================================================
# PowerShell toggle-wrapper test
# =============================================================================
echo ""
echo "[pwsh] toggle-wrapper OFF"
echo "hello wrapper" > "$WORK/wrap_test.txt"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "\$env:_DEN_WRAPPERS='0'; cat '$WORK/wrap_test.txt' | Out-String")
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_eq "pwsh/toggle off cat" "hello wrapper" "$actual"

# --- grep PS fallback: -n (line numbers) ---
echo "[pwsh] grep PS fallback -n"
echo -e "aaa\nbbb\nccc" > "$WORK/grep_n.txt"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "_grep_ps_fallback -n 'bbb' '$WORK/grep_n.txt'" | tr -d '\r')
assert_eq "pwsh/grep -n line number" "2:bbb" "$actual"

# --- grep PS fallback: -r (recursive) ---
echo "[pwsh] grep PS fallback -r"
mkdir -p "$WORK/grepdir/sub"
echo "findme" > "$WORK/grepdir/a.txt"
echo "nope" > "$WORK/grepdir/sub/b.txt"
echo "findme too" > "$WORK/grepdir/sub/c.txt"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "Set-Location '$WORK/grepdir'; _grep_ps_fallback -r 'findme'" | tr -d '\r' | sort)
assert_contains "pwsh/grep -r a.txt" "a.txt" "$actual"
assert_contains "pwsh/grep -r c.txt" "c.txt" "$actual"
rm -rf "$WORK/grepdir"

# --- grep PS fallback: -vi (compound flags) ---
echo "[pwsh] grep PS fallback -vi"
printf "Hello\nworld\nHELLO\n" > "$WORK/grep_vi.txt"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "_grep_ps_fallback -vi 'hello' '$WORK/grep_vi.txt'" | tr -d '\r')
assert_eq "pwsh/grep -vi" "world" "$actual"

# --- find PS fallback: -name + -type combined ---
echo "[pwsh] find PS fallback -name + -type"
setup_fixtures
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "_find_ps_fallback '$WORK/src' -name '*.txt' -type f" | tr -d '\r' | sort)
assert_contains "pwsh/find -name -type f1" "file1.txt" "$actual"
assert_contains "pwsh/find -name -type f3" "file3.txt" "$actual"

# --- grep / find PS fallbacks: [ ] in a path ---
# An operand that exists is that path: [ ] in app/[slug] are not wildcards.
# Read as a wildcard, app/[slug]/page.tsx matched nothing and grep printed
# nothing, with no error, and find '[a]' walked a/ instead. An operand that does
# not exist is still a pattern (a function gets app/*/page.tsx unexpanded), and
# one that matches nothing is reported, as grep and find do.
echo "[pwsh] grep/find PS fallbacks take [ ] in a path literally"
rm -rf "$WORK/fb" && mkdir -p "$WORK/fb/app/[slug]" "$WORK/fb/[a]" "$WORK/fb/a"
echo 'useRouter()' > "$WORK/fb/app/[slug]/page.tsx"
: > "$WORK/fb/[a]/in-brackets.txt"
: > "$WORK/fb/a/in-a.txt"
actual=$(cd "$WORK/fb" && run_pwsh "$WRAPPERS_PS1_STRIPPED" "_grep_ps_fallback useRouter 'app/[slug]/page.tsx'" 2>&1 | tr -d '\r')
assert_eq "pwsh/grep fallback reads app/[slug]/page.tsx" "useRouter()" "$actual"
actual=$(cd "$WORK/fb" && run_pwsh "$WRAPPERS_PS1_STRIPPED" "_grep_ps_fallback useRouter 'app/*/page.tsx'" 2>&1 | tr -d '\r')
assert_eq "pwsh/grep fallback still expands a pattern" "useRouter()" "$actual"
actual=$(cd "$WORK/fb" && run_pwsh "$WRAPPERS_PS1_STRIPPED" "_find_ps_fallback 'app/[slug]' -name '*.tsx'; _find_ps_fallback '[a]'" 2>&1 | tr -d '\r')
assert_eq "pwsh/find fallback walks app/[slug] and [a], not a" "$WORK/fb/app/[slug]/page.tsx
$WORK/fb/[a]/in-brackets.txt" "$actual"
err=$(cd "$WORK/fb" && run_pwsh_stderr "$WRAPPERS_PS1_STRIPPED" "_grep_ps_fallback useRouter 'nomatch*.tsx'")
assert_contains "pwsh/grep fallback reports an operand that matches nothing" "nomatch*.tsx" "$err"
err=$(cd "$WORK/fb" && run_pwsh_stderr "$WRAPPERS_PS1_STRIPPED" "_find_ps_fallback nodir")
assert_contains "pwsh/find fallback reports a start directory that is not there" "nodir" "$err"
rm -rf "$WORK/fb"

# A pattern that stands for two files makes grep name each file, as grep does
# when the shell expands the pattern into both. Counting operands instead, the
# fallback printed the lines of both with no file names, and -c one total.
echo "[pwsh] grep PS fallback names each file a pattern stands for"
rm -rf "$WORK/fm" && mkdir -p "$WORK/fm"
echo 'hit one' > "$WORK/fm/a.txt"
echo 'hit two' > "$WORK/fm/b.txt"
actual=$(cd "$WORK/fm" && run_pwsh "$WRAPPERS_PS1_STRIPPED" "_grep_ps_fallback hit '*.txt'; _grep_ps_fallback -c hit '*.txt'" 2>&1 | tr -d '\r')
assert_eq "pwsh/grep fallback, a pattern for two files: each line and count names its file" "$WORK/fm/a.txt:hit one
$WORK/fm/b.txt:hit two
$WORK/fm/a.txt:1
$WORK/fm/b.txt:1" "$actual"
actual=$(cd "$WORK/fm" && run_pwsh "$WRAPPERS_PS1_STRIPPED" "_grep_ps_fallback hit 'a*.txt'; _grep_ps_fallback -c hit 'a*.txt'" 2>&1 | tr -d '\r')
assert_eq "pwsh/grep fallback, a pattern for one file: no file name" "hit one
1" "$actual"
rm -rf "$WORK/fm"

echo "[pwsh] cat fallback reads stdin (not only file args)"
# Force the PS fallback branch: wrappers OFF skips bat, and an empty PATH means
# no native 'cat' resolves either, so the wrapper falls through to the inline
# 'if ($Args.Count) { Get-Content @Args } else { $input }'. Pre-fix this branch
# was a bare 'Get-Content @Args', which errors with no path instead of passing
# stdin through.
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "\$env:_DEN_WRAPPERS='0'; \$env:PATH=''; 'piped-line' | cat" | tr -d '\r')
assert_eq "pwsh/cat fallback stdin" "piped-line" "$actual"

# Get-ChildItem -Name emits the names as strings, and the ls fallback read .Name
# off them: `ls -Name` printed nothing (a single $null) instead of the names.
# Wrappers OFF and an empty PATH force the fallback, as in the cat case above.
# Objects that do have a .Name (files, another provider's items) still print it.
echo "[pwsh] ls fallback prints the names for -Name"
setup_fixtures
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "\$env:_DEN_WRAPPERS='0'; \$env:PATH=''; ls -Name '$WORK/src'" | tr -d '\r' | sort)
assert_eq "pwsh/ls fallback -Name" "file1.txt
file2.txt
subdir" "$actual"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "\$env:_DEN_WRAPPERS='0'; \$env:PATH=''; ls '$WORK/src'" | tr -d '\r' | sort)
assert_eq "pwsh/ls fallback without -Name" "file1.txt
file2.txt
subdir" "$actual"
actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "\$env:_DEN_WRAPPERS='0'; \$env:PATH=''; ls Function: | Where-Object { \$_ -eq 'lt' }" | tr -d '\r')
assert_eq "pwsh/ls fallback on another provider" "lt" "$actual"

# The lt/llt fallback makes each path relative with [IO.Path]::GetRelativePath,
# which the .NET Framework under Windows PowerShell 5.1 does not have: there it
# stops with one terminating error and lists nothing. The copy of wrappers.ps1
# whose edition check reads "Desktop" stands in for 5.1. With lsd the wrapper
# never reaches the fallback, so lsd (a stub here) still runs there, and on
# pwsh 7 the fallback lists as before.
echo "[pwsh] lt / llt fallback on Windows PowerShell 5.1"
setup_fixtures
for _f in lt llt; do
    err=$(run_pwsh_stderr_oneline "$WRAPPERS_PS1_DESKTOP" "\$env:_DEN_WRAPPERS='0'; Set-Location '$WORK'; $_f 'src'")
    assert_contains "pwsh/$_f on 5.1 says it requires pwsh 7" \
        "$_f: without lsd this requires PowerShell 7+ (pwsh), not Windows PowerShell 5.1" "$err"
    actual=$(run_pwsh "$WRAPPERS_PS1_DESKTOP" "\$env:_DEN_WRAPPERS='0'; Set-Location '$WORK'; $_f 'src'; 'after'" 2>/dev/null | tr -d '\r')
    assert_eq "pwsh/$_f on 5.1 lists nothing and stops" "" "$actual"
    run_pwsh "$WRAPPERS_PS1_DESKTOP" "\$env:_DEN_WRAPPERS='0'; Set-Location '$WORK'; $_f 'src'" >/dev/null 2>&1
    assert_eq "pwsh/$_f on 5.1 exits 1" "1" "$?"
    actual=$(run_pwsh "$WRAPPERS_PS1_STRIPPED" "\$env:_DEN_WRAPPERS='0'; Set-Location '$WORK'; $_f 'src' | Out-String" 2>&1 | tr -d '\r')
    assert_contains "pwsh/$_f fallback on pwsh 7 still lists relative paths" "src/file1.txt" "$actual"
    assert_not_contains "pwsh/$_f fallback on pwsh 7 raises no error" "requires PowerShell 7+" "$actual"
done
mkdir -p "$WORK/lsdstub"
printf '#!/bin/sh\necho "stub lsd $*"\n' > "$WORK/lsdstub/lsd"
chmod +x "$WORK/lsdstub/lsd"
actual=$(PATH="$WORK/lsdstub:$PATH" run_pwsh "$WRAPPERS_PS1_DESKTOP" "\$env:_DEN_WRAPPERS='1'; \$env:_DEN_WRAPPER_LOG='0'; lt 'src'" 2>&1 | tr -d '\r')
assert_eq "pwsh/lt on 5.1 with lsd still runs lsd" "stub lsd --tree src" "$actual"

# =============================================================================
# Where the wrappers run the modern tool (stand-in modern tools)
# =============================================================================
# Typed at the prompt, a wrapper named after its native command (ls, cat,
# grep, find) runs the modern tool; in a function (a user's own included) or a
# sourced file it runs the native command that code was written for, as
# builtin cd replaces den's zoxide cd there. eval, $(...), `again` (stubbed here) and `snippet run` / `snippet
# pick` at the prompt count as typed; `bash -c` / `zsh -c` count as the prompt. The modern stand-ins print their
# name and arguments. den's own names (la, ll, lla, lt, llt, ripgrep) and the
# w names mean nothing else, so they always run the modern tool.
echo ""
echo "================================================"
echo "  Testing where the wrappers run the modern tool"
echo "================================================"
printf 'apple\nbanana\n' > "$WORK/typed.txt"
printf '%s\n' "grep banana typed.txt" "ls -d ." > "$WORK/typed_src.sh"
# snippet.sh with a store of one snippet, and an fzf stand-in that picks the
# first line.
SNIPPET_SH="$DOTFILES/shell/posix/snippet.sh"
SNIP_BIN="$TESTTMP/snipbin"
mkdir -p "$SNIP_BIN" "$WORK/snipcfg/den"
printf '#!/bin/sh\nhead -n 1\n' > "$SNIP_BIN/fzf"
chmod +x "$SNIP_BIN/fzf"
printf 'g\tgrep banana typed.txt\n' > "$WORK/snipcfg/den/snippets"
for _sh in bash zsh; do
    _run="run_${_sh}_i"
    echo "[$_sh] typed at the prompt: the modern tool, also through eval, \$(...) and again"
    actual=$(PATH="$MODERN_STANDINS:$PATH" _DEN_WRAPPER_LOG=0 "$_run" "$WRAPPERS_SH" "cd '$WORK'; grep banana typed.txt; eval 'cat typed.txt'; x=\$(find .); echo \"\$x\"; again() { eval \"\$1\"; }; again 'ls -d .'")
    assert_eq "$_sh/typed: rg, bat, fd, lsd" "modern rg banana typed.txt
modern bat --style=plain --paging=never typed.txt
modern fd .
modern lsd -d ." "$actual"

    echo "[$_sh] in a function or a sourced file: the native command"
    actual=$(PATH="$MODERN_STANDINS:$PATH" _DEN_WRAPPER_LOG=0 "$_run" "$WRAPPERS_SH" "cd '$WORK'; f() { grep banana typed.txt; cat typed.txt; ls -d .; find typed.txt; }; f; . ./typed_src.sh; again() { eval \"\$1\"; }; g() { again 'grep apple typed.txt'; }; g")
    assert_eq "$_sh/function, sourced file, again in a function: native" "banana
apple
banana
.
typed.txt
banana
.
apple" "$actual"

    echo "[$_sh] snippet run and pick at the prompt count as typed; in a function they do not"
    actual=$(PATH="$SNIP_BIN:$MODERN_STANDINS:$PATH" XDG_CONFIG_HOME="$WORK/snipcfg" _DEN_WRAPPER_LOG=0 "$_run" "$WRAPPERS_SH" ". '$SNIPPET_SH'; cd '$WORK'; snippet run g; snippet pick; f() { snippet run g; }; f")
    assert_eq "$_sh/snippet run, pick: modern; in a function: native" "modern rg banana typed.txt
modern rg banana typed.txt
banana" "$actual"

    echo "[$_sh] in a function, den's own names and the w names stay modern"
    actual=$(PATH="$MODERN_STANDINS:$PATH" _DEN_WRAPPER_LOG=0 "$_run" "$WRAPPERS_SH" "f() { la a; ll b; lla c; lt x; llt v; ripgrep y; grepw z; lsw w; }; f")
    assert_eq "$_sh/function: la, ll, lla, lt, llt, ripgrep, grepw, lsw modern" "modern lsd -a a
modern lsd -l b
modern lsd -la c
modern lsd --tree x
modern lsd -l --tree v
modern rg y
modern rg z
modern lsd w" "$actual"
done

# =============================================================================
# File names that read as options (typed cat, find, grep: bat, fd, rg)
# =============================================================================
# Typed at the prompt, cat, find and grep run bat, fd and rg, and a glob such
# as * puts the names of the files it matches among their arguments. Those
# tools read a word that starts with - as an option, and some of their options
# run a program: `grep needle *` beside a file named --pre=sh ran
# `rg needle --pre=sh data.txt`, and rg ran sh on every file it searched; fd
# -x / -X (in any spelling) ran a program on what it found, and bat --pager
# with a later --paging=always piped the files into one. A wrapper cannot tell
# a typed word from a glob's, so it runs nothing when an argument starts with
# - and names a file. pwsh expands a wildcard typed without quotes for a native
# command itself on Linux and macOS (./* to bare names), after the wrapper has
# seen it, so the pwsh wrappers look the names up as pwsh will; a quoted one
# reaches the tool as it is (see the words a wrapper hands its tool, below).
# The stand-ins
# log each run; each case is a fresh directory holding data.txt and the
# given files.
echo ""
echo "================================================"
echo "  Testing file names that read as options"
echo "================================================"
OPT_BIN="$TESTTMP/opt-bin"
OPT_LOG="$TESTTMP/opt-ran.log"
mkdir -p "$OPT_BIN" || abort_suite "cannot create $OPT_BIN"
for _t in bat fd rg; do
    cat > "$OPT_BIN/$_t" <<EOF || abort_suite "cannot write $OPT_BIN/$_t"
#!/bin/sh
echo "$_t \$*" >> '$OPT_LOG'
EOF
    chmod +x "$OPT_BIN/$_t"
done

# opt_tree <dir> <name>... - a fresh $WORK/opt/<dir> with data.txt and an empty
# file of each <name>.
opt_tree() {
    local d="$WORK/opt/$1" n
    shift
    rm -rf "$d" && mkdir -p "$d" && echo 'needle here' > "$d/data.txt" || return 1
    for n in "$@"; do : > "$d/$n" || return 1; done
}

# opt_ran → what the stand-ins logged since the last reset, on one line.
opt_ran() {
    if [ -e "$OPT_LOG" ]; then echo "ran: $(paste -sd '|' "$OPT_LOG")"; else echo "ran: no"; fi
}

# One case per tool and spelling: <call> | <tool> | <file names>.
OPT_CASES="grep needle *|rg|--pre=sh
grep needle *|rg|--pre sh
grep needle *|rg|--hostname-bin=sh
find *|fd|--exec=sh
find *|fd|-xsh
find *|fd|-Xsh
find *|fd|--exec-batch=sh
find *|fd|-x sh
find *|fd|-HIxsh
cat *|bat|--pager=sh --paging=always"

for _sh in bash zsh; do
    _run="run_${_sh}_i"
    echo "[$_sh] typed grep, find, cat with a glob beside a file named like an option: the tool does not run"
    while IFS='|' read -r _call _tool _names; do
        # shellcheck disable=SC2086 # the names are words
        opt_tree case $_names || abort_suite "cannot make the tree for $_names"
        rm -f "$OPT_LOG"
        actual=$(PATH="$OPT_BIN:$PATH" _DEN_WRAPPER_LOG=0 "$_run" "$WRAPPERS_SH" "cd '$WORK/opt/case'; $_call 2>&1; echo \"rc=\$?\"" < /dev/null)
        got="$(grep -o "$_tool did not run" <<< "$actual" | head -n 1); $(grep -o 'rc=[0-9]*' <<< "$actual"); $(opt_ran)"
        assert_eq "$_sh/typed $_call beside $_names: $_tool does not run" "$_tool did not run; rc=2; ran: no" "$got"
    done <<< "$OPT_CASES"

    echo "[$_sh] the message names the file, ./, and the native command"
    opt_tree msg --pre=sh || abort_suite "cannot make the tree for the message"
    rm -f "$OPT_LOG"
    actual=$(PATH="$OPT_BIN:$PATH" _DEN_WRAPPER_LOG=0 "$_run" "$WRAPPERS_SH" "cd '$WORK/opt/msg'; grep needle * 2>&1; echo \"rc=\$?\"")
    assert_eq "$_sh/the refusal of grep needle *" "grep: '--pre=sh' names a file, and rg would read it as an option: rg did not run.
grep: write it as ./--pre=sh (a glob as ./*), or run the native grep: command grep
rc=2" "$actual"

    echo "[$_sh] a dangling symlink named like an option counts too"
    opt_tree link || abort_suite "cannot make the tree for the symlink"
    ln -s "$WORK/opt/nowhere" "$WORK/opt/link/--pre=sh" || abort_suite "cannot make the symlink"
    rm -f "$OPT_LOG"
    actual=$(PATH="$OPT_BIN:$PATH" _DEN_WRAPPER_LOG=0 "$_run" "$WRAPPERS_SH" "cd '$WORK/opt/link'; grep needle * 2>&1; echo \"rc=\$?\"")
    got="$(grep -o 'rg did not run' <<< "$actual" | head -n 1); $(grep -o 'rc=[0-9]*' <<< "$actual"); $(opt_ran)"
    assert_eq "$_sh/grep needle * beside a dangling --pre=sh symlink" "rg did not run; rc=2; ran: no" "$got"

    echo "[$_sh] typed use without such a file name runs the tool as before"
    opt_tree ok - || abort_suite "cannot make the tree for the controls"
    rm -f "$OPT_LOG"
    PATH="$OPT_BIN:$PATH" _DEN_WRAPPER_LOG=0 "$_run" "$WRAPPERS_SH" "cd '$WORK/opt/ok'; grep -rn foo .; find -e py; cat data.txt; cat - </dev/null; grep needle *" >/dev/null
    assert_eq "$_sh/grep -rn, find -e, cat file, cat -, grep with a glob: the tool runs" "ran: rg -rn foo .|fd -e py|bat --style=plain --paging=never data.txt|bat --style=plain --paging=never -|rg needle - data.txt" "$(opt_ran)"
    opt_tree dash --pre=sh || abort_suite "cannot make the tree for the controls"
    rm -f "$OPT_LOG"
    PATH="$OPT_BIN:$PATH" _DEN_WRAPPER_LOG=0 "$_run" "$WRAPPERS_SH" "cd '$WORK/opt/dash'; grep needle data.txt; grep needle ./*" >/dev/null
    actual=$(opt_ran)
    assert_contains "$_sh/beside --pre=sh, grep needle data.txt runs rg" "ran: rg needle data.txt|" "$actual"
    assert_contains "$_sh/beside --pre=sh, grep needle ./* runs rg on ./--pre=sh" "./--pre=sh" "$actual"
done

echo "[bash/zsh] _wrap_optfile: names test(1) reads as operators, a dangling symlink, and - alone"
opt_tree edge -e -o -a -n -L - || abort_suite "cannot make the tree for the edge names"
ln -s "$WORK/opt/nowhere" "$WORK/opt/edge/-d" || abort_suite "cannot make the symlink"
mkdir -p "$WORK/opt/empty"
# shellcheck disable=SC2016 # the shells under test expand it
EDGE_CALL='for n in -e -o -a -n -L -d - -q; do _wrap_optfile x t "$n" 2>/dev/null; printf "%s=%s " "$n" "$?"; done'
for _sh in bash zsh; do
    actual=$("run_$_sh" "$HELPERS_SH" "cd '$WORK/opt/edge' && $EDGE_CALL")
    assert_eq "$_sh/_wrap_optfile beside those files" "-e=1 -o=1 -a=1 -n=1 -L=1 -d=1 -=0 -q=0 " "$actual"
    actual=$("run_$_sh" "$HELPERS_SH" "cd '$WORK/opt/empty' && $EDGE_CALL")
    assert_eq "$_sh/_wrap_optfile in an empty directory" "-e=0 -o=0 -a=0 -n=0 -L=0 -d=0 -=0 -q=0 " "$actual"
done

echo "[pwsh] typed grep, find, cat with a wildcard beside a file named like an option: the tool does not run"
# Each case is a directory of its own, made here; the pwsh session goes through
# them in order and prints one line for each.
_i=0
OPT_PWSH_DIRS=()
while IFS='|' read -r _call _tool _names; do
    _i=$((_i + 1))
    # shellcheck disable=SC2086 # the names are words
    opt_tree "p$_i" $_names || abort_suite "cannot make the tree for $_names"
    OPT_PWSH_DIRS+=("$_call|$WORK/opt/p$_i")
done <<< "$OPT_CASES"
for _d in pq pn pc; do opt_tree "$_d" --pre=sh || abort_suite "cannot make the pwsh trees"; done
opt_tree pok || abort_suite "cannot make the pwsh trees"
OPT_PWSH_CASES=""
for _c in "${OPT_PWSH_DIRS[@]}"; do
    OPT_PWSH_CASES+="Test-Opt '${_c#*|}' { ${_c%%|*} }
"
done
OPT_PWSH_CASES+="Test-Opt '$WORK/opt/pq' { grep needle '*' }
Test-Opt '$WORK/opt/pn' { grep needle (Get-ChildItem -Name) }
Test-Opt '$WORK/opt/pc' { grep needle data.txt }
Test-Opt '$WORK/opt/pc' { grep needle \$PWD/--pre* }
Test-Opt '$WORK/opt/pc' { Set-Location Env:; grep needle '--pre=sh' data.txt }
Test-Opt '$WORK/opt/pok' { grep -rn foo . }
Test-Opt '$WORK/opt/pok' { find -e py }
Test-Opt '$WORK/opt/pok' { cat data.txt }
"
# Test-Opt <dir> <call> - run <call> in <dir>: 'refused' or 'ran', and what the
# stand-ins logged.
OPT_PWSH_FN="
    \$env:_DEN_WRAPPER_LOG = '0'
    function Test-Opt([string]\$Dir, [scriptblock]\$Call) {
        Set-Location -LiteralPath \$Dir
        Remove-Item -LiteralPath '$OPT_LOG' -ErrorAction SilentlyContinue
        \$r = try { \$null = & \$Call 2>&1; 'ran' } catch {
            if (\$_.Exception.Message -like '* did not run. *') { 'refused' } else { 'error: ' + \$_.Exception.Message }
        }
        \$log = if (Test-Path -LiteralPath '$OPT_LOG') { (Get-Content -LiteralPath '$OPT_LOG') -join '|' } else { 'no' }
        \"\$r; ran: \$log\"
    }"
actual=$(PATH="$OPT_BIN:$PATH" run_pwsh "$WRAPPERS_PS1_STRIPPED" "$OPT_PWSH_FN
    $OPT_PWSH_CASES
" < /dev/null 2>&1 | tr -d '\r')
# One label and one expected line per Test-Opt line above, in order.
OPT_PWSH_WANT=()
while IFS='|' read -r _call _tool _names; do
    OPT_PWSH_WANT+=("typed $_call beside $_names: $_tool does not run|refused; ran: no")
done <<< "$OPT_CASES"
OPT_PWSH_WANT+=(
    "grep needle '*' (quoted, so not expanded) beside --pre=sh runs rg on the word *|ran; ran: rg needle *"
    "grep needle (Get-ChildItem -Name) beside --pre=sh: rg does not run|refused; ran: no"
    "beside --pre=sh, grep needle data.txt runs rg|ran; ran: rg needle data.txt"
    "beside --pre=sh, a full path (\$PWD/--pre*) runs rg on it|ran; ran: rg needle $WORK/opt/pc/--pre=sh"
    "on the Env: drive, grep needle '--pre=sh' beside that file in the folder rg runs in: rg does not run|refused; ran: no"
    "grep -rn foo . runs rg|ran; ran: rg -rn foo ."
    "find -e py runs fd|ran; ran: fd -e py"
    "cat data.txt runs bat with a last --paging=never|ran; ran: bat --style=plain --paging=never data.txt --paging=never"
)
mapfile -t _got <<< "$actual"
assert_eq "pwsh/one line per case" "${#OPT_PWSH_WANT[@]}" "${#_got[@]}"
for _i in "${!OPT_PWSH_WANT[@]}"; do
    _w=${OPT_PWSH_WANT[$_i]}
    assert_eq "pwsh/${_w%%|*}" "${_w#*|}" "${_got[$_i]-}"
done

echo "[pwsh] the message names the wildcard, the file and the ways that work"
err=$(cd "$WORK/opt/pc" && PATH="$OPT_BIN:$PATH" run_pwsh_stderr_oneline "$WRAPPERS_PS1_STRIPPED" "\$env:_DEN_WRAPPER_LOG = '0'; grep needle *")
assert_eq "pwsh/the refusal of grep needle *" "grep: '*' stands for the file '--pre=sh', which rg would read as an option: rg did not run. Write the wildcard with a full path (\$PWD/*), or run the native grep with the wrappers off (tgl-wr)." "$err"

echo "[pwsh, Windows] cat expands a wildcard for bat itself and refuses a match named like an option"
# On Windows pwsh expands no wildcard, and bat expands each word that holds
# * ? [ or ] itself, one word at a time: `cat ???* *` beside files named --,
# --pager=sh and --paging=always gave bat the pager options from the first
# word and a -- from the second, which made the last --paging=never a file
# name. There cat refuses a match whose name starts with -, and hands bat the
# names a word matches (a full path for a rooted word or a name that holds [
# or ]), or the word made a full path when it matches none. An _OnWindows
# that says true stands in for Windows; the stand-in bat logs what it got.
opt_tree w4 -- --pager=sh --paging=always notes.txt || abort_suite "cannot make the tree for the Windows cases"
opt_tree wok 'b[1].txt' || abort_suite "cannot make the tree for the Windows cases"
actual=$(PATH="$OPT_BIN:$PATH" run_pwsh "$WRAPPERS_PS1_STRIPPED" "$OPT_PWSH_FN
    function global:_OnWindows { \$true }
    Test-Opt '$WORK/opt/w4' { cat ???* * }
    Test-Opt '$WORK/opt/w4' { cat * }
    Test-Opt '$WORK/opt/w4' { cat \$PWD/--pagi* }
    Test-Opt '$WORK/opt/wok' { cat da* }
    Test-Opt '$WORK/opt/wok' { cat b* }
    Test-Opt '$WORK/opt/wok' { cat no*match }
    Test-Opt '$WORK/opt/wok' { cat data.txt - }
" < /dev/null 2>&1 | tr -d '\r')
OPT_WIN_WANT=(
    "cat ???* * beside --, --pager=sh, --paging=always: bat does not run|refused; ran: no"
    "cat * beside them: bat does not run|refused; ran: no"
    "a full path (\$PWD/--pagi*) gets the full path of the match|ran; ran: bat --style=plain --paging=never $WORK/opt/w4/--paging=always --paging=never"
    "da* gets the name it matches|ran; ran: bat --style=plain --paging=never data.txt --paging=never"
    "b* gets the full path of b[1].txt|ran; ran: bat --style=plain --paging=never $WORK/opt/wok/b[1].txt --paging=never"
    "a wildcard that matches nothing goes on as a full path|ran; ran: bat --style=plain --paging=never $WORK/opt/wok/no*match --paging=never"
    "data.txt and - go on as they are|ran; ran: bat --style=plain --paging=never data.txt - --paging=never"
)
mapfile -t _got <<< "$actual"
assert_eq "pwsh, Windows/one line per case" "${#OPT_WIN_WANT[@]}" "${#_got[@]}"
for _i in "${!OPT_WIN_WANT[@]}"; do
    _w=${OPT_WIN_WANT[$_i]}
    assert_eq "pwsh, Windows/${_w%%|*}" "${_w#*|}" "${_got[$_i]-}"
done

echo "[pwsh, Windows] cat refuses an option or an option's value that holds a wildcard"
# bat expands an option or an option's value too, and pwsh hands it on
# unquoted; cat expanded it as a file operand, which made an option a path:
# `cat '--file-name=*.py' -` gave bat <cwd>/--file-name=*.py as a file, and
# `cat -l '*' x` gave it a file name as the language. So cat runs nothing
# when a word that starts with - holds * ? [ or ], or the value of an option
# that takes it from the next word does (bat --help: --map-syntax, -l, -H,
# a cluster ending in -l). An option or a value without them goes on as it
# is, and a wildcard after an option's value is a file operand. A quoted --
# is refused before any of this (see the next block).
opt_tree wopt a.h || abort_suite "cannot make the tree for the Windows option cases"
actual=$(PATH="$OPT_BIN:$PATH" run_pwsh "$WRAPPERS_PS1_STRIPPED" "$OPT_PWSH_FN
    function global:_OnWindows { \$true }
    Test-Opt '$WORK/opt/wopt' { cat '--file-name=*.py' - }
    Test-Opt '$WORK/opt/wopt' { cat --map-syntax '*.h:C++' data.txt }
    Test-Opt '$WORK/opt/wopt' { cat -l '*' data.txt }
    Test-Opt '$WORK/opt/wopt' { cat -pl '*' data.txt }
    Test-Opt '$WORK/opt/wopt' { cat -H '[1]' data.txt }
    Test-Opt '$WORK/opt/wopt' { cat --file-name=x.py - }
    Test-Opt '$WORK/opt/wopt' { cat --map-syntax '.h:C++' -l rust da* }
    Test-Opt '$WORK/opt/wopt' { cat -lrust -n da* }
    Test-Opt '$WORK/opt/wopt' { cat '--' '-x*' }
" < /dev/null 2>&1 | tr -d '\r')
OPT_WINOPT_WANT=(
    "cat '--file-name=*.py' -: bat does not run|refused; ran: no"
    "cat --map-syntax '*.h:C++' data.txt: bat does not run|refused; ran: no"
    "cat -l '*' data.txt: bat does not run|refused; ran: no"
    "cat -pl '*' data.txt: bat does not run|refused; ran: no"
    "cat -H '[1]' data.txt: bat does not run|refused; ran: no"
    "--file-name=x.py goes on as it is|ran; ran: bat --style=plain --paging=never --file-name=x.py - --paging=never"
    "values without a wildcard go on as they are, and da* after them is a file|ran; ran: bat --style=plain --paging=never --map-syntax .h:C++ -l rust data.txt --paging=never"
    "-lrust holds its value, so da* is a file|ran; ran: bat --style=plain --paging=never -lrust -n data.txt --paging=never"
    "a quoted -- before a wildcard: bat does not run|refused; ran: no"
)
mapfile -t _got <<< "$actual"
assert_eq "pwsh, Windows/one line per option case" "${#OPT_WINOPT_WANT[@]}" "${#_got[@]}"
for _i in "${!OPT_WINOPT_WANT[@]}"; do
    _w=${OPT_WINOPT_WANT[$_i]}
    assert_eq "pwsh, Windows/${_w%%|*}" "${_w#*|}" "${_got[$_i]-}"
done

echo "[pwsh, Windows] the message names the word, the option and bat or catw"
err=$(cd "$WORK/opt/wopt" && PATH="$OPT_BIN:$PATH" run_pwsh_stderr_oneline "$WRAPPERS_PS1_STRIPPED" "\$env:_DEN_WRAPPER_LOG = '0'; function global:_OnWindows { \$true }; cat '--file-name=*.py' -" < /dev/null)
assert_eq "pwsh, Windows/the refusal of cat '--file-name=*.py' -" "cat: '--file-name=*.py' is an option that holds * ? [ or ], which bat would expand as a wildcard on Windows: bat did not run. Run bat or catw by name for it." "$err"
err=$(cd "$WORK/opt/wopt" && PATH="$OPT_BIN:$PATH" run_pwsh_stderr_oneline "$WRAPPERS_PS1_STRIPPED" "\$env:_DEN_WRAPPER_LOG = '0'; function global:_OnWindows { \$true }; cat -l '*' data.txt" < /dev/null)
assert_eq "pwsh, Windows/the refusal of cat -l '*' data.txt" "cat: '*', the value of -l, holds * ? [ or ], which bat would expand as a wildcard on Windows: bat did not run. Run bat or catw by name for it." "$err"

echo "[pwsh] cat refuses a -- that reaches it, on every system"
# cat hands bat a last --paging=never after the arguments, and after a -- bat
# reads every word as a file name, that one too. pwsh drops a bare -- typed to
# a function, but a quoted '--', a second --, or one in a variable or an array
# reaches cat, and it reached bat. So cat refuses each, here as on Windows
# (above), as cmd's cat does; a bare -- still runs bat, without it.
opt_tree pdd || abort_suite "cannot make the tree for the -- cases"
actual=$(PATH="$OPT_BIN:$PATH" run_pwsh "$WRAPPERS_PS1_STRIPPED" "$OPT_PWSH_FN
    Test-Opt '$WORK/opt/pdd' { cat '--' data.txt }
    Test-Opt '$WORK/opt/pdd' { cat -- -- data.txt }
    Test-Opt '$WORK/opt/pdd' { \$d = '--'; cat \$d data.txt }
    Test-Opt '$WORK/opt/pdd' { cat data.txt @('-n', '--') }
    Test-Opt '$WORK/opt/pdd' { cat -- data.txt }
" < /dev/null 2>&1 | tr -d '\r')
OPT_DD_WANT=(
    "cat '--' data.txt: bat does not run|refused; ran: no"
    "cat -- -- data.txt (pwsh drops the first): bat does not run|refused; ran: no"
    "cat \$d data.txt, \$d = '--': bat does not run|refused; ran: no"
    "cat data.txt @('-n', '--'): bat does not run|refused; ran: no"
    "a bare -- is pwsh's, and bat runs without it|ran; ran: bat --style=plain --paging=never data.txt --paging=never"
)
mapfile -t _got <<< "$actual"
assert_eq "pwsh/one line per -- case" "${#OPT_DD_WANT[@]}" "${#_got[@]}"
for _i in "${!OPT_DD_WANT[@]}"; do
    _w=${OPT_DD_WANT[$_i]}
    assert_eq "pwsh/${_w%%|*}" "${_w#*|}" "${_got[$_i]-}"
done
err=$(cd "$WORK/opt/pdd" && PATH="$OPT_BIN:$PATH" run_pwsh_stderr_oneline "$WRAPPERS_PS1_STRIPPED" "\$env:_DEN_WRAPPER_LOG = '0'; cat '--' data.txt" < /dev/null)
assert_eq "pwsh/the refusal of cat '--' data.txt" "cat: '--' would make bat read den's last --paging=never as a file name: bat did not run. Write a file whose name starts with - as ./-name instead, or run bat or catw by name." "$err"
unset _sh _run _call _tool _names _i _c _d _w _got

# =============================================================================
# PowerShell: the words a wrapper hands its tool
# =============================================================================
# On Linux and macOS pwsh expands a wildcard (* ? [ ]) and a leading ~ in an
# argument of a program unless the code that calls the program writes it in
# quotes, and the wrappers handed the tool their arguments as @__a: every word
# was expanded, so `grep 'foo*' x` beside foo1 and foo2 had rg search the files
# foo2 and x for foo1. A word quoted at the prompt, or one from a variable,
# now reaches the tool as it is; one typed without quotes is still expanded,
# as for the tool typed by name. -c:v, which reaches $args as -c: and v and
# which @__a handed on as v alone, goes as one word. The stand-ins log one
# line per call, each argument in [ ].
echo ""
echo "================================================"
echo "  Testing the words a pwsh wrapper hands its tool"
echo "================================================"
G6_BIN="$TESTTMP/g6-bin"
G6_NATIVE_BIN="$TESTTMP/g6-native-bin"
G6_LOG="$TESTTMP/g6.log"
mkdir -p "$G6_BIN" "$G6_NATIVE_BIN" || abort_suite "cannot create $G6_BIN"
# g6_stub <path> <name> - a stand-in that logs <name> and its arguments, after
# it has read what was piped in.
g6_stub() {
    cat > "$1" <<EOF || return 1
#!/bin/sh
cat > /dev/null
{ printf '%s' '$2'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> '$G6_LOG'
EOF
    chmod +x "$1"
}
for _t in bat fd rg lsd; do g6_stub "$G6_BIN/$_t" "$_t" || abort_suite "cannot write $G6_BIN/$_t"; done
g6_stub "$G6_NATIVE_BIN/grep" grep || abort_suite "cannot write $G6_NATIVE_BIN/grep"
rm -rf "$WORK/g6" && mkdir -p "$WORK/g6" && : > "$WORK/g6/foo1" && : > "$WORK/g6/foo2" && : > "$WORK/g6/x" ||
    abort_suite "cannot make $WORK/g6"

echo "[pwsh] a quoted wildcard reaches each wrapper's tool as it is; one typed bare is expanded"
rm -f "$G6_LOG"
PATH="$G6_BIN:$PATH" run_pwsh "$WRAPPERS_PS1_STRIPPED" "
    \$env:_DEN_WRAPPER_LOG = '0'
    Set-Location -LiteralPath '$WORK/g6'
    grep 'foo*' x
    grep \"foo?\" x
    find 'foo[12]'
    cat 'foo*'
    ls 'foo?'
    la 'foo*'
    ll 'foo*'
    lla 'foo*'
    lt 'foo*'
    llt 'foo*'
    ripgrep 'foo*'
    grepw 'foo*'
    findw 'foo?'
    catw 'foo[12]'
    lsw 'foo*'
    grep '~/foo' x
    \$p = 'foo*'; grep \$p x
    \$s = @('foo?', 'x'); grep @s
    grep -c:v x
    'piped' | grep 'foo*'
    grep needle foo*
    grep needle foo?
    ls ~
" > /dev/null 2>&1 < /dev/null
G6_WANT=(
    "grep 'foo*' x|rg [foo*] [x]"
    "grep \"foo?\" x|rg [foo?] [x]"
    "find 'foo[12]'|fd [foo[12]]"
    "cat 'foo*'|bat [--style=plain] [--paging=never] [foo*] [--paging=never]"
    "ls 'foo?'|lsd [foo?]"
    "la 'foo*'|lsd [-a] [foo*]"
    "ll 'foo*'|lsd [-l] [foo*]"
    "lla 'foo*'|lsd [-la] [foo*]"
    "lt 'foo*'|lsd [--tree] [foo*]"
    "llt 'foo*'|lsd [-l] [--tree] [foo*]"
    "ripgrep 'foo*'|rg [foo*]"
    "grepw 'foo*'|rg [foo*]"
    "findw 'foo?'|fd [foo?]"
    "catw 'foo[12]'|bat [--style=plain] [--paging=never] [foo[12]]"
    "lsw 'foo*'|lsd [foo*]"
    "grep '~/foo' x (a quoted ~)|rg [~/foo] [x]"
    "grep \$p x, \$p = 'foo*'|rg [foo*] [x]"
    "grep @s, \$s = @('foo?', 'x')|rg [foo?] [x]"
    "grep -c:v x (one word, as typed)|rg [-c:v] [x]"
    "grep 'foo*' with input piped in|rg [foo*]"
    "grep needle foo* (bare: expanded)|rg [needle] [foo1] [foo2]"
    "grep needle foo? (bare: expanded)|rg [needle] [foo1] [foo2]"
    "ls ~ (bare: the home folder)|lsd [$HOME]"
)
mapfile -t _got < <(cat "$G6_LOG" 2>/dev/null)
assert_eq "pwsh/one tool call per wrapper call" "${#G6_WANT[@]}" "${#_got[@]}"
for _i in "${!G6_WANT[@]}"; do
    _w=${G6_WANT[$_i]}
    assert_eq "pwsh/${_w%%|*}" "${_w#*|}" "${_got[$_i]-}"
done

echo "[pwsh] the native tier: a quoted wildcard reaches grep as it is; one typed bare is expanded"
rm -f "$G6_LOG"
PATH="$G6_NATIVE_BIN:$PATH" run_pwsh "$WRAPPERS_PS1_STRIPPED" "
    \$env:_DEN_WRAPPER_LOG = '0'
    Set-Location -LiteralPath '$WORK/g6'
    grep 'foo*' x
    grep needle foo*
" > /dev/null 2>&1 < /dev/null
actual=$(cat "$G6_LOG" 2>/dev/null)
assert_eq "pwsh/native grep gets 'foo*' as it is, and foo* expanded" "grep [--color=auto] [foo*] [x]
grep [--color=auto] [needle] [foo1] [foo2]" "$actual"
rm -rf "$WORK/g6"

# =============================================================================
# PowerShell on Windows: find with input piped in is Windows' find.exe
# =============================================================================
# Typed at the prompt, find is den's wrapper, which runs fd, and fd reads no
# input: `netstat -ano | find "8080"` printed nothing and succeeded. cmd's typed
# find is find.exe (owner decision 13); pwsh's now hands a call with input piped
# in to find.exe too, on Windows only, with the text to look for in the double
# quotes find.exe needs (pwsh drops the ones typed). _OnWindows says true here,
# and a stand-in find.exe under $env:SystemRoot/System32 logs its arguments
# and what reached it. On pwsh's Linux, find.exe gets its arguments as they are
# (pwsh's Standard passing); on Windows pwsh passes them in its Legacy way,
# which keeps those quotes on the command line.
echo ""
echo "[pwsh, Windows] find with input piped in runs find.exe; without, fd"
mkdir -p "$WORK/winroot/System32" || abort_suite "cannot create $WORK/winroot"
cat > "$WORK/winroot/System32/find.exe" <<EOF || abort_suite "cannot write the find.exe stand-in"
#!/bin/sh
{ printf 'find.exe'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; while IFS= read -r l; do printf 'in: %s\n' "\$l"; done; } >> '$G6_LOG'
EOF
chmod +x "$WORK/winroot/System32/find.exe"
rm -f "$G6_LOG"
PATH="$G6_BIN:$PATH" run_pwsh "$WRAPPERS_PS1_STRIPPED" "
    \$env:_DEN_WRAPPER_LOG = '0'
    'tcp 8080', 'udp 53' | find 8080
    function global:_OnWindows { \$true }
    \$env:SystemRoot = '$WORK/winroot'
    'tcp 8080', 'udp 53' | find \"8080\"
    'x' | find /i /c 'a\"b'
    'y' | find '\"q\"'
    find 8080
    \$env:_DEN_WRAPPERS = '0'
    'z 8080' | find 8080
" > /dev/null 2>&1 < /dev/null
actual=$(cat "$G6_LOG" 2>/dev/null)
assert_eq "pwsh/find with input: fd on Linux, find.exe on Windows (wrappers on or off), fd without input" "fd [8080]
find.exe [\"8080\"]
in: tcp 8080
in: udp 53
find.exe [/i] [/c] [\"a\"\"b\"]
in: x
find.exe [\"q\"]
in: y
fd [8080]
find.exe [\"8080\"]
in: z 8080" "$actual"
rm -rf "$WORK/winroot"

unset _t _i _w _got

# =============================================================================
# Wrapper notice of the real wrappers (stub modern tools)
# =============================================================================
# The fallback tests above run without the modern tools; here stub lsd/bat on
# PATH make the real wrappers take the modern branch, so the notice they print
# (with each wrapper's own fallback flags) is compared as a whole line, and the
# docs must quote exactly that line.
echo ""
echo "================================================"
echo "  Testing the wrapper notice (stub lsd/bat)"
echo "================================================"

STUB_BIN="$WORK/stubbin"
mkdir -p "$STUB_BIN"
for _t in lsd bat; do
    printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/$_t"
    chmod +x "$STUB_BIN/$_t"
done

# Keep only the notice lines of stderr, color codes stripped: an interactive
# shell without a terminal also prints job control warnings there. zsh -f skips
# ~/.zshrc, as --norc does for bash.
run_bash_i_notice() {
    PATH="$STUB_BIN:$PATH" bash --norc -ic "source '$HELPERS_SH' && source '$1' && $2" 2>&1 >/dev/null </dev/null |
        sed 's/\x1b\[[0-9;]*m//g' | grep '^\[den\]'
}

run_zsh_i_notice() {
    PATH="$STUB_BIN:$PATH" zsh -f -ic "source '$HELPERS_SH' && source '$1' && $2" 2>&1 >/dev/null </dev/null |
        sed 's/\x1b\[[0-9;]*m//g' | grep '^\[den\]'
}

LS_NOTICE="[den] ls -> lsd  (native: command ls, off: tgl-wr)"
LS_NOTICE_PWSH="[den] ls -> lsd  (off: tgl-wr)"

for _sh in bash zsh; do
    _run="run_${_sh}_i_notice"
    echo "[$_sh] real wrappers print their own fallback in the notice"
    actual=$("$_run" "$WRAPPERS_SH" "ls >/dev/null")
    assert_eq "$_sh/notice ls" "$LS_NOTICE" "$actual"
    actual=$("$_run" "$WRAPPERS_SH" "la >/dev/null")
    assert_eq "$_sh/notice la" "[den] la -> lsd  (native: command ls -A, off: tgl-wr)" "$actual"
    actual=$("$_run" "$WRAPPERS_SH" "cat /dev/null")
    assert_eq "$_sh/notice cat" "[den] cat -> bat  (native: command cat, off: tgl-wr)" "$actual"
    actual=$("$_run" "$WRAPPERS_SH" "lt >/dev/null")
    assert_eq "$_sh/notice lt (no native)" "[den] lt -> lsd  (off: tgl-wr)" "$actual"

    echo "[$_sh] w-suffix names print no notice"
    actual=$("$_run" "$WRAPPERS_SH" "lsw >/dev/null; catw /dev/null")
    assert_eq "$_sh/notice none for lsw catw" "" "$actual"

    echo "[$_sh] a wrapper a function runs prints no notice (it runs the native command)"
    actual=$("$_run" "$WRAPPERS_SH" "f() { ls >/dev/null; cat /dev/null; }; f")
    assert_eq "$_sh/notice none for ls cat in a function" "" "$actual"
done

echo "[pwsh] real wrappers print the notice; w-suffix names do not"
actual=$(PATH="$STUB_BIN:$PATH" run_pwsh "$WRAPPERS_PS1_STRIPPED" "
    \$env:_DEN_WRAPPERS = '1'; \$env:_DEN_WRAPPER_LOG = '1'
    function notice([scriptblock]\$Call) {
        @(& \$Call 6>&1 | Where-Object { \$_ -is [System.Management.Automation.InformationRecord] } |
            ForEach-Object { \$_.MessageData.Message }) -join ';'
    }
    Write-Output (notice { ls })
    Write-Output (notice { cat /dev/null })
    Write-Output ('w:' + (notice { lsw; catw /dev/null }))
" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/notice ls cat, none for lsw catw" \
    "$LS_NOTICE_PWSH"$'\n'"[den] cat -> bat  (off: tgl-wr)"$'\n'"w:" "$actual"

# doc_quote <file> <text> prints <text> when the file contains it, else nothing,
# so a failure shows the missing text instead of the whole file.
doc_quote() {
    grep -oF -- "$2" "$1" | head -n 1
}

echo "[docs] the docs quote the notice the ls wrapper prints"
README_MD="$DOTFILES/shell/README.md"
assert_eq "docs/README quotes the ls notice" "$LS_NOTICE" "$(doc_quote "$README_MD" "$LS_NOTICE")"
assert_eq "docs/README quotes the pwsh ls notice" "$LS_NOTICE_PWSH" "$(doc_quote "$README_MD" "$LS_NOTICE_PWSH")"
assert_eq "docs/README la hint keeps its flags" "command ls -A\`" "$(doc_quote "$README_MD" "command ls -A\`")"
# The shell test image copies only shell/ and tests/shell/, not COMMANDS.md.
if [ -f "$DOTFILES/COMMANDS.md" ]; then
    assert_eq "docs/COMMANDS quotes the ls notice" "$LS_NOTICE" "$(doc_quote "$DOTFILES/COMMANDS.md" "$LS_NOTICE")"
    assert_eq "docs/COMMANDS quotes the pwsh ls notice" "$LS_NOTICE_PWSH" "$(doc_quote "$DOTFILES/COMMANDS.md" "$LS_NOTICE_PWSH")"
else
    echo "  SKIP: docs/COMMANDS quotes the ls notice (no COMMANDS.md in $DOTFILES)"
fi

# =============================================================================
# Summary
# =============================================================================
print_summary "test_wrappers"
[ "$FAIL" -eq 0 ]
