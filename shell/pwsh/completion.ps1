# completion.ps1 - bash-like Tab completion for pwsh. Dot-sourced by init.ps1
# AFTER _helpers.ps1 (which provides Initialize-Cache + Test-CacheSafe). Two layers,
# like Ubuntu:
#   1. PSReadLine Tab shows a completion MENU (like the zsh menu-select on Linux),
#      not silent cycling. Only when PSReadLine is loaded (interactive sessions).
#   2. Per-tool argument completers: each tool's generated PowerShell completion
#      script is cached + sourced (skipped when the tool is absent), so
#      `docker run <Tab>` etc. complete. git uses posh-git, but only when installed.

# This file only matters in INTERACTIVE sessions (where you press Tab), so skip it
# otherwise. _DenInteractive (in _helpers.ps1) is REPL-only on every platform, unlike
# the bare [Environment]::UserInteractive this used to gate on (always $true on
# non-Windows pwsh, so a no-op there), so `pwsh -File`/`-Command` runs no longer spawn
# the docker/gh/uv/rustup completers. (Matches wrappers/coreutils/aliases.)
if (-not (_DenInteractive)) { return }

# Tab UX: show a completion menu (matches the zsh menu-select on Linux).
if (Get-Module -Name PSReadLine) {
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
}

# Per-tool completers via the shared Initialize-Cache (cache suffix 'completion';
# the completion subcommand varies per tool). Dot-source the cache HERE, at this
# file's (global) scope: some completion scripts (docker's) register a scriptblock
# that closes over state which must outlive the call, so sourcing inside
# Initialize-Cache would scope that away and the completer silently fails -- hence
# Initialize-Cache returns the path and the caller sources it. Skipped when absent.
$_c = Initialize-Cache 'docker' @('completion', 'powershell') 'completion'; if ($_c) { . $_c }
$_c = Initialize-Cache 'gh' @('completion', '-s', 'powershell') 'completion'; if ($_c) { . $_c }
$_c = Initialize-Cache 'uv' @('generate-shell-completion', 'powershell') 'completion'; if ($_c) { . $_c }
$_c = Initialize-Cache 'rustup' @('completions', 'powershell') 'completion'; if ($_c) { . $_c }
Remove-Variable _c -ErrorAction SilentlyContinue

# git: branch/remote completion via posh-git, but ONLY when it is already installed.
# posh-git is a heavy module, so we never force-install it or pay an import when it is
# absent (then git completion is simply skipped).
if (Get-Module -ListAvailable -Name posh-git) {
    Import-Module posh-git
}
