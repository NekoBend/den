#!/usr/bin/env bash
# parallel.sh — Parallel file operation helpers.
# Sourced by .bashrc / .zshrc. Requires bash or zsh.
# Deploy target: ~/.config/shell/parallel.sh

# Skip in non-interactive shells
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0;; esac

# ===== Internal Helpers =====

# _nproc → return CPU count portably
_nproc() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    elif command -v sysctl >/dev/null 2>&1; then
        sysctl -n hw.ncpu 2>/dev/null || echo 4
    else
        echo 4
    fi
}

# _parallel_gnu → is the `parallel` on PATH GNU parallel? Only GNU parallel is
# used: moreutils' `parallel` has different flags. `parallel --version` costs
# about 60 ms, so the answer is cached for the program's resolved path and
# asked again only when PATH resolves `parallel` somewhere else. Callers ask
# it BEFORE their pipeline: bash runs every element of a pipeline in a
# subshell, where the cache would be written and then thrown away.
_parallel_gnu() {
    local p
    p=$(command -v parallel 2>/dev/null) || return 1
    if [ "$p" != "${_DEN_PARALLEL_PATH-}" ]; then
        _DEN_PARALLEL_PATH=$p
        _DEN_PARALLEL_GNU=0
        if command parallel --version 2>/dev/null | grep -q 'GNU parallel'; then
            _DEN_PARALLEL_GNU=1
        fi
    fi
    [ "$_DEN_PARALLEL_GNU" = 1 ]
}

# _parallel_exec → run a command over its operands in parallel batches
#   $1 = job count, $2 = operand count, $3 = 1 to use GNU parallel (the
#   caller's _parallel_gnu answer), remaining args = the command
#   stdin = NUL-separated operands, appended to the command in batches
#
# One cp/mv/rm per operand made `pcp * dest` over a few thousand small files
# 10-70x slower than a plain cp: the fork and exec per file cost far more than
# the copy. Each job gets a batch instead. xargs takes at most 256 operands
# per command, and fewer when that would leave jobs idle, so a handful of big
# directories still spread over the jobs; GNU parallel's -X spreads the
# operands evenly over its jobs by itself.
#
# GNU parallel joins the template words with spaces and hands the string to a
# shell, so without -q a destination like "My Documents" became TWO cp
# operands and "x;rm -rf y" executed the rm. -q shell-quotes every template
# word (and -X every operand) before that join, so each word reaches the
# command as one argument and metacharacters stay literal. The job still runs
# through a shell; -q makes the template safe, it does not remove the shell.
# xargs, by contrast, execs the command without a shell of its own. pcp and
# pmv hand either one a fixed `sh -c` script with the operands as positional
# arguments, so no operand is ever read as shell code.
_parallel_exec() {
    local jobs="$1" count="$2" gnu="$3" per
    shift 3
    if [ "$gnu" = 1 ]; then
        command parallel -0 -q -X -j"$jobs" "$@"
    else
        per=$(( (count + jobs - 1) / jobs ))
        [ "$per" -gt 256 ] && per=256
        [ "$per" -lt 1 ] && per=1
        command xargs -0 -P"$jobs" -n"$per" "$@"
    fi
}

# _count_entries → count files/dirs recursively for display
_count_entries() {
    local limit=10000 total=0 p remaining count
    for p in "$@"; do
        if [ -d "$p" ]; then
            if [ "$total" -ge "$limit" ]; then
                echo "${limit}+"
                return
            fi
            remaining=$((limit - total))
            # `command find`: the bare name resolves to the fd wrapper when fd is
            # installed (fd's syntax differs -> wrong/zero count), and this count
            # is shown in prm's destructive [y/N] confirmation.
            count="$(command find "$p" -print 2>/dev/null | awk -v limit="$remaining" '
                NR > limit { print limit "+"; exit }
                END { if (NR <= limit) print NR }
            ')"
            case "$count" in
                *+)
                    echo "${limit}+"
                    return
                    ;;
                *)
                    total=$((total + count))
                    ;;
            esac
        else
            total=$((total + 1))
        fi
        if [ "$total" -gt "$limit" ]; then
            echo "${limit}+"
            return
        fi
    done
    echo "$total"
}

# ===== Parallel File Operations =====

# pcp → parallel copy (like cp, last arg is destination)
pcp() {
    if [ $# -lt 2 ]; then
        echo "usage: pcp <src...> <dest>" >&2
        return 1
    fi

    # Shell-agnostic "last arg = dest, the rest = srcs". bash and zsh disagree
    # on both array index base and ${@:n:m} slicing, so avoid those entirely:
    # iterate the positional parameters and drop the final one.
    local dest
    eval "dest=\${$#}"
    local -a srcs=()
    local _pi=1 _pa
    for _pa in "$@"; do
        [ "$_pi" -lt "$#" ] && srcs+=("$_pa")
        _pi=$((_pi + 1))
    done

    if [ ! -d "$dest" ] && [ ${#srcs[@]} -gt 1 ]; then
        echo "pcp: '$dest' is not a directory" >&2
        return 1
    fi

    local jobs gnu=0
    jobs="$(_nproc)"
    _parallel_gnu && gnu=1
    local entries
    entries="$(_count_entries "${srcs[@]}")"
    echo "+ pcp: ${#srcs[@]} paths ($entries entries) → $dest ($jobs jobs)"
    # -f: overwrite an existing destination file even when it is read-only,
    # the same semantics as pwsh's Copy-Item -Force (and as mv below).
    # The operands come last, so the destination reaches cp through sh's $0:
    # `cp -t` would do the same but is GNU-only.
    printf '%s\0' "${srcs[@]}" |
        _parallel_exec "$jobs" "${#srcs[@]}" "$gnu" sh -c 'cp -af -- "$@" "$0"' "$dest"
}

# pmv → parallel move (like mv, last arg is destination)
pmv() {
    if [ $# -lt 2 ]; then
        echo "usage: pmv <src...> <dest>" >&2
        return 1
    fi

    # Shell-agnostic "last arg = dest, the rest = srcs". bash and zsh disagree
    # on both array index base and ${@:n:m} slicing, so avoid those entirely:
    # iterate the positional parameters and drop the final one.
    local dest
    eval "dest=\${$#}"
    local -a srcs=()
    local _pi=1 _pa
    for _pa in "$@"; do
        [ "$_pi" -lt "$#" ] && srcs+=("$_pa")
        _pi=$((_pi + 1))
    done

    if [ ! -d "$dest" ] && [ ${#srcs[@]} -gt 1 ]; then
        echo "pmv: '$dest' is not a directory" >&2
        return 1
    fi

    local jobs gnu=0
    jobs="$(_nproc)"
    _parallel_gnu && gnu=1
    local entries
    entries="$(_count_entries "${srcs[@]}")"
    echo "+ pmv: ${#srcs[@]} paths ($entries entries) → $dest ($jobs jobs)"
    printf '%s\0' "${srcs[@]}" |
        _parallel_exec "$jobs" "${#srcs[@]}" "$gnu" sh -c 'mv -- "$@" "$0"' "$dest"
}

# prm → parallel remove with interactive confirmation by default
prm() {
    local force=0
    # Flags count only BEFORE the first operand, and `--` ends them: a
    # glob-expanded file literally named -f must never flip force mode (it
    # would silently skip the [y/N] confirmation). Remove such a file with
    # `prm -- -f`. An unknown dash-word is an error, not a path.
    while [ $# -gt 0 ]; do
        case "$1" in
            --force|-f)
                # A file literally named -f (a mistyped `tar -f` leaves one)
                # in an unprotected glob would arrive here first and silently
                # skip the confirmation; refuse the ambiguity instead of
                # guessing. -L as well as -e: -e follows symlinks, so a
                # DANGLING symlink named -f would otherwise pass as absent.
                if [ -e "$1" ] || [ -L "$1" ]; then
                    echo "prm: '$1' is both a flag and an existing file; use \`prm -- ...\` or \`./$1\`" >&2
                    return 1
                fi
                force=1; shift ;;
            --) shift; break ;;
            -*)
                echo "prm: unknown option '$1' (use -- before paths that start with -)" >&2
                echo "usage: prm [--force|-f] [--] <path...>" >&2
                return 1
                ;;
            *) break ;;
        esac
    done
    local -a items=("$@")

    if [ ${#items[@]} -eq 0 ]; then
        echo "usage: prm [--force|-f] [--] <path...>" >&2
        return 1
    fi

    local jobs flags reply gnu=0
    jobs="$(_nproc)"
    _parallel_gnu && gnu=1
    local entries
    entries="$(_count_entries "${items[@]}")"

    if [ "$force" -eq 0 ]; then
        printf "prm: remove %d paths (%s entries)? [y/N] " "${#items[@]}" "$entries"
        read -r reply
        case "$reply" in
            y|Y) ;;
            *)
                echo "prm: aborted" >&2
                return 1
                ;;
        esac
        flags="-r"
    else
        flags="-rf"
    fi

    echo "+ prm: removing ${#items[@]} paths ($entries entries, $jobs jobs)"
    printf '%s\0' "${items[@]}" | _parallel_exec "$jobs" "${#items[@]}" "$gnu" rm "$flags" --
}

# _ptar_pipe <out> <compressor> <compressor-option> <src...>
# `tar | compressor > out` for ptar. Without pipefail a pipeline's status is
# the compressor's, so a source tar could not read (a typo, a permission)
# still reported success, and `ptar backup.tgz dir && prm -f dir` deleted data
# that never reached the archive. The redirection had also truncated any
# existing <out> before tar started. The pipeline runs in a subshell with
# pipefail (bash and zsh both have it; the option stays in the subshell) and
# writes into a private staging directory beside <out>; only a pipeline that
# succeeded as a whole is renamed over <out>, so a failed run leaves no
# truncated archive and an existing one exactly as it was. The directory is
# mktemp -d's 0700 one for the reason archive() gives: a predictable name in a
# shared directory could be swapped for a symlink before the shell opens it.
# tar leaves that directory out by its unique name: with <out> inside a source
# (`ptar out.tgz .`), it would otherwise store the half-written archive.
_ptar_pipe() {
    local out="$1" comp="$2" copt="$3" dir tmpd rc
    shift 3
    case "$out" in
        */*) dir="${out%/*}" ;;
        *)   dir="." ;;
    esac
    tmpd=$(command mktemp -d "$dir/.ptar.XXXXXX" 2>/dev/null)
    if [ -z "$tmpd" ]; then
        echo "ptar: cannot create a temporary directory in '$dir'" >&2
        return 1
    fi
    ( set -o pipefail; tar -cf - --exclude="${tmpd##*/}" -- "$@" | command "$comp" "$copt" > "$tmpd/archive" )
    rc=$?
    if [ "$rc" -eq 0 ]; then
        mv -f -- "$tmpd/archive" "$out"
        rc=$?
    fi
    rm -rf -- "$tmpd"
    return "$rc"
}

# ptar → parallel compress using pigz/pbzip2/pxz when available
ptar() {
    if [ $# -lt 2 ]; then
        echo "usage: ptar <output.tar|.tar.gz|.tgz|.tar.bz2|.tbz2|.tar.xz|.txz> <src...>" >&2
        return 1
    fi

    local out="$1"
    shift

    # A directory at the output path is not an output: the staged rename in
    # _ptar_pipe would move the archive INTO it and report success.
    if [ -d "$out" ]; then
        echo "ptar: output '$out' is a directory" >&2
        return 1
    fi

    local jobs
    jobs="$(_nproc)"

    case "$out" in
        *.tar.gz|*.tgz)
            if command -v pigz >/dev/null 2>&1; then
                echo "+ ptar: compressing → $out (using pigz)"
                _ptar_pipe "$out" pigz -p"$jobs" "$@"
            else
                echo "+ ptar: compressing → $out (using standard)"
                tar czf "$out" -- "$@"
            fi
            ;;
        *.tar.bz2|*.tbz2)
            if command -v pbzip2 >/dev/null 2>&1; then
                echo "+ ptar: compressing → $out (using pbzip2)"
                _ptar_pipe "$out" pbzip2 -p"$jobs" "$@"
            else
                echo "+ ptar: compressing → $out (using standard)"
                tar cjf "$out" -- "$@"
            fi
            ;;
        *.tar.xz|*.txz)
            if command -v pxz >/dev/null 2>&1; then
                echo "+ ptar: compressing → $out (using pxz)"
                _ptar_pipe "$out" pxz -T"$jobs" "$@"
            elif command -v xz >/dev/null 2>&1; then
                echo "+ ptar: compressing → $out (using xz)"
                _ptar_pipe "$out" xz -T"$jobs" "$@"
            else
                echo "+ ptar: compressing → $out (using standard)"
                tar cJf "$out" -- "$@"
            fi
            ;;
        *.tar)
            echo "+ ptar: archiving → $out (no compression)"
            tar -cf "$out" -- "$@"
            ;;
        *)
            echo "ptar: unsupported format '$out'" >&2
            echo "  supported: .tar .tar.gz .tgz .tar.bz2 .tbz2 .tar.xz .txz" >&2
            return 1
            ;;
    esac
}

# pxargs → shortcut for xargs with parallel jobs
pxargs() {
    command xargs -P"$(_nproc)" "$@"
}
