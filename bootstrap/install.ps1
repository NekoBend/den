# install.ps1 - den bootstrap installer (Windows / PowerShell).
#
# One entry point, branching by component. Pick what you want, skip the rest:
#   - shell environment : PowerShell config, starship, helpers (-> $PROFILE dir)
#   - LLM agent skills  : the agents/ skill set (-> ~/.agents and ~/.claude),
#                         delegated to bootstrap/skills.ps1
#
# The cmd/Clink shims are a separate, smaller installer: bootstrap/install.cmd.
#
# The flags use the same --xxx-yyy form as install.sh. PowerShell accepts both a
# single and a double dash, so --skills-only and -skills-only both work. (The
# params are declared with hyphenated names, e.g. ${skills-only}, which is why
# they read with braces in the body.)
#
# Usage: pwsh .\install.ps1 [options]
#   --shell / --no-shell      install (or skip) the shell environment
#   --agents / --no-agents    install (or skip) the LLM agent skills
#   --skills-only             install only the skills (= --no-shell --agents)
#   --with-parent / --no-parent
#                             install (or skip) AGENTS.md + CLAUDE.md with skills
#   --all                     install everything, no prompts
#   --yes                     accept defaults, no prompts
#   --dry-run                 print actions without writing
#
# With no component flag the installer is interactive and asks per component.
[CmdletBinding()]
param(
    [switch]${shell},
    [switch]${no-shell},
    [switch]${agents},
    [switch]${no-agents},
    [switch]${skills-only},
    [switch]${with-parent},
    [switch]${no-parent},
    [switch]${all},
    [switch]${yes},
    [switch]${dry-run}
)
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$profileDir = Split-Path -Parent $PROFILE

# --- Resolve component selection ---
if (${skills-only}) { ${no-shell} = $true; ${agents} = $true }
if (${all}) { ${shell} = $true; ${agents} = $true; ${with-parent} = $true; ${yes} = $true }

$interactive = -not (${yes} -or ${dry-run})

function Confirm-Component([string]$Default, [string]$Message) {
    if (-not $interactive) { return ($Default -eq 'Y') }
    $hint = if ($Default -eq 'Y') { '[Y/n]' } else { '[y/N]' }
    $ans = Read-Host "$Message $hint"
    if ($ans -eq '') { return ($Default -eq 'Y') }
    return ($ans -match '^[yY]')
}

# Shell: explicit flags win, else ask (default yes).
if (${shell}) { $doShell = $true }
elseif (${no-shell}) { $doShell = $false }
else { $doShell = Confirm-Component 'Y' 'Install shell environment (PowerShell, starship, helpers)?' }

# Agents: explicit flags win, else ask (default no).
if (${agents}) { $doAgents = $true }
elseif (${no-agents}) { $doAgents = $false }
else { $doAgents = Confirm-Component 'N' 'Install LLM agent skills (-> ~/.agents, ~/.claude)?' }

if (-not $doShell -and -not $doAgents) {
    Write-Host 'Nothing selected. Re-run with --shell, --agents, --skills-only, or --all.'
    return
}

$label = if (${dry-run}) { 'DRY' } else { 'OK' }

# ============================================================================
# Component: shell environment
# ============================================================================
if ($doShell) {
    $requiredFiles = @(
        "$RepoRoot\shell\pwsh\_helpers.ps1"
        "$RepoRoot\shell\pwsh\init.ps1"
        "$RepoRoot\shell\pwsh\wrappers.ps1"
        "$RepoRoot\shell\pwsh\coreutils.ps1"
        "$RepoRoot\shell\pwsh\aliases.ps1"
        "$RepoRoot\shell\pwsh\functions.ps1"
        "$RepoRoot\shell\pwsh\hwinfo.ps1"
    )
    $missing = $requiredFiles | Where-Object { -not (Test-Path $_) }
    if ($missing) {
        foreach ($m in $missing) { Write-Error "Source file not found: $m" }
        throw 'Aborting: missing source files.'
    }

    $suffix = if (${dry-run}) { ' (dry run)' } else { '' }
    Write-Host "Shell environment -> $profileDir$suffix" -ForegroundColor Cyan

    if (-not (Test-Path $profileDir)) {
        if (${dry-run}) {
            Write-Host "  [DRY] mkdir $profileDir" -ForegroundColor Yellow
        } else {
            New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        }
    }

    $files = @(
        @{ Src = "$RepoRoot\shell\pwsh\_helpers.ps1";   Dst = "$profileDir\_helpers.ps1" }
        @{ Src = "$RepoRoot\shell\pwsh\init.ps1";       Dst = "$profileDir\init.ps1" }
        @{ Src = "$RepoRoot\shell\pwsh\wrappers.ps1";   Dst = "$profileDir\wrappers.ps1" }
        @{ Src = "$RepoRoot\shell\pwsh\coreutils.ps1";  Dst = "$profileDir\coreutils.ps1" }
        @{ Src = "$RepoRoot\shell\pwsh\aliases.ps1";    Dst = "$profileDir\aliases.ps1" }
        @{ Src = "$RepoRoot\shell\pwsh\functions.ps1";  Dst = "$profileDir\functions.ps1" }
        @{ Src = "$RepoRoot\shell\pwsh\hwinfo.ps1";     Dst = "$profileDir\hwinfo.ps1" }
    )
    foreach ($f in $files) {
        if (-not (Test-Path $f.Src)) {
            Write-Host "  [SKIP] $($f.Src) (not found)" -ForegroundColor DarkGray
            continue
        }
        if (${dry-run}) {
            Write-Host "  [DRY] $(Split-Path -Leaf $f.Src)" -ForegroundColor Yellow
        } else {
            Copy-Item -Path $f.Src -Destination $f.Dst -Force
            Write-Host "  [$label] $(Split-Path -Leaf $f.Src)" -ForegroundColor Green
        }
    }

    # Optional modules
    $modules = @(
        @{ File = 'python.ps1';   Prompt = 'Install Python/uv helpers?' }
        @{ File = 'ffmpeg.ps1';   Prompt = 'Install ffmpeg helpers?' }
        @{ File = 'parallel.ps1'; Prompt = 'Install parallel file operation helpers (pcp, pmv, prm, ptar)?' }
    )
    foreach ($mod in $modules) {
        if (Confirm-Component 'Y' "  $($mod.Prompt)") {
            $src = "$RepoRoot\shell\pwsh\$($mod.File)"
            if (Test-Path $src) {
                if (${dry-run}) {
                    Write-Host "  [DRY] $($mod.File)" -ForegroundColor Yellow
                } else {
                    Copy-Item -Path $src -Destination "$profileDir\$($mod.File)" -Force
                    Write-Host "  [OK] $($mod.File)" -ForegroundColor Green
                }
            } else {
                Write-Host "  [SKIP] $($mod.File) (not found)" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  [SKIP] $($mod.File)" -ForegroundColor DarkGray
        }
    }

    # Append source line to $PROFILE if not already present
    $comment = '# ===== den ====='
    $sourceLine = '. "$PSScriptRoot\init.ps1"'
    if (Test-Path $PROFILE) {
        if (Select-String -Path $PROFILE -Pattern 'init\.ps1' -SimpleMatch:$false -Quiet) {
            Write-Host "  [SKIP] $PROFILE already configured" -ForegroundColor DarkGray
        } else {
            if (${dry-run}) {
                Write-Host "  [DRY] Would append source line to $PROFILE" -ForegroundColor Yellow
            } else {
                Add-Content -Path $PROFILE -Value "`n$comment`n$sourceLine"
                Write-Host "  [OK] Appended source line to $PROFILE" -ForegroundColor Green
            }
        }
    } else {
        if (${dry-run}) {
            Write-Host "  [DRY] Would create $PROFILE" -ForegroundColor Yellow
        } else {
            Set-Content -Path $PROFILE -Value "$comment`n$sourceLine"
            Write-Host "  [OK] Created $PROFILE" -ForegroundColor Green
        }
    }
}

# ============================================================================
# Component: LLM agent skills (delegated to skills.ps1)
# ============================================================================
if ($doAgents) {
    Write-Host ''
    # Skills depend on the parent invariants; default to installing them.
    if (${with-parent}) { $useParent = $true }
    elseif (${no-parent}) { $useParent = $false }
    else { $useParent = Confirm-Component 'Y' 'Install parent AGENTS.md / CLAUDE.md with the skills?' }

    $skillArgs = @{}
    if ($useParent) { $skillArgs['with-parent'] = $true }
    if (${dry-run}) { $skillArgs['dry-run'] = $true }
    & "$RepoRoot\bootstrap\skills.ps1" @skillArgs
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
if ($doShell) {
    Write-Host "  Run 'reload' or restart PowerShell." -ForegroundColor Cyan
}
