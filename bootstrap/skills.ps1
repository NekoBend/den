#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Install den prompt skills into coding-agent directories.
.DESCRIPTION
  Each skill is installed as a SELF-CONTAINED unit with only the shared/
  resources it references, rewritten to absolute paths. No top-level shared/
  tree is created in the target.

  Use --tool to deploy to a named tool's correct directories. Supported:
  claude, codex, cline, copilot, gemini. --all-tools deploys to all five.

  Tool-specific locations (verified 2026-06-04):
    claude  : skills -> ~/.claude/skills/    parent -> ~/.claude/CLAUDE.md
    codex   : skills -> ~/.agents/skills/    parent -> ~/.codex/AGENTS.md
    cline   : skills -> ~/.cline/skills/     parent -> ~/.agents/AGENTS.md
    copilot : skills -> ~/.copilot/skills/   parent -> ~/.copilot/copilot-instructions.md
    gemini  : skills -> ~/.gemini/skills/    parent -> ~/.gemini/GEMINI.md
.PARAMETER tool
  Tool name(s) to deploy for. Repeatable. Values: claude, codex, cline, copilot, gemini.
.PARAMETER all-tools
  Deploy to all supported tools.
.PARAMETER target
  Custom target root(s). Overrides tool defaults.
.PARAMETER with-parent
  Install the parent prompt into each tool's correct location.
.PARAMETER dry-run
  Print actions without writing.
.PARAMETER codex-config
  Print the [[skills.config]] block for ~/.codex/config.toml.
.EXAMPLE
  ./skills.ps1 --tool claude --tool cline --with-parent
.EXAMPLE
  ./skills.ps1 --all-tools --with-parent
.EXAMPLE
  ./skills.ps1 --target ~/.codex --codex-config
.NOTES
  Flags use the same --xxx-yyy form as skills.sh. PowerShell accepts both a
  single and a double dash, so --with-parent and -with-parent both work.
#>
[CmdletBinding()]
param(
  [string[]]${tool},
  [switch]${all-tools},
  [string[]]${target},
  [switch]${with-parent},
  [switch]${dry-run},
  [switch]${codex-config}
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path $PSScriptRoot -Parent
$src       = Join-Path $repoRoot 'agents'
$distSrc   = Join-Path $src 'dist'
$skillsSrc = Join-Path $src 'skills'
$sharedSrc = Join-Path $src 'shared'
if (-not (Test-Path $skillsSrc) -or -not (Test-Path $sharedSrc)) {
  Write-Error "expected $skillsSrc and $sharedSrc to exist"
}

# --- Tool registry ---
# Returns [skillsDir, parentDir, parentFile]
function Get-ToolConfig([string]$toolName) {
  switch ($toolName) {
    'claude'  { return @(
        (Join-Path $HOME '.claude' 'skills'),
        (Join-Path $HOME '.claude'),
        'CLAUDE.md') }
    'codex'   { return @(
        (Join-Path $HOME '.agents' 'skills'),
        (Join-Path $HOME '.codex'),
        'AGENTS.md') }
    'cline'   { return @(
        (Join-Path $HOME '.cline' 'skills'),
        (Join-Path $HOME '.agents'),
        'AGENTS.md') }
    'copilot' { return @(
        (Join-Path $HOME '.copilot' 'skills'),
        (Join-Path $HOME '.copilot'),
        'copilot-instructions.md') }
    'gemini'  { return @(
        (Join-Path $HOME '.gemini' 'skills'),
        (Join-Path $HOME '.gemini'),
        'GEMINI.md') }
    default   { Write-Error "unknown tool '$toolName' (valid: claude codex cline copilot gemini)" }
  }
}

$excludeDirs = @('__pycache__', '.pytest_cache', 'tests')
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Expand-Path([string]$p) {
  if ($p -like '~*') { $p = Join-Path $HOME ($p.Substring(1).TrimStart('/', '\')) }
  return [System.IO.Path]::GetFullPath($p)
}

function Copy-Tree([string]$from, [string]$to) {
  $base = (Resolve-Path $from).Path
  Get-ChildItem $base -Recurse -File | Where-Object {
    $rel   = $_.FullName.Substring($base.Length)
    $parts = $rel.Split([char[]]@('/', '\'), [StringSplitOptions]::RemoveEmptyEntries)
    (-not ($parts | Where-Object { $excludeDirs -contains $_ })) -and ($_.Extension -ne '.pyc')
  } | ForEach-Object {
    $rel  = $_.FullName.Substring($base.Length).TrimStart('/', '\')
    $dest = Join-Path $to $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
  }
}

function Install-Skill([string]$name, [string]$skillsDir) {
  $skSrc = Join-Path $skillsSrc $name
  $dest  = Join-Path $skillsDir $name
  Copy-Tree $skSrc $dest

  $mdFiles    = Get-ChildItem $dest -Recurse -Filter '*.md'
  $needScripts = $false; $needAllRefs = $false
  $refFiles   = New-Object System.Collections.Generic.HashSet[string]
  foreach ($md in $mdFiles) {
    $text = [System.IO.File]::ReadAllText($md.FullName)
    if ($text -match 'shared/scripts/')  { $needScripts = $true }
    if ($text -match 'shared/reference/<') { $needAllRefs = $true }
    foreach ($m in [regex]::Matches($text, 'shared/reference/([A-Za-z0-9_-]+\.md)')) {
      [void]$refFiles.Add($m.Groups[1].Value)
    }
  }
  $refDst = Join-Path (Join-Path $dest 'shared') 'reference'
  if ($needAllRefs) {
    New-Item -ItemType Directory -Force -Path $refDst | Out-Null
    Get-ChildItem (Join-Path $sharedSrc 'reference') -Filter '*.md' |
      ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $refDst -Force }
  } elseif ($refFiles.Count -gt 0) {
    New-Item -ItemType Directory -Force -Path $refDst | Out-Null
    foreach ($rf in $refFiles) {
      $rfSrc = Join-Path (Join-Path $sharedSrc 'reference') $rf
      if (Test-Path $rfSrc) { Copy-Item -LiteralPath $rfSrc -Destination (Join-Path $refDst $rf) -Force }
    }
  }
  if ($needScripts) {
    Copy-Tree (Join-Path $sharedSrc 'scripts') (Join-Path (Join-Path $dest 'shared') 'scripts')
  }
  $destFwd    = $dest -replace '\\', '/'
  $destFwdEsc = $destFwd.Replace('$', '$$')
  $rewritten  = 0
  foreach ($md in (Get-ChildItem $dest -Recurse -Filter '*.md')) {
    $orig = [System.IO.File]::ReadAllText($md.FullName)
    $new  = [regex]::Replace($orig, '(\.\./)*shared/(reference|scripts)/', "$destFwdEsc/shared/`$2/")
    if ($new -ne $orig) {
      [System.IO.File]::WriteAllText($md.FullName, $new, $utf8)
      $rewritten++
    }
  }
  Write-Host "  $name (rewrote $rewritten md files)"
}

function Deploy-Target([string]$skillsDir, [string]$parentDir, [string]$parentFile) {
  $skillNames = Get-ChildItem $skillsSrc -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') } |
    Select-Object -ExpandProperty Name | Sort-Object

  if (${dry-run}) {
    Write-Host "[dry-run] skills -> $skillsDir/<name>/"
    Write-Host "[dry-run]   skills: $($skillNames -join ', ')"
    if (${with-parent}) { Write-Host "[dry-run]   parent -> $parentDir\$parentFile" }
    return
  }

  New-Item -ItemType Directory -Force -Path $skillsDir | Out-Null
  Write-Host "installing skills -> $skillsDir"
  foreach ($name in $skillNames) { Install-Skill $name $skillsDir }

  if (${with-parent}) {
    $srcFile = if ($parentFile -eq 'CLAUDE.md') {
      Join-Path $distSrc 'CLAUDE.md'
    } else {
      Join-Path $distSrc 'AGENTS.md'
    }
    if (Test-Path $srcFile) {
      New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
      Copy-Item -LiteralPath $srcFile -Destination (Join-Path $parentDir $parentFile) -Force
      Write-Host "  parent -> $parentDir\$parentFile"
    } else {
      Write-Warning "$srcFile not found; run tools/build.py first"
    }
  }
}

# Build the work list.
$firstSkillsDir = $null
$hasWork = $false

$allToolNames = @('claude', 'codex', 'cline', 'copilot', 'gemini')
$toolList = if (${all-tools}) { $allToolNames } else { ${tool} }

foreach ($t in $toolList) {
  $cfg = Get-ToolConfig $t
  Deploy-Target $cfg[0] $cfg[1] $cfg[2]
  if ($null -eq $firstSkillsDir) { $firstSkillsDir = $cfg[0] }
  $hasWork = $true
}

foreach ($t in ${target}) {
  $abs = Expand-Path $t
  $skillsDir = Join-Path $abs 'skills'
  $skillNames = Get-ChildItem $skillsSrc -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') } |
    Select-Object -ExpandProperty Name | Sort-Object

  if (${dry-run}) {
    Write-Host "[dry-run] skills -> $skillsDir/<name>/"
    Write-Host "[dry-run]   skills: $($skillNames -join ', ')"
    if (${with-parent}) { Write-Host "[dry-run]   plus AGENTS.md + CLAUDE.md -> $abs/" }
    $hasWork = $true; continue
  }
  New-Item -ItemType Directory -Force -Path $abs | Out-Null
  Write-Host "installing -> $abs"
  foreach ($name in $skillNames) { Install-Skill $name $skillsDir }
  if (${with-parent}) {
    $a = Join-Path $distSrc 'AGENTS.md'; $c = Join-Path $distSrc 'CLAUDE.md'
    if ((Test-Path $a) -and (Test-Path $c)) {
      Copy-Item -LiteralPath $a -Destination (Join-Path $abs 'AGENTS.md') -Force
      Copy-Item -LiteralPath $c -Destination (Join-Path $abs 'CLAUDE.md') -Force
      Write-Host "  parent: AGENTS.md + CLAUDE.md -> $abs\"
    } else { Write-Warning "AGENTS.md/CLAUDE.md not found in $distSrc; run tools/build.py first" }
  }
  if ($null -eq $firstSkillsDir) { $firstSkillsDir = $skillsDir }
  $hasWork = $true
}

# Default (no --tool and no --target): backward-compatible.
if ($toolList.Count -eq 0 -and ${target}.Count -eq 0) {
  Deploy-Target (Join-Path $HOME '.claude' 'skills') (Join-Path $HOME '.claude') 'CLAUDE.md'
  Deploy-Target (Join-Path $HOME '.agents' 'skills') (Join-Path $HOME '.agents') 'AGENTS.md'
  $firstSkillsDir = Join-Path $HOME '.agents' 'skills'
}

if (${codex-config}) {
  $sd = if ($firstSkillsDir) { $firstSkillsDir -replace '\\','/' } else { "$HOME/.agents/skills" }
  $skillNames = Get-ChildItem $skillsSrc -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') } |
    Select-Object -ExpandProperty Name | Sort-Object
  Write-Host ''
  Write-Host '# --- paste into ~/.codex/config.toml ---'
  foreach ($name in $skillNames) {
    Write-Host "[[skills.config]]"
    Write-Host "path = `"$sd/$name/SKILL.md`""
    Write-Host "enabled = true"
    Write-Host ''
  }
}

if (-not ${dry-run} -and -not ${with-parent} -and $hasWork) {
  Write-Host ''
  Write-Host 'Note: skills reference a parent prompt. Re-run with --with-parent to install it.'
}
