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
# Combined wrappers + coreutils for pipe chain tests
COREUTILS_PS1="$DOTFILES/shell/pwsh/coreutils.ps1"
COMBINED_PS1="$TESTTMP/wrappers_combined.ps1"
{
    cat "$WRAPPERS_PS1_STRIPPED"
    grep -v '_DenInteractive' "$COREUTILS_PS1"
} > "$COMBINED_PS1" || abort_suite "cannot write $COMBINED_PS1"

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
# PowerShell: wrappers called from a user script
# =============================================================================
# A function's $script: is the scope of the script RUNNING it, so the command
# cache _helpers.ps1 kept there was $null inside a user's .ps1: each wrapper call
# printed "You cannot call a method on a null-valued expression" and fell through
# to its PowerShell fallback. Run cat/grep/head from a script with &, and from a
# function inside it, as a user's script would.
echo ""
echo "[pwsh] wrappers called from a user script"
cat > "$WORK/usewrap.ps1" <<EOF
cat '$WORK/fruits.txt' | grep 'an'
function Get-FirstLine { cat '$WORK/lines20.txt' | head -n 2 }
Get-FirstLine
EOF
actual=$(run_pwsh "$COMBINED_PS1" "\$env:_DEN_WRAPPER_LOG = '0'; & '$WORK/usewrap.ps1'" 2>/dev/null)
actual=$(echo "$actual" | tr -d '\r' | sed '/^$/d')
assert_eq "pwsh/wrappers from a script" "banana
line1
line2" "$actual"
err=$(run_pwsh_stderr "$COMBINED_PS1" "\$env:_DEN_WRAPPER_LOG = '0'; & '$WORK/usewrap.ps1'")
assert_eq "pwsh/wrappers from a script: no errors" "" "$err"

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
