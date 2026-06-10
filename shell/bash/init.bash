# ~/.config/shell/init.bash — sourced from ~/.bashrc

# ===== Guard & History =====
case $- in *i*) ;; *) return;; esac
[[ -z "$BASH_VERSION" ]] && return

HISTCONTROL=ignoreboth; shopt -s histappend
HISTSIZE=8192; HISTFILESIZE=8192
HISTIGNORE="again:again *:sagain:sagain *"

# ============================================================================
# Custom configuration
# ============================================================================

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
_init_cache zoxide bash --no-cmd
_init_cache starship bash --print-full-init

# ===== Reload =====
reload() {
    rm -f "${XDG_CACHE_HOME:-$HOME/.cache}"/shell/*.bash
    history -a
    exec "$BASH"
}
