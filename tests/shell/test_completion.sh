#!/usr/bin/env bash
# test_completion.sh — Tests for Tab completion: init.zsh's compinit (zsh) and
# completion.ps1 (pwsh). The completion itself needs a real terminal, so the zsh
# tests watch which compinit runs and what happens to ~/.zcompdump, and the pwsh
# test is a load smoke test; the rest is PSScriptAnalyzer (CI) plus manual
# verification on Windows.
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
assert_eq "zsh/old and missing dump: full compinit" "compinit
compinit" "$(cat "$ZC/compinit.log" 2>/dev/null)"

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

print_summary "test_completion"
[ "$FAIL" -eq 0 ]
