# Skip in non-interactive shells
[[ ! -o interactive ]] && return

# ===== Completion =====
# zsh's own compinit + a little styling (replaces what oh-my-zsh set up; the omz
# framework + theme + git plugin were dead weight here -- starship overrides the
# theme and aliases.sh owns the git aliases). -C skips the slow security audit.
autoload -Uz compinit && compinit -C
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
    rm -f "${XDG_CACHE_HOME:-$HOME/.cache}"/shell/*.zsh
    fc -W
    exec "$SHELL"
}
