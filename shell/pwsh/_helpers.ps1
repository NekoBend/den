# _helpers.ps1 — DRY helpers for dotfiles PowerShell config.
# Dot-sourced first by init.ps1.

# ========== wrapper log ==========

# _WrapLog <name> <tool> — announce a modern-tool substitution on EVERY wrapped
# call. The modern tool's flags and output differ from the native command, so a
# silent substitution is easy to miss (and commands that assume the native
# behavior then break). Silence the notice with _DEN_WRAPPER_LOG=0.
function _WrapLog([string]$Name, [string]$Tool) {
    if ($env:_DEN_WRAPPER_LOG -eq '0') { return }
    Write-Host "[den] $Name -> $Tool  | disable: run toggle-wrapper, or `$env:_DEN_WRAPPERS = '0'" -ForegroundColor DarkGray
}

# ========== microsoft/coreutils tier (Windows) ==========

# _OnWindows — true on ANY Windows PowerShell, including Windows PowerShell 5.1
# (Desktop edition) where the $IsWindows automatic variable does not exist (it is
# $null there). Used to skip the DOS-colliding native commands (see $winNativeSkip
# in New-Wrapper) on every Windows host, 5.1 included.
function _OnWindows {
    [bool]($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop')
}

# _CoreutilsBin — path to the microsoft/coreutils multi-call binary, or $null. This
# is the middle dispatch tier on Windows (modern -> coreutils -> native -> PS
# fallback): microsoft/coreutils bundles uutils/coreutils + findutils + grep into
# ONE binary invoked as `<bin> <name> ...`, so real Unix `ls`/`cat`/`grep`/`find`
# are available. Its installer is admin/all-user only and drops the binary at a
# FIXED path, %ProgramFiles%\coreutils\coreutils.exe; the optional "add to PATH"
# task only adds the bin\ subdir (the per-command hardlinks, NOT coreutils.exe), so
# we resolve the absolute path directly instead of trusting PATH. Restricted to
# pwsh 7+ on Windows ($IsWindows -eq $true); Windows PowerShell 5.1 and Linux/macOS
# skip it. Resolution is lazy + cached. Override the binary (name or full path)
# with $env:_DEN_COREUTILS, or set it to '0' to disable.
# Per-session command-resolution cache. Get-Command is slow (a MISS especially so
# on Windows), and the generated wrappers run it on every ls/cat/grep/... call;
# memoizing per session reaches bash's hashed-command parity. A tool installed
# mid-session is picked up after `reload` (which re-sources this file and so resets
# the cache). Value is the resolved path/name, or '' = absent. App-lookup keys also
# carry $VIRTUAL_ENV (see _ResolveCmd) so a venv switch re-resolves pip/python.
$script:_DenCmdCache = @{}

# _ResolveCmd <name> [type] — cached Get-Command. Type 'App' resolves to the real
# executable PATH (CommandType Application), which skips a same-named function or
# alias -- the wrappers and the uv/pip/python overrides are functions named after
# the command they wrap, so they MUST call the resolved path to avoid recursion and
# to work cross-platform (no hardcoded .exe). Any other type returns the NAME if the
# command exists at all (used only as a boolean existence check). $null when absent.
function _ResolveCmd([string]$Name, [string]$Type = 'Any') {
    # An 'App' result is a resolved PATH that depends on the active venv (pip and
    # python live in $VIRTUAL_ENV when one is active), so key it by $VIRTUAL_ENV --
    # otherwise activating a second venv in the same session would reuse the first
    # venv's pip/python path and install into the wrong environment. 'Any' returns
    # the bare name (an existence check), which is venv-insensitive.
    $key = if ($Type -eq 'App') { "App|$Name|$env:VIRTUAL_ENV" } else { "Any|$Name" }
    if (-not $script:_DenCmdCache.ContainsKey($key)) {
        $val = ''
        if ($Type -eq 'App') {
            $src = (Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
            if ($src) { $val = $src }
        }
        elseif (Get-Command $Name -ErrorAction SilentlyContinue) {
            $val = $Name
        }
        $script:_DenCmdCache[$key] = $val
    }
    $v = $script:_DenCmdCache[$key]
    if ($v -eq '') { return $null } else { return $v }
}

$script:_DenCoreutils = $null   # $null = unresolved, '' = resolved-absent, else path
function _CoreutilsBin {
    if ($env:_DEN_COREUTILS -eq '0') { return $null }
    if ($IsWindows -ne $true) { return $null }
    if ($null -eq $script:_DenCoreutils) {
        $found = ''
        if ($env:_DEN_COREUTILS) {
            $g = (Get-Command $env:_DEN_COREUTILS -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
            if ($g) { $found = $g }
            elseif (Test-Path -LiteralPath $env:_DEN_COREUTILS -PathType Leaf) { $found = $env:_DEN_COREUTILS }
        }
        if (-not $found) {
            $g = (Get-Command 'coreutils' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
            if ($g) { $found = $g }
        }
        if (-not $found) {
            foreach ($p in @("$env:ProgramFiles\coreutils\coreutils.exe", "${env:ProgramFiles(x86)}\coreutils\coreutils.exe")) {
                if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { $found = $p; break }
            }
        }
        $script:_DenCoreutils = $found
    }
    if ($script:_DenCoreutils) { return $script:_DenCoreutils } else { return $null }
}

# ========== wrapper generator ==========

# New-Wrapper <func> <modern> <modernFlags> <nativeCmd> <nativeCmdFlags> <fallbackExpr>
function New-Wrapper([string]$FuncName, [string]$Modern, [string]$ModernFlags, [string]$NativeCmd, [string]$NativeCmdFlags, [string]$FallbackExpr) {
    # Dispatch order: modern tool -> (Windows) microsoft/coreutils -> native exe on
    # PATH -> PowerShell fallback. The coreutils and native tiers both reuse
    # $NativeCmd as the Unix command name ('ls'/'cat'/'grep'/'find'), so on Windows a
    # real Git-for-Windows GNU tool is still used when coreutils is absent. The one
    # exception is names whose Windows System32 namesake behaves DIFFERENTLY from the
    # Unix tool (see $winNativeSkip, e.g. `find`): for those the native lookup is
    # skipped on Windows so it never resolves to the DOS command -- coreutils or the
    # PS fallback handles them instead. The coreutils and native lookups are both
    # LAZY (resolved on the non-modern branch only), so startup stays cheap.
    $fallbackCode = if ($FallbackExpr) { $FallbackExpr } else { "Write-Warning '${FuncName}: $Modern is not installed.'" }
    $winNativeSkip = @('find', 'sort', 'more')
    $nativeGuard = if ($NativeCmd -and ($NativeCmd -in $winNativeSkip)) {
        "'$NativeCmd' -and -not (_OnWindows)"
    } elseif ($NativeCmd) {
        "'$NativeCmd'"
    } else {
        "`$false"
    }
    $sb = [scriptblock]::Create(@"
if (`$env:_DEN_WRAPPERS -ne '0' -and (_ResolveCmd '$Modern')) {
    _WrapLog '$FuncName' '$Modern'
    `$input | & '$Modern' $ModernFlags @Args
} else {
    `$__cu = if ('$NativeCmd') { _CoreutilsBin } else { `$null }
    if (`$__cu) {
        `$input | & `$__cu $NativeCmd $NativeCmdFlags @Args
    } else {
        `$__nc = if ($nativeGuard) { _ResolveCmd '$NativeCmd' 'App' } else { `$null }
        if (`$__nc) {
            `$input | & `$__nc $NativeCmdFlags @Args
        } else {
            $fallbackCode
        }
    }
}
"@)
    Set-Item -Path "function:global:$FuncName" -Value $sb
}

# New-WrapperSuffix <func> <modern> <modernFlags> — always use modern (w-suffix)
function New-WrapperSuffix([string]$FuncName, [string]$Modern, [string]$ModernFlags) {
    $sb = [scriptblock]::Create(@"
if (_ResolveCmd '$Modern') {
    `$input | & '$Modern' $ModernFlags @Args
} else {
    Write-Warning "${FuncName}: $Modern is not installed."
}
"@)
    Set-Item -Path "function:global:$FuncName" -Value $sb
}

# New-CoreutilsWrapper <func> <cmdName> <builtinExpr> — for commands with no modern
# tool: prefer microsoft/coreutils on Windows, else the PowerShell builtin. Used for
# the destructive coreutils (cp/mv/rm/mkdir/rmdir). On non-Windows _CoreutilsBin is
# $null so these collapse to the builtin, matching the stock PowerShell aliases.
function New-CoreutilsWrapper([string]$FuncName, [string]$CmdName, [string]$BuiltinExpr) {
    $sb = [scriptblock]::Create(@"
`$__cu = _CoreutilsBin
if (`$__cu) {
    `$input | & `$__cu $CmdName @Args
} else {
    $BuiltinExpr
}
"@)
    Set-Item -Path "function:global:$FuncName" -Value $sb
}

# ========== toggle ==========

function toggle-wrapper {
    if ($env:_DEN_WRAPPERS -ne '0') {
        $env:_DEN_WRAPPERS = '0'
        $env:STARSHIP_WRAPPER_STATE = 'OFF'
        Write-Host 'wrappers: ' -NoNewline
        Write-Host 'OFF' -ForegroundColor Yellow -NoNewline
        Write-Host ' (using native commands)'
    }
    else {
        $env:_DEN_WRAPPERS = '1'
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
