# Skip in non-interactive shells
[[ ! -o interactive ]] && return

# ===== Completion =====
# zsh's own compinit + a little styling (replaces what oh-my-zsh set up; the omz
# framework + theme + git plugin were dead weight here -- starship overrides the
# theme and aliases.sh owns the git aliases).
# compinit runs once per shell: not at all here when completion is already set
# up (compdef is defined: ~/.zshrc ran compinit before this file, or Ubuntu's
# /etc/zsh/zshrc did, unless skip_global_compinit is set; a second compinit
# would undo compdef calls since). While ~/.zcompdump is less than a day
# old and compaudit passes, -C loads it as it is, without looking for new
# completion functions. Otherwise the full compinit runs, which writes the
# dump again when it finds functions added since (an apt package, a new tool);
# touch then dates it today either way, so the next shells can take -C again
# (compdump would rewrite it the same, at about 70 ms against touch's 2). A
# dump touch cannot date (not yours) only means the full compinit again next
# time. reload deletes the dump.
# compaudit flags what in fpath others may have written: a directory others
# may write to (group- or world-writable, or owned by a user other than you
# and root), a file or a digest (<dir>.zwc, which autoload reads in place of
# the directory) someone else owns, and the parent of an fpath directory when
# others may write to it (they could put a digest there). A completion
# function from any of these would run as you at the next Tab. When compaudit
# fails, the fpath directories it lists come out of fpath, and so do those
# that hold a function file or a function's digest it lists, lie below a
# directory it lists or have their digest listed; then the full compinit runs
# with -i, which on its own would leave out only the first kind, and asks
# nothing. When $_compdir names a collection with a Base, compaudit adds its
# subdirectories to fpath: they are judged the same way, and that compinit
# runs with _compdir empty, so its own compaudit cannot add them back.
# compinit is loaded only after that, never from a directory taken out
# (preloading it would undo that). Plain compinit asks whether
# to use them, and with no terminal to answer (zsh -i -c, as an editor's
# environment probe runs it) gives up and writes no dump, so it asks again at
# every start; -u would use them unchecked. -C skips the audit and keeps fpath
# as it is, so a dump less than a day old is only loaded after compaudit
# passes (a few ms); while it fails, every shell runs the full compinit.
# `compaudit` lists what it flags. The dump's age is tested through eval,
# under zsh's own options: with SH_GLOB set (in ~/.zshrc, above den's line)
# the glob qualifier is a parse error, and zsh stops reading this file there.
autoload -Uz compinit compaudit
if (( ! ${+functions[compdef]} )); then
    () {
        emulate -L zsh
        setopt extendedglob
        local dump=${ZDOTDIR:-$HOME}/.zcompdump d f
        local -a listed kept
        if compaudit >/dev/null 2>&1; then
            if eval '[[ -n $dump(#qN.mh-24) ]]'; then
                compinit -C
                return
            fi
        else
            # compaudit's list as compinit gets it: with _i_check set,
            # compaudit leaves it in _i_wdirs and _i_wfiles and prints
            # nothing. The list it prints on its own reads backslash escapes
            # in a name (a file named with \c ends the list there) and breaks
            # a name at a newline. A directory is not taken out for holding
            # a listed directory, nor a directory's digest (X/sub.zwc serves
            # X/sub only). compaudit names a parent ${d:h}: that is . for a
            # relative entry such as zfunc, which $f/* does not match.
            # compaudit also adds to fpath the subdirectories of $_compdir
            # (a collection with a Base) and audits them: that fpath comes
            # out first, after its length.
            listed=( ${(0)"$(local _i_check=y; compaudit 2>/dev/null
                print -rN -- $#fpath $fpath $_i_wdirs $_i_wfiles)"} )
            for d in ${listed[2,listed[1]+1]}; do
                for f in ${listed[listed[1]+2,-1]}; do
                    [[ $d == $f || $d == $f/* || ${d:h} == $f ||
                       $d.zwc == $f ||
                       ( ${f%/*} == $d && ! -d $f && ! -d ${f%.zwc} ) ]] &&
                        continue 2
                done
                kept+=( $d )
            done
            fpath=( $kept )
            # compinit's own compaudit would add them back: an empty
            # _compdir stops that, for this compinit only (it and compdump
            # do not read _compdir).
            local _compdir=
        fi
        compinit -i && command touch -- "$dump" 2>/dev/null
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
