#!/bin/sh
# snippet.sh — save favorite commands by name, then list / run them later.
# A lightweight replacement for `history | grep`. Sourced by .bashrc / .zshrc.
# POSIX sh compatible. Deploy target: ~/.config/shell/snippet.sh
#
# Snippets live in $XDG_CONFIG_HOME/den/snippets, one per line, TAB-separated:
#   name<TAB>command
# The command is everything after the first TAB, so it may itself contain tabs;
# only the name (field 1) is restricted to [A-Za-z0-9_-]. `run`/`pick` eval the
# command in the CURRENT shell (you saved it, so it is trusted), which lets it
# cd, set vars, and see the current environment.

# Skip in non-interactive shells
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0;; esac

_snip_file() {
    printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/den/snippets"
}

_snip_usage() {
    printf '%s\n' \
        "usage: snippet <command>   (alias: snip)" \
        "  save <name> <command...>  save a command (or pipe it via stdin)" \
        "  ls                        list saved snippets" \
        "  show <name>               print a snippet's command (no run)" \
        "  run <name>                run a snippet" \
        "  rm <name>                 delete a snippet" \
        "  pick                      fzf-select a snippet and run it (default)" >&2
}

# Look up a snippet by name; print its command (no newline) and return 0, or 1.
_snip_get() {
    _sg_file=$(_snip_file)
    [ -f "$_sg_file" ] || { unset _sg_file; return 1; }
    _sg_tab=$(printf '\t')
    while IFS= read -r _sg_line || [ -n "$_sg_line" ]; do
        if [ "${_sg_line%%"$_sg_tab"*}" = "$1" ]; then
            printf '%s' "${_sg_line#*"$_sg_tab"}"
            unset _sg_file _sg_tab _sg_line
            return 0
        fi
    done < "$_sg_file"
    unset _sg_file _sg_tab _sg_line
    return 1
}

# Echo the command (so the user sees what runs) then eval it in this shell.
_snip_exec() {
    printf '+ %s\n' "$1" >&2
    eval "$1"
}

_snippet_save() {
    if [ -z "$1" ]; then
        echo "usage: snippet save <name> <command...>" >&2
        return 1
    fi
    case "$1" in
        *[!A-Za-z0-9_-]*)
            echo "snippet save: name must match [A-Za-z0-9_-]" >&2
            return 1 ;;
    esac
    _ss_name=$1
    shift
    if [ "$#" -gt 0 ]; then
        _ss_cmd="$*"
    else
        # Keep a populated read even at EOF (a line with no trailing newline);
        # `|| _ss_cmd=''` would clobber it. A truly empty stdin leaves _ss_cmd
        # empty, which the next check rejects.
        IFS= read -r _ss_cmd
    fi
    if [ -z "$_ss_cmd" ]; then
        echo "snippet save: empty command" >&2
        unset _ss_name _ss_cmd
        return 1
    fi
    # The store is one record per line, so a newline in the command would split
    # into phantom rows that `run` could eval; reject multi-line commands.
    if [ "$(printf '%s' "$_ss_cmd" | wc -l)" -ne 0 ]; then
        echo "snippet save: command must be a single line" >&2
        unset _ss_name _ss_cmd
        return 1
    fi
    _ss_file=$(_snip_file)
    mkdir -p "$(dirname "$_ss_file")" || {
        unset _ss_name _ss_cmd _ss_file
        return 1
    }
    _ss_tab=$(printf '\t')
    _ss_tmp="$_ss_file.tmp.$$"
    : > "$_ss_tmp" || {
        echo "snippet save: cannot write $_ss_file" >&2
        unset _ss_name _ss_cmd _ss_file _ss_tab _ss_tmp
        return 1
    }
    if [ -f "$_ss_file" ]; then
        # Drop any existing snippet with this name (literal field-1 compare).
        while IFS= read -r _ss_line || [ -n "$_ss_line" ]; do
            if [ "${_ss_line%%"$_ss_tab"*}" != "$_ss_name" ]; then
                printf '%s\n' "$_ss_line" >> "$_ss_tmp"
            fi
        done < "$_ss_file"
    fi
    printf '%s\t%s\n' "$_ss_name" "$_ss_cmd" >> "$_ss_tmp"
    mv "$_ss_tmp" "$_ss_file"
    echo "snippet: saved '$_ss_name'" >&2
    unset _ss_name _ss_cmd _ss_file _ss_tab _ss_tmp _ss_line
}

_snippet_ls() {
    _sl_file=$(_snip_file)
    if [ ! -s "$_sl_file" ]; then
        echo "snippet: no snippets (use: snippet save <name> <command...>)" >&2
        unset _sl_file
        return 0
    fi
    _sl_tab=$(printf '\t')
    while IFS= read -r _sl_line || [ -n "$_sl_line" ]; do
        [ -n "$_sl_line" ] || continue
        printf '%s\t%s\n' "${_sl_line%%"$_sl_tab"*}" "${_sl_line#*"$_sl_tab"}"
    done < "$_sl_file"
    unset _sl_file _sl_tab _sl_line
}

_snippet_show() {
    if [ -z "$1" ]; then
        echo "usage: snippet show <name>" >&2
        return 1
    fi
    if ! _ssh_cmd=$(_snip_get "$1"); then
        echo "snippet show: no such snippet '$1'" >&2
        unset _ssh_cmd
        return 1
    fi
    printf '%s\n' "$_ssh_cmd"
    unset _ssh_cmd
}

_snippet_rm() {
    if [ -z "$1" ]; then
        echo "usage: snippet rm <name>" >&2
        return 1
    fi
    _srm_file=$(_snip_file)
    if [ ! -f "$_srm_file" ]; then
        echo "snippet rm: no such snippet '$1'" >&2
        unset _srm_file
        return 1
    fi
    _srm_tab=$(printf '\t')
    _srm_tmp="$_srm_file.tmp.$$"
    _srm_found=0
    : > "$_srm_tmp" || {
        echo "snippet rm: cannot write $_srm_file" >&2
        unset _srm_file _srm_tab _srm_tmp _srm_found
        return 1
    }
    while IFS= read -r _srm_line || [ -n "$_srm_line" ]; do
        if [ "${_srm_line%%"$_srm_tab"*}" = "$1" ]; then
            _srm_found=1
        else
            printf '%s\n' "$_srm_line" >> "$_srm_tmp"
        fi
    done < "$_srm_file"
    if [ "$_srm_found" -eq 1 ]; then
        mv "$_srm_tmp" "$_srm_file"
        echo "snippet: removed '$1'" >&2
    else
        rm -f "$_srm_tmp"
        echo "snippet rm: no such snippet '$1'" >&2
        unset _srm_file _srm_tab _srm_tmp _srm_found _srm_line
        return 1
    fi
    unset _srm_file _srm_tab _srm_tmp _srm_found _srm_line
}

_snippet_run() {
    if [ -z "$1" ]; then
        echo "usage: snippet run <name>" >&2
        return 1
    fi
    if ! _sr_cmd=$(_snip_get "$1"); then
        echo "snippet run: no such snippet '$1' (snippet ls)" >&2
        unset _sr_cmd
        return 1
    fi
    set -- "$_sr_cmd"
    unset _sr_cmd
    _snip_exec "$1"
}

_snippet_pick() {
    if ! command -v fzf >/dev/null 2>&1; then
        echo "snippet pick: fzf not found; use 'snippet run <name>'" >&2
        return 1
    fi
    _sp_file=$(_snip_file)
    if [ ! -s "$_sp_file" ]; then
        echo "snippet: no snippets (use: snippet save <name> <command...>)" >&2
        unset _sp_file
        return 0
    fi
    _sp_tab=$(printf '\t')
    _sp_sel=$(fzf --no-multi --prompt='snippet> ' < "$_sp_file") || _sp_sel=''
    if [ -z "$_sp_sel" ]; then
        unset _sp_file _sp_tab _sp_sel
        return 0
    fi
    set -- "${_sp_sel#*"$_sp_tab"}"
    unset _sp_file _sp_tab _sp_sel
    _snip_exec "$1"
}

# snippet — save / list / run named command snippets (alias: snip).
snippet() {
    case "${1:-pick}" in
        save)           shift; _snippet_save "$@" ;;
        ls|list)        _snippet_ls ;;
        show|cat)       shift; _snippet_show "$@" ;;
        rm|remove)      shift; _snippet_rm "$@" ;;
        run|exec)       shift; _snippet_run "$@" ;;
        pick)           _snippet_pick ;;
        -h|--help|help) _snip_usage ;;
        *)
            echo "snippet: unknown command '$1'" >&2
            _snip_usage
            return 1 ;;
    esac
}

alias snip='snippet'
