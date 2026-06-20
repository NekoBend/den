# completion.ps1 - bash-like Tab completion for pwsh. Dot-sourced by init.ps1
# AFTER _helpers.ps1 (which provides Test-CacheSafe). Two layers, like Ubuntu:
#   1. PSReadLine Tab shows a completion MENU (like the zsh menu-select on Linux),
#      not silent cycling. Only when PSReadLine is loaded (interactive sessions).
#   2. Per-tool argument completers: tools that emit a PowerShell completion script
#      are cached + sourced (skipped when the tool is absent), so `docker run <Tab>`
#      etc. complete. git uses posh-git, but only when it is already installed.

# Initialize-Completion <tool> <args> - cache + source a tool's completion script.
# Like Initialize-Cache, but the completion subcommand varies per tool
# (completion / completions / generate-shell-completion), so it is passed in.
# Regenerates when the tool binary is newer; validates with the shared
# Test-CacheSafe before sourcing.
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

    # Source the cache if present (a prior good one, if regen was skipped above).
    if (Test-Path -LiteralPath $_cf -PathType Leaf) {
        if (Test-CacheSafe -Path $_cf) {
            . $_cf
        } else {
            Write-Warning "Initialize-Completion: refusing to source unsafe cache file '$_cf'"
        }
    }
}

# Tab UX: show a completion menu (matches the zsh menu-select on Linux).
if (Get-Module -Name PSReadLine) {
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
}

# Per-tool completers (cached; each is skipped when its tool is not installed).
Initialize-Completion 'docker' @('completion', 'powershell')
Initialize-Completion 'gh'     @('completion', '-s', 'powershell')
Initialize-Completion 'uv'     @('generate-shell-completion', 'powershell')
Initialize-Completion 'rustup' @('completions', 'powershell')

# git: branch/remote completion via posh-git, but ONLY when it is already
# installed. posh-git is a heavy module, so we never force-install it or pay an
# import when it is absent (then git completion is simply skipped).
if (Get-Module -ListAvailable -Name posh-git) {
    Import-Module posh-git
}
