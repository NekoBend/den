#!/bin/sh
# cheat.sh — browse den's bundled cheatsheets (deployed by `den install cheatsheets`).
# POSIX sh compatible. Sourced by .bashrc / .zshrc. Deploy target: ~/.config/shell/cheat.sh
#
# Cheatsheets live under $XDG_DATA_HOME/den/cheatsheets (default
# ~/.local/share/den/cheatsheets), a tree of .md / .py reference files that
# `den install cheatsheets` writes. `cheat` fzf-picks one (or takes a name
# substring) and renders it with bat, falling back to cat. Mirrors snippet.sh's
# shape (an fzf-pick plus a by-name lookup).

# Skip in non-interactive shells
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0;; esac

_cheat_dir() {
    printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/den/cheatsheets"
}

_cheat_usage() {
    printf '%s\n' \
        "usage: cheat [name]        no name: fzf-pick (needs 'den install cheatsheets')" \
        "  ls                       list available cheatsheets" \
        "  <name>                   render the cheatsheet whose path matches <name>" >&2
}

# Cheatsheet paths (relative to the cheat dir), sorted, one per line. Nonzero if
# the cheat dir does not exist.
_cheat_list() {
    _cl_dir=$(_cheat_dir)
    [ -d "$_cl_dir" ] || { unset _cl_dir; return 1; }
    ( cd "$_cl_dir" || exit; find . -type f ! -name '*.pyc' ! -path '*/__pycache__/*' ) |
        sed 's|^\./||' | LC_ALL=C sort
    unset _cl_dir
}

# Render a cheatsheet given its path relative to the cheat dir (bat, else cat).
_cheat_render() {
    _crf="$(_cheat_dir)/$1"
    if command -v bat >/dev/null 2>&1; then
        bat --style=plain --paging=auto "$_crf"
    else
        cat "$_crf"
    fi
    unset _crf
}

# cheat — browse den's cheatsheets: no arg fzf-picks, a name renders the match.
cheat() {
    if [ ! -d "$(_cheat_dir)" ]; then
        echo "cheat: no cheatsheets installed. Run: den install cheatsheets" >&2
        return 1
    fi
    case "${1:-}" in
        -h|--help|help) _cheat_usage; return 0 ;;
        ls|list)        _cheat_list;  return 0 ;;
    esac

    if [ -z "${1:-}" ]; then
        if ! command -v fzf >/dev/null 2>&1; then
            echo "cheat: fzf not found; use 'cheat <name>' or 'cheat ls'" >&2
            return 1
        fi
        _ch_sel=$(_cheat_list | fzf --no-multi --prompt='cheat> ') || _ch_sel=''
        [ -n "$_ch_sel" ] && _cheat_render "$_ch_sel"
        unset _ch_sel
        return 0
    fi

    # By name: an exact full-path match wins, otherwise a substring match.
    _ch_all=$(_cheat_list)
    if printf '%s\n' "$_ch_all" | grep -qxF -- "$1"; then
        _ch_hit=$1
    else
        _ch_hit=$(printf '%s\n' "$_ch_all" | grep -F -- "$1")
    fi
    if [ -z "$_ch_hit" ]; then
        echo "cheat: no cheatsheet matching '$1' (cheat ls)" >&2
        unset _ch_all _ch_hit
        return 1
    fi
    if [ "$(printf '%s\n' "$_ch_hit" | grep -c .)" -gt 1 ]; then
        if command -v fzf >/dev/null 2>&1; then
            _ch_sel=$(printf '%s\n' "$_ch_hit" | fzf --no-multi --prompt='cheat> ') || _ch_sel=''
            [ -n "$_ch_sel" ] && _cheat_render "$_ch_sel"
            unset _ch_all _ch_hit _ch_sel
            return 0
        fi
        echo "cheat: '$1' is ambiguous:" >&2
        printf '%s\n' "$_ch_hit" | sed 's/^/  /' >&2
        unset _ch_all _ch_hit
        return 1
    fi
    _cheat_render "$_ch_hit"
    unset _ch_all _ch_hit
}
