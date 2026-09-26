#!/usr/bin/env bash
# test_hwinfo.sh — Tests for hwinfo.sh / hwinfo.ps1 (toggle-hwinfo).
# Also checks every shell/pwsh/*.ps1 for syntax Windows PowerShell 5.1 cannot parse.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

# helpers.sh already honours a DOTFILES override so the suite can run against a
# checkout; hardcoding it here silently discarded that and tested the INSTALLED
# copy instead, whatever DOTFILES said.
DOTFILES="${DOTFILES:-/root/.dotfiles}"
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
    echo "SAVED_CPU=$_DEN_SAVED_CPU_INTEL"
    echo "SAVED_GPU=$_DEN_SAVED_GPU_NVIDIA"
    echo "HIDDEN=$_DEN_HWINFO_HIDDEN"
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
    echo "HIDDEN=$_DEN_HWINFO_HIDDEN"
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

echo "[bash] Intel GPU detection via lspci"
# Mock lspci and point the cache at an empty dir so live detection runs; pre-fix
# no block ever set STARSHIP_GPU_INTEL on POSIX (parity gap with hwinfo.ps1).
HWINFO_MOCKBIN="$WORK/hwinfo-mockbin"
mkdir -p "$HWINFO_MOCKBIN"
cat > "$HWINFO_MOCKBIN/lspci" << 'MOCK'
#!/bin/sh
echo "00:02.0 VGA compatible controller: Intel Corporation UHD Graphics 620 (rev 07)"
MOCK
chmod +x "$HWINFO_MOCKBIN/lspci"
actual=$(bash -c "
    export PATH=\"$HWINFO_MOCKBIN:\$PATH\"
    export XDG_RUNTIME_DIR='$WORK/hwinfo-emptycache'
    mkdir -p \"\$XDG_RUNTIME_DIR\"
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    source '$HWINFO_SH'
    echo \"GPU_INTEL=\$STARSHIP_GPU_INTEL\"
" | tr -d '\r')
assert_contains "bash/Intel GPU via lspci" "GPU_INTEL=UHD Graphics 620" "$actual"

echo "[bash] cache write ignores a planted temp symlink"
# The old write path opened the predictable "$cache.tmp.$$" with a truncating
# redirect, so another user sharing /tmp (XDG_RUNTIME_DIR unset) could pre-plant
# that name as a symlink and have the shell rewrite the file it points at.
mkdir -p "$WORK/hwinfo-symcache"
echo "VICTIM" > "$WORK/hwinfo-victim.txt"
actual=$(bash -c "
    export XDG_RUNTIME_DIR='$WORK/hwinfo-symcache'
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    mid=\$(command cat /etc/machine-id 2>/dev/null || command hostname 2>/dev/null || echo unknown)
    ln -sf '$WORK/hwinfo-victim.txt' \"\$XDG_RUNTIME_DIR/den-hwinfo.\${mid}.sh.tmp.\$\$\"
    source '$HWINFO_SH'
    command cat '$WORK/hwinfo-victim.txt'
" | tr -d '\r')
assert_eq "bash/hwinfo does not write through planted symlink" "VICTIM" "$actual"
hwc_mid=$(command cat /etc/machine-id 2>/dev/null || command hostname 2>/dev/null || echo unknown)
assert_exists "bash/hwinfo cache still written" "$WORK/hwinfo-symcache/den-hwinfo.${hwc_mid}.sh"

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
    Write-Output "SAVED=$env:_DEN_SAVED_CPU_INTEL"
    Write-Output "HIDDEN=$env:_DEN_HWINFO_HIDDEN"
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

# =============================================================================
# Windows PowerShell 5.1 syntax, over every shell/pwsh/*.ps1
# =============================================================================
# init.ps1 dot-sources these files on Windows PowerShell 5.1 too, which cannot
# parse PowerShell 7 operators and then runs none of the file: hwinfo.ps1's
# `(...)?.Trim()` put toggle-hwinfo at stake. pwsh 7's parser still reads those
# operators, so its AST finds them without a 5.1 host.

PWSH_SYNTAX_SCAN="$WORK/pwsh_syntax_scan.ps1"
cat > "$PWSH_SYNTAX_SCAN" << 'PS1'
param([string]$Dir)
foreach ($f in Get-ChildItem -LiteralPath $Dir -Filter *.ps1 -File) {
  $tokens = $null; $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
  foreach ($e in $errors) { "$($f.Name):$($e.Extent.StartLineNumber): parse error: $($e.Message)" }
  # ?. and ?[] (7.1); ternary, ??, ??=, && and || (7.0)
  $hits = $ast.FindAll({
      param($n)
      ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.NullConditional) -or
      ($n -is [System.Management.Automation.Language.IndexExpressionAst] -and $n.NullConditional) -or
      ($n -is [System.Management.Automation.Language.TernaryExpressionAst]) -or
      ($n -is [System.Management.Automation.Language.PipelineChainAst]) -or
      ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and $n.Operator -eq 'QuestionQuestion') -or
      ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Operator -eq 'QuestionQuestionEquals')
    }, $true)
  foreach ($h in $hits) { "$($f.Name):$($h.Extent.StartLineNumber): $(($h.Extent.Text -split "`n")[0])" }
}
PS1

echo "[pwsh] no PowerShell 7-only syntax in shell/pwsh/*.ps1"
actual=$(pwsh -NoProfile -NonInteractive -File "$PWSH_SYNTAX_SCAN" "$DOTFILES/shell/pwsh" | tr -d '\r')
assert_eq "pwsh/5.1-parsable syntax" "" "$actual"

# PSUseCompatibleSyntax is the analyzer's view of the same class; the shell test
# image has no PSScriptAnalyzer, so the AST scan above is what runs there.
echo "[pwsh] PSUseCompatibleSyntax (5.1, 7.0) over shell/pwsh/*.ps1"
if pwsh -NoProfile -NonInteractive -Command 'if (Get-Module -ListAvailable PSScriptAnalyzer) { exit 0 }; exit 1' >/dev/null 2>&1; then
    # A hashtable, not a settings file: see the PSScriptAnalyzer step in ci.yml.
    actual=$(pwsh -NoProfile -NonInteractive -Command "
        \$settings = @{
            IncludeRules = @('PSUseCompatibleSyntax')
            Rules = @{ PSUseCompatibleSyntax = @{ Enable = \$true; TargetVersions = @('5.1', '7.0') } }
        }
        Get-ChildItem -LiteralPath '$DOTFILES/shell/pwsh' -Filter *.ps1 -File |
            ForEach-Object { Invoke-ScriptAnalyzer -Path \$_.FullName -Settings \$settings } |
            ForEach-Object { '{0}:{1}: {2}' -f \$_.ScriptName, \$_.Line, \$_.Message }
    " | tr -d '\r')
    assert_eq "pwsh/PSUseCompatibleSyntax 5.1 and 7.0" "" "$actual"
else
    echo "  SKIP: pwsh/PSUseCompatibleSyntax (PSScriptAnalyzer not installed)"
fi

print_summary "test_hwinfo"
[ "$FAIL" -eq 0 ]
