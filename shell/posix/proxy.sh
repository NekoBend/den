#!/bin/sh
# proxy.sh — named proxy profiles with easy on/off (shell env vars only).
# Sourced by .bashrc / .zshrc. POSIX sh compatible.
# Deploy target: ~/.config/shell/proxy.sh
#
# Profiles live in $XDG_CONFIG_HOME/den/proxy.conf, one per line, TAB-separated:
#   name<TAB>url<TAB>no_proxy(optional)
# `proxy on <name>` exports the standard proxy env vars (lower + upper case)
# into the CURRENT shell; `proxy off` unsets them. The active profile is tracked
# per-shell in _DOTFILES_PROXY_ACTIVE, so it never disagrees with another shell:
# this feature only ever touches env vars, never global tool config.

# Skip in non-interactive shells
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0;; esac

_proxy_conf() {
    printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/den/proxy.conf"
}

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
    mkdir -p "$(dirname "$_pa_conf")" || {
        unset _pa_name _pa_url _pa_np _pa_conf
        return 1
    }
    _pa_tab=$(printf '\t')
    _pa_tmp="$_pa_conf.tmp.$$"
    : > "$_pa_tmp" || {
        echo "proxy add: cannot write $_pa_conf" >&2
        unset _pa_name _pa_url _pa_np _pa_conf _pa_tab _pa_tmp
        return 1
    }
    if [ -f "$_pa_conf" ]; then
        # Drop any existing entry with this name (compare field 1 literally, no
        # glob), then the new one is appended below.
        while IFS= read -r _pa_line || [ -n "$_pa_line" ]; do
            if [ "${_pa_line%%"$_pa_tab"*}" != "$_pa_name" ]; then
                printf '%s\n' "$_pa_line" >> "$_pa_tmp"
            fi
        done < "$_pa_conf"
    fi
    printf '%s\t%s\t%s\n' "$_pa_name" "$_pa_url" "$_pa_np" >> "$_pa_tmp"
    mv "$_pa_tmp" "$_pa_conf"
    echo "proxy: saved '$_pa_name' -> $_pa_url" >&2
    unset _pa_name _pa_url _pa_np _pa_conf _pa_tab _pa_tmp _pa_line
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
    : > "$_pr_tmp" || {
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
        mv "$_pr_tmp" "$_pr_conf"
        echo "proxy: removed '$1'" >&2
        if [ "${_DOTFILES_PROXY_ACTIVE:-}" = "$1" ]; then
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
        if [ "$_pl_n" = "${_DOTFILES_PROXY_ACTIVE:-}" ]; then
            _pl_mark='*'
        else
            _pl_mark=' '
        fi
        if [ -n "$_pl_p" ]; then
            printf '%s %s\t%s\t(no_proxy: %s)\n' "$_pl_mark" "$_pl_n" "$_pl_u" "$_pl_p"
        else
            printf '%s %s\t%s\n' "$_pl_mark" "$_pl_n" "$_pl_u"
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
    _DOTFILES_PROXY_ACTIVE="$1"
    echo "proxy: on ($1 -> $_po_url)" >&2
    unset _po_conf _po_tab _po_url _po_np _po_found _po_n _po_u _po_p
}

_proxy_off() {
    unset http_proxy https_proxy all_proxy no_proxy
    unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
    if [ -n "${_DOTFILES_PROXY_ACTIVE:-}" ]; then
        echo "proxy: off (was $_DOTFILES_PROXY_ACTIVE)" >&2
    else
        echo "proxy: off" >&2
    fi
    unset _DOTFILES_PROXY_ACTIVE
}

_proxy_status() {
    echo "active: ${_DOTFILES_PROXY_ACTIVE:-(none)}"
    echo "http_proxy=${http_proxy:-}"
    echo "https_proxy=${https_proxy:-}"
    echo "all_proxy=${all_proxy:-}"
    echo "no_proxy=${no_proxy:-}"
}

# proxy — register named proxy profiles and toggle them on/off (env vars only).
proxy() {
    case "${1:-status}" in
        add)            shift; _proxy_add "$@" ;;
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
