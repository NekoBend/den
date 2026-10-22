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

# _DenLazyCompleter <tool> <cache> - register a stand-in native completer for
# <tool> that loads <cache>, a completion script (one that registers a
# self-contained Register-ArgumentCompleter -Native script block, as clap's do),
# only at the first Tab after <tool>. uv's is about 750 KB, and dot-sourcing it
# took about 60 ms of every start. On that Tab the stand-in dot-sources the
# cache with Register-ArgumentCompleter shadowed, so that it gets hold of the
# script block the cache registers for <tool>; the shadow still registers it,
# in place of the stand-in, and the stand-in hands this Tab to it. The cache is
# checked with Test-CacheSafe again first: it may have changed since startup.
function _DenLazyCompleter([string]$Tool, [string]$Cache) {
    if (-not $Tool -or -not $Cache) { return }
    Register-ArgumentCompleter -Native -CommandName $Tool -ScriptBlock {
        param($wordToComplete, $commandAst, $cursorPosition)
        if (-not (Test-CacheSafe -Path $Cache)) { return }
        $box = @{}
        function Register-ArgumentCompleter {
            param([string[]]$CommandName, [string]$ParameterName, [scriptblock]$ScriptBlock, [switch]$Native)
            if ($Native -and $CommandName -contains $Tool) { $box['Block'] = $ScriptBlock }
            Microsoft.PowerShell.Core\Register-ArgumentCompleter @PSBoundParameters
        }
        . $Cache
        if ($box['Block']) { & $box['Block'] $wordToComplete $commandAst $cursorPosition }
    }.GetNewClosure()
}

# Per-tool completers via the shared Initialize-Cache (cache suffix 'completion';
# the completion subcommand varies per tool). Dot-source the cache HERE, at this
# file's (global) scope: some completion scripts (docker's) register a scriptblock
# that closes over state which must outlive the call, so sourcing inside
# Initialize-Cache would scope that away and the completer silently fails -- hence
# Initialize-Cache returns the path and the caller sources it. Skipped when absent.
# uv's and rustup's (clap's: one self-contained script block) load at the first
# Tab instead (_DenLazyCompleter); docker's and gh's (cobra's) need their helper
# functions at global scope, and are small.
$_c = Initialize-Cache 'docker' @('completion', 'powershell') 'completion'; if ($_c) { . $_c }
$_c = Initialize-Cache 'gh' @('completion', '-s', 'powershell') 'completion'; if ($_c) { . $_c }
$_c = Initialize-Cache 'uv' @('generate-shell-completion', 'powershell') 'completion'; if ($_c) { _DenLazyCompleter 'uv' $_c }
$_c = Initialize-Cache 'rustup' @('completions', 'powershell') 'completion'; if ($_c) { _DenLazyCompleter 'rustup' $_c }
Remove-Variable _c -ErrorAction SilentlyContinue

# git: branch/remote completion via posh-git, but ONLY when it is already installed.
# posh-git is a heavy module, so we never force-install it or pay an import when it is
# absent (then git completion is simply skipped).
if (Get-Module -ListAvailable -Name posh-git) {
    Import-Module posh-git
}
