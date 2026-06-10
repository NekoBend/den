# Skip in non-interactive shells
[[ ! -o interactive ]] && return

# ===== Oh My Zsh =====
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git zsh-autosuggestions)
source $ZSH/oh-my-zsh.sh

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

# ===== Reload =====
reload() {
    rm -f "${XDG_CACHE_HOME:-$HOME/.cache}"/shell/*.zsh
    fc -W
    exec "$SHELL"
}
