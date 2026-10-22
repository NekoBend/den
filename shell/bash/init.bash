# ~/.config/shell/init.bash — sourced from ~/.bashrc

# ===== Guard & History =====
case $- in *i*) ;; *) return;; esac
[[ -z "$BASH_VERSION" ]] && return

# A HISTCONTROL or HISTIGNORE already set when this file runs (above den's
# line in ~/.bashrc, or in the environment) is kept. HISTCONTROL gets den's
# ignoreboth only when it is unset; HISTIGNORE gets each of den's again/sagain
# patterns it does not hold yet, so loading this file again (~/.bashrc sourced
# again, or reload with HISTIGNORE exported) adds none of them twice.
HISTCONTROL=${HISTCONTROL-ignoreboth}; shopt -s histappend
HISTSIZE=8192; HISTFILESIZE=8192
for _den_hi in again 'again *' sagain 'sagain *'; do
    case ":${HISTIGNORE-}:" in
        *":$_den_hi:"*) ;;
        *) HISTIGNORE="${HISTIGNORE:+$HISTIGNORE:}$_den_hi" ;;
    esac
done
unset _den_hi

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
# starship's init moves a PROMPT_COMMAND string into STARSHIP_PROMPT_COMMAND
# and runs it from its own hook, so zoxide's __zoxide_hook still runs at each
# prompt. zoxide's doctor looks for the hook only in PROMPT_COMMAND and would
# warn, on the first cd or zd, that zoxide is set up wrong; turn it off only
# then. (A PROMPT_COMMAND array keeps the hook in place: starship moves only
# its first element.) The cost: a later ~/.bashrc line that overwrites
# PROMPT_COMMAND stops both hooks, and the doctor no longer says so; starship's
# prompt then never shows, which does. Putting the hook back in PROMPT_COMMAND,
# after starship_precmd, would keep the doctor, but on bash before 4.4 any
# command there restarts starship's timer (a DEBUG trap), so cmd_duration
# would count the time spent at the prompt.
case ${STARSHIP_PROMPT_COMMAND-} in *__zoxide_hook*) _ZO_DOCTOR=0 ;; esac

# ===== Reload =====
reload() {
    rm -f "${XDG_CACHE_HOME:-$HOME/.cache}"/shell/*.bash
    history -a
    exec "$BASH"
}
