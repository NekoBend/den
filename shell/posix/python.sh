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
    if [ -n "$VIRTUAL_ENV" ] && [ -n "$_DEN_VENV_PYTHON" ] && [ "$1" = "run" ]; then
        shift
        # `--` ends uv's OWN option parsing, so injecting it unconditionally turned
        # every `uv run` option into the command to spawn (`uv run --with rich app.py`
        # -> "Failed to spawn: --with"). Only separate when the first user argument
        # cannot be mistaken for a uv option.
        case "${1-}" in
            -*) command uv run --python "$_DEN_VENV_PYTHON" "$@" ;;
            *)  command uv run --python "$_DEN_VENV_PYTHON" -- "$@" ;;
        esac
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
    if [ -n "$VIRTUAL_ENV" ] && [ -n "$_DEN_VENV_PYTHON" ]; then
        command uv run --python "$_DEN_VENV_PYTHON" -- python "$@"
    else
        _show_uv_only_message "py${*:+ $*}" "uv run -- python${*:+ $*}"
        command uv run -- python "$@"
    fi
}

# python → uv run python (uses venv version when active)
python() {
    if [ -n "$VIRTUAL_ENV" ] && [ -n "$_DEN_VENV_PYTHON" ]; then
        command uv run --python "$_DEN_VENV_PYTHON" -- python "$@"
    else
        _show_uv_only_message "python${*:+ $*}" "uv run -- python${*:+ $*}"
        command uv run -- python "$@"
    fi
}

# python3 → uv run python (uses venv version when active)
python3() {
    if [ -n "$VIRTUAL_ENV" ] && [ -n "$_DEN_VENV_PYTHON" ]; then
        command uv run --python "$_DEN_VENV_PYTHON" -- python "$@"
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
    local activate="$name/bin/activate"
    if [ ! -f "$activate" ]; then
        echo "activate script not found: $activate" >&2
        return 1
    fi
    # The activate script runs in THIS shell, so the venv's own content is checked
    # the way pyvenv.cfg below already is. A venv you create is untracked; a venv
    # COMMITTED to a repo (git tracks .venv happily, even force-added past a
    # .gitignore) is code that arrived with the clone, and `va` in a fresh checkout
    # would run it. Not a git repo, or no git, means nothing to check: pass.
    if [ -n "$(command git -C "$name" ls-files -- bin/activate pyvenv.cfg 2>/dev/null)" ]; then
        echo "va: $activate is tracked by git (a venv committed to the repo) — source it yourself if you trust it: source $activate" >&2
        return 1
    fi
    # Anyone-can-rewrite is the other way this file stops being ours. World-writable
    # check without stat(1), whose output differs across platforms: position 9 of
    # the `ls -l` mode string is the other-write bit.
    case "$(command ls -ld -- "$activate" 2>/dev/null)" in
        ????????w*)
            echo "va: $activate is world-writable — source it yourself if you trust it: source $activate" >&2
            return 1
            ;;
    esac
    source "$activate"
    local pyver pyver_raw
    pyver_raw="$(sed -n 's/^version_info[[:space:]]*=[[:space:]]*//p' "$name/pyvenv.cfg" 2>/dev/null)"
    # Strip trailing CR for Windows-CRLF pyvenv.cfg.
    pyver_raw="${pyver_raw%"$(printf '\r')"}"
    # virtualenv (tox, nox, the virtualenv CLI) writes all five version_info fields,
    # e.g. "3.12.3.final.0", which uv reads as an executable NAME and rejects; keep
    # the MAJOR.MINOR.PATCH prefix uv understands.
    pyver="$(printf '%s' "$pyver_raw" | cut -d. -f1-3)"
    # NOTE: allowlist validation is required — do not remove (pyvenv.cfg is untrusted).
    # Digits and dots only, leading digit required: a version request is all this
    # value is ever used for.
    case "$pyver" in
        ''|[!0-9]*|*[!0-9.]*)
            [ -n "$pyver_raw" ] && echo "va: rejecting suspicious version_info='$pyver_raw' from pyvenv.cfg" >&2
            unset _DEN_VENV_PYTHON
            ;;
        *)
            export _DEN_VENV_PYTHON="$pyver"
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
    unset _DEN_VENV_PYTHON
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
    if [ "${_DEN_UV_OVERRIDE:-1}" = "1" ]; then
        unset -f uv python python3 pip pip3 py _show_uv_only_message 2>/dev/null
        export _DEN_UV_OVERRIDE=0
        echo "uv override: OFF (using system python/pip)"
    else
        . "${HOME}/.config/shell/python.sh"
        export _DEN_UV_OVERRIDE=1
        echo "uv override: ON (python/pip → uv)"
    fi
}

fi
