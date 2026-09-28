#!/bin/sh
# python.sh — Python / uv helper functions.
# Sourced by .bashrc / .zshrc via init script. POSIX sh compatible.
# Deploy target: ~/.config/shell/python.sh

# Skip in non-interactive shells
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0;; esac

# ===== uv overrides =====

# toggle-uv exports _DEN_UV_OVERRIDE, so a reload (a new shell) or a child shell
# inherits its OFF: define the overrides only when it is not 0, as toggle-uv left
# them, or its next call would take the OFF branch again and change nothing.
if [ "${_DEN_UV_OVERRIDE:-1}" != 0 ] && command -v uv >/dev/null 2>&1; then

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

# pip → uv pip (an active venv's own pip when it has one)
# A venv made by uv (vv, vva) has no pip: a PATH lookup then found another
# Python's pip, which installed there. uv pip installs into the active venv.
pip() {
    if [ -n "$VIRTUAL_ENV" ] && [ -x "$VIRTUAL_ENV/bin/pip" ]; then
        "$VIRTUAL_ENV/bin/pip" "$@"
    else
        _show_uv_only_message "pip${*:+ $*}" "uv pip${*:+ $*}"
        uv pip "$@"
    fi
}

# pip3 → uv pip (an active venv's own pip3 when it has one)
pip3() {
    if [ -n "$VIRTUAL_ENV" ] && [ -x "$VIRTUAL_ENV/bin/pip3" ]; then
        "$VIRTUAL_ENV/bin/pip3" "$@"
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
    # A venv tool makes bin/ and bin/activate a real directory and file. A symlink
    # there reads the script from elsewhere, and git reports only the link itself,
    # not a tracked file behind it: refuse it. A symlinked venv directory (.venv ->
    # ~/venvs/proj) is fine; git -C follows it into the venv's own repository.
    if [ -L "$name/bin" ] || [ -L "$activate" ]; then
        echo "va: $name: bin/ or bin/activate is a symlink, which no venv tool makes; source it yourself if you trust it: source $activate" >&2
        return 1
    fi
    local tracked why
    if command -v git >/dev/null 2>&1; then
        # Ask about all of bin/: a committed symlink bin -> ../scripts is listed as
        # "bin" and the files behind it not at all.
        # The -f test above ignores case on default APFS and git pathspecs do not, so
        # :(icase) also catches a committed BIN/activate. The exact names still match
        # when GIT_LITERAL_PATHSPECS=1 makes :(icase) a plain file name.
        # safe.bareRepository=explicit: a venv committed with a HEAD, objects/,
        # refs/ and a config of its own is a repository git would read instead,
        # with an empty index (nothing tracked) and a core.fsmonitor it runs. Git
        # then refuses, and the refusal below fails closed. Git before 2.38 ignores
        # the key and cannot be kept out of such a repository.
        if ! tracked="$(command git -c safe.bareRepository=explicit -C "$name" ls-files -- bin pyvenv.cfg ':(icase)bin' ':(icase)pyvenv.cfg' 2>/dev/null)"; then
            # Fail closed: only "not a git repository" means nothing to check. Any
            # other failure, such as a checkout git will not open for dubious
            # ownership, leaves a committed venv possible.
            why="$(LC_ALL=C command git -c safe.bareRepository=explicit -C "$name" ls-files -- bin 2>&1 >/dev/null | head -n 1)"
            case "$why" in
                *[Nn]"ot a git repository"*) tracked="" ;;
                *)
                    echo "va: $name: git could not tell whether the venv is committed (${why:-git failed}); source it yourself if you trust it: source $activate" >&2
                    return 1
                    ;;
            esac
        fi
        if [ -n "$tracked" ]; then
            # Name what git actually reports: the match may be pyvenv.cfg alone, so
            # a message about the activate script would be wrong.
            echo "va: $name: venv content is tracked by git ($(printf '%s' "$tracked" | tr '\n' ' ')) - a venv committed to the repo; source it yourself if you trust it: source $activate" >&2
            return 1
        fi
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
        # Set before the file is read: it defines the overrides only when not 0.
        export _DEN_UV_OVERRIDE=1
        . "${HOME}/.config/shell/python.sh"
        echo "uv override: ON (python/pip → uv)"
    fi
}

# tgl-uv → short name for toggle-uv
tgl-uv() {
    toggle-uv "$@"
}

fi
