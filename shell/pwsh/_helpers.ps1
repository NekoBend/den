# _helpers.ps1 — DRY helpers for dotfiles PowerShell config.
# Dot-sourced first by init.ps1.

# ========== wrapper log ==========

# _WrapLog <name> <tool> — announce a modern-tool substitution on EVERY wrapped
# call. The modern tool's flags and output differ from the native command, so a
# silent substitution is easy to miss (and commands that assume the native
# behavior then break). Silence the notice with _DOTFILES_WRAPPER_LOG=0.
function _WrapLog([string]$Name, [string]$Tool) {
    if ($env:_DOTFILES_WRAPPER_LOG -eq '0') { return }
    Write-Host "[dotfiles] $Name -> $Tool  | disable: run toggle-wrapper, or `$env:_DOTFILES_WRAPPERS = '0'" -ForegroundColor DarkGray
}

# ========== wrapper generator ==========

# New-Wrapper <func> <modern> <modernFlags> <nativeCmd> <nativeCmdFlags> <fallbackExpr>
function New-Wrapper([string]$FuncName, [string]$Modern, [string]$ModernFlags, [string]$NativeCmd, [string]$NativeCmdFlags, [string]$FallbackExpr) {
    # The native command is resolved LAZILY, on the fallback branch only (i.e.
    # when the modern tool is absent), not at init time. Pre-resolving it meant
    # a PATH-scanning Get-Command per wrapper on every shell startup, for a path
    # most users never hit; lazy resolution keeps startup cheap.
    $fallbackCode = if ($FallbackExpr) { $FallbackExpr } else { "Write-Warning '${FuncName}: $Modern is not installed.'" }
    $sb = [scriptblock]::Create(@"
if (`$env:_DOTFILES_WRAPPERS -ne '0' -and (Get-Command '$Modern' -ErrorAction SilentlyContinue)) {
    _WrapLog '$FuncName' '$Modern'
    `$input | & '$Modern' $ModernFlags @Args
} else {
    `$__nc = if ('$NativeCmd') { (Get-Command '$NativeCmd' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source } else { `$null }
    if (`$__nc) {
        `$input | & `$__nc $NativeCmdFlags @Args
    } else {
        $fallbackCode
    }
}
"@)
    Set-Item -Path "function:global:$FuncName" -Value $sb
}

# New-WrapperSuffix <func> <modern> <modernFlags> — always use modern (w-suffix)
function New-WrapperSuffix([string]$FuncName, [string]$Modern, [string]$ModernFlags) {
    $sb = [scriptblock]::Create(@"
if (Get-Command '$Modern' -ErrorAction SilentlyContinue) {
    `$input | & '$Modern' $ModernFlags @Args
} else {
    Write-Warning "${FuncName}: $Modern is not installed."
}
"@)
    Set-Item -Path "function:global:$FuncName" -Value $sb
}

# ========== toggle ==========

function toggle-wrapper {
    if ($env:_DOTFILES_WRAPPERS -ne '0') {
        $env:_DOTFILES_WRAPPERS = '0'
        $env:STARSHIP_WRAPPER_STATE = 'OFF'
        Write-Host 'wrappers: ' -NoNewline
        Write-Host 'OFF' -ForegroundColor Yellow -NoNewline
        Write-Host ' (using native commands)'
    }
    else {
        $env:_DOTFILES_WRAPPERS = '1'
        Remove-Item Env:\STARSHIP_WRAPPER_STATE -ErrorAction SilentlyContinue
        Write-Host 'wrappers: ' -NoNewline
        Write-Host 'ON' -ForegroundColor Green -NoNewline
        Write-Host ' (using modern tools)'
    }
}

# ========== cache init ==========

# Test-CacheSafe <path> — verify generated cache file is safe to dot-source.
function Test-CacheSafe([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

    try {
        $cacheItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        return $false
    }

    if ($cacheItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        return $false
    }

    if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
        try {
            $cacheOwner = (Get-Acl -LiteralPath $Path -ErrorAction Stop).Owner
            $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        } catch {
            return $false
        }
        if ($cacheOwner -ne $currentUser) {
            return $false
        }
    }

    return $true
}

# Initialize-Cache <tool> <shell> [extra_args...]
function Initialize-Cache([string]$Tool, [string]$Shell, [string[]]$ExtraArgs) {
    $toolPath = Get-Command $Tool -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Source
    if ([string]::IsNullOrWhiteSpace($toolPath)) { return }

    $_cd = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'shell-cache'
    if (-not (Test-Path -LiteralPath $_cd -PathType Container)) {
        New-Item -ItemType Directory -Path $_cd -Force | Out-Null
    }

    $_cf = Join-Path $_cd "${Tool}-init.ps1"
    $needsRegen = (-not (Test-Path -LiteralPath $_cf -PathType Leaf)) -or
        ((Get-Item -LiteralPath $_cf).LastWriteTime -lt (Get-Item -LiteralPath $toolPath).LastWriteTime)

    if ($needsRegen) {
        $tmpCache = $_cf + '.tmp.' + [guid]::NewGuid().ToString('N')
        try {
            & $toolPath init $Shell @ExtraArgs | Set-Content -LiteralPath $tmpCache -Encoding UTF8
            Move-Item -LiteralPath $tmpCache -Destination $_cf -Force
        } finally {
            if (Test-Path -LiteralPath $tmpCache -PathType Leaf) {
                Remove-Item -LiteralPath $tmpCache -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not (Test-CacheSafe -Path $_cf)) {
        Write-Warning "Initialize-Cache: refusing to source unsafe cache file '$_cf'"
        return
    }

    . $_cf
}
