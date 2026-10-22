# Skip in non-interactive shells
[[ ! -o interactive ]] && return

# ===== Completion =====
# zsh's own compinit + a little styling (replaces what oh-my-zsh set up; the omz
# framework + theme + git plugin were dead weight here -- starship overrides the
# theme and aliases.sh owns the git aliases).
# compinit runs once per shell: not at all here when completion is already set
# up (compdef is defined: ~/.zshrc ran compinit before this file, or Ubuntu's
# /etc/zsh/zshrc did, which `den install shell` turns off with
# skip_global_compinit=1 in ~/.zshenv). While ~/.zcompdump is less than a day
# old, -C loads it as it is, without looking for new completion functions. A
# missing or older dump gets the full compinit, which writes the dump again
# when it finds functions added since (an apt package, a new tool); touch then
# dates it today either way, so the next shells take -C again (compdump would
# rewrite it the same, at about 70 ms against touch's 2). A dump touch cannot
# date (not yours) only means the full compinit again next time. reload
# deletes the dump. -u: the full compinit uses every fpath directory, as -C
# does, without the security audit, which asks whether to use one that others
# may write to; with no terminal to answer (zsh -i -c, as an editor's
# environment probe runs it), compinit gave up, wrote no dump, and so asked
# again at every start. The dump's age is tested through eval, under zsh's own
# options: with SH_GLOB set (in ~/.zshrc, above den's line) the glob qualifier
# is a parse error, and zsh stops reading this file there.
autoload -Uz compinit
if (( ! ${+functions[compdef]} )); then
    () {
        emulate -L zsh
        setopt extendedglob
        local dump=${ZDOTDIR:-$HOME}/.zcompdump
        if eval '[[ -n $dump(#qN.mh-24) ]]'; then
            compinit -C
        else
            compinit -u && command touch -- "$dump" 2>/dev/null
        fi
    }
fi
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'   # case-insensitive
[ -n "$LS_COLORS" ] && zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
setopt AUTO_CD

# ===== Zsh Settings =====
bindkey -e

HISTFILE=~/.zsh_history
HISTSIZE=8192
SAVEHIST=8192
HISTORY_IGNORE="(again|again *|sagain|sagain *)"

# ===== Helpers =====
. "$HOME/.config/shell/_helpers.sh"

# ===== PATH & env =====
_init_path "$HOME/.local/bin" "$HOME/.cargo/bin"
[ -f "$HOME/.cargo/env" ]     && . "$HOME/.cargo/env"
[ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"

# ===== Load common config =====
unalias cat find grep la ll lla ls 2>/dev/null
_source_all "$HOME/.config/shell"

# ===== Cached init =====
_init_cache zoxide zsh --no-cmd
_init_cache starship zsh --print-full-init

# ===== Plugins (cloned into ~/.config/zsh/plugins by `den install shell`) =====
# Each is guarded, so a missing plugin just disables that feature. Order matters:
# autosuggestions first; zsh-syntax-highlighting MUST be sourced LAST because it
# wraps the ZLE widgets that exist at source time.
_zp="${XDG_CONFIG_HOME:-$HOME/.config}/zsh/plugins"
[ -r "$_zp/zsh-autosuggestions/zsh-autosuggestions.zsh" ] && \
    . "$_zp/zsh-autosuggestions/zsh-autosuggestions.zsh"
[ -r "$_zp/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ] && \
    . "$_zp/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
unset _zp

# ===== Reload =====
reload() {
    # The completion dump too, so the new shell's compinit looks for new
    # completion functions at once. NULL_GLOB, under zsh's own options: no init
    # cache is no error. Not the (N) qualifier, which SH_GLOB makes a parse
    # error where this file defines reload.
    () {
        emulate -L zsh
        setopt nullglob
        rm -f "${XDG_CACHE_HOME:-$HOME/.cache}"/shell/*.zsh "${ZDOTDIR:-$HOME}/.zcompdump"
    }
    # Append only this session's unsaved lines, as init.bash's `history -a`
    # does. `fc -W` rewrote $HISTFILE from this session's list, which lacks
    # what other sessions saved after it started, so those lines were lost.
    fc -AI
    # Re-exec zsh explicitly, not $SHELL: $SHELL is the login shell from passwd,
    # which may be bash even when zsh was launched manually. Mirrors init.bash's
    # `exec "$BASH"`. Prefer zsh's hashed absolute path ($commands[zsh]) over a
    # bare PATH lookup, falling back to `zsh` if it is not hashed.
    exec "${commands[zsh]:-zsh}"
}
