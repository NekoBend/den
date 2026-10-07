#!/bin/sh
# proxy.sh — named proxy profiles with easy on/off (shell env vars only).
# Sourced by .bashrc / .zshrc. POSIX sh compatible.
# Deploy target: ~/.config/shell/proxy.sh
#
# Profiles live in $XDG_CONFIG_HOME/den/proxy.conf, one per line, TAB-separated:
#   name<TAB>url<TAB>no_proxy(optional)
# `proxy on <name>` exports the standard proxy env vars (lower + upper case)
# into the CURRENT shell; `proxy off` unsets them. The active profile is tracked
# per-shell in _DEN_PROXY_ACTIVE, so it never disagrees with another shell:
# this feature only ever touches env vars, never global tool config.
# A url may carry a password (http://user:password@host:port): the store is
# 0600 in a 0700 directory, and add/on/ls/status print it as user:***@host. A
# store that is a symlink is written through, as pwsh does (_den_put, in
# _helpers.sh, which init.bash and init.zsh load first). The line that typed
# such a url stays out of the history file ($HISTFILE): see _proxy_forget and
# _proxy_histhook below.

# Skip in non-interactive shells
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0;; esac

_proxy_conf() {
    printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/den/proxy.conf"
}

# _proxy_show <url> - the url as add/on/ls/status print it: the password of a
# user:password@ part shows as ***. The store and the env vars keep it.
_proxy_show() {
    _psh_pre='' _psh_rest=$1
    case $1 in *://*) _psh_pre="${1%%://*}://" _psh_rest=${1#*://} ;; esac
    # The userinfo ends at the last @, the user at its first :.
    _psh_info=${_psh_rest%@*}
    if [ "$_psh_info" != "$_psh_rest" ] && [ "${_psh_info#*:}" != "$_psh_info" ]; then
        printf '%s%s:***@%s' "$_psh_pre" "${_psh_info%%:*}" "${_psh_rest##*@}"
    else
        printf '%s' "$1"
    fi
    unset _psh_pre _psh_rest _psh_info
}

# _proxy_secret_line <line> - true when a command line runs proxy add with a
# url that holds a password, as _proxy_show finds one. With the quotes taken
# out of the line, the word proxy (first, or after a character that is not
# part of a name or a path: not after a letter, a digit or one of _ . / : $ -,
# so ~/proxy and myproxy are not it) is followed by blanks and the word add;
# in the text after add, once every :// is taken out, there is an @ and a :
# before the last one. It reads the text only, so it errs toward true: a line
# it keeps out of the history for nothing costs less than a password in the
# history file.
_proxy_secret_line() {
    case $1 in
        *proxy*add*@*) ;;
        *) return 1 ;;
    esac
    _psl_t=$1
    while :; do
        case $_psl_t in
            *\'*) _psl_t=${_psl_t%%\'*}${_psl_t#*\'} ;;
            *\"*) _psl_t=${_psl_t%%\"*}${_psl_t#*\"} ;;
            *) break ;;
        esac
    done
    # Each proxy in turn. The y put back in front of the text after one is
    # the character before the next, when the two touch (proxyproxy).
    _psl_t=" $_psl_t" _psl_at=''
    while [ -z "$_psl_at" ]; do
        case $_psl_t in
            *proxy*) ;;
            *) break ;;
        esac
        _psl_p=${_psl_t%%proxy*}
        _psl_t=y${_psl_t#*proxy}
        case $_psl_p in
            *[A-Za-z0-9_./:\$-]) continue ;;
        esac
        _psl_r=${_psl_t#y}
        case $_psl_r in
            [[:space:]\\]*) ;;
            *) continue ;;
        esac
        while :; do
            case $_psl_r in
                [[:space:]\\]*) _psl_r=${_psl_r#?} ;;
                *) break ;;
            esac
        done
        case $_psl_r in
            add[[:space:]\\]*) _psl_at=${_psl_r#add} ;;
        esac
    done
    while :; do
        case $_psl_at in
            *://*) _psl_at="${_psl_at%%://*}${_psl_at#*://}" ;;
            *) break ;;
        esac
    done
    case $_psl_at in
        *:*@*) unset _psl_t _psl_p _psl_r _psl_at; return 0 ;;
    esac
    unset _psl_t _psl_p _psl_r _psl_at
    return 1
}

# _proxy_forget <add arguments> - bash: when one of the arguments is a url
# that holds a password, take the line that ran proxy add out of the history
# list, before bash writes the list to $HISTFILE (at exit, or by a
# `history -a` in PROMPT_COMMAND, which runs after the command). Only an
# entry that _proxy_secret_line finds goes: when HISTCONTROL or HISTIGNORE
# kept this line out (a leading space, a duplicate), the last entry is an
# older line, and it stays unless it holds such a url too. A subshell (a pipe,
# $(...)) has a copy of the list, so there the command to run is printed.
# What bash wrote before the command ran (a `history -a` from PS0 or a DEBUG
# trap) stays. zsh keeps the line out in _proxy_histhook, below.
_proxy_forget() {
    [ -n "${BASH_VERSION-}" ] || return 0
    _pf_pw=0
    for _pf_a in "$@"; do
        if [ "$(_proxy_show "$_pf_a")" != "$_pf_a" ]; then
            _pf_pw=1
            break
        fi
    done
    if [ "$_pf_pw" -eq 1 ]; then
        # No HISTTIMEFORMAT: a time stamp holds a : of its own.
        _pf_h=$(HISTTIMEFORMAT='' history 1)
        if _proxy_secret_line "$_pf_h"; then
            _pf_n=${_pf_h#"${_pf_h%%[0-9]*}"}
            _pf_n=${_pf_n%%[!0-9]*}
            # shellcheck disable=SC3028  # BASHPID: this function runs only in bash
            if [ -z "$_pf_n" ]; then
                :
            elif [ "${BASHPID:-$$}" = "$$" ]; then
                history -d "$_pf_n"
            else
                echo "proxy: this line, password and all, stays in the shell history: it ran in a subshell; run: history -d $_pf_n" >&2
            fi
        fi
    fi
    unset _pf_pw _pf_a _pf_h _pf_n
}

# _proxy_histhook <line> - zsh's zshaddhistory hook: a line that
# _proxy_secret_line finds is not saved. 1, not 2 (saved in memory only):
# fc -W, which reload runs, and fc -A write a line a hook answered with 2 to
# $HISTFILE too. It lingers until the next line runs, so it can be edited
# again at once. add-zsh-hook adds it next to the user's own hooks.
_proxy_histhook() {
    if _proxy_secret_line "$1"; then
        return 1
    fi
    return 0
}
if [ -n "${ZSH_VERSION-}" ]; then
    autoload -Uz add-zsh-hook && add-zsh-hook zshaddhistory _proxy_histhook
fi

_proxy_usage() {
    printf '%s\n' \
        "usage: proxy <command>" \
        "  add <name> <url> [no_proxy]   register/overwrite a profile" \
        "  rm <name>                     remove a profile" \
        "  ls                            list profiles (* = active this shell)" \
        "  on <name>                     export proxy env vars from <name>" \
        "  off                           unset proxy env vars (this shell)" \
        "  status                        show active profile + env (default)" >&2
}

_proxy_add() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "usage: proxy add <name> <url> [no_proxy]" >&2
        return 1
    fi
    case "$1" in
        *[!A-Za-z0-9_-]*)
            echo "proxy add: name must match [A-Za-z0-9_-]" >&2
            return 1 ;;
    esac
    _pa_name=$1 _pa_url=$2 _pa_np=${3:-}
    _pa_conf=$(_proxy_conf)
    # The directory is made 0700, and the store 0600 (the temporary file is
    # created so and renamed over it, or a symlink's target is made so),
    # whatever the umask; an older den's looser modes are tightened too.
    _pa_dir=$(dirname "$_pa_conf")
    if ! { mkdir -p "$_pa_dir" && chmod 700 "$_pa_dir"; }; then
        unset _pa_name _pa_url _pa_np _pa_conf _pa_dir
        return 1
    fi
    _pa_tab=$(printf '\t')
    _pa_tmp="$_pa_conf.tmp.$$"
    (umask 077 && : > "$_pa_tmp") || {
        echo "proxy add: cannot write $_pa_conf" >&2
        unset _pa_name _pa_url _pa_np _pa_conf _pa_dir _pa_tab _pa_tmp
        return 1
    }
    if [ -f "$_pa_conf" ]; then
        # Drop any existing entry with this name (compare field 1 literally, no
        # glob), then the new one is appended below. A store that cannot be
        # read ends the add, so it is never replaced by the new entry alone.
        while IFS= read -r _pa_line || [ -n "$_pa_line" ]; do
            if [ "${_pa_line%%"$_pa_tab"*}" != "$_pa_name" ]; then
                printf '%s\n' "$_pa_line" >> "$_pa_tmp"
            fi
        done < "$_pa_conf" || {
            rm -f "$_pa_tmp"
            echo "proxy add: cannot read $_pa_conf; it is left as it was" >&2
            unset _pa_name _pa_url _pa_np _pa_conf _pa_dir _pa_tab _pa_tmp _pa_line
            return 1
        }
    fi
    printf '%s\t%s\t%s\n' "$_pa_name" "$_pa_url" "$_pa_np" >> "$_pa_tmp"
    if ! _den_put "$_pa_tmp" "$_pa_conf"; then
        echo "proxy add: cannot write $_pa_conf" >&2
        if [ -e "$_pa_tmp" ]; then
            echo "proxy add: the whole new store is in $_pa_tmp" >&2
        fi
        unset _pa_name _pa_url _pa_np _pa_conf _pa_dir _pa_tab _pa_tmp _pa_line
        return 1
    fi
    echo "proxy: saved '$_pa_name' -> $(_proxy_show "$_pa_url")" >&2
    unset _pa_name _pa_url _pa_np _pa_conf _pa_dir _pa_tab _pa_tmp _pa_line
}

_proxy_rm() {
    if [ -z "$1" ]; then
        echo "usage: proxy rm <name>" >&2
        return 1
    fi
    _pr_conf=$(_proxy_conf)
    if [ ! -f "$_pr_conf" ]; then
        echo "proxy rm: no such profile '$1'" >&2
        unset _pr_conf
        return 1
    fi
    _pr_tab=$(printf '\t')
    _pr_tmp="$_pr_conf.tmp.$$"
    _pr_found=0
    # A 0700 directory and a 0600 store, as add makes them.
    { chmod 700 "$(dirname "$_pr_conf")" && (umask 077 && : > "$_pr_tmp"); } || {
        echo "proxy rm: cannot write $_pr_conf" >&2
        unset _pr_conf _pr_tab _pr_tmp _pr_found
        return 1
    }
    while IFS= read -r _pr_line || [ -n "$_pr_line" ]; do
        if [ "${_pr_line%%"$_pr_tab"*}" = "$1" ]; then
            _pr_found=1
        else
            printf '%s\n' "$_pr_line" >> "$_pr_tmp"
        fi
    done < "$_pr_conf"
    if [ "$_pr_found" -eq 1 ]; then
        if ! _den_put "$_pr_tmp" "$_pr_conf"; then
            echo "proxy rm: cannot write $_pr_conf" >&2
            if [ -e "$_pr_tmp" ]; then
                echo "proxy rm: the whole new store is in $_pr_tmp" >&2
            fi
            unset _pr_conf _pr_tab _pr_tmp _pr_found _pr_line
            return 1
        fi
        echo "proxy: removed '$1'" >&2
        if [ "${_DEN_PROXY_ACTIVE:-}" = "$1" ]; then
            echo "proxy: '$1' is still active in this shell; run 'proxy off'" >&2
        fi
    else
        rm -f "$_pr_tmp"
        echo "proxy rm: no such profile '$1'" >&2
        unset _pr_conf _pr_tab _pr_tmp _pr_found _pr_line
        return 1
    fi
    unset _pr_conf _pr_tab _pr_tmp _pr_found _pr_line
}

_proxy_ls() {
    _pl_conf=$(_proxy_conf)
    if [ ! -s "$_pl_conf" ]; then
        echo "proxy: no profiles (use: proxy add <name> <url> [no_proxy])" >&2
        unset _pl_conf
        return 0
    fi
    _pl_tab=$(printf '\t')
    while IFS="$_pl_tab" read -r _pl_n _pl_u _pl_p || [ -n "$_pl_n" ]; do
        [ -n "$_pl_n" ] || continue
        if [ "$_pl_n" = "${_DEN_PROXY_ACTIVE:-}" ]; then
            _pl_mark='*'
        else
            _pl_mark=' '
        fi
        if [ -n "$_pl_p" ]; then
            printf '%s %s\t%s\t(no_proxy: %s)\n' "$_pl_mark" "$_pl_n" "$(_proxy_show "$_pl_u")" "$_pl_p"
        else
            printf '%s %s\t%s\n' "$_pl_mark" "$_pl_n" "$(_proxy_show "$_pl_u")"
        fi
    done < "$_pl_conf"
    unset _pl_conf _pl_tab _pl_n _pl_u _pl_p _pl_mark
}

_proxy_on() {
    if [ -z "$1" ]; then
        echo "usage: proxy on <name>" >&2
        return 1
    fi
    _po_conf=$(_proxy_conf)
    if [ ! -f "$_po_conf" ]; then
        echo "proxy on: no profiles (use: proxy add <name> <url>)" >&2
        unset _po_conf
        return 1
    fi
    _po_tab=$(printf '\t')
    _po_url=''
    _po_np=''
    _po_found=0
    while IFS="$_po_tab" read -r _po_n _po_u _po_p || [ -n "$_po_n" ]; do
        if [ "$_po_n" = "$1" ]; then
            _po_url=$_po_u _po_np=$_po_p _po_found=1
            break
        fi
    done < "$_po_conf"
    if [ "$_po_found" -ne 1 ]; then
        echo "proxy on: no such profile '$1' (proxy ls to list)" >&2
        unset _po_conf _po_tab _po_url _po_np _po_found _po_n _po_u _po_p
        return 1
    fi
    # Loopback is always excluded; a profile's own no_proxy entries add to it.
    # The sole exception is "*" (bypass everything), which must stay standalone.
    if [ -z "$_po_np" ]; then
        _po_np="localhost,127.0.0.1,::1"
    elif [ "$_po_np" != "*" ]; then
        _po_np="localhost,127.0.0.1,::1,$_po_np"
    fi
    export http_proxy="$_po_url" https_proxy="$_po_url" \
        all_proxy="$_po_url" no_proxy="$_po_np"
    export HTTP_PROXY="$_po_url" HTTPS_PROXY="$_po_url" \
        ALL_PROXY="$_po_url" NO_PROXY="$_po_np"
    _DEN_PROXY_ACTIVE="$1"
    echo "proxy: on ($1 -> $(_proxy_show "$_po_url"))" >&2
    unset _po_conf _po_tab _po_url _po_np _po_found _po_n _po_u _po_p
}

_proxy_off() {
    unset http_proxy https_proxy all_proxy no_proxy
    unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
    if [ -n "${_DEN_PROXY_ACTIVE:-}" ]; then
        echo "proxy: off (was $_DEN_PROXY_ACTIVE)" >&2
    else
        echo "proxy: off" >&2
    fi
    unset _DEN_PROXY_ACTIVE
}

_proxy_status() {
    echo "active: ${_DEN_PROXY_ACTIVE:-(none)}"
    echo "http_proxy=$(_proxy_show "${http_proxy:-}")"
    echo "https_proxy=$(_proxy_show "${https_proxy:-}")"
    echo "all_proxy=$(_proxy_show "${all_proxy:-}")"
    echo "no_proxy=${no_proxy:-}"
}

# proxy — register named proxy profiles and toggle them on/off (env vars only).
proxy() {
    case "${1:-status}" in
        add)            shift; _proxy_forget "$@"; _proxy_add "$@" ;;
        rm)             shift; _proxy_rm "$@" ;;
        ls)             _proxy_ls ;;
        on)             shift; _proxy_on "$@" ;;
        off)            _proxy_off ;;
        status)         _proxy_status ;;
        -h|--help|help) _proxy_usage ;;
        *)
            echo "proxy: unknown command '$1'" >&2
            _proxy_usage
            return 1 ;;
    esac
}
