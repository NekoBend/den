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

# pip → the active venv's own pip when it has one, else uv pip, which installs
# into the active venv: a venv made by uv (vv, vva) has no pip, and a PATH
# lookup then found another Python's pip, which installed there. With no venv
# active, pip runs nothing: uv pip would pick an environment itself, the .venv
# in this directory or one above it, and run the python in it, which may be one
# a cloned repository committed. va activates a venv after checking that it did
# not come with the clone.
# uv pip reads only your own uv settings, as pip reads no uv.toml or
# pyproject.toml: uv reads them from this directory and the ones above it, and
# a clone's settings there can have it run a python the clone ships ([pip]
# python) or install a package from the clone's own files (find-links). uv
# --config-file reads the one file _den_uv_config names in place of all of
# those, and with none, uv --no-config reads none. The line on stderr says
# which, and typed uv pip reads them all.
pip() {
    local cfg
    if [ -z "$VIRTUAL_ENV" ]; then
        printf 'pip: no venv is active; activate one with va, or type uv pip%s directly\n' "${*:+ $*}" >&2
        return 1
    elif [ -x "$VIRTUAL_ENV/bin/pip" ]; then
        "$VIRTUAL_ENV/bin/pip" "$@"
    elif cfg=$(_den_uv_config); then
        _show_uv_only_message "pip${*:+ $*}" "uv --config-file $cfg pip${*:+ $*} (reads your uv settings, not a uv.toml or pyproject.toml here or above, which a clone can ship; type uv pip to read those)"
        command uv --config-file "$cfg" pip "$@"
    else
        _show_uv_only_message "pip${*:+ $*}" "uv --no-config pip${*:+ $*} (reads no uv.toml or pyproject.toml here or above, which a clone can ship; type uv pip to read those)"
        command uv --no-config pip "$@"
    fi
}

# pip3 → the same, with an active venv's own pip3
pip3() {
    local cfg
    if [ -z "$VIRTUAL_ENV" ]; then
        printf 'pip3: no venv is active; activate one with va, or type uv pip%s directly\n' "${*:+ $*}" >&2
        return 1
    elif [ -x "$VIRTUAL_ENV/bin/pip3" ]; then
        "$VIRTUAL_ENV/bin/pip3" "$@"
    elif cfg=$(_den_uv_config); then
        _show_uv_only_message "pip3${*:+ $*}" "uv --config-file $cfg pip${*:+ $*} (reads your uv settings, not a uv.toml or pyproject.toml here or above, which a clone can ship; type uv pip to read those)"
        command uv --config-file "$cfg" pip "$@"
    else
        _show_uv_only_message "pip3${*:+ $*}" "uv --no-config pip${*:+ $*} (reads no uv.toml or pyproject.toml here or above, which a clone can ship; type uv pip to read those)"
        command uv --no-config pip "$@"
    fi
}

# _den_py_exe → print the python to run in uv run's place when no venv's own
# runs: the system Python uv finds, else one uv installed (uv python install).
# Fails when there is none. --system skips the .venv here, and --no-config the
# .python-version, uv.toml and pyproject.toml here: a .python-version may name
# a program in the repository, which uv would run to ask its version.
_den_py_exe() {
    local p kind
    for kind in --no-managed-python --managed-python; do
        p=$(command uv python find --system --no-config "$kind" 2>/dev/null) &&
            [ -n "$p" ] && [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

# _den_py <name> [args...] → python, python3 and py: uv run python, with the
# version of the venv va activated, and outside a venv a line on stderr that
# says so. Not where uv run would build or run code that came with a clone:
# with one of _den_py_marker's files in this directory or one above it, uv run
# builds that project (its build backend is the repository's own code) or runs
# a python it names, even for `python --version`. There a python runs directly,
# for --version and -V too: the active venv's own, with no line, as on cmd,
# else, after a line on stderr, the one _den_py_exe names. Elsewhere --version
# and -V go through uv run as well, so they name the python that `python x.py`
# runs.
_den_py() {
    local name=$1 marker exe
    shift
    if marker=$(_den_py_marker); then
        if [ -n "$VIRTUAL_ENV" ]; then
            for exe in "$VIRTUAL_ENV/bin/python" "$VIRTUAL_ENV/Scripts/python.exe"; do
                if [ -x "$exe" ]; then
                    "$exe" "$@"
                    return
                fi
            done
        fi
        if ! exe=$(_den_py_exe); then
            printf '%s: no Python found to run in place of uv run; uv python install installs one\n' "$name" >&2
            return 1
        fi
        printf '%s: running %s, not uv run: uv run would build or run code from %s\n' "$name" "$exe" "$marker" >&2
        "$exe" "$@"
    elif [ -n "$VIRTUAL_ENV" ] && [ -n "$_DEN_VENV_PYTHON" ]; then
        command uv run --python "$_DEN_VENV_PYTHON" -- python "$@"
    else
        _show_uv_only_message "$name${*:+ $*}" "uv run -- python${*:+ $*}"
        command uv run -- python "$@"
    fi
}

# python, python3, py → _den_py
python() { _den_py python "$@"; }
python3() { _den_py python3 "$@"; }
py() { _den_py py "$@"; }

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
    # would run it. Not a git repo, or no git, means nothing to check: pass. So the
    # check covers git checkouts only: a venv that came in an archive or a shared
    # folder is sourced as it is, as `source` would source it.
    # A venv tool makes bin/ and bin/activate a real directory and file. A symlink
    # there reads the script from elsewhere, and git reports only the link itself,
    # not a tracked file behind it: refuse it. A symlinked venv directory (.venv ->
    # ~/venvs/proj) is fine; git -C follows it into the venv's own repository.
    if [ -L "$name/bin" ] || [ -L "$activate" ]; then
        echo "va: $name: bin/ or bin/activate is a symlink, which no venv tool makes; source it yourself if you trust it: source $activate" >&2
        return 1
    fi
    local tracked why nl='
'
    if command -v git >/dev/null 2>&1; then
        # Ask from inside bin/, about all of it: git then learns the directory's
        # name from the file system (Git for Windows asks it for the stored name),
        # so "." lists what is tracked there under a spelling the file system folds
        # and :(icase), which folds ASCII only, does not. The ../ pathspecs keep
        # :(icase) for bin/ and reach pyvenv.cfg.
        # The -f test above ignores case on default APFS and git pathspecs do not, so
        # :(icase) also catches a committed BIN/activate. The exact names still match
        # when GIT_LITERAL_PATHSPECS=1 makes :(icase) a plain file name.
        # safe.bareRepository=explicit: a venv committed with a HEAD, objects/,
        # refs/ and a config of its own is a repository git would read instead,
        # with an empty index (nothing tracked) and a core.fsmonitor it runs. Git
        # then refuses, and the refusal below fails closed. Git before 2.38 ignores
        # the key and cannot be kept out of such a repository.
        # core.fsmonitor= (empty, off): the enclosing repository's .git/config,
        # which an archive or a shared folder can deliver with the tree, may name
        # a program git runs when it reads the index, even for a venv it then
        # refuses. Empty, not false: git 2.36 and later read the key as a boolean
        # first (fsmonitor-settings.c, lookup_fsmonitor_settings), and an empty
        # value is false; git 2.16 to 2.35 read it as the path of a hook alone
        # and take an empty one for none (config.c, git_config_get_fsmonitor),
        # where false names a program to run. Git before 2.16 has no fsmonitor.
        # The other programs such a config can name (hooks, filters,
        # diff.external, core.sshCommand) do not run for ls-files, and its pager
        # runs on a terminal only, which these calls' output never is.
        if ! tracked="$(command git -c core.fsmonitor= -c safe.bareRepository=explicit -C "$name/bin" ls-files -- . ../bin ':(icase)../bin' ../pyvenv.cfg ':(icase)../pyvenv.cfg' 2>/dev/null)"; then
            # Fail closed: only "not a git repository" means nothing to check. Any
            # other failure, such as a checkout git will not open for dubious
            # ownership, leaves a committed venv possible. Any line of git's, as
            # trace lines may come first, and only from its start, as other
            # messages quote a path that may hold the same words.
            why="$nl$(LC_ALL=C command git -c core.fsmonitor= -c safe.bareRepository=explicit -C "$name/bin" ls-files -- . 2>&1 >/dev/null)"
            case "$why" in
                *"${nl}fatal: "[Nn]"ot a git repository"*) tracked="" ;;
                *)
                    # Show git's fatal line, else its first.
                    case "$why" in *"${nl}fatal:"*) why="${nl}fatal:${why#*"${nl}fatal:"}" ;; esac
                    why="${why#"$nl"}"
                    why="${why%%"$nl"*}"
                    echo "va: $name: git could not tell whether the venv is committed (${why:-git failed}); source it yourself if you trust it: source $activate" >&2
                    return 1
                    ;;
            esac
        fi
        if [ -n "$tracked" ]; then
            # Name what git actually reports: the match may be pyvenv.cfg alone, so
            # a message about the activate script would be wrong. git names paths
            # from bin/; name them from the venv, as the message always has.
            tracked="$(printf '%s\n' "$tracked" | sed -e 's|^|bin/|' -e 's|^bin/\.\./||')"
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

# _den_py_marker → print the pyproject.toml, .venv, pyvenv.cfg, uv.toml or
# .python-version that uv run would read from here: the first one in this
# directory or a directory above it. uv takes a directory that holds a
# pyvenv.cfg for a venv, whatever its name, and runs the python in it; a
# uv.toml's settings can have it install and run a python the clone ships; and
# it runs the program a .python-version names to ask its version (a
# .python-versions as well, which it reads the same way). A .python-version
# counts only when it names a path, comment (#) and blank lines aside: a line
# with / or \ in it, or one that, trimmed of white space as uv trims it, names
# a file or directory in the current directory. uv looks such a name up there,
# not beside the file, and takes a directory for a venv and runs its python.
# One that holds version requests alone (3.13, cpython@3.13) does not count,
# so a pyenv ~/.python-version leaves home alone, unless the current directory
# holds something of the same name. Fails when there is none. uv starts from
# the directory the system reports, with its symbolic links resolved (pwd -P).
# _den_py_marker <dir> <cwd> → the same for uv started elsewhere (vv and vva,
# see _den_uv_venv): the walk starts from <dir>, and a bare name is looked up
# in <cwd>, the directory uv runs in.
# Defined here, with vv and vva, not with the overrides that toggle-uv removes:
# vv and vva ask it with the overrides off as well.
_den_py_marker() {
    local d f l n t w c rest ws='' here=${2-} nl='
'
    d=${1-}
    # $( ) drops every newline at the end of what it captures, pwd's own and
    # those of a directory whose name ends in one, which would walk from
    # another directory: the x after them keeps those of the name, and the
    # newline before it is pwd's.
    if [ -z "$d" ]; then
        if d=$(pwd -P 2>/dev/null && printf x); then
            d=${d%x}
            d=${d%"$nl"}
        else
            d=$PWD
        fi
    fi
    while :; do
        for f in pyproject.toml .venv pyvenv.cfg uv.toml .python-version .python-versions; do
            [ -e "${d%/}/$f" ] || continue
            if [ "$f" = .python-version ] || [ "$f" = .python-versions ]; then
                # A regular file, as uv reads: a link to /dev/zero or a FIFO
                # would not end.
                [ -f "${d%/}/$f" ] && [ -r "${d%/}/$f" ] || continue
                n=0
                while IFS= read -r l || [ -n "$l" ]; do
                    case $l in ''|'#'*) continue ;; esac
                    # A line over 128 characters, or a 65th one, counts without
                    # the checks below: no version request is that long, nor
                    # is a file of them, and trimming such lines here would
                    # take seconds.
                    n=$((n + 1))
                    if [ "$n" -gt 64 ] || [ "${#l}" -gt 128 ]; then
                        printf '%s\n' "${d%/}/$f"
                        return 0
                    fi
                    case ${l#"${l%%[! ]*}"} in
                        '#'*) continue ;;
                        *[/\\]*) printf '%s\n' "${d%/}/$f"; return 0 ;;
                    esac
                    # uv trims each line with Rust's str::trim, which takes off
                    # the Unicode White_Space characters: here in UTF-8, each
                    # followed by a comma.
                    [ -n "$ws" ] || ws=$(printf ' ,\t,\v,\f,\r,\302\205,\302\240,\341\232\200,\342\200\200,\342\200\201,\342\200\202,\342\200\203,\342\200\204,\342\200\205,\342\200\206,\342\200\207,\342\200\210,\342\200\211,\342\200\212,\342\200\250,\342\200\251,\342\200\257,\342\201\237,\343\200\200,')
                    t=$l
                    while :; do
                        w=$t
                        rest=$ws
                        while [ -n "$rest" ]; do
                            c=${rest%%,*}
                            rest=${rest#*,}
                            case $t in "$c"*) t=${t#"$c"} ;; esac
                            case $t in *"$c") t=${t%"$c"} ;; esac
                        done
                        [ "$t" = "$w" ] && break
                    done
                    case $t in ''|'#'*) continue ;; esac
                    if [ -e "${here:+${here%/}/}$t" ]; then
                        printf '%s\n' "${d%/}/$f"
                        return 0
                    fi
                done < "${d%/}/$f"
                continue
            fi
            printf '%s\n' "${d%/}/$f"
            return 0
        done
        case $d in ''|/) return 1 ;; esac
        d=${d%/*}
    done
}

# _den_uv_config → print the uv.toml of your own that uv reads besides a
# project's, for uv --config-file to read in place of them all: the file
# UV_CONFIG_FILE names (uv reads it even under UV_NO_CONFIG); else, unless
# UV_NO_CONFIG is true, the user one, $XDG_CONFIG_HOME/uv/uv.toml (an absolute
# XDG_CONFIG_HOME only, as uv takes) or ~/.config/uv/uv.toml; else, unless
# UV_NO_SYSTEM_CONFIG is true, the system one, uv/uv.toml in the first of
# $XDG_CONFIG_DIRS (/etc/xdg) that has one, else /etc/uv/uv.toml. uv reads an
# XDG_CONFIG_DIRS entry that is not absolute from the current directory, where
# a clone can ship one: such entries are skipped here. uv merges the user and
# the system file, and --config-file reads one: with both, the user one, and
# the system one's settings are left out. Fails when there is none. Not one of
# the overrides that toggle-uv removes: vv and vva ask it with them off as well.
_den_uv_config() {
    local f rest
    if [ -n "${UV_CONFIG_FILE-}" ]; then
        printf '%s\n' "$UV_CONFIG_FILE"
        return 0
    fi
    # The values uv takes for true, in any case.
    case ${UV_NO_CONFIG-} in [1Yy]|[Yy][Ee][Ss]|[Tt]|[Tt][Rr][Uu][Ee]|[Oo][Nn]) return 1 ;; esac
    case ${XDG_CONFIG_HOME-} in
        /*) f=$XDG_CONFIG_HOME/uv/uv.toml ;;
        *) f=$HOME/.config/uv/uv.toml ;;
    esac
    if [ -f "$f" ]; then
        printf '%s\n' "$f"
        return 0
    fi
    case ${UV_NO_SYSTEM_CONFIG-} in [1Yy]|[Yy][Ee][Ss]|[Tt]|[Tt][Rr][Uu][Ee]|[Oo][Nn]) return 1 ;; esac
    rest=${XDG_CONFIG_DIRS:-/etc/xdg}:
    while [ -n "$rest" ]; do
        f=${rest%%:*}
        rest=${rest#*:}
        case $f in /*) ;; *) continue ;; esac
        if [ -f "$f/uv/uv.toml" ]; then
            printf '%s\n' "$f/uv/uv.toml"
            return 0
        fi
    done
    if [ -f /etc/uv/uv.toml ]; then
        printf '%s\n' /etc/uv/uv.toml
        return 0
    fi
    return 1
}

# _den_uv_venv <name> [args...] → vv and vva: uv venv, but where
# _den_py_marker finds a file, as python runs no uv run there, uv --no-config
# venv after a line on stderr: uv venv runs the program a .python-version
# names to ask its version, and a uv.toml's or pyproject.toml's settings can
# have it run a python the clone ships, or install one from the clone's own
# files and run it, --python 3.13 given or not. --no-config skips those files,
# and with them a .python-version that only pins a version, yours in uv's
# config directory too: the line says to pick a python with --python, or to
# type uv venv. With a uv.toml of your own (_den_uv_config), --config-file
# reads it, as --no-config alone would not, and still no .python-version.
# The walk starts where uv's does. uv first enters the directory --directory
# names (else UV_WORKING_DIR, else UV_WORKING_DIRECTORY) and reads from there
# as it would from here. --project (else UV_PROJECT) names the directory its
# walk starts from instead, or a pyproject.toml in it, taken from the one uv
# runs in, where a .python-version's bare name is still looked up. The options
# count as uv 0.13.6 parses them: before a --, as --directory DIR or
# --directory=DIR; uv refuses a second one, and a value that starts with -, so
# no other option's value is one.
_den_uv_venv() {
    local name=$1 marker='' cfg a next='' dir project here start at='here or above' there='here or above' nl='
'
    shift
    dir=${UV_WORKING_DIR-${UV_WORKING_DIRECTORY-}}
    project=${UV_PROJECT-}
    for a in "$@"; do
        case $next in
            d) dir=$a; next=''; continue ;;
            p) project=$a; next=''; continue ;;
        esac
        case $a in
            --) break ;;
            --directory) next=d ;;
            --directory=*) dir=${a#--directory=} ;;
            --project) next=p ;;
            --project=*) project=${a#--project=} ;;
        esac
    done
    if [ -z "$dir" ] && [ -z "$project" ]; then
        marker=$(_den_py_marker)
    # The directory uv runs in, with its symbolic links resolved, as uv reads
    # it back: a relative one from here, entered as ./DIR so that cd takes no
    # CDPATH entry and no - or +N for a directory it remembers, with the
    # builtin past a cd function, and with zsh's -q, which runs no chpwd hook
    # (zoxide's records the directory). Where cd cannot enter it, uv cannot
    # either, and stops before it reads anything. The x keeps the newlines
    # that end a directory's name, as in _den_py_marker.
    elif here=$(
        case $dir in
            '') ;;
            /*) builtin cd ${ZSH_VERSION:+-q} -P -- "$dir" ;;
            *) builtin cd ${ZSH_VERSION:+-q} -P -- "./$dir" ;;
        esac >/dev/null 2>&1 && builtin pwd -P && printf x
    ); then
        here=${here%x}
        here=${here%"$nl"}
        start=$here
        if [ -n "$project" ]; then
            # Made absolute from there and normalized by name, as uv does: .
            # and empty names go, and .. takes the name before it with it.
            case $project in /*) a=$project/ ;; *) a=$here/$project/ ;; esac
            start=''
            while [ -n "$a" ]; do
                case ${a%%/*} in
                    ''|.) ;;
                    ..) start=${start%/*} ;;
                    *) start=$start/${a%%/*} ;;
                esac
                a=${a#*/}
            done
            case $start in */pyproject.toml) [ -f "$start" ] && start=${start%/*} ;; esac
            start=${start:-/}
        fi
        at="in or above $start" there='there or above'
        marker=$(_den_py_marker "$start" "$here")
    fi
    if [ -z "$marker" ]; then
        command uv venv "$@"
    elif cfg=$(_den_uv_config); then
        printf '%s: uv --no-config --config-file %s venv, as %s is %s (reads your uv settings, not a .python-version, uv.toml or pyproject.toml %s, which a clone can ship, nor your global .python-version; pick a python with --python, or type uv venv to read those)\n' "$name" "$cfg" "$marker" "$at" "$there" >&2
        command uv --no-config --config-file "$cfg" venv "$@"
    else
        printf '%s: uv --no-config venv, as %s is %s (reads no .python-version, uv.toml or pyproject.toml %s, which a clone can ship, nor your global .python-version; pick a python with --python, or type uv venv to read those)\n' "$name" "$marker" "$at" "$there" >&2
        command uv --no-config venv "$@"
    fi
}

# vv → uv venv (create only)
vv() {
    _den_uv_venv vv "$@"
}

# vva → uv venv + activate (default: .venv)
vva() {
    _den_uv_venv vva "$@" && va "${1:-.venv}"
}

# ===== Toggles =====

# toggle-uv → flip uv python/pip override on/off
toggle-uv() {
    if [ "${_DEN_UV_OVERRIDE:-1}" = "1" ]; then
        unset -f uv python python3 pip pip3 py _show_uv_only_message _den_py _den_py_exe 2>/dev/null
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
