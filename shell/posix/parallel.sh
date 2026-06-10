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

# _parallel_exec → run command in parallel via GNU parallel or xargs
#   $1 = job count, remaining args = command template
#   stdin = NUL-separated arguments
_parallel_exec() {
    local jobs="$1"
    shift
    if command -v parallel >/dev/null 2>&1; then
        command parallel -0 -j"$jobs" "$@"
    else
        command xargs -0 -P"$jobs" -I{} "$@"
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

    local jobs
    jobs="$(_nproc)"
    local entries
    entries="$(_count_entries "${srcs[@]}")"
    echo "+ pcp: ${#srcs[@]} paths ($entries entries) → $dest ($jobs jobs)"
    printf '%s\0' "${srcs[@]}" | _parallel_exec "$jobs" cp -a -- {} "$dest"
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

    local jobs
    jobs="$(_nproc)"
    local entries
    entries="$(_count_entries "${srcs[@]}")"
    echo "+ pmv: ${#srcs[@]} paths ($entries entries) → $dest ($jobs jobs)"
    printf '%s\0' "${srcs[@]}" | _parallel_exec "$jobs" mv -- {} "$dest"
}

# prm → parallel remove with interactive confirmation by default
prm() {
    local force=0
    local -a items=()
    local arg
    for arg in "$@"; do
        case "$arg" in
            --force|-f) force=1 ;;
            *) items+=("$arg") ;;
        esac
    done

    if [ ${#items[@]} -eq 0 ]; then
        echo "usage: prm [--force|-f] <path...>" >&2
        return 1
    fi

    local jobs flags reply
    jobs="$(_nproc)"
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
    printf '%s\0' "${items[@]}" | _parallel_exec "$jobs" rm "$flags" -- {}
}

# ptar → parallel compress using pigz/pbzip2/pxz when available
ptar() {
    if [ $# -lt 2 ]; then
        echo "usage: ptar <output.tar.gz|.tar.bz2|.tar.xz> <src...>" >&2
        return 1
    fi

    local out="$1"
    shift

    local jobs
    jobs="$(_nproc)"

    case "$out" in
        *.tar.gz|*.tgz)
            if command -v pigz >/dev/null 2>&1; then
                echo "+ ptar: compressing → $out (using pigz)"
                tar -cf - -- "$@" | pigz -p"$jobs" > "$out"
            else
                echo "+ ptar: compressing → $out (using standard)"
                tar czf "$out" -- "$@"
            fi
            ;;
        *.tar.bz2)
            if command -v pbzip2 >/dev/null 2>&1; then
                echo "+ ptar: compressing → $out (using pbzip2)"
                tar -cf - -- "$@" | pbzip2 -p"$jobs" > "$out"
            else
                echo "+ ptar: compressing → $out (using standard)"
                tar cjf "$out" -- "$@"
            fi
            ;;
        *.tar.xz)
            if command -v pxz >/dev/null 2>&1; then
                echo "+ ptar: compressing → $out (using pxz)"
                tar -cf - -- "$@" | pxz -T"$jobs" > "$out"
            elif command -v xz >/dev/null 2>&1; then
                echo "+ ptar: compressing → $out (using xz)"
                tar -cf - -- "$@" | xz -T"$jobs" > "$out"
            else
                echo "+ ptar: compressing → $out (using standard)"
                tar cJf "$out" -- "$@"
            fi
            ;;
        *)
            echo "ptar: unsupported format '$out'" >&2
            echo "  supported: .tar.gz .tgz .tar.bz2 .tar.xz" >&2
            return 1
            ;;
    esac
}

# pxargs → shortcut for xargs with parallel jobs
pxargs() {
    command xargs -P"$(_nproc)" "$@"
}
