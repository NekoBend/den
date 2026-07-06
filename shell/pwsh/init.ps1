# init.ps1 — Load den config.
# Sourced by $PROFILE. Deploy target: alongside aliases.ps1, functions.ps1, hwinfo.ps1.

# ===== Helpers (must load first) =====
. "$PSScriptRoot\_helpers.ps1"

# ===== Load config =====
. "$PSScriptRoot\wrappers.ps1"
. "$PSScriptRoot\coreutils.ps1"
. "$PSScriptRoot\functions.ps1"
. "$PSScriptRoot\aliases.ps1"
. "$PSScriptRoot\hwinfo.ps1"
if (Test-Path "$PSScriptRoot\python.ps1") { . "$PSScriptRoot\python.ps1" }
if (Test-Path "$PSScriptRoot\ffmpeg.ps1") { . "$PSScriptRoot\ffmpeg.ps1" }
if (Test-Path "$PSScriptRoot\parallel.ps1") { . "$PSScriptRoot\parallel.ps1" }
if (Test-Path "$PSScriptRoot\completion.ps1") { . "$PSScriptRoot\completion.ps1" }
if (Test-Path "$PSScriptRoot\cheat.ps1") { . "$PSScriptRoot\cheat.ps1" }
if (Test-Path "$PSScriptRoot\proxy.ps1") { . "$PSScriptRoot\proxy.ps1" }
if (Test-Path "$PSScriptRoot\snippet.ps1") { . "$PSScriptRoot\snippet.ps1" }

# ===== History =====
if (Get-Module -Name PSReadLine) {
  Set-PSReadLineOption -AddToHistoryHandler {
    param($line)
    return ($line -notmatch '^\s*s?again(\s|$)')
  }
}

# reload PowerShell profile (clears cache)
# Uses Invoke-Command with -NoNewScope to dot-source in the caller's (global) scope.
function reload {
  $_cd = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'shell-cache'
  if (Test-Path $_cd) { Remove-Item (Join-Path $_cd '*') -Force -ErrorAction SilentlyContinue }
  $sb = [scriptblock]::Create(". '$PROFILE'")
  Invoke-Command -ScriptBlock $sb -NoNewScope
}

# ===== Init tools (cached) =====
# Dot-source the cached init HERE (global scope); Initialize-Cache returns the path.
$_s = Initialize-Cache 'starship' @('init', 'powershell')
if ($_s) { . $_s }
Remove-Variable _s -ErrorAction SilentlyContinue
