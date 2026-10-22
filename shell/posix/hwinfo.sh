#!/bin/sh
# hwinfo.sh — Detect CPU/GPU and export STARSHIP_* env vars for starship prompt.
# Sourced by .bashrc / .zshrc. POSIX-compatible.
# Deploy target: ~/.config/shell/hwinfo.sh

# Skip in non-interactive shells
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0;; esac

# --- Machine-local, per-boot, machine-id-keyed hardware cache ---
# Lives under $XDG_RUNTIME_DIR (tmpfs: per-boot, per-machine) so a shared or
# synced $HOME never serves one machine's hardware to another, and the cache
# auto-refreshes on reboot. Falls back to /tmp, still keyed by machine-id.
# _den_hwinfo_file sets _hwc_f to that file. The machine id is read with the
# read builtin, not a cat process at every shell start; without one, the host
# name stands in ($HOSTNAME in bash, $HOST in zsh, else hostname's).
_den_hwinfo_file() {
    _hwc_mid=
    { IFS= read -r _hwc_mid < /etc/machine-id; } 2>/dev/null
    # shellcheck disable=SC3028  # HOSTNAME: bash sets it, zsh HOST; else hostname below
    [ -n "$_hwc_mid" ] || _hwc_mid=${HOSTNAME:-${HOST:-}}
    [ -n "$_hwc_mid" ] || _hwc_mid=$(command hostname 2>/dev/null)
    _hwc_f="${XDG_RUNTIME_DIR:-/tmp}/den-hwinfo.${_hwc_mid:-unknown}.sh"
    unset _hwc_mid
}

# Source the cache only if a regular file, not a symlink, owned by us, and only
# when no STARSHIP_* value came from the parent (a nested shell needs no file).
# A cache den writes ends with _DEN_HWINFO_CACHED=1, so one that holds no CPU or
# GPU name (none recognized) still counts, and the detection below does not run
# again at every start; refresh-hwinfo deletes the file to detect again.
_hwc_hit=
if [ -z "$STARSHIP_CPU_INTEL" ] && [ -z "$STARSHIP_CPU_AMD" ] && \
   [ -z "$STARSHIP_GPU_NVIDIA" ] && [ -z "$STARSHIP_GPU_AMD" ] && \
   [ -z "$STARSHIP_GPU_INTEL" ]; then
    _den_hwinfo_file
    if [ -f "$_hwc_f" ] && [ ! -L "$_hwc_f" ] && [ -O "$_hwc_f" ]; then
        _DEN_HWINFO_CACHED=
        . "$_hwc_f"
        _hwc_hit=$_DEN_HWINFO_CACHED
        unset _DEN_HWINFO_CACHED
    fi
fi

# --- Detect hardware live only if still uncached (env + file cache both miss) ---
if [ -z "$_hwc_hit" ] && \
   [ -z "$STARSHIP_CPU_INTEL" ] && [ -z "$STARSHIP_CPU_AMD" ] && \
   [ -z "$STARSHIP_GPU_NVIDIA" ] && [ -z "$STARSHIP_GPU_AMD" ] && \
   [ -z "$STARSHIP_GPU_INTEL" ]; then

    # --- CPU detection from /proc/cpuinfo ---
    if [ -f /proc/cpuinfo ]; then
        _hwinfo_cpu_info=$(awk -F': ' '
            /^model name[[:space:]]*:/ {
                vendor = ""
                if ($2 ~ /Intel|intel/) vendor = "intel"
                else if ($2 ~ /AMD|amd/) vendor = "amd"
                short = $2
                gsub(/\(R\)|\(TM\)/, "", short)
                gsub(/[0-9]+[a-z]+ Gen /, "", short)
                gsub(/Genuine |Intel |AMD |Core /, "", short)
                sub(/ CPU.*$/, "", short)
                sub(/ [0-9]+-Core Processor/, "", short)
                gsub(/  +/, " ", short)
                gsub(/^ +| +$/, "", short)
                print vendor "|" short
                exit
            }
        ' /proc/cpuinfo)
        if [ -n "$_hwinfo_cpu_info" ]; then
            _hwinfo_cpu_vendor=${_hwinfo_cpu_info%%|*}
            _hwinfo_cpu_short=${_hwinfo_cpu_info#*|}
        else
            _hwinfo_cpu_vendor=""
            _hwinfo_cpu_short=""
        fi
        case "$_hwinfo_cpu_vendor" in
            intel) export STARSHIP_CPU_INTEL="$_hwinfo_cpu_short" ;;
            amd)   export STARSHIP_CPU_AMD="$_hwinfo_cpu_short" ;;
        esac
        unset _hwinfo_cpu_info _hwinfo_cpu_vendor _hwinfo_cpu_short
    fi

    # --- GPU detection: nvidia-smi (NVIDIA) ---
    if command -v nvidia-smi >/dev/null 2>&1; then
        _hwinfo_gpu_short=$(nvidia-smi --query-gpu=gpu_name --format=csv,noheader 2>/dev/null | awk '
            NR == 1 {
                short = $0
                gsub(/NVIDIA[[:space:]]*GeForce[[:space:]]*/, "", short)
                gsub(/NVIDIA[[:space:]]*/, "", short)
                gsub(/[[:space:]]+/, " ", short)
                gsub(/^ +| +$/, "", short)
            }
            END {
                if (NR > 0) {
                    if (NR > 1) printf "%s x%d\n", short, NR
                    else print short
                }
            }
        ')
        [ -n "$_hwinfo_gpu_short" ] && export STARSHIP_GPU_NVIDIA="$_hwinfo_gpu_short"
        unset _hwinfo_gpu_short
    fi

    # --- GPU detection: rocm-smi (AMD) ---
    if command -v rocm-smi >/dev/null 2>&1; then
        _hwinfo_gpu_short=$(rocm-smi --showproductname 2>/dev/null | awk -F': ' '
            /Card [Ss]eries/ {
                count++
                if (count == 1) {
                    short = $2
                    gsub(/^[ \t]+|[ \t]+$/, "", short)
                    gsub(/AMD[[:space:]]*/, "", short)
                    gsub(/[[:space:]]+/, " ", short)
                    gsub(/^ +| +$/, "", short)
                }
            }
            END {
                if (count > 0) {
                    if (count > 1) printf "%s x%d\n", short, count
                    else print short
                }
            }
        ')
        [ -n "$_hwinfo_gpu_short" ] && export STARSHIP_GPU_AMD="$_hwinfo_gpu_short"
        unset _hwinfo_gpu_short
    fi

    # --- GPU detection: lspci (Intel iGPU) ---
    # Only when no discrete GPU was found, matching the pwsh port's
    # NVIDIA > AMD > Intel priority (hwinfo.ps1). Without this block Intel GPUs
    # were plumbed through the cache/toggle but never actually detected on POSIX.
    if [ -z "$STARSHIP_GPU_NVIDIA" ] && [ -z "$STARSHIP_GPU_AMD" ] && \
       command -v lspci >/dev/null 2>&1; then
        _hwinfo_gpu_short=$(lspci 2>/dev/null | awk -F': ' '
            /VGA compatible controller|3D controller|Display controller/ && /Intel/ {
                count++
                if (count == 1) {
                    short = $NF
                    gsub(/Intel Corporation[[:space:]]*/, "", short)
                    gsub(/[[:space:]]*\(rev[^)]*\)/, "", short)
                    gsub(/[[:space:]]+/, " ", short)
                    gsub(/^ +| +$/, "", short)
                }
            }
            END {
                if (count > 0) {
                    if (count > 1) printf "%s x%d\n", short, count
                    else print short
                }
            }
        ')
        [ -n "$_hwinfo_gpu_short" ] && export STARSHIP_GPU_INTEL="$_hwinfo_gpu_short"
        unset _hwinfo_gpu_short
    fi

    # --- Write the cache (machine-local, mode 600) ---
    # Create the temp file with mktemp (O_EXCL + 0600 + random suffix) rather than
    # the predictable "$_hwc_f.tmp.$$": with XDG_RUNTIME_DIR unset the cache lives
    # in a shared /tmp, where another user can pre-plant that exact name as a
    # symlink and have the truncating `>` below rewrite whatever it points at.
    # Without mktemp, fall back to a noclobber (set -C) redirect, which also fails
    # closed on an existing path or symlink. Same fail-closed intent as the read
    # side above and _init_cache in _helpers.sh.
    _hwc_tmp=$(command mktemp "$_hwc_f.tmp.XXXXXX" 2>/dev/null)
    if [ -z "$_hwc_tmp" ]; then
        _hwc_tmp="$_hwc_f.tmp.$$"
        (umask 077 && set -C && : > "$_hwc_tmp") 2>/dev/null || _hwc_tmp=""
    fi
    if [ -n "$_hwc_tmp" ]; then
        for _hwc_v in STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL; do
            eval "_hwc_val=\$$_hwc_v"
            if [ -n "$_hwc_val" ]; then
                # Single-quote the value, escaping any embedded single quote.
                _hwc_esc=$(printf '%s' "$_hwc_val" | sed "s/'/'\\''/g")
                printf "export %s='%s'\n" "$_hwc_v" "$_hwc_esc" >> "$_hwc_tmp"
            fi
        done
        # Last, so a file cut short by a failed write does not count as a hit.
        printf '_DEN_HWINFO_CACHED=1\n' >> "$_hwc_tmp"
        mv -f "$_hwc_tmp" "$_hwc_f" 2>/dev/null || rm -f "$_hwc_tmp"
    fi
    unset _hwc_v _hwc_val _hwc_esc _hwc_tmp
fi

# toggle-hwinfo exports _DEN_HWINFO_HIDDEN, so a reload (a new shell) or a child
# shell inherits its OFF, and the cache or the detection above brings the values
# back. Hide them again the way toggle-hwinfo does, or its next call would take
# the ON branch and change nothing. An empty value keeps an inherited saved one.
if [ "${_DEN_HWINFO_HIDDEN:-0}" = 1 ]; then
    for _hwc_v in CPU_INTEL CPU_AMD GPU_NVIDIA GPU_AMD GPU_INTEL; do
        eval "_hwc_val=\$STARSHIP_$_hwc_v"
        if [ -n "$_hwc_val" ]; then
            eval "_DEN_SAVED_$_hwc_v=\$_hwc_val"
            export "_DEN_SAVED_$_hwc_v"
        fi
        unset "STARSHIP_$_hwc_v"
    done
    unset _hwc_v _hwc_val
fi
unset _hwc_f _hwc_hit

# refresh-hwinfo → clear the hardware info cache (re-detect on next shell)
refresh-hwinfo() {
    _den_hwinfo_file
    rm -f "$_hwc_f"
    unset _hwc_f
    echo "hwinfo cache cleared. Restart shell to refresh."
}

# toggle-hwinfo → flip hardware info display in starship prompt on/off
toggle-hwinfo() {
    if [ "${_DEN_HWINFO_HIDDEN:-0}" = "0" ]; then
        _DEN_SAVED_CPU_INTEL="$STARSHIP_CPU_INTEL"
        _DEN_SAVED_CPU_AMD="$STARSHIP_CPU_AMD"
        _DEN_SAVED_GPU_NVIDIA="$STARSHIP_GPU_NVIDIA"
        _DEN_SAVED_GPU_AMD="$STARSHIP_GPU_AMD"
        _DEN_SAVED_GPU_INTEL="$STARSHIP_GPU_INTEL"
        export _DEN_SAVED_CPU_INTEL _DEN_SAVED_CPU_AMD
        export _DEN_SAVED_GPU_NVIDIA _DEN_SAVED_GPU_AMD _DEN_SAVED_GPU_INTEL
        unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD
        unset STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
        export _DEN_HWINFO_HIDDEN=1
        echo "hwinfo: OFF (hidden from prompt)"
    else
        [ -n "$_DEN_SAVED_CPU_INTEL" ]  && export STARSHIP_CPU_INTEL="$_DEN_SAVED_CPU_INTEL"
        [ -n "$_DEN_SAVED_CPU_AMD" ]    && export STARSHIP_CPU_AMD="$_DEN_SAVED_CPU_AMD"
        [ -n "$_DEN_SAVED_GPU_NVIDIA" ] && export STARSHIP_GPU_NVIDIA="$_DEN_SAVED_GPU_NVIDIA"
        [ -n "$_DEN_SAVED_GPU_AMD" ]    && export STARSHIP_GPU_AMD="$_DEN_SAVED_GPU_AMD"
        [ -n "$_DEN_SAVED_GPU_INTEL" ]  && export STARSHIP_GPU_INTEL="$_DEN_SAVED_GPU_INTEL"
        unset _DEN_SAVED_CPU_INTEL _DEN_SAVED_CPU_AMD
        unset _DEN_SAVED_GPU_NVIDIA _DEN_SAVED_GPU_AMD _DEN_SAVED_GPU_INTEL
        export _DEN_HWINFO_HIDDEN=0
        echo "hwinfo: ON (visible in prompt)"
    fi
}

# tgl-hw → short name for toggle-hwinfo
tgl-hw() {
    toggle-hwinfo "$@"
}
