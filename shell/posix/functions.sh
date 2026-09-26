#!/bin/sh
# functions.sh — Utility functions (file ops, system, navigation, history).
# Sourced by .bashrc / .zshrc. POSIX sh compatible.
# Deploy target: ~/.config/shell/functions.sh

# Skip in non-interactive shells
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0;; esac

# ===== File Utils =====

# _dg_usage → dg's usage text on stdout (a refusal sends it to stderr).
_dg_usage() {
    printf '%s\n' \
        "usage: dg [algo] <file...>        hash; one file prints the bare hash" \
        "       dg [algo] <file> <hash>    check a file against an expected hash" \
        "       dg -e [algo] <a> <b>       do a and b have the same content?" \
        "       dg -c <sumsfile...>        verify checksum files (GNU or BSD lines)" \
        "algo: md5|sha256|sha512 or 5|256|512; default sha256, or the one the" \
        "<hash>'s length implies. -- ends option and algo parsing. digest = dg."
}

# _dg_token → the algorithm an algo token names (md5, sha256, sha512; 5, 256
# and 512 are short for them), or status 1 when $1 is not one.
_dg_token() {
    case "$1" in
        md5|MD5|5)         echo md5 ;;
        sha256|SHA256|256) echo sha256 ;;
        sha512|SHA512|512) echo sha512 ;;
        *) return 1 ;;
    esac
}

# _dg_bylen → the algorithm whose hex digest is $1 characters long.
_dg_bylen() {
    case "$1" in
        32)  echo md5 ;;
        64)  echo sha256 ;;
        128) echo sha512 ;;
        *) return 1 ;;
    esac
}

# _dg_hash → the bare hash of file $2 with algorithm $1, in lowercase hex;
# status 1 (after the *sum tool's own message) when it cannot be read.
_dg_hash() {
    # Neutralize a leading-dash filename so it is not parsed as an option.
    case "$2" in -*) set -- "$1" "./$2" ;; esac
    # The hash is taken in a command substitution rather than piped into
    # awk, so the *sum tool's OWN status is still readable: a pipeline
    # reports the status of its last command, so an unreadable file --
    # `[ -f ]` is true for one -- used to leave the tool's "Permission
    # denied" on stderr while digest printed an empty line and returned 0.
    _dg_out=$("${1}sum" "$2") || return 1
    # "<hash>  <name>" from every *sum tool; cut at the first space. GNU
    # starts the line with a backslash when it had to escape the name (one
    # holding a backslash or a newline), and that is not part of the hash.
    _dg_out=${_dg_out%% *}
    printf '%s\n' "${_dg_out#\\}"
}

# _dg_expect → can $1 be an expected hash? Trimmed, lowercased and with an
# optional "md5:" / "sha256:" / "sha512:" prefix taken off (blanks after it
# too, as in "SHA256: <hex>"), it must be 32, 64 or 128 hex digits. Sets
# _dg_xh (the hex) and _dg_xp (the prefix's algorithm, or empty).
_dg_expect() {
    _dg_xh=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    _dg_xh=${_dg_xh#"${_dg_xh%%[![:space:]]*}"}
    _dg_xh=${_dg_xh%"${_dg_xh##*[![:space:]]}"}
    _dg_xp=
    case $_dg_xh in
        md5:*|sha256:*|sha512:*)
            _dg_xp=${_dg_xh%%:*}
            _dg_xh=${_dg_xh#*:}
            _dg_xh=${_dg_xh#"${_dg_xh%%[![:space:]]*}"}
            ;;
    esac
    case $_dg_xh in ''|*[!0123456789abcdef]*) return 1 ;; esac
    _dg_bylen "${#_dg_xh}" >/dev/null
}

# _dg_print → dg [algo] <file...>: $1 is the algorithm, then the files.
_dg_print() {
    _dg_a=$1; shift
    # One file prints the bare hash (scriptable); several print hash and
    # name per line, like the *sum tools, so the lines stay attributable.
    _dg_many=$#
    _dg_fail=0
    for _dg_f in "$@"; do
        if [ ! -f "$_dg_f" ]; then
            echo "dg: '$_dg_f' is not a file" >&2
            _dg_fail=1
            continue
        fi
        if ! _dg_h=$(_dg_hash "$_dg_a" "$_dg_f"); then
            _dg_fail=1
            continue
        fi
        if [ "$_dg_many" -gt 1 ]; then
            printf '%s  %s\n' "$_dg_h" "$_dg_f"
        else
            printf '%s\n' "$_dg_h"
        fi
    done
    return "$_dg_fail"
}

# _dg_compare → dg [algo] <file> <hash>: $1 is the algo token's algorithm
# (or empty), $2 the file, and _dg_expect has read the hash. The algorithm
# is the one the hash's length implies; an algo token or prefix that names
# another is refused. 0 OK, 1 MISMATCH, 2 when it cannot be checked.
_dg_compare() {
    _dg_by=$(_dg_bylen "${#_dg_xh}")
    for _dg_named in "$1" "$_dg_xp"; do
        if [ -n "$_dg_named" ] && [ "$_dg_named" != "$_dg_by" ]; then
            echo "dg: the expected hash is ${#_dg_xh} hex digits ($_dg_by), not $_dg_named" >&2
            return 2
        fi
    done
    if [ ! -f "$2" ]; then
        echo "dg: '$2' is not a file" >&2
        return 2
    fi
    _dg_h=$(_dg_hash "$_dg_by" "$2") || return 2
    if [ "$_dg_h" = "$_dg_xh" ]; then
        printf 'OK  %s\n' "$2"
        return 0
    fi
    printf 'MISMATCH  %s\n  expected %s\n  actual   %s\n' "$2" "$_dg_xh" "$_dg_h"
    return 1
}

# _dg_equal → dg -e [algo] <a> <b>: $1 is the algorithm, then the operands.
# 0 SAME, 1 DIFFERENT, 2 when they cannot be compared.
_dg_equal() {
    if [ $# -ne 3 ]; then
        echo "usage: dg -e [algo] <a> <b>" >&2
        return 2
    fi
    _dg_fail=0
    for _dg_f in "$2" "$3"; do
        if [ ! -f "$_dg_f" ]; then
            echo "dg: '$_dg_f' is not a file" >&2
            _dg_fail=1
        fi
    done
    [ "$_dg_fail" -eq 0 ] || return 2
    _dg_ha=$(_dg_hash "$1" "$2") || return 2
    _dg_hb=$(_dg_hash "$1" "$3") || return 2
    if [ "$_dg_ha" = "$_dg_hb" ]; then
        printf 'SAME  %s  %s\n' "$2" "$3"
        return 0
    fi
    printf 'DIFFERENT  %s  %s\n  %s  %s\n  %s  %s\n' "$2" "$3" "$_dg_ha" "$2" "$_dg_hb" "$3"
    return 1
}

# _dg_line → parse one checksum-file line ($1): GNU "<hash>  <name>" or
# "<hash> *<name>", or BSD "SHA256 (<name>) = <hash>" (MD5, SHA512 alike).
# Sets _dg_la (algorithm, from the tag or the hash's length), _dg_lh
# (lowercase hash) and _dg_ln (name) and returns 0; returns 1 for a blank
# or # comment line and 2 for a malformed one.
_dg_line() {
    _dg_l=${1%"$_dg_cr"}
    case $_dg_l in '#'*) return 1 ;; esac
    case $_dg_l in *[![:space:]]*) ;; *) return 1 ;; esac
    # GNU starts a line with a backslash when it escaped the name in it.
    _dg_le=
    case $_dg_l in \\*) _dg_le=1; _dg_l=${_dg_l#?} ;; esac
    case $_dg_l in
        'MD5 ('*') = '*|'SHA256 ('*') = '*|'SHA512 ('*') = '*)
            _dg_la=${_dg_l%% *}
            _dg_l=${_dg_l#*' ('}
            # The LAST ") = " ends the name, so a name may hold one.
            _dg_lh=${_dg_l##*') = '}
            _dg_ln=${_dg_l%') = '*}
            ;;
        *)
            _dg_la=
            _dg_lh=${_dg_l%% *}
            _dg_ln=${_dg_l#"$_dg_lh"}
            case $_dg_ln in
                '  '?*|' *'?*) _dg_ln=${_dg_ln#??} ;;
                *) return 2 ;;
            esac
            ;;
    esac
    case $_dg_lh in ''|*[!0123456789abcdefABCDEF]*) return 2 ;; esac
    [ -n "$_dg_ln" ] || return 2
    _dg_lh=$(printf '%s' "$_dg_lh" | tr ABCDEF abcdef)
    _dg_l=$(_dg_bylen "${#_dg_lh}") || return 2
    # A BSD tag has to agree with the hash's length.
    case $_dg_la in
        '')     ;;
        MD5)    [ "$_dg_l" = md5 ] || return 2 ;;
        SHA256) [ "$_dg_l" = sha256 ] || return 2 ;;
        *)      [ "$_dg_l" = sha512 ] || return 2 ;;
    esac
    _dg_la=$_dg_l
    if [ -n "$_dg_le" ]; then
        # Undo GNU's escaping (\\, \n, \r); the x keeps a trailing newline
        # from being stripped by the command substitution.
        _dg_ln=$(printf '%bx' "$_dg_ln")
        _dg_ln=${_dg_ln%x}
    fi
    return 0
}

# _dg_check → dg -c <sumsfile...>: verify every entry of every checksum
# file. Names are relative to the current directory, as with sha256sum -c.
_dg_check() {
    _dg_cr=$(printf '\r')
    _dg_ok=0; _dg_bad=0; _dg_miss=0; _dg_unread=0
    for _dg_sums in "$@"; do
        if [ ! -f "$_dg_sums" ] || [ ! -r "$_dg_sums" ]; then
            echo "dg: '$_dg_sums' is not a readable file" >&2
            _dg_unread=$((_dg_unread + 1))
            continue
        fi
        _dg_mal=0
        # Read on fd 3, so nothing run for an entry can eat the lines.
        while IFS= read -r _dg_raw <&3 || [ -n "$_dg_raw" ]; do
            _dg_line "$_dg_raw"
            case $? in
                1) continue ;;
                2) _dg_mal=$((_dg_mal + 1)); continue ;;
            esac
            if [ ! -e "$_dg_ln" ]; then
                printf '%s: MISSING\n' "$_dg_ln"
                _dg_miss=$((_dg_miss + 1))
            elif _dg_h=$(_dg_hash "$_dg_la" "$_dg_ln") && [ "$_dg_h" = "$_dg_lh" ]; then
                printf '%s: OK\n' "$_dg_ln"
                _dg_ok=$((_dg_ok + 1))
            else
                printf '%s: FAILED\n' "$_dg_ln"
                _dg_bad=$((_dg_bad + 1))
            fi
        done 3< "$_dg_sums"
        if [ "$_dg_mal" -gt 0 ]; then
            echo "dg: '$_dg_sums': $_dg_mal malformed line(s) ignored" >&2
        fi
    done
    _dg_n=$((_dg_ok + _dg_bad + _dg_miss))
    if [ "$_dg_n" -eq 0 ]; then
        echo "dg: no checksum lines found" >&2
        return 1
    fi
    [ $((_dg_bad + _dg_miss + _dg_unread)) -eq 0 ] && return 0
    _dg_msg="$_dg_bad FAILED, $_dg_miss MISSING of $_dg_n checked"
    if [ "$_dg_unread" -gt 0 ]; then
        _dg_msg="$_dg_msg, $_dg_unread sums file(s) unreadable"
    fi
    echo "dg: $_dg_msg" >&2
    return 1
}

# _dg_main → dg's body; dg itself only clears the variables afterwards.
_dg_main() {
    _dg_mode="hash"
    _dg_dd=
    # Options come first. -- ends them and the algo token as well, so
    # `dg -- 256` hashes a file named 256.
    while [ $# -gt 0 ]; do
        case "$1" in
            -e|-c)
                _dg_o=equal
                [ "$1" = -c ] && _dg_o=check
                if [ "$_dg_mode" != hash ] && [ "$_dg_mode" != "$_dg_o" ]; then
                    echo "dg: -e and -c cannot be combined" >&2
                    return 1
                fi
                _dg_mode=$_dg_o
                ;;
            -h|--help) _dg_usage; return 0 ;;
            --) _dg_dd=1; shift; break ;;
            -?*)
                echo "dg: unknown option '$1'" >&2
                _dg_usage >&2
                return 1
                ;;
            *) break ;;
        esac
        shift
    done
    _dg_alg=
    if [ -z "$_dg_dd" ] && [ $# -gt 0 ] && _dg_alg=$(_dg_token "$1"); then
        shift
        # `dg sha256 -- -x.txt` ends parsing too.
        if [ "${1-}" = -- ]; then shift; fi
    fi
    case $_dg_mode in
        check)
            if [ -n "$_dg_alg" ]; then
                echo "dg: -c takes no algo (each line names its own)" >&2
                return 1
            fi
            if [ $# -eq 0 ]; then _dg_usage >&2; return 1; fi
            _dg_check "$@"
            ;;
        equal)
            _dg_equal "${_dg_alg:-sha256}" "$@"
            ;;
        *)
            if [ $# -eq 0 ]; then _dg_usage >&2; return 1; fi
            # Two operands where the second is no path but reads as a hash:
            # check the first against it.
            if [ $# -eq 2 ] && [ ! -e "$2" ] && _dg_expect "$2"; then
                _dg_compare "$_dg_alg" "$1"
            else
                _dg_print "${_dg_alg:-sha256}" "$@"
            fi
            ;;
    esac
}

# dg → file hashes (md5, sha256, sha512): print them, check a file against
# an expected hash, compare two files, or verify checksum files. See
# _dg_usage for the forms.
dg() {
    _dg_main "$@"
    set -- "$?"
    unset _dg_mode _dg_dd _dg_o _dg_alg _dg_out _dg_xh _dg_xp _dg_a \
        _dg_many _dg_fail _dg_f _dg_h _dg_by _dg_named _dg_ha _dg_hb \
        _dg_cr _dg_ok _dg_bad _dg_miss _dg_unread _dg_sums _dg_mal \
        _dg_raw _dg_n _dg_msg _dg_l _dg_le _dg_la _dg_lh _dg_ln
    return "$1"
}

# digest → dg under its older name; every form works the same.
digest() { dg "$@"; }

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
    # 'command -v' answers with the bare NAME for a shell function or an alias
    # and with a path for a program, so a plain success test accepted a local
    # `zstd` function as the zstd that tar is about to spawn -- which tar
    # cannot see, let alone call. Only an absolute path is a program.
    #
    # A function also HIDES the program from 'command -v', so asking inside a
    # subshell that has dropped the function is what finds the real one; the
    # answer is then a path exactly when a program exists, shadowed or not.
    # The callers invoke it with `command`, which likewise runs the program
    # rather than a function of that name.
    case $(unset -f "$2" 2>/dev/null; command -v "$2" 2>/dev/null) in
        /*) return 0 ;;
    esac
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
            # 'command' runs the program, never a shell function of that name
            # (parity with the pwsh twin, which invokes the resolved path).
            *.gz)               _ar_have extract gunzip  && command gunzip  -- "$_ex_f" ;;
            *.bz2)              _ar_have extract bunzip2 && command bunzip2 -- "$_ex_f" ;;
            *.xz)               _ar_have extract unxz    && command unxz    -- "$_ex_f" ;;
            *.zst)              _ar_have extract unzstd  && command unzstd  -- "$_ex_f" ;;
            *.zip)              unzip -- "$_ex_f"     ;;
            *.7z)
                # 7z reads a leading '-' as a switch (already neutralised
                # above) and a leading '@' as a listfile — it would extract
                # the archives named INSIDE that file rather than the file
                # itself. 7z is not in tests/shell/Dockerfile, so its '--'
                # marker cannot be exercised in CI; './' neutralises both forms without depending on
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
                command zstd -q -k -f -o "$_ar_tmp" -- "$1"
            else
                command "$_ar_tool" -k -c -- "$1" > "$_ar_tmp"
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

# xt / pk → short names for extract / archive. Every argument and the exit
# status pass through unchanged, and messages keep the long name.
xt() {
    extract "$@"
}

pk() {
    archive "$@"
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

# ===== Directory History (back / fwd) =====
# Browser-style history for this shell session, never written to disk.
# _den_dh_back / _den_dh_fwd hold one directory per line, nearest first, and
# _den_dh_last is the directory the history saw last. Any change of directory
# (den's cd, builtin cd, pushd/popd, mkcd, up, cdf, y) pushes the directory it
# left onto the back list and clears the forward list, as a browser does.
# zsh reports every change through a chpwd hook; bash has none, so it compares
# $PWD at each prompt (PROMPT_COMMAND), and den's cd records at once so several
# cds on one command line are each kept. back/fwd walk the lists themselves and
# set _den_dh_nav so the hook does not take their move for a new one.
# A directory whose name holds a newline cannot be stored and is left out.
_den_dh_max=50
_den_dh_back=${_den_dh_back-}
_den_dh_fwd=${_den_dh_fwd-}
_den_dh_last=${_den_dh_last:-$PWD}

# _den_dh_record → note a change of directory (the chpwd / prompt hook). Returns
# the status it was called with, so it can sit anywhere in PROMPT_COMMAND.
_den_dh_record() {
    local rc=$? nl='
' rest kept='' i=0
    [ "$PWD" = "${_den_dh_last-}" ] && return "$rc"
    if [ -n "${_den_dh_nav-}" ]; then
        _den_dh_nav=
    elif [ -n "${_den_dh_last-}" ]; then
        case $_den_dh_last in
            *"$nl"*) ;;
            *)
                # A consecutive duplicate is kept once, and only the nearest
                # _den_dh_max entries are kept at all.
                if [ "${_den_dh_back%%"$nl"*}" != "$_den_dh_last" ]; then
                    rest="$_den_dh_last$nl${_den_dh_back-}"
                    while [ -n "$rest" ] && [ "$i" -lt "$_den_dh_max" ]; do
                        kept="$kept${rest%%"$nl"*}$nl"
                        rest=${rest#*"$nl"}
                        i=$((i + 1))
                    done
                    _den_dh_back=$kept
                fi
                ;;
        esac
        _den_dh_fwd=
    fi
    _den_dh_last=$PWD
    return "$rc"
}

# _den_dh_go <back|fwd> <N> → move N entries along that list (N already
# validated). The entries passed over and the directory being left go to the
# other list, nearest first, so `back 3` then `fwd 3` returns to the start.
_den_dh_go() {
    local nl='
' word to rest item target='' before='' passed='' here noun i=0
    if [ "$1" = back ]; then word=back to=fwd; else word=forward to=back; fi
    eval "rest=\${_den_dh_$1-}"
    while [ -n "$rest" ]; do
        item=${rest%%"$nl"*}
        rest=${rest#*"$nl"}
        i=$((i + 1))
        # String compare: N is canonical digits, and may be too big for -eq.
        if [ "$i" = "$2" ]; then
            target=$item
            break
        fi
        before="$before$item$nl"
        passed="$item$nl$passed"
    done
    if [ -z "$target" ]; then
        if [ "$i" = 1 ]; then noun=entry; else noun=entries; fi
        echo "$1: history has $i $word $noun, cannot go $word $2" >&2
        return 1
    fi
    if [ ! -d "$target" ]; then
        eval "_den_dh_$1=\$before\$rest"
        echo "$1: $target no longer exists, dropped from history" >&2
        return 1
    fi
    here=$PWD
    _den_dh_nav=1
    builtin cd -- "$target" || { _den_dh_nav=; return 1; }
    _den_dh_nav=
    _den_dh_last=$PWD
    case $here in *"$nl"*) here= ;; *) here="$here$nl" ;; esac
    eval "_den_dh_$to=\$passed\$here\${_den_dh_$to-}"
    eval "_den_dh_$1=\$rest"
    pwd
}

# _den_dh_show <label> <dir> → one line of `back -l`, with $HOME shown as ~
_den_dh_show() {
    if [ -n "${HOME-}" ] && [ "$HOME" != / ]; then
        case $2 in
            "$HOME") set -- "$1" '~' ;;
            "$HOME"/*) set -- "$1" "~${2#"$HOME"}" ;;
        esac
    fi
    printf '%3s  %s\n' "$1" "$2"
}

# _den_dh_list → `back -l`: back entries farthest first, then the current
# directory as *, then forward entries as +1, +2 ...
_den_dh_list() {
    local nl='
' rest rev='' i=0
    rest=${_den_dh_back-}
    while [ -n "$rest" ]; do
        rev="${rest%%"$nl"*}$nl$rev"
        rest=${rest#*"$nl"}
        i=$((i + 1))
    done
    while [ -n "$rev" ]; do
        _den_dh_show "$i" "${rev%%"$nl"*}"
        rev=${rev#*"$nl"}
        i=$((i - 1))
    done
    _den_dh_show '*' "$PWD"
    rest=${_den_dh_fwd-}
    while [ -n "$rest" ]; do
        i=$((i + 1))
        _den_dh_show "+$i" "${rest%%"$nl"*}"
        rest=${rest#*"$nl"}
    done
}

# back → go back N entries in the directory history (default 1); -l lists the
# history, -i picks an entry with fzf
back() {
    local n="${1:-1}" pick label
    case "$n" in
        -l)
            _den_dh_record
            _den_dh_list
            return
            ;;
        -i)
            if ! command -v fzf >/dev/null 2>&1; then
                echo "back: fzf is not installed." >&2
                return 1
            fi
            _den_dh_record
            # --tac shows the list in `back -l` order; the label in front of
            # the pick says which move reaches it.
            pick=$(_den_dh_list | fzf --tac --no-sort --prompt='back> ') || return
            pick=${pick#"${pick%%[! ]*}"}
            label=${pick%% *}
            case $label in
                '*') return 0 ;;
                +*) fwd "${label#+}" ;;
                *) back "$label" ;;
            esac
            return
            ;;
        ''|*[!0-9]*|0|0[0-9]*)
            echo "usage: back [N | -l | -i]  (N=positive integer, default 1)" >&2
            return 1
            ;;
    esac
    _den_dh_record  # a move bash has not seen yet (no prompt since) comes first
    _den_dh_go back "$n"
}

# fwd → go forward N entries in the directory history (default 1), undoing back
fwd() {
    local n="${1:-1}"
    case "$n" in
        ''|*[!0-9]*|0|0[0-9]*)
            echo "usage: fwd [N]  (N=positive integer, default 1)" >&2
            return 1
            ;;
    esac
    _den_dh_record
    _den_dh_go fwd "$n"
}

# Hook the recorder in. zsh: chpwd (add-zsh-hook skips a duplicate). bash: add
# it to PROMPT_COMMAND once; that is a string, or (bash 5.1+) may be an array.
# zoxide and starship add their hooks after this file and keep what is there,
# and the recorder returns the status it was given, so $? reaches them intact.
if [ -n "${ZSH_VERSION-}" ]; then
    autoload -Uz add-zsh-hook && add-zsh-hook chpwd _den_dh_record
elif [ -n "${BASH_VERSION-}" ]; then
    if [ -z "${PROMPT_COMMAND-}" ]; then
        PROMPT_COMMAND=_den_dh_record
    else
        # shellcheck disable=SC3044  # declare: this branch runs only in bash
        case $(declare -p PROMPT_COMMAND) in
            *_den_dh_record*) ;;
            # eval: array syntax would stop a POSIX parser reading this file
            'declare -a'*) eval 'PROMPT_COMMAND+=(_den_dh_record)' ;;
            *)
                # Drop trailing ';' and blanks first: ';;' is a syntax error.
                PROMPT_COMMAND="${PROMPT_COMMAND%"${PROMPT_COMMAND##*[![:space:];]}"}"
                PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }_den_dh_record"
                ;;
        esac
    fi
fi

# ===== Zoxide Navigation =====

# cd → wrapper ON: __zoxide_z, OFF: builtin cd
cd() {
    if [ "${_DEN_WRAPPERS:-1}" != "0" ] && type __zoxide_z >/dev/null 2>&1; then
        __zoxide_z "$@"
    else
        builtin cd "$@"
    fi || return
    # Record now rather than at the next prompt (bash), so each cd on one
    # command line is kept.
    _den_dh_record
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

