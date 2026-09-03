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
        md5|sha256|sha512) ;;
        *)
            echo "usage: digest {md5|sha256|sha512} <file...>" >&2
            return 1
            ;;
    esac
    _h_algo="$1"; shift
    if [ $# -eq 0 ]; then
        echo "usage: digest $_h_algo <file...>" >&2
        unset _h_algo
        return 1
    fi
    # One file prints the bare hash (scriptable); several print hash and
    # name per line, like the *sum tools, so the lines stay attributable.
    _h_many=$#
    _h_fail=0
    for _h_f in "$@"; do
        if [ ! -f "$_h_f" ]; then
            echo "digest: '$_h_f' is not a file" >&2
            _h_fail=1
            continue
        fi
        # Neutralize a leading-dash filename so it is not parsed as an option.
        case "$_h_f" in -*) _h_f="./$_h_f" ;; esac
        if [ "$_h_many" -gt 1 ]; then
            "${_h_algo}sum" "$_h_f" | awk -v f="$_h_f" '{ print $1 "  " f }'
        else
            "${_h_algo}sum" "$_h_f" | awk '{ print $1 }'
        fi
    done
    unset _h_algo _h_f _h_many
    if [ "$_h_fail" -ne 0 ]; then unset _h_fail; return 1; fi
    unset _h_fail
    return 0
}

# mkfile → create a dummy file of specified size (e.g. mkfile 10M test.bin)
mkfile() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "usage: mkfile <size> <path>  (e.g. mkfile 10M test.bin)" >&2
        return 1
    fi
    # Neutralise a leading-dash path so truncate cannot parse it as an option
    # (parity with extract/archive/digest/mkcd).
    _mf_path="$2"
    case "$_mf_path" in -*) _mf_path="./$_mf_path" ;; esac
    truncate -s "$1" "$_mf_path" && echo "Created $_mf_path ($1)"
    unset _mf_path
}

# _ar_have → guard one branch of extract()/archive() on the tool it needs.
# Usage: _ar_have <caller> <tool>. A missing compressor becomes that caller's
# own per-item failure instead of a stray "command not found" from the branch,
# and archive() calls it BEFORE the redirection that would create the output.
_ar_have() {
    command -v "$2" >/dev/null 2>&1 && return 0
    echo "$1: $2 is not installed" >&2
    return 1
}

# extract → auto-detect and extract archives
# NOTE: leading-dash './' prefix is required — do not remove. The 7z branch
# neutralises a leading '@' on top of that; see the comment there.
extract() {
    if [ $# -eq 0 ]; then
        echo "usage: extract <file...>" >&2
        return 1
    fi
    # Every argument is an archive; each is extracted in turn and a failure
    # on one does not hide the others (the exit code is 1 if any failed).
    _ex_fail=0
    for _ex_f in "$@"; do
        if [ ! -f "$_ex_f" ]; then
            echo "extract: '$_ex_f' is not a file" >&2
            _ex_fail=1
            continue
        fi
        # Neutralise leading dash so downstream tools cannot parse filename as option
        case "$_ex_f" in -*) _ex_f="./$_ex_f" ;; esac
        case "$_ex_f" in
            *.tar.gz|*.tgz)     tar xzf "$_ex_f"   ;;
            *.tar.bz2|*.tbz2)   tar xjf "$_ex_f"   ;;
            *.tar.xz|*.txz)     tar xJf "$_ex_f"   ;;
            # tar shells zstd out for these, so the guard is on zstd, not tar.
            *.tar.zst|*.tzst)   _ar_have extract zstd && tar --zstd -xf "$_ex_f" ;;
            *.tar)              tar xf  "$_ex_f"    ;;
            # Single file: each tool writes the decompressed file next to the
            # archive. gunzip/bunzip2/unxz consume the archive and unzstd keeps
            # it — that is each tool's own default, and the pwsh twin matches.
            *.gz)               _ar_have extract gunzip  && gunzip  -- "$_ex_f" ;;
            *.bz2)              _ar_have extract bunzip2 && bunzip2 -- "$_ex_f" ;;
            *.xz)               _ar_have extract unxz    && unxz    -- "$_ex_f" ;;
            *.zst)              _ar_have extract unzstd  && unzstd  -- "$_ex_f" ;;
            *.zip)              unzip -- "$_ex_f"     ;;
            *.7z)
                # 7z reads a leading '-' as a switch (already neutralised
                # above) and a leading '@' as a listfile — it would extract
                # the archives named INSIDE that file rather than the file
                # itself. 7z is in neither this image nor
                # tests/shell/Dockerfile, so its '--' marker cannot be
                # exercised; './' neutralises both forms without depending on
                # marker support, as archive() does.
                case "$_ex_f" in @*) _ex_f="./$_ex_f" ;; esac
                7z x "$_ex_f"
                ;;
            *.rar)              unrar x -- "$_ex_f"   ;;
            *) echo "extract: unsupported format '$_ex_f'" >&2; false ;;
        esac || _ex_fail=1
    done
    unset _ex_f
    if [ "$_ex_fail" -ne 0 ]; then unset _ex_fail; return 1; fi
    unset _ex_fail
    return 0
}

# archive → create archive (format auto-detected from output filename)
# NOTE: './' normalisation on $out is required, and so is the end-of-options
# marker in front of the sources: every argument after $out is a source, never
# an option, so a file whose name looks like one (a glob picking up
# '--checkpoint-action=exec=...', say) cannot be parsed as an option and run
# by GNU tar. Do not remove either.
archive() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "usage: archive <output> <source...>" >&2
        return 1
    fi
    local out="$1"; shift
    local _ar_arg _ar_n _ar_tool _ar_tmp _ar_rc _ar_tmpd _ar_outdir
    # Neutralise leading dash on output path
    case "$out" in -*) out="./$out" ;; esac
    # A directory already sitting at the output path is not an output. Checked
    # for every format, before any of them starts: the single-file branch's
    # rename would otherwise put the temporary INSIDE that directory and report
    # success with no archive written at all, and the tar/zip branches only
    # fail late, with the archiver's own message.
    if [ -d "$out" ]; then
        echo "archive: output '$out' is a directory" >&2
        return 1
    fi
    case "$out" in
        *.tar.gz|*.tgz)     tar czf "$out" -- "$@"   ;;
        *.tar.bz2|*.tbz2)   tar cjf "$out" -- "$@"   ;;
        *.tar.xz|*.txz)     tar cJf "$out" -- "$@"   ;;
        # tar shells zstd out for these, so the guard is on zstd, not tar.
        *.tar.zst|*.tzst)   _ar_have archive zstd && tar --zstd -cf "$out" -- "$@" ;;
        *.tar)              tar cf "$out" -- "$@"    ;;
        # Single-file compression. Every '.tar.*' form and its 't*' alias is
        # matched above, so only a bare .gz/.bz2/.xz/.zst reaches here, and
        # these four tools compress exactly ONE file: several sources or a
        # directory is a usage error, not something to silently tar up first.
        *.gz|*.bz2|*.xz|*.zst)
            case "$out" in
                *.gz)  _ar_tool=gzip  ;;
                *.bz2) _ar_tool=bzip2 ;;
                *.xz)  _ar_tool=xz    ;;
                *)     _ar_tool=zstd  ;;
            esac
            # Exactly one source, and it must already be a regular file.
            # '-d' alone was false for a path that does not exist, so a typo'd
            # source got this far and the redirection below then created or
            # truncated the output before the compressor failed on it.
            if [ $# -ne 1 ] || [ ! -f "$1" ]; then
                echo "usage: archive <output.gz|.bz2|.xz|.zst> <one-file>" >&2
                return 1
            fi
            # Naming the source as the output is refused outright, for the
            # clear message: '-ef' compares device and inode, so a './'
            # spelling, a hard link and a chain of symlinks all resolve to the
            # same file and are caught. It is not what makes this SAFE, though
            # — the staging below is — so it can stay this cheap.
            # shellcheck disable=SC3013  # -ef: not in POSIX, but in dash/bash/zsh
            if [ "$out" -ef "$1" ]; then
                echo "archive: output '$out' is the source file" >&2
                return 1
            fi
            # The tool check comes before anything is written, so a missing
            # compressor leaves nothing behind at all.
            _ar_have archive "$_ar_tool" || return 1
            # Compress into a temporary sibling of the output and rename that
            # into place only once the compressor has succeeded. The file being
            # written is never the source under any name, so nothing can
            # truncate the source before it is read; a failed run leaves an
            # existing output exactly as it was; and the rename is atomic
            # because the temporary is in the output's own directory.
            # '--' stops each tool's option parsing (all four support it), so a
            # source named like a switch reaches it as a path — the same rule
            # the tar branches above follow.
            # Stage inside a private DIRECTORY, not a temporary file. mktemp
            # creates a file exclusively, but the compressor then reopens it by
            # pathname, and in a directory anyone else can write to that file
            # can be unlinked and replaced with a symlink in between -- the
            # exclusive creation does not survive being reopened. A 0700
            # directory (mktemp -d's default) nobody else can traverse means
            # the name inside it cannot be swapped at all, so there is no
            # window to race. A predictable-name fallback would give the window
            # straight back, so a missing mktemp is a missing tool like any
            # other, and the branch fails closed.
            case "$out" in
                */*) _ar_outdir="${out%/*}" ;;
                *)   _ar_outdir="." ;;
            esac
            _ar_have archive mktemp || return 1
            _ar_tmpd=$(command mktemp -d "$_ar_outdir/.archive.XXXXXX" 2>/dev/null)
            if [ -z "$_ar_tmpd" ]; then
                echo "archive: cannot create a temporary directory in '$_ar_outdir'" >&2
                return 1
            fi
            # The name inside is fixed: the directory is what makes it private,
            # and staging beside the output keeps the publish below a rename.
            _ar_tmp="$_ar_tmpd/archive"
            if [ "$_ar_tool" = zstd ]; then
                # zstd is the only one of the four with -o; the others have
                # none, so -k -c writes the bytes and the shell names the file.
                zstd -q -k -f -o "$_ar_tmp" -- "$1"
            else
                "$_ar_tool" -k -c -- "$1" > "$_ar_tmp"
            fi
            _ar_rc=$?
            if [ "$_ar_rc" -ne 0 ]; then
                # The compressor started and failed. Take the staging directory
                # with it and report ITS code, the way the tar and zip branches
                # report the archiver's; an existing output at $out was never
                # opened, so it is still whatever it was.
                rm -rf -- "$_ar_tmpd"
                return "$_ar_rc"
            fi
            # Inside a 0700 directory the file is 0600. The archive itself
            # should land with the user's umask, as the tar and zip branches'
            # outputs do -- 'umask -S' gives the directory form, so strip the
            # execute bits it carries.
            chmod "$(umask -S)" "$_ar_tmp" 2>/dev/null && chmod a-x "$_ar_tmp" 2>/dev/null
            # Publishing can fail too (a read-only directory, a full disk).
            # Report that, and take the staging directory with it on every exit
            # path rather than leaving one behind for the caller to find.
            mv -f -- "$_ar_tmp" "$out"
            _ar_rc=$?
            rm -rf -- "$_ar_tmpd"
            return "$_ar_rc"
            ;;
        *.zip)              zip -r "$out" -- "$@"    ;;
        *.7z)
            # 7z is not in the test image (tests/shell/Dockerfile), so a '--'
            # marker here cannot be exercised; give the two source names 7z
            # reads as something other than a path the './' prefix instead,
            # which neutralises them without depending on any marker support.
            # '-x' is a switch; '@list' is a listfile, i.e. 7z archives the
            # paths named INSIDE the file rather than the file itself.
            _ar_n=$#
            for _ar_arg in "$@"; do
                case "$_ar_arg" in -*|@*) _ar_arg="./$_ar_arg" ;; esac
                set -- "$@" "$_ar_arg"
            done
            shift "$_ar_n"
            7z a "$out" "$@"
            ;;
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
    _ag_tab="$(printf '\t')"  # real TAB for the leading-whitespace trim below
    _ag_i=1
    while [ "$_ag_i" -le 50 ]; do
        _ag_try="$(fc -ln "-$_ag_i" "-$_ag_i" 2>/dev/null)"
        while :; do
            case "$_ag_try" in
                ' '*)        _ag_try="${_ag_try# }" ;;
                "$_ag_tab"*) _ag_try="${_ag_try#"$_ag_tab"}" ;;
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
    unset _ag_found _ag_i _ag_try _ag_norm _ag_tab

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

