# completion.ps1 - bash-like Tab completion for pwsh. Dot-sourced by init.ps1
# AFTER _helpers.ps1 (which provides Test-CacheSafe). Two layers, like Ubuntu:
#   1. PSReadLine Tab shows a completion MENU (like the zsh menu-select on Linux),
#      not silent cycling. Only when PSReadLine is loaded (interactive sessions).
#   2. Per-tool argument completers: tools that emit a PowerShell completion script
#      are cached + sourced (skipped when the tool is absent), so `docker run <Tab>`
#      etc. complete. git uses posh-git, but only when it is already installed.

# Initialize-Completion <tool> <args> - ensure a fresh, validated cache of a tool's
# completion script and RETURN its path (or nothing). The CALLER dot-sources it at
# GLOBAL scope on purpose: some completion scripts (e.g. docker's) register a
# scriptblock that closes over state which must outlive this call, so sourcing it
# inside the function would scope that state away and the completer silently fails.
# The completion subcommand varies per tool, so it is passed in; the cache is
# regenerated only when the tool binary is newer, and validated by Test-CacheSafe.
function Initialize-Completion([string]$Tool, [string[]]$CompletionArgs) {
    $toolPath = Get-Command $Tool -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Source
    if ([string]::IsNullOrWhiteSpace($toolPath)) { return }

    $_cd = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'shell-cache'
    if (-not (Test-Path -LiteralPath $_cd -PathType Container)) {
        New-Item -ItemType Directory -Path $_cd -Force | Out-Null
    }

    $_cf = Join-Path $_cd "$Tool-completion.ps1"
    $needsRegen = (-not (Test-Path -LiteralPath $_cf -PathType Leaf)) -or
        ((Get-Item -LiteralPath $_cf).LastWriteTime -lt (Get-Item -LiteralPath $toolPath).LastWriteTime)

    if ($needsRegen) {
        # Commit the cache ONLY when the command succeeded AND printed something.
        # A tool that is present but whose completion command fails or prints
        # nothing (unsupported version, transient error) would otherwise write an
        # empty file whose mtime is newer than the binary, so the freshness check
        # never regenerates and completion stays silently broken until a reinstall.
        $out = & $toolPath @CompletionArgs 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            $tmpCache = $_cf + '.tmp.' + [guid]::NewGuid().ToString('N')
            try {
                $out | Set-Content -LiteralPath $tmpCache -Encoding UTF8
                Move-Item -LiteralPath $tmpCache -Destination $_cf -Force
            } finally {
                if (Test-Path -LiteralPath $tmpCache -PathType Leaf) {
                    Remove-Item -LiteralPath $tmpCache -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    # Return the cache path for the caller to dot-source at GLOBAL scope (a prior
    # good cache is reused if regen was skipped above).
    if (Test-Path -LiteralPath $_cf -PathType Leaf) {
        if (Test-CacheSafe -Path $_cf) {
            return $_cf
        }
        Write-Warning "Initialize-Completion: refusing to source unsafe cache file '$_cf'"
    }
}

# The Tab handler and per-tool completers only matter in INTERACTIVE sessions
# (where you press Tab). Skip them in non-interactive / automation runs, which
# also avoids spawning docker/gh/uv/rustup there. Initialize-Completion above is
# still defined, so it stays reusable + testable. (Matches wrappers/coreutils.)
if (-not [Environment]::UserInteractive) { return }

# Tab UX: show a completion menu (matches the zsh menu-select on Linux).
if (Get-Module -Name PSReadLine) {
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
}

# Per-tool completers (cached; each is skipped when its tool is not installed).
# Dot-source the cache HERE, at this file's (global) scope -- see the note above.
$_c = Initialize-Completion 'docker' @('completion', 'powershell');               if ($_c) { . $_c }
$_c = Initialize-Completion 'gh'     @('completion', '-s', 'powershell');          if ($_c) { . $_c }
$_c = Initialize-Completion 'uv'     @('generate-shell-completion', 'powershell'); if ($_c) { . $_c }
$_c = Initialize-Completion 'rustup' @('completions', 'powershell');               if ($_c) { . $_c }
Remove-Variable _c -ErrorAction SilentlyContinue

# git: branch/remote completion via posh-git, but ONLY when it is already
# installed. posh-git is a heavy module, so we never force-install it or pay an
# import when it is absent (then git completion is simply skipped).
if (Get-Module -ListAvailable -Name posh-git) {
    Import-Module posh-git
}
