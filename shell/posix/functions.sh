#!/bin/sh
# functions.sh — Utility functions (file ops, system, navigation, history).
# Sourced by .bashrc / .zshrc. POSIX sh compatible.
# Deploy target: ~/.config/shell/functions.sh

# Skip in non-interactive shells
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0;; esac

# ===== File Utils =====

# digest → unified hash function (md5, sha256, sha512)
digest() {
    case "$1" in
        md5|sha256|sha512)
            if [ -z "$2" ]; then
                echo "usage: digest $1 <file>" >&2
                return 1
            fi
            if [ ! -f "$2" ]; then
                echo "digest: '$2' is not a file" >&2
                return 1
            fi
            _h_algo="$1"; shift
            # Neutralize a leading-dash filename so it is not parsed as an option.
            case "$1" in -*) set -- "./$1" ;; esac
            "${_h_algo}sum" "$1" | awk '{ print $1 }'
            unset _h_algo
            ;;
        *)
            echo "usage: digest {md5|sha256|sha512} <file>" >&2
            return 1
            ;;
    esac
}

# mkfile → create a dummy file of specified size (e.g. mkfile 10M test.bin)
mkfile() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "usage: mkfile <size> <path>  (e.g. mkfile 10M test.bin)" >&2
        return 1
    fi
    truncate -s "$1" "$2" && echo "Created $2 ($1)"
}

# extract → auto-detect and extract archives
# NOTE: leading-dash './' prefix is required — do not remove.
extract() {
    if [ -z "$1" ]; then
        echo "usage: extract <file>" >&2
        return 1
    fi
    if [ ! -f "$1" ]; then
        echo "extract: '$1' is not a file" >&2
        return 1
    fi
    # Neutralise leading dash so downstream tools cannot parse filename as option
    _ex_f="$1"
    case "$_ex_f" in -*) _ex_f="./$_ex_f" ;; esac
    case "$_ex_f" in
        *.tar.gz|*.tgz)     tar xzf "$_ex_f"   ;;
        *.tar.bz2|*.tbz2)   tar xjf "$_ex_f"   ;;
        *.tar.xz|*.txz)     tar xJf "$_ex_f"   ;;
        *.tar.zst)          tar --zstd -xf "$_ex_f" ;;
        *.tar)              tar xf  "$_ex_f"    ;;
        *.gz)               gunzip -- "$_ex_f"    ;;
        *.bz2)              bunzip2 -- "$_ex_f"   ;;
        *.xz)               unxz -- "$_ex_f"      ;;
        *.zst)              unzstd -- "$_ex_f"    ;;
        *.zip)              unzip -- "$_ex_f"     ;;
        *.7z)               7z x -- "$_ex_f"      ;;
        *.rar)              unrar x -- "$_ex_f"   ;;
        *) echo "extract: unsupported format '$_ex_f'" >&2; unset _ex_f; return 1 ;;
    esac
    _ex_rc=$?
    unset _ex_f
    return "$_ex_rc"
}

# archive → create archive (format auto-detected from output filename)
# NOTE: './' normalisation on $out is required; $@ is pass-through by design.
archive() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "usage: archive <output> <source...>" >&2
        return 1
    fi
    local out="$1"; shift
    # Neutralise leading dash on output path
    case "$out" in -*) out="./$out" ;; esac
    case "$out" in
        *.tar.gz|*.tgz)     tar czf "$out" "$@"   ;;
        *.tar.bz2|*.tbz2)   tar cjf "$out" "$@"   ;;
        *.tar.xz|*.txz)     tar cJf "$out" "$@"   ;;
        *.tar.zst)          tar --zstd -cf "$out" "$@" ;;
        *.tar)              tar cf "$out" "$@"    ;;
        *.zip)              zip -r "$out" "$@"    ;;
        *.7z)               7z a "$out" "$@"      ;;
        *) echo "archive: unsupported format '$out'" >&2; return 1 ;;
    esac
}

# ===== System =====

# path → display PATH entries one per line
path() {
    echo "$PATH" | tr ':' '\n'
}

# ports → show listening TCP ports with process info
ports() {
    if command -v ss >/dev/null 2>&1; then
        ss -tlnp
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tlnp
    else
        echo "Neither ss nor netstat found" >&2
    fi
}

# ===== Navigation =====

# up N → go up N directories (default: 1)
up() {
    local count="${1:-1}" d=""
    case "$count" in
        ''|*[!0-9]*|0|0[0-9]*)
            echo "usage: up [N]  (N=positive integer, default 1)" >&2
            return 1
            ;;
    esac
    while [ "$count" -gt 0 ]; do
        d="../$d"
        count=$((count - 1))
    done
    cd "$d" || return
}

# cdf → fuzzy find and cd into a subdirectory (requires fd + fzf)
cdf() {
    if ! command -v fzf >/dev/null 2>&1; then
        echo "fzf is not installed." >&2
        return 1
    fi
    local dir
    dir="$(fd -t d . 2>/dev/null | fzf)" && [ -n "$dir" ] && builtin cd -- "$dir"
}

# mkcd → mkdir + cd in one step
mkcd() {
    if [ -z "$1" ]; then
        echo "usage: mkcd <dir>" >&2
        return 1
    fi
    mkdir -p -- "$1" && builtin cd -- "$1"
}

# y → yazi file manager (tracks cwd on exit)
# NOTE: trap and [ -d "$cwd" ] check are required — do not remove.
y() {
    if ! command -v yazi >/dev/null 2>&1; then
        echo "yazi is not installed." >&2
        return 1
    fi
    local tmp cwd
    tmp="$(mktemp -t "yazi-cwd.XXXXXX")" || return 1
    trap 'rm -f -- "$tmp"' EXIT INT TERM HUP
    yazi "$@" --cwd-file="$tmp"
    if cwd="$(command cat -- "$tmp")" && [ -n "$cwd" ] && [ -d "$cwd" ] && [ "$cwd" != "$PWD" ]; then
        builtin cd -- "$cwd"
    fi
    trap - EXIT INT TERM HUP
    rm -f -- "$tmp"
}

# ===== History / Replay =====

# again → re-run the Nth previous command (default N=1), -s/--sudo for sudo
again() {
    _ag_sudo=0
    case "$1" in
        -s|--sudo) _ag_sudo=1; shift ;;
    esac
    _ag_n="${1:-1}"

    case "$_ag_n" in
        ''|*[!0-9]*|0|0[0-9]*)
            echo "usage: again [-s|--sudo] [N]  (N=positive integer, default 1)" >&2
            unset _ag_sudo _ag_n; return 1
            ;;
    esac

    # Skip again/sagain entries in history to find the real Nth command.
    # Strip "command ", "builtin ", and leading backslash so the skip cannot
    # be bypassed by e.g. `\again`, `command again`.
    _ag_found=0; _ag_cmd=""
    _ag_i=1
    while [ "$_ag_i" -le 50 ]; do
        _ag_try="$(fc -ln "-$_ag_i" "-$_ag_i" 2>/dev/null)"
        while :; do
            case "$_ag_try" in
                ' '*) _ag_try=${_ag_try# } ;;
		'\t'*) _ag_try=${_ag_try#	} ;;
                *) break ;;
            esac
        done
        [ -z "$_ag_try" ] && break
        # Normalised form used only for the skip-check; actual replay uses original.
        # Loop to defuse nested prefixes like '\command again' or 'command command again'.
        _ag_norm="$_ag_try"
        while :; do
            case "$_ag_norm" in
                'command '*) _ag_norm=${_ag_norm#command } ;;
                'builtin '*) _ag_norm=${_ag_norm#builtin } ;;
                '\'*)        _ag_norm=${_ag_norm#\\} ;;
                *) break ;;
            esac
        done
        case "$_ag_norm" in
            again|sagain|'again '*|'sagain '*|'again	'*|'sagain	'*)
                : skip ;;
            *)
                _ag_found=$((_ag_found + 1))
                if [ "$_ag_found" -eq "$_ag_n" ]; then
                    _ag_cmd="$_ag_try"
                    break
                fi
                ;;
        esac
        _ag_i=$((_ag_i + 1))
    done
    unset _ag_found _ag_i _ag_try _ag_norm

    if [ -z "$_ag_cmd" ]; then
        echo "again: no command at position $_ag_n in history" >&2
        unset _ag_sudo _ag_n _ag_cmd; return 1
    fi

    if [ "$_ag_sudo" = "1" ]; then
        echo "+ sudo $_ag_cmd"
        printf 'Re-run with sudo? [Y/n] '
    else
        echo "+ $_ag_cmd"
        printf 'Re-run? [Y/n] '
    fi
    read -r _ag_ans
    case "$_ag_ans" in n|N) unset _ag_sudo _ag_n _ag_cmd _ag_ans; return 1;; esac

    { set +o history; } 2>/dev/null
    if [ "$_ag_sudo" = "1" ]; then
        eval "sudo $_ag_cmd"
    else
        eval "$_ag_cmd"
    fi
    _ag_rc=$?
    { set -o history; } 2>/dev/null
    unset _ag_sudo _ag_n _ag_cmd _ag_ans
    return "$_ag_rc"
}

# sagain → backward-compatible wrapper
sagain() { again --sudo "$@"; }

# back → go back to the Nth previous directory (default N=1)
back() {
    local n="${1:-1}"
    case "$n" in
        ''|*[!0-9]*|0|0[0-9]*)
            echo "usage: back [N]  (N=positive integer, default 1)" >&2
            return 1
            ;;
    esac
    if [ "$n" -eq 1 ]; then
        builtin cd - >/dev/null && pwd
    else
        echo "back: only N=1 is supported (uses cd -)" >&2
        echo "hint: use 'pushd'/'popd' or enable AUTO_PUSHD for deeper history" >&2
        return 1
    fi
}

# ===== Zoxide Navigation =====

# cd → wrapper ON: __zoxide_z, OFF: builtin cd
cd() {
    if [ "${_DEN_WRAPPERS:-1}" != "0" ] && type __zoxide_z >/dev/null 2>&1; then
        __zoxide_z "$@"
    else
        builtin cd "$@"
    fi
}

# cdi → wrapper ON: __zoxide_zi (interactive)
cdi() {
    if [ "${_DEN_WRAPPERS:-1}" != "0" ] && type __zoxide_zi >/dev/null 2>&1; then
        __zoxide_zi "$@"
    else
        echo "cdi: wrappers are OFF or zoxide is not available" >&2
        return 1
    fi
}

# zd → always __zoxide_z (ignores toggle)
zd() {
    if type __zoxide_z >/dev/null 2>&1; then
        __zoxide_z "$@"
    else
        echo "zoxide is not installed." >&2
        return 1
    fi
}

# zdi → always __zoxide_zi (ignores toggle)
zdi() {
    if type __zoxide_zi >/dev/null 2>&1; then
        __zoxide_zi "$@"
    else
        echo "zoxide is not installed." >&2
        return 1
    fi
}

