#!/bin/sh
# python.sh — Python / uv helper functions.
# Sourced by .bashrc / .zshrc via init script. POSIX sh compatible.
# Deploy target: ~/.config/shell/python.sh

# Skip in non-interactive shells
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0;; esac

# ===== uv overrides =====

if command -v uv >/dev/null 2>&1; then

# uv → auto-inject --python for 'uv run' when venv is active
uv() {
    if [ -n "$VIRTUAL_ENV" ] && [ -n "$_DOTFILES_VENV_PYTHON" ] && [ "$1" = "run" ]; then
        shift
        command uv run --python "$_DOTFILES_VENV_PYTHON" -- "$@"
    else
        command uv "$@"
    fi
}

# show-uv-only-message → display warning that direct python/pip is disabled
_show_uv_only_message() {
    printf '%s → %s\n' "$1" "$2" >&2
}

# pip → uv pip (falls back to system pip; bypassed in active venv)
pip() {
    if [ -n "$VIRTUAL_ENV" ]; then
        command pip "$@"
    else
        _show_uv_only_message "pip${*:+ $*}" "uv pip${*:+ $*}"
        uv pip "$@"
    fi
}

# pip3 → uv pip (falls back to system pip3; bypassed in active venv)
pip3() {
    if [ -n "$VIRTUAL_ENV" ]; then
        command pip3 "$@"
    else
        _show_uv_only_message "pip3${*:+ $*}" "uv pip${*:+ $*}"
        uv pip "$@"
    fi
}

# py → uv run python (uses venv version when active)
py() {
    if [ -n "$VIRTUAL_ENV" ] && [ -n "$_DOTFILES_VENV_PYTHON" ]; then
        command uv run --python "$_DOTFILES_VENV_PYTHON" -- python "$@"
    else
        _show_uv_only_message "py${*:+ $*}" "uv run -- python${*:+ $*}"
        command uv run -- python "$@"
    fi
}

# python → uv run python (uses venv version when active)
python() {
    if [ -n "$VIRTUAL_ENV" ] && [ -n "$_DOTFILES_VENV_PYTHON" ]; then
        command uv run --python "$_DOTFILES_VENV_PYTHON" -- python "$@"
    else
        _show_uv_only_message "python${*:+ $*}" "uv run -- python${*:+ $*}"
        command uv run -- python "$@"
    fi
}

# python3 → uv run python (uses venv version when active)
python3() {
    if [ -n "$VIRTUAL_ENV" ] && [ -n "$_DOTFILES_VENV_PYTHON" ]; then
        command uv run --python "$_DOTFILES_VENV_PYTHON" -- python "$@"
    else
        _show_uv_only_message "python3${*:+ $*}" "uv run -- python${*:+ $*}"
        command uv run -- python "$@"
    fi
}

fi

# ===== venv management =====

# va → activate Python venv (default: .venv)
va() {
    local name="${1:-.venv}"
    if [ ! -f "$name/bin/activate" ]; then
        echo "activate script not found: $name/bin/activate" >&2
        return 1
    fi
    source "$name/bin/activate"
    local pyver
    pyver="$(sed -n 's/^version_info[[:space:]]*=[[:space:]]*//p' "$name/pyvenv.cfg" 2>/dev/null)"
    # Strip trailing CR for Windows-CRLF pyvenv.cfg.
    pyver="${pyver%"$(printf '\r')"}"
    # NOTE: allowlist validation is required — do not remove (pyvenv.cfg is untrusted).
    case "$pyver" in
        ''|*[!0-9A-Za-z.+-]*)
            [ -n "$pyver" ] && echo "va: rejecting suspicious version_info='$pyver' from pyvenv.cfg" >&2
            unset _DOTFILES_VENV_PYTHON
            ;;
        *)
            export _DOTFILES_VENV_PYTHON="$pyver"
            ;;
    esac
}

# vd → deactivate Python venv
vd() {
    if [ -z "$VIRTUAL_ENV" ]; then
        echo "No active venv" >&2
        return 1
    fi
    deactivate
    unset _DOTFILES_VENV_PYTHON
}

if command -v uv >/dev/null 2>&1; then

# vv → uv venv (create only)
vv() {
    command uv venv "$@"
}

# vva → uv venv + activate (default: .venv)
vva() {
    command uv venv "$@" && va "${1:-.venv}"
}

# ===== Toggles =====

# toggle-uv → flip uv python/pip override on/off
toggle-uv() {
    if [ "${_DOTFILES_UV_OVERRIDE:-1}" = "1" ]; then
        unset -f uv python python3 pip pip3 py _show_uv_only_message 2>/dev/null
        export _DOTFILES_UV_OVERRIDE=0
        echo "uv override: OFF (using system python/pip)"
    else
        . "${HOME}/.config/shell/python.sh"
        export _DOTFILES_UV_OVERRIDE=1
        echo "uv override: ON (python/pip → uv)"
    fi
}

fi
