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
_hwc_dir="${XDG_RUNTIME_DIR:-/tmp}"
_hwc_mid=$(command cat /etc/machine-id 2>/dev/null || command hostname 2>/dev/null || echo unknown)
_hwc_f="$_hwc_dir/dotfiles-hwinfo.${_hwc_mid}.sh"

# Source the cache only if a regular file, not a symlink, owned by us.
if [ -z "$STARSHIP_CPU_INTEL" ] && [ -z "$STARSHIP_CPU_AMD" ] && \
   [ -z "$STARSHIP_GPU_NVIDIA" ] && [ -z "$STARSHIP_GPU_AMD" ]; then
    if [ -f "$_hwc_f" ] && [ ! -L "$_hwc_f" ] && [ -O "$_hwc_f" ]; then
        . "$_hwc_f"
    fi
fi

# --- Detect hardware live only if still uncached (env + file cache both miss) ---
if [ -z "$STARSHIP_CPU_INTEL" ] && [ -z "$STARSHIP_CPU_AMD" ] && \
   [ -z "$STARSHIP_GPU_NVIDIA" ] && [ -z "$STARSHIP_GPU_AMD" ]; then

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

    # --- Write the cache (machine-local, mode 600 via umask) ---
    _hwc_tmp="$_hwc_f.tmp.$$"
    if (umask 077 && : > "$_hwc_tmp") 2>/dev/null; then
        for _hwc_v in STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL; do
            eval "_hwc_val=\$$_hwc_v"
            if [ -n "$_hwc_val" ]; then
                # Single-quote the value, escaping any embedded single quote.
                _hwc_esc=$(printf '%s' "$_hwc_val" | sed "s/'/'\\''/g")
                printf "export %s='%s'\n" "$_hwc_v" "$_hwc_esc" >> "$_hwc_tmp"
            fi
        done
        mv -f "$_hwc_tmp" "$_hwc_f" 2>/dev/null || rm -f "$_hwc_tmp"
    fi
    unset _hwc_v _hwc_val _hwc_esc _hwc_tmp
fi
unset _hwc_dir _hwc_mid _hwc_f

# refresh-hwinfo → clear the hardware info cache (re-detect on next shell)
refresh-hwinfo() {
    _rh_mid=$(command cat /etc/machine-id 2>/dev/null || command hostname 2>/dev/null || echo unknown)
    rm -f "${XDG_RUNTIME_DIR:-/tmp}/dotfiles-hwinfo.${_rh_mid}.sh"
    unset _rh_mid
    echo "hwinfo cache cleared. Restart shell to refresh."
}

# toggle-hwinfo → flip hardware info display in starship prompt on/off
toggle-hwinfo() {
    if [ "${_DOTFILES_HWINFO_HIDDEN:-0}" = "0" ]; then
        _DOTFILES_SAVED_CPU_INTEL="$STARSHIP_CPU_INTEL"
        _DOTFILES_SAVED_CPU_AMD="$STARSHIP_CPU_AMD"
        _DOTFILES_SAVED_GPU_NVIDIA="$STARSHIP_GPU_NVIDIA"
        _DOTFILES_SAVED_GPU_AMD="$STARSHIP_GPU_AMD"
        _DOTFILES_SAVED_GPU_INTEL="$STARSHIP_GPU_INTEL"
        export _DOTFILES_SAVED_CPU_INTEL _DOTFILES_SAVED_CPU_AMD
        export _DOTFILES_SAVED_GPU_NVIDIA _DOTFILES_SAVED_GPU_AMD _DOTFILES_SAVED_GPU_INTEL
        unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD
        unset STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
        export _DOTFILES_HWINFO_HIDDEN=1
        echo "hwinfo: OFF (hidden from prompt)"
    else
        [ -n "$_DOTFILES_SAVED_CPU_INTEL" ]  && export STARSHIP_CPU_INTEL="$_DOTFILES_SAVED_CPU_INTEL"
        [ -n "$_DOTFILES_SAVED_CPU_AMD" ]    && export STARSHIP_CPU_AMD="$_DOTFILES_SAVED_CPU_AMD"
        [ -n "$_DOTFILES_SAVED_GPU_NVIDIA" ] && export STARSHIP_GPU_NVIDIA="$_DOTFILES_SAVED_GPU_NVIDIA"
        [ -n "$_DOTFILES_SAVED_GPU_AMD" ]    && export STARSHIP_GPU_AMD="$_DOTFILES_SAVED_GPU_AMD"
        [ -n "$_DOTFILES_SAVED_GPU_INTEL" ]  && export STARSHIP_GPU_INTEL="$_DOTFILES_SAVED_GPU_INTEL"
        unset _DOTFILES_SAVED_CPU_INTEL _DOTFILES_SAVED_CPU_AMD
        unset _DOTFILES_SAVED_GPU_NVIDIA _DOTFILES_SAVED_GPU_AMD _DOTFILES_SAVED_GPU_INTEL
        export _DOTFILES_HWINFO_HIDDEN=0
        echo "hwinfo: ON (visible in prompt)"
    fi
}
