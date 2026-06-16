#!/bin/sh
# _helpers.sh — DRY helpers for den shell config.
# Sourced first by init.bash / init.zsh. POSIX sh compatible.
# Deploy target: ~/.config/shell/_helpers.sh

# ========== wrapper log ==========

# _wrap_log <name> <modern> <fallback> <fallback_flags> — announce a modern-tool
# substitution (dim, stderr). Prints on EVERY wrapped call: the modern tool's
# flags and output differ from the native command, so a silent substitution is
# easy to miss (and tools or generated commands that assume the native behavior
# then break). The "native one-off" hint names the actual FALLBACK command
# (e.g. `command ls -A` for `la`), not the wrapper name, since wrappers like
# la/ll/lt have no binary of their own. Silence the notice with _DEN_WRAPPER_LOG=0.
_wrap_log() {
    [ "${_DEN_WRAPPER_LOG:-1}" = "0" ] && return 0
    if [ -n "$3" ]; then
        _wl_native="command $3${4:+ $4}"
    else
        _wl_native="(no native equivalent)"
    fi
    printf '\033[2m[den] %s -> %s  | native one-off: %s  | silence: _DEN_WRAPPER_LOG=0  | disable: toggle-wrapper or export _DEN_WRAPPERS=0\033[0m\n' "$1" "$2" "$_wl_native" >&2
    unset _wl_native
}

# ========== wrapper generator ==========

# _wrap <func> <modern> <modern_flags> <fallback> <fallback_flags>
_wrap() {
    _w_name="$1" _w_mod="$2" _w_mf="$3" _w_fb="$4" _w_fbf="$5"
    eval "${_w_name}() {
        if [ \"\${_DEN_WRAPPERS:-1}\" != \"0\" ] && command -v ${_w_mod} >/dev/null 2>&1; then
            _wrap_log \"${_w_name}\" \"${_w_mod}\" \"${_w_fb}\" \"${_w_fbf}\"
            ${_w_mod} ${_w_mf} \"\$@\"
        elif [ -n \"${_w_fb}\" ]; then
            command ${_w_fb} ${_w_fbf} \"\$@\"
        else
            echo \"${_w_name}: ${_w_mod} is not installed.\" >&2; return 1
        fi
    }"
    unset _w_name _w_mod _w_mf _w_fb _w_fbf
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
    for _sa_f in wrappers.sh functions.sh aliases.sh hwinfo.sh python.sh ffmpeg.sh parallel.sh; do
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
