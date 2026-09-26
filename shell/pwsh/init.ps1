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

# reload - clear den's shell caches and start PowerShell afresh, the counterpart of
# bash/zsh's `exec`. PowerShell cannot replace its own process, so reload runs the
# same executable with the arguments this session was started with, in the current
# directory and environment, waits for it, and exits with its exit code: leaving the
# new shell closes the terminal, as after exec. Those arguments apply again, but for
# -WorkingDirectory, which reload leaves out (see _DenRelaunchArgs) so that the new
# shell stays in the current directory: a -NoExit -Command or -File payload runs
# again there, and a relative path in it, or given to -File, -SettingsFile or
# -ConfigurationFile, is read from there. In a VS Code terminal that payload is
# `-noexit -command ". <shellIntegration.ps1>"`, and reload hands back the values
# the integration script took out of the environment (see _DenVSCodeEnv). Each
# reload nests one more process, and variables made in this session do not carry
# over (environment variables do). Dot-sourcing $PROFILE from here instead defines
# everything in this function's scope, which is gone when it returns.
# PSReadLine's default HistorySaveStyle, SaveIncrementally, has written this
# session's commands, reload included, before the new shell reads the history file;
# SaveAtExit would write them only when this process exits, after the new shell.
# Only an interactive console session at its top-level prompt restarts, and only
# while fewer than 8 reloads in a row led to it (a reload in the startup payload
# would otherwise start shells without end). Otherwise (a -File or -Command run, a
# -NonInteractive launch, another host such as the ISE or VS Code's extension
# terminal, a nested prompt such as the debugger's, where exit would only leave the
# nested prompt) reload clears the caches and warns.
# $global:_DenReloadDepth counts the reloads in a row that led to this session:
# reload passes the count on in _DEN_RELOAD_DEPTH, which is taken out of the
# environment here, so that programs started from this session do not inherit it.
$global:_DenReloadDepth = 0
if ("$env:_DEN_RELOAD_DEPTH" -match '^[0-9]{1,4}$') { $global:_DenReloadDepth = [int]$env:_DEN_RELOAD_DEPTH }
$env:_DEN_RELOAD_DEPTH = $null
function reload {
  $_base = [Environment]::GetFolderPath('LocalApplicationData')
  if ($_base) {
    $_cd = Join-Path $_base 'shell-cache'
    if (Test-Path $_cd) { Remove-Item (Join-Path $_cd '*') -Force -ErrorAction SilentlyContinue }
  }
  $exe = (Get-Process -Id $PID).Path
  $argv = [Environment]::GetCommandLineArgs()
  $launch = @(_DenRelaunchArgs -CommandLineArgs $argv)
  $depth = [int]$global:_DenReloadDepth
  # Not _DenInteractive: its _DEN_FORCE_INTERACTIVE override would restart a
  # `-NonInteractive -Command` run, which runs its command again.
  $why = $null
  if ($Host.Name -ne 'ConsoleHost') {
    $why = "the '$($Host.Name)' host is not a console shell"
  } elseif (-not ([Environment]::UserInteractive -and (_DenLaunchIsRepl -Arguments $launch))) {
    $why = 'this session was not started as an interactive shell (-File, -Command or -NonInteractive)'
  } elseif ($NestedPromptLevel -gt 0) {
    $why = 'reload was called from a nested prompt (such as the debugger)'
  } elseif ($depth -ge 8) {
    $why = "$depth reloads in a row led to this shell, each one nested in the one before"
  } elseif ($launch -contains '--%') {
    $why = "its launch arguments hold '--%', which cannot be passed on"
  } elseif (-not $exe) {
    $why = 'the path of this PowerShell executable is unknown'
  }
  if ($why) {
    Write-Warning "reload: caches cleared, but not restarting: $why. Open a new session to load the config."
    return
  }
  if (_DenLegacyArgPassing) { $launch = @(_DenRelaunchArgs -CommandLineArgs $argv -Legacy) }
  # Only for the new shell: this process exits once it ends, unless it cannot start.
  $handOn = _DenVSCodeEnv
  $handOn['_DEN_RELOAD_DEPTH'] = [string]($depth + 1)
  foreach ($name in $handOn.Keys) { [Environment]::SetEnvironmentVariable($name, $handOn[$name]) }
  # exit runs in finally: a Ctrl+C in the new shell reaches this process too and
  # stops this pipeline, which still waits for the new shell but then skips the
  # statements after it, so a later exit would land back in this stale session.
  # Only a failure to start is caught; any other error (such as a nonzero exit
  # under $PSNativeCommandUseErrorActionPreference) still exits.
  $failed = $false
  try {
    & $exe @launch
  } catch [System.Management.Automation.CommandNotFoundException], [System.Management.Automation.ApplicationFailedException] {
    $failed = $true
    foreach ($name in $handOn.Keys) { [Environment]::SetEnvironmentVariable($name, $null) }
    Write-Warning "reload: could not start ${exe}: $($_.Exception.Message)"
  } finally {
    if (-not $failed) { exit $LASTEXITCODE }
  }
}

# ===== Init tools (cached) =====
# Dot-source the cached init HERE (global scope); Initialize-Cache returns the path.
$_s = Initialize-Cache 'starship' @('init', 'powershell')
if ($_s) { . $_s }
Remove-Variable _s -ErrorAction SilentlyContinue

# ===== Directory history =====
# back/fwd history records moves at each prompt (see functions.ps1). Hooked
# here, after starship, because starship's init replaces the prompt function.
# A prompt defined after this file (a later line in $PROFILE, such as an
# oh-my-posh or posh-git init) replaces the wrapper the same way; then only den's
# navigation commands and back/fwd record, as COMMANDS.md warns.
_DenDirHookPrompt
