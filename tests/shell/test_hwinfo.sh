#!/usr/bin/env bash
# test_hwinfo.sh — Tests for hwinfo.sh / hwinfo.ps1 (toggle-hwinfo).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

DOTFILES="/root/.dotfiles"
HWINFO_SH_GUARDED="$DOTFILES/shell/posix/hwinfo.sh"
HWINFO_PS1="$DOTFILES/shell/pwsh/hwinfo.ps1"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

HWINFO_SH="$WORK/hwinfo_test.sh"
make_noninteractive_source_copy "$HWINFO_SH_GUARDED" "$HWINFO_SH"

# Extract only the toggle-hwinfo function from pwsh (detection uses Windows-only APIs)
HWINFO_PS1_TOGGLE="$WORK/hwinfo_toggle.ps1"
awk '/^function toggle-hwinfo/,0' "$HWINFO_PS1" > "$HWINFO_PS1_TOGGLE"

# =============================================================================
# Bash tests
# =============================================================================

echo "[bash] toggle-hwinfo OFF message"
actual=$(run_bash "$HWINFO_SH" '
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    export STARSHIP_CPU_INTEL="i9-13900K"
    export STARSHIP_GPU_NVIDIA="RTX 4090"
    toggle-hwinfo
')
assert_contains "bash/toggle-hwinfo OFF message" "hwinfo: OFF" "$actual"

echo "[bash] toggle-hwinfo OFF clears vars"
actual=$(run_bash "$HWINFO_SH" '
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    export STARSHIP_CPU_INTEL="i9-13900K"
    export STARSHIP_GPU_NVIDIA="RTX 4090"
    toggle-hwinfo >/dev/null
    echo "CPU=${STARSHIP_CPU_INTEL:-UNSET}"
    echo "GPU=${STARSHIP_GPU_NVIDIA:-UNSET}"
')
assert_contains "bash/toggle OFF cpu cleared" "CPU=UNSET" "$actual"
assert_contains "bash/toggle OFF gpu cleared" "GPU=UNSET" "$actual"

echo "[bash] toggle-hwinfo OFF saves vars"
actual=$(run_bash "$HWINFO_SH" '
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    export STARSHIP_CPU_INTEL="i9-13900K"
    export STARSHIP_GPU_NVIDIA="RTX 4090"
    toggle-hwinfo >/dev/null
    echo "SAVED_CPU=$_DOTFILES_SAVED_CPU_INTEL"
    echo "SAVED_GPU=$_DOTFILES_SAVED_GPU_NVIDIA"
    echo "HIDDEN=$_DOTFILES_HWINFO_HIDDEN"
')
assert_contains "bash/toggle OFF saved cpu" "SAVED_CPU=i9-13900K" "$actual"
assert_contains "bash/toggle OFF saved gpu" "SAVED_GPU=RTX 4090" "$actual"
assert_contains "bash/toggle OFF hidden flag" "HIDDEN=1" "$actual"

echo "[bash] toggle-hwinfo ON message"
actual=$(run_bash "$HWINFO_SH" '
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    export STARSHIP_CPU_INTEL="i9-13900K"
    export STARSHIP_GPU_NVIDIA="RTX 4090"
    toggle-hwinfo >/dev/null
    toggle-hwinfo
')
assert_contains "bash/toggle-hwinfo ON message" "hwinfo: ON" "$actual"

echo "[bash] toggle-hwinfo roundtrip restores vars"
actual=$(run_bash "$HWINFO_SH" '
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    export STARSHIP_CPU_INTEL="i9-13900K"
    export STARSHIP_GPU_NVIDIA="RTX 4090"
    toggle-hwinfo >/dev/null
    toggle-hwinfo >/dev/null
    echo "CPU=$STARSHIP_CPU_INTEL"
    echo "GPU=$STARSHIP_GPU_NVIDIA"
    echo "HIDDEN=$_DOTFILES_HWINFO_HIDDEN"
')
assert_contains "bash/roundtrip cpu" "CPU=i9-13900K" "$actual"
assert_contains "bash/roundtrip gpu" "GPU=RTX 4090" "$actual"
assert_contains "bash/roundtrip hidden" "HIDDEN=0" "$actual"

echo "[bash] guard: non-interactive source skips hwinfo"
actual=$(bash -c "
    source '$HWINFO_SH_GUARDED'
    type toggle-hwinfo >/dev/null 2>&1 && echo 'DEFINED' || echo 'UNDEFINED'
" | tr -d '\r')
assert_eq "bash/guard non-interactive" "UNDEFINED" "$actual"

echo "[bash] toggle-hwinfo defined with cached env"
actual=$(bash -c "
    export STARSHIP_CPU_INTEL='Cached'
    source '$HWINFO_SH'
    type toggle-hwinfo >/dev/null 2>&1 && echo 'DEFINED' || echo 'UNDEFINED'
" | tr -d '\r')
assert_eq "bash/toggle-hwinfo cached env" "DEFINED" "$actual"

# =============================================================================
# Zsh tests
# =============================================================================

echo "[zsh] toggle-hwinfo OFF/ON messages"
actual=$(run_zsh "$HWINFO_SH" '
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    export STARSHIP_CPU_INTEL="i9-13900K"
    toggle-hwinfo
    toggle-hwinfo
')
assert_contains "zsh/toggle OFF message" "hwinfo: OFF" "$actual"
assert_contains "zsh/toggle ON message" "hwinfo: ON" "$actual"

echo "[zsh] toggle-hwinfo var roundtrip"
actual=$(run_zsh "$HWINFO_SH" '
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    export STARSHIP_CPU_INTEL="Ryzen 9 7950X"
    toggle-hwinfo >/dev/null
    echo "OFF:CPU=${STARSHIP_CPU_INTEL:-UNSET}"
    toggle-hwinfo >/dev/null
    echo "ON:CPU=$STARSHIP_CPU_INTEL"
')
assert_contains "zsh/roundtrip OFF cleared" "OFF:CPU=UNSET" "$actual"
assert_contains "zsh/roundtrip ON restored" "ON:CPU=Ryzen 9 7950X" "$actual"

# =============================================================================
# PowerShell tests
# =============================================================================

echo "[pwsh] toggle-hwinfo OFF message"
actual=$(run_pwsh "$HWINFO_PS1_TOGGLE" '
    $env:STARSHIP_CPU_INTEL = "i9-13900K"
    $env:STARSHIP_GPU_NVIDIA = "RTX 4090"
    toggle-hwinfo 6>&1
' | tr -d '\r')
assert_contains "pwsh/toggle OFF message" "OFF" "$actual"

echo "[pwsh] toggle-hwinfo OFF clears vars"
actual=$(run_pwsh "$HWINFO_PS1_TOGGLE" '
    $env:STARSHIP_CPU_INTEL = "i9-13900K"
    $env:STARSHIP_GPU_NVIDIA = "RTX 4090"
    toggle-hwinfo *>$null
    Write-Output "CPU=$env:STARSHIP_CPU_INTEL"
    Write-Output "GPU=$env:STARSHIP_GPU_NVIDIA"
    Write-Output "SAVED=$env:_DOTFILES_SAVED_CPU_INTEL"
    Write-Output "HIDDEN=$env:_DOTFILES_HWINFO_HIDDEN"
' | tr -d '\r')
assert_eq "pwsh/toggle OFF cpu cleared" "CPU=" "$(echo "$actual" | grep '^CPU=')"
assert_eq "pwsh/toggle OFF gpu cleared" "GPU=" "$(echo "$actual" | grep '^GPU=')"
assert_eq "pwsh/toggle OFF saved cpu" "SAVED=i9-13900K" "$(echo "$actual" | grep '^SAVED=')"
assert_eq "pwsh/toggle OFF hidden flag" "HIDDEN=1" "$(echo "$actual" | grep '^HIDDEN=')"

echo "[pwsh] toggle-hwinfo roundtrip"
actual=$(run_pwsh "$HWINFO_PS1_TOGGLE" '
    $env:STARSHIP_CPU_INTEL = "i9-13900K"
    $env:STARSHIP_GPU_NVIDIA = "RTX 4090"
    toggle-hwinfo *>$null
    toggle-hwinfo 6>&1
    Write-Output "CPU=$env:STARSHIP_CPU_INTEL"
' | tr -d '\r')
assert_contains "pwsh/roundtrip ON message" "ON" "$actual"
assert_contains "pwsh/roundtrip cpu restored" "CPU=i9-13900K" "$actual"

print_summary "test_hwinfo"
[ "$FAIL" -eq 0 ]
