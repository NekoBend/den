#!/bin/sh
# _helpers.sh — DRY helpers for den shell config.
# Sourced first by init.bash / init.zsh. POSIX sh compatible.
# Deploy target: ~/.config/shell/_helpers.sh

# ========== wrapper log ==========

# _wrap_log <name> <modern> <fallback> <fallback_flags> — announce a modern-tool
# substitution (dim, stderr). Prints on EVERY wrapped call: the modern tool's
# flags and output differ from the native command, so a silent substitution is
# easy to miss (and tools or generated commands that assume the native behavior
# then break). One short line, both hints in one parenthesis:
#   [den] ls -> lsd  (native: command ls, off: tgl-wr)
# "native:" names the actual FALLBACK command for a one-off call (e.g.
# `command ls -A` for `la`), not the wrapper name, since wrappers like la/ll/lt
# have no binary of their own; a wrapper with no native equivalent shows only
# "off:". Flags that only change how the output looks (--color, --colour and
# their =VALUE forms) are left out of the hint to keep the line short; the
# fallback itself still runs with them. "off:" is the session switch (tgl-wr = toggle-wrapper).
# _DEN_WRAPPER_LOG=0 silences the notice and _DEN_WRAPPERS=0 disables the
# wrappers; both are documented in COMMANDS.md and shell/README.md rather than
# in the line.
_wrap_log() {
    [ "${_DEN_WRAPPER_LOG:-1}" = "0" ] && return 0
    if [ -n "$3" ]; then
        # Split the flags by hand: zsh does not word-split an unquoted $4.
        _wl_rest="$4"
        _wl_flags=
        while [ -n "$_wl_rest" ]; do
            _wl_f="${_wl_rest%% *}"
            case "$_wl_rest" in
                *" "*) _wl_rest="${_wl_rest#* }" ;;
                *) _wl_rest= ;;
            esac
            case "$_wl_f" in
                ''|--color|--color=*|--colour|--colour=*) ;;
                *) _wl_flags="${_wl_flags:+$_wl_flags }$_wl_f" ;;
            esac
        done
        printf '\033[2m[den] %s -> %s  (native: command %s, off: tgl-wr)\033[0m\n' "$1" "$2" "$3${_wl_flags:+ $_wl_flags}" >&2
        unset _wl_rest _wl_flags _wl_f
    else
        printf '\033[2m[den] %s -> %s  (off: tgl-wr)\033[0m\n' "$1" "$2" >&2
    fi
}

# ========== typed at the prompt ==========

# _den_typed → status 0 when the den command that called it was typed at the
# prompt, 1 when a function or a sourced file (~/.bashrc, ~/.zshrc too) ran
# it. Typed counts through eval and $(...) at the prompt, through `bash -c` /
# `zsh -c`, and through `again` / `sagain`, which replay a typed line. den's
# cd hands a directory to zoxide, and a wrapper with a native fallback runs
# the modern tool, only when typed: code in a function or a script gets
# builtin cd and the native command it was written for.
# The call stack is bash's FUNCNAME or zsh's funcstack (which also lists each
# sourced file by its path and each eval as "(eval)"); eval keeps the array
# syntax away from a POSIX parser.
_den_typed() {
    if [ -n "${BASH_VERSION-}" ]; then
        eval 'set -- "${FUNCNAME[@]}"'
    elif [ -n "${ZSH_VERSION-}" ]; then
        eval 'set -- "${funcstack[@]}"'
    else
        return 0
    fi
    # Skip this function's own frame (zsh lists the eval above first), then
    # the den command's; what is left are its callers.
    while [ $# -gt 0 ]; do
        _dt_f=$1
        shift
        [ "$_dt_f" = _den_typed ] && break
    done
    [ $# -gt 0 ] && shift
    for _dt_f in "$@"; do
        case $_dt_f in
            again|sagain|'(eval)') ;;
            *) unset _dt_f; return 1 ;;
        esac
    done
    unset _dt_f
    return 0
}

# ========== wrapper generator ==========

# _wrap <func> <modern> <modern_flags> <fallback> <fallback_flags>
# A wrapper with a native fallback runs the modern tool only when typed at the
# prompt (_den_typed); one with none (lt, ripgrep) always does.
_wrap() {
    _w_name="$1" _w_mod="$2" _w_mf="$3" _w_fb="$4" _w_fbf="$5"
    _w_typed=
    [ -n "$_w_fb" ] && _w_typed=" && _den_typed"
    eval "${_w_name}() {
        if [ \"\${_DEN_WRAPPERS:-1}\" != \"0\" ] && command -v ${_w_mod} >/dev/null 2>&1${_w_typed}; then
            _wrap_log \"${_w_name}\" \"${_w_mod}\" \"${_w_fb}\" \"${_w_fbf}\"
            ${_w_mod} ${_w_mf} \"\$@\"
        elif [ -n \"${_w_fb}\" ]; then
            command ${_w_fb} ${_w_fbf} \"\$@\"
        else
            echo \"${_w_name}: ${_w_mod} is not installed.\" >&2; return 1
        fi
    }"
    unset _w_name _w_mod _w_mf _w_fb _w_fbf _w_typed
}

# _wsfx <func> <modern> <modern_flags> — always use modern (w-suffix bypass)
_wsfx() {
    _ww_n="$1" _ww_m="$2" _ww_f="$3"
    eval "${_ww_n}() {
        if command -v ${_ww_m} >/dev/null 2>&1; then
            ${_ww_m} ${_ww_f} \"\$@\"
        else
            echo \"${_ww_n}: ${_ww_m} is not installed.\" >&2; return 1
        fi
    }"
    unset _ww_n _ww_m _ww_f
}

# ========== toggle ==========

toggle-wrapper() {
    if [ "${_DEN_WRAPPERS:-1}" != "0" ]; then
        export _DEN_WRAPPERS=0
        export STARSHIP_WRAPPER_STATE="OFF"
        echo "wrappers: OFF (using native commands)"
    else
        export _DEN_WRAPPERS=1
        unset STARSHIP_WRAPPER_STATE
        echo "wrappers: ON (using modern tools)"
    fi
}

# tgl-wr → short name for toggle-wrapper.
# A function, not an alias: aliases expand only in interactive shells.
tgl-wr() {
    toggle-wrapper "$@"
}

# ========== PATH ==========

# _init_path <dir>... — add to PATH if not already present
_init_path() {
    for _ip_d in "$@"; do
        case ":$PATH:" in *":$_ip_d:"*) ;; *) export PATH="$_ip_d:$PATH" ;; esac
    done
    unset _ip_d
}

# ========== source loader ==========

_source_all() {
    _sa_d="${1:-$HOME/.config/shell}"
    for _sa_f in wrappers.sh functions.sh aliases.sh hwinfo.sh python.sh ffmpeg.sh parallel.sh proxy.sh snippet.sh cheat.sh; do
        [ -f "$_sa_d/$_sa_f" ] && . "$_sa_d/$_sa_f"
    done
    unset _sa_d _sa_f
}

# ========== cache init ==========

# _init_cache <tool> <shell> [extra_args...]
# NOTE: umask 077 and symlink/owner checks are required — do not remove.
_init_cache() {
    _ic_t="$1"; _ic_s="$2"; shift 2
    _ic_d="${XDG_CACHE_HOME:-$HOME/.cache}/shell"
    # Only fork the subshell+mkdir and the external chmod when the dir is missing;
    # on the warm path it already exists, and sourcing is guarded per-FILE by the
    # [ -L ]/[ -O ] checks below regardless of dir perms. Avoids ~4 forks on every
    # interactive shell (2 cache calls x mkdir+chmod).
    if [ ! -d "$_ic_d" ]; then
        (umask 077 && mkdir -p -- "$_ic_d") || { unset _ic_t _ic_s _ic_d; return 0; }
        chmod 700 -- "$_ic_d" 2>/dev/null
    fi
    _ic_f="$_ic_d/${_ic_t}-init.${_ic_s}"
    _ic_b=$(command -v "$_ic_t" 2>/dev/null)
    if [ -n "$_ic_b" ]; then
        # Regenerate cache when missing or older than the binary (binary upgrade)
        if [ ! -f "$_ic_f" ] || [ "$_ic_b" -nt "$_ic_f" ]; then
            (umask 077 && "$_ic_t" init "$_ic_s" "$@" > "$_ic_f")
        fi
        # Owner check ([ -O ]) guards against another user writing the file on
        # shared cache paths. POSIX-optional but supported in bash/dash/zsh/ash.
        if [ -L "$_ic_f" ]; then
            echo "_init_cache: refusing to source symlink '$_ic_f'" >&2
        elif [ -O "$_ic_f" ]; then
            . "$_ic_f"
        else
            echo "_init_cache: refusing to source '$_ic_f' (not owned by current user)" >&2
        fi
    fi
    unset _ic_t _ic_s _ic_d _ic_f _ic_b
}
