#!/usr/bin/env bash
# test_completion.sh - Tests for Tab completion: init.zsh's compinit (zsh) and
# completion.ps1 (pwsh). The completion itself needs a real terminal, so the zsh
# tests watch which compinit runs and what happens to ~/.zcompdump, and the pwsh
# tests ask TabExpansion2, which is what PSReadLine's Tab calls; the rest is
# PSScriptAnalyzer (CI) plus manual verification on Windows.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

HELPERS_PS1="$DOTFILES/shell/pwsh/_helpers.ps1"
COMPLETION_PS1="$DOTFILES/shell/pwsh/completion.ps1"

# pwsh keeps its caches under LocalApplicationData, which is XDG_DATA_HOME off
# Windows; under WORK, so the tests never write the real ~/.local/share/shell-cache
# (completion.ps1 caches the completion of every tool it finds on PATH). The
# directory must exist: GetFolderPath('LocalApplicationData') returns '' for a
# missing one.
export XDG_DATA_HOME="$WORK/xdg"
mkdir -p "$XDG_DATA_HOME"

# =============================================================================
# zsh: init.zsh's compinit
# =============================================================================
echo "================================================"
echo "  Testing init.zsh's compinit with ZSH"
echo "================================================"

# Every case loads init.zsh from a fresh HOME (~/.config/shell holds the posix
# files and init.zsh) in an interactive zsh that reads no startup file (-f), so
# Ubuntu's /etc/zsh/zshrc runs no compinit of its own. XDG_CACHE_HOME is under
# that HOME too, and PATH holds the system directories only, where zoxide and
# starship are not installed (in /usr/bin, their init would be cached there).
# A compinit function defined before init.zsh (its `autoload -Uz compinit` keeps
# a function already defined) notes each call to $COMPINIT_LOG instead of
# running.
ZC="$WORK/zcomp"
# zc_run <commands before init.zsh> <commands after> - stdout and stderr
zc_run() {
    (cd "$ZC/home" && env -u ZDOTDIR HOME="$ZC/home" XDG_CACHE_HOME="$ZC/home/.cache" \
        PATH=/usr/local/bin:/usr/bin:/bin COMPINIT_LOG="$ZC/compinit.log" zsh -f -i -c "
            $1
            . ~/.config/shell/init.zsh
            $2
        " < /dev/null 2>&1)
}
zc_reset() {
    rm -rf "$ZC"
    mkdir -p "$ZC/home/.config/shell"
    cp "$DOTFILES"/shell/posix/*.sh "$DOTFILES/shell/zsh/init.zsh" "$ZC/home/.config/shell/"
}
ZC_LOGGER='compinit() { print -r -- compinit "$@" >> "$COMPINIT_LOG"; }'

# Ubuntu's /etc/zsh/zshrc, or the user's ~/.zshrc, may have run compinit
# before init.zsh: a second one only cost time (about a third of a zsh start).
echo "[zsh] init.zsh runs no compinit when completion is already set up"
zc_reset
zc_run "$ZC_LOGGER; compdef() { :; }" "" > /dev/null
assert_eq "zsh/no second compinit" "" "$(cat "$ZC/compinit.log" 2>/dev/null)"

echo "[zsh] init.zsh: -C while the dump is less than a day old"
zc_reset
touch -d '23 hours ago' "$ZC/home/.zcompdump"
zc_run "$ZC_LOGGER" "" > /dev/null
assert_eq "zsh/fresh dump: compinit -C" "compinit -C" "$(cat "$ZC/compinit.log" 2>/dev/null)"

# -C never looks for completion functions added since the dump was written (an
# apt package, a new tool), so they stayed out until the dump was deleted by
# hand. A dump a day old, or none, now gets the full compinit.
echo "[zsh] init.zsh: the full compinit for a day-old dump, and for none"
zc_reset
touch -d '25 hours ago' "$ZC/home/.zcompdump"
zc_run "$ZC_LOGGER" "" > /dev/null
rm -f "$ZC/home/.zcompdump"
zc_run "$ZC_LOGGER" "" > /dev/null
assert_eq "zsh/old and missing dump: full compinit" "compinit -u
compinit -u" "$(cat "$ZC/compinit.log" 2>/dev/null)"

# The full compinit rewrites the dump only when it finds the completion files
# changed; init.zsh dates it today either way, or every later shell would run
# the full compinit again.
echo "[zsh] init.zsh: after the full compinit the dump counts as fresh again"
zc_reset
zc_run "" "" > /dev/null
touch -d '2 days ago' "$ZC/home/.zcompdump"
out=$(zc_run "" "(( \${+functions[compdef]} )) && echo compdef-ok")
assert_eq "zsh/full compinit: completion set up, nothing printed" "compdef-ok" "$out"
assert_eq "zsh/full compinit: the dump is from today" "fresh" \
    "$(find "$ZC/home/.zcompdump" -newermt '1 hour ago' -printf 'fresh\n' 2>/dev/null)"

# The full compinit audited fpath (compaudit), which the -C before it never
# did: a directory there that others may write to made it ask "Ignore insecure
# directories and continue [y] or abort compinit [n]?", and with no terminal to
# answer (zsh -i -c, as an editor's environment probe runs it) it gave up: no
# completion, and no dump, so every later start did the same. -u uses fpath as
# it is, as -C does.
echo "[zsh] init.zsh: an fpath directory others may write to, with no terminal"
zc_reset
mkdir -p "$ZC/home/zfunc"
printf '#compdef zctool\n_zctool() { _files }\n' > "$ZC/home/zfunc/_zctool"
chmod 777 "$ZC/home/zfunc"
out=$(zc_run "fpath=(~/zfunc \$fpath)" \
    "(( \${+functions[compdef]} )) && echo compdef-ok; echo \"zctool=\${_comps[zctool]-none}\"")
assert_eq "zsh/insecure fpath: completion set up, nothing asked" "compdef-ok
zctool=_zctool" "$out"
assert_exists "zsh/insecure fpath: the dump written" "$ZC/home/.zcompdump"

# reload starts zsh again: deleting the dump too makes that shell's compinit
# look for new completion functions at once. It must do so with no init cache
# to delete as well (zoxide and starship not installed): zsh then printed "no
# matches found" for the cache pattern and skipped the whole rm. The restarted
# zsh is a stub that ends the run.
echo "[zsh] reload deletes the dump, with no init cache to delete"
zc_reset
mkdir -p "$ZC/bin"
printf '#!/bin/sh\nexit 0\n' > "$ZC/bin/zsh"
chmod +x "$ZC/bin/zsh"
out=$(zc_run "" "hash zsh='$ZC/bin/zsh'; [ -f ~/.zcompdump ] && echo dump-made; reload")
assert_eq "zsh/reload: nothing printed" "dump-made" "$out"
assert_not_exists "zsh/reload deleted the dump" "$ZC/home/.zcompdump"

# SH_GLOB, set before den's line (in ~/.zshrc), made init.zsh's glob qualifiers
# a parse error, and zsh stopped reading the file there: none of den's zsh setup
# loaded. They are not in the text zsh parses as it reads the file now.
echo "[zsh] init.zsh under SH_GLOB: read to its end, and its compinit and reload work"
zc_reset
mkdir -p "$ZC/bin" "$ZC/home/.cache/shell"
printf '#!/bin/sh\nexit 0\n' > "$ZC/bin/zsh"
chmod +x "$ZC/bin/zsh"
touch -d '23 hours ago' "$ZC/home/.zcompdump"
out=$(zc_run "setopt shglob; $ZC_LOGGER" "(( \${+functions[reload]} )) && echo read-to-the-end")
assert_eq "zsh/SH_GLOB: init.zsh read to its end" "read-to-the-end" "$out"
touch -d '25 hours ago' "$ZC/home/.zcompdump"
: > "$ZC/home/.cache/shell/zctool-init.zsh"
out=$(zc_run "setopt shglob; $ZC_LOGGER" "hash zsh='$ZC/bin/zsh'; reload")
assert_eq "zsh/SH_GLOB: reload printed nothing" "" "$out"
assert_eq "zsh/SH_GLOB: -C for a fresh dump, the full compinit for an old one" "compinit -C
compinit -u" "$(cat "$ZC/compinit.log" 2>/dev/null)"
assert_not_exists "zsh/SH_GLOB: reload deleted the init cache" "$ZC/home/.cache/shell/zctool-init.zsh"
assert_not_exists "zsh/SH_GLOB: reload deleted the dump" "$ZC/home/.zcompdump"
rm -rf "$ZC"

# =============================================================================
# pwsh: completion.ps1
# =============================================================================
echo ""
echo "================================================"
echo "  Testing completion.ps1 with PWSH"
echo "================================================"

if ! command -v pwsh >/dev/null 2>&1; then
    echo "pwsh not found; skipping completion tests"
    print_summary "test_completion"
    [ "$FAIL" -eq 0 ]
    return 0 2>/dev/null || exit 0
fi

# completion.ps1 uses the shared Initialize-Cache (in _helpers.ps1) and registers
# the per-tool completers. Sourcing both must not error: the trailing sentinel
# prints only if completion.ps1 sourced without a terminating error. run_pwsh is
# -NonInteractive, which the _DenInteractive gate treats as non-interactive, so set
# _DEN_FORCE_INTERACTIVE=1 to exercise the body; the per-tool completers no-op
# because their tools are absent. Stderr is NOT suppressed, so a load failure shows.
echo "[pwsh] completion.ps1 sources cleanly"
actual=$(run_pwsh "$HELPERS_PS1" "\$env:_DEN_FORCE_INTERACTIVE='1'; . '$COMPLETION_PS1'; 'SOURCED-OK'" | tr -d '\r')
assert_eq "pwsh/completion sources cleanly" "SOURCED-OK" "$actual"

# uv's completion script is about 750 KB, and completion.ps1 dot-sourced it at
# every start (about 60 ms) for a Tab that may never come. Now a stand-in
# completer loads it at the first Tab after uv, which it then completes, and the
# script's own completer takes the Tabs after; rustup's, clap's too, the same.
# The stub uv and rustup print a completion script in clap's form that counts
# its loads and completes alpha.
LZ="$WORK/lazy"
mkdir -p "$LZ/bin" "$LZ/cwd"
for t in uv rustup; do
    cat > "$LZ/bin/$t" <<EOF
#!/bin/sh
case "\$*" in
    'generate-shell-completion powershell'|'completions powershell') ;;
    *) exit 0 ;;
esac
cat <<'PS1'
using namespace System.Management.Automation
\$global:DenLazyLoads['$t']++
Register-ArgumentCompleter -Native -CommandName '$t' -ScriptBlock {
    param(\$wordToComplete, \$commandAst, \$cursorPosition)
    [CompletionResult]::new('alpha', 'alpha', [CompletionResultType]::ParameterValue, 'alpha')
}
PS1
EOF
    chmod +x "$LZ/bin/$t"
done
# lazy_run <commands> - completion.ps1 loaded with the stubs first on PATH (and
# their caches made), then the commands, in an empty directory: a Tab that no
# completer answers falls back to the file names there.
lazy_run() {
    (cd "$LZ/cwd" && run_pwsh "$HELPERS_PS1" "
        \$env:_DEN_FORCE_INTERACTIVE = '1'
        \$env:PATH = '$LZ/bin:' + \$env:PATH
        \$global:DenLazyLoads = @{ uv = 0; rustup = 0 }
        . '$COMPLETION_PS1'
        $1
    " 2>&1 | tr -d '\r')
}
TAB_UV="(TabExpansion2 -inputScript 'uv al' -cursorColumn 5).CompletionMatches.CompletionText -join ','"
TAB_RUSTUP="(TabExpansion2 -inputScript 'rustup al' -cursorColumn 9).CompletionMatches.CompletionText -join ','"
LOADS="'uv=' + \$global:DenLazyLoads['uv'] + ' rustup=' + \$global:DenLazyLoads['rustup']"

echo "[pwsh] uv's and rustup's completion scripts load at the first Tab, not at startup"
actual=$(lazy_run "
    'start: ' + ($LOADS)
    'tab uv: ' + ($TAB_UV) + ' ' + ($LOADS)
    'tab uv: ' + ($TAB_UV) + ' ' + ($LOADS)
    'tab rustup: ' + ($TAB_RUSTUP) + ' ' + ($LOADS)
")
assert_eq "pwsh/lazy completion" "start: uv=0 rustup=0
tab uv: alpha uv=1 rustup=0
tab uv: alpha uv=1 rustup=0
tab rustup: alpha uv=1 rustup=1" "$actual"

echo "[pwsh] the first Tab under Set-StrictMode"
actual=$(lazy_run "
    Set-StrictMode -Version Latest
    \$Error.Clear()
    'tab uv: ' + ($TAB_UV)
    'errors: ' + \$Error.Count
")
assert_eq "pwsh/lazy completion under strict mode" "tab uv: alpha
errors: 0" "$actual"

# The cache is checked again at that Tab, as at startup: a file swapped for a
# symlink since then is not loaded.
echo "[pwsh] a cache that is no longer safe at the first Tab is not loaded"
actual=$(lazy_run "
    \$c = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'shell-cache/uv-completion.Core.ps1'
    Move-Item -LiteralPath \$c -Destination \"\$c.real\"
    \$null = New-Item -ItemType SymbolicLink -Path \$c -Target \"\$c.real\"
    'tab uv: [' + ($TAB_UV) + '] ' + ($LOADS)
    Remove-Item -LiteralPath \$c
    Move-Item -LiteralPath \"\$c.real\" -Destination \$c
")
assert_eq "pwsh/lazy completion refuses a swapped cache" "tab uv: [] uv=0 rustup=0" "$actual"

print_summary "test_completion"
[ "$FAIL" -eq 0 ]
