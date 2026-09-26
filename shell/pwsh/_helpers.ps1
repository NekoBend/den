# _helpers.ps1 — DRY helpers for den PowerShell config.
# Dot-sourced first by init.ps1.

# ========== wrapper log ==========

# _WrapLog <name> <tool> — announce a modern-tool substitution on EVERY wrapped
# call. The modern tool's flags and output differ from the native command, so a
# silent substitution is easy to miss (and commands that assume the native
# behavior then break). One short line: `[den] ls -> lsd  (off: tgl-wr)`. No
# "native:" hint here (unlike POSIX): PowerShell has no `command` builtin and the
# native-bypass idiom is awkward, so it only points at the toggle (tgl-wr =
# toggle-wrapper). _DEN_WRAPPER_LOG=0 silences just this notice and
# _DEN_WRAPPERS=0 disables the wrappers; both are documented in COMMANDS.md and
# shell/README.md rather than in the line.
function _WrapLog([string]$Name, [string]$Tool) {
    if ($env:_DEN_WRAPPER_LOG -eq '0') { return }
    Write-Host "[den] $Name -> $Tool  (off: tgl-wr)" -ForegroundColor DarkGray
}

# ========== microsoft/coreutils tier (Windows) ==========

# _OnWindows — true on ANY Windows PowerShell, including Windows PowerShell 5.1
# (Desktop edition) where the $IsWindows automatic variable does not exist (it is
# $null there). Used to skip the DOS-colliding native commands (see $winNativeSkip
# in New-Wrapper) on every Windows host, 5.1 included.
function _OnWindows {
    [bool]($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop')
}

# _DenInteractive - true only for an interactive REPL. den's wrappers/aliases/
# coreutils/completion load only here, so a `pwsh -File script.ps1` / `pwsh -Command
# ...` run does NOT get ls/cat/rm/grep/find silently replaced by den's functions.
# [Environment]::UserInteractive is unreliable for this: it is $true for -File/-Command
# in a desktop session (which still load $PROFILE) and ALWAYS $true on non-Windows
# pwsh, so the plain gate was a no-op off Windows. So also read the launch switches
# ([Environment]::GetCommandLineArgs(), minus argv[0], the pwsh binary) the way pwsh
# does; see _DenLaunchIsRepl.
# Set _DEN_FORCE_INTERACTIVE=1 to force-load (used by the shell tests, which run under
# `pwsh -NonInteractive -Command`).
function _DenInteractive {
    if ($env:_DEN_FORCE_INTERACTIVE -eq '1') { return $true }
    if (-not [Environment]::UserInteractive) { return $false }
    $argv = [Environment]::GetCommandLineArgs()
    $launch = @()
    if ($argv.Count -gt 1) { $launch = $argv[1..($argv.Count - 1)] }
    return (_DenLaunchIsRepl -Arguments $launch)
}

# _DenLaunchIsRepl <args> - whether pwsh launched with these arguments ends in a
# REPL, following pwsh's own parsing (checked against pwsh 7.6):
# - A switch starts with -, --, / or a Unicode dash (en dash, em dash, horizontal
#   bar), and is named by any prefix of its name down to its shortest form, or by an
#   alias: -noe, -noexit, --noexit and /noexit are all -NoExit.
# - -Command, -CommandWithArgs and -File take the rest of the line; -EncodedCommand
#   and switches such as -ExecutionPolicy take exactly one value.
# - The first argument that is not a known switch (a script path, an unknown switch,
#   an empty string, a colon form such as -ExecutionPolicy:Bypass) is the script
#   path of pwsh's implicit -File.
# A payload (script, command, encoded command) ends the session unless -NoExit comes
# before it: VS Code's shell integration starts every terminal as
# `pwsh -noexit -command ". <shellIntegration.ps1>"`, which IS followed by a REPL.
# -NonInteractive always wins, even with -NoExit; -Version and -Help print and exit.
# Windows PowerShell 5.1 differs in -Version, which takes a value there.
function _DenLaunchIsRepl([string[]]$Arguments) {
    $versionKind = 'exit'
    if ($PSVersionTable.PSEdition -eq 'Desktop') { $versionKind = 'value' }
    # Kind: rest = the rest of the line is the payload; encoded = a payload in one
    # value; value = takes one value; flag = takes none.
    $switches = @(
        @{ Name = 'command'; Min = 'c'; Alias = @(); Kind = 'rest' }
        @{ Name = 'commandwithargs'; Min = 'commandwithargs'; Alias = @('cwa'); Kind = 'rest' }
        @{ Name = 'file'; Min = 'f'; Alias = @(); Kind = 'rest' }
        @{ Name = 'encodedcommand'; Min = 'e'; Alias = @('ec'); Kind = 'encoded' }
        @{ Name = 'encodedarguments'; Min = 'encodeda'; Alias = @('ea'); Kind = 'value' }
        @{ Name = 'executionpolicy'; Min = 'ex'; Alias = @('ep'); Kind = 'value' }
        @{ Name = 'inputformat'; Min = 'inp'; Alias = @('if'); Kind = 'value' }
        @{ Name = 'outputformat'; Min = 'o'; Alias = @('of'); Kind = 'value' }
        @{ Name = 'workingdirectory'; Min = 'wo'; Alias = @('wd'); Kind = 'value' }
        @{ Name = 'windowstyle'; Min = 'w'; Alias = @(); Kind = 'value' }
        @{ Name = 'configurationname'; Min = 'config'; Alias = @(); Kind = 'value' }
        @{ Name = 'configurationfile'; Min = 'configurationfile'; Alias = @(); Kind = 'value' }
        @{ Name = 'custompipename'; Min = 'custompipename'; Alias = @(); Kind = 'value' }
        @{ Name = 'settingsfile'; Min = 'settings'; Alias = @(); Kind = 'value' }
        @{ Name = 'noexit'; Min = 'noe'; Alias = @(); Kind = 'noexit' }
        @{ Name = 'noninteractive'; Min = 'noni'; Alias = @(); Kind = 'noninteractive' }
        @{ Name = 'nologo'; Min = 'nol'; Alias = @(); Kind = 'flag' }
        @{ Name = 'noprofile'; Min = 'nop'; Alias = @(); Kind = 'flag' }
        @{ Name = 'noprofileloadtime'; Min = 'noprofileloadtime'; Alias = @(); Kind = 'flag' }
        @{ Name = 'interactive'; Min = 'i'; Alias = @(); Kind = 'flag' }
        @{ Name = 'login'; Min = 'l'; Alias = @(); Kind = 'flag' }
        @{ Name = 'sta'; Min = 'sta'; Alias = @(); Kind = 'flag' }
        @{ Name = 'mta'; Min = 'mta'; Alias = @(); Kind = 'flag' }
        @{ Name = 'version'; Min = 'v'; Alias = @(); Kind = $versionKind }
        @{ Name = 'help'; Min = 'h'; Alias = @('?'); Kind = 'exit' }
    )
    $payload = $false
    $noExit = $false
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $kind = 'script'
        $a = "$($Arguments[$i])".Trim()
        if ($a.Length -ge 2) {
            $c = [int]$a[0]
            $dash = $c -eq 0x2D -or ($c -ge 0x2013 -and $c -le 0x2015)
            if ($dash -or $c -eq 0x2F) {
                $key = $a.Substring(1)
                if ($dash -and $key.Length -gt 0 -and [int]$key[0] -eq $c) { $key = $key.Substring(1) }
                $key = $key.ToLowerInvariant()
                foreach ($s in $switches) {
                    if (($s.Alias -contains $key) -or
                        ($key.Length -ge $s.Min.Length -and $s.Name.StartsWith($key, [StringComparison]::Ordinal))) {
                        $kind = $s.Kind
                        break
                    }
                }
            }
        }
        if ($kind -eq 'noninteractive' -or $kind -eq 'exit') { return $false }
        if ($kind -eq 'noexit') { $noExit = $true }
        elseif ($kind -eq 'value') { $i++ }
        elseif ($kind -eq 'encoded') { $payload = $true; $i++ }
        elseif ($kind -eq 'rest' -or $kind -eq 'script') { $payload = $true; break }
    }
    return (-not $payload) -or $noExit
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
# This cache and _CoreutilsBin's live in $global:, not in $script:, because den's
# commands also run inside a user's scripts, where $script: names the running
# script's scope and the cache does not exist.
$global:_DenCmdCache = @{}

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
    if (-not $global:_DenCmdCache.ContainsKey($key)) {
        $val = ''
        if ($Type -eq 'App') {
            $src = (Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
            if ($src) { $val = $src }
        }
        elseif (Get-Command $Name -ErrorAction SilentlyContinue) {
            $val = $Name
        }
        $global:_DenCmdCache[$key] = $val
    }
    $v = $global:_DenCmdCache[$key]
    if ($v -eq '') { return $null } else { return $v }
}

$global:_DenCoreutils = $null   # $null = unresolved, '' = resolved-absent, else path
function _CoreutilsBin {
    if ($env:_DEN_COREUTILS -eq '0') { return $null }
    if ($IsWindows -ne $true) { return $null }
    if ($null -eq $global:_DenCoreutils) {
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
        $global:_DenCoreutils = $found
    }
    if ($global:_DenCoreutils) { return $global:_DenCoreutils } else { return $null }
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

# tgl-wr → short name for toggle-wrapper
function tgl-wr {
    toggle-wrapper @Args
}

# ========== cache init ==========

# _DenTrustedCacheOwner -OwnerSid -UserSid -UserGroupSids - pure decision (no ACL
# access, so it is unit-tested off Windows): may a cache file owned by OwnerSid be
# dot-sourced by the user whose token is UserSid + UserGroupSids? Compares security
# identifiers, never account names. The likely cause of the refusals a name
# comparison gave (not confirmed): a file created from an elevated session (or with
# UAC off) is owned by BUILTIN\Administrators, not the user; account-name formats
# can also differ. Trusted owners: the user itself, LocalSystem (S-1-5-18), and
# BUILTIN\Administrators (S-1-5-32-544) only when that group is in the user's token.
function _DenTrustedCacheOwner([string]$OwnerSid, [string]$UserSid, [string[]]$UserGroupSids) {
    if ([string]::IsNullOrEmpty($OwnerSid)) { return $false }
    if (-not [string]::IsNullOrEmpty($UserSid) -and $OwnerSid -eq $UserSid) { return $true }
    if ($OwnerSid -eq 'S-1-5-18') { return $true }
    if ($OwnerSid -eq 'S-1-5-32-544' -and @($UserGroupSids) -contains $OwnerSid) { return $true }
    return $false
}

# _DenTokenGroupSids <identity> - the group SIDs in a WindowsIdentity's token, for
# _DenTrustedCacheOwner: the enabled groups (.Groups) PLUS the deny-only ones
# (DenyOnlySid claims). .Groups skips deny-only groups, and under UAC a
# non-elevated admin holds Administrators only as deny-only, so a cache written
# once from an elevated session (owned by BUILTIN\Administrators, and not
# regenerated until the tool binary changes) would be refused in every normal
# session. Takes the identity as a parameter so a stand-in object tests it off
# Windows.
function _DenTokenGroupSids($Identity) {
    $denyOnly = [System.Security.Claims.ClaimTypes]::DenyOnlySid
    foreach ($g in $Identity.Groups) { $g.Value }
    foreach ($c in $Identity.Claims) {
        if ($c.Type -eq $denyOnly) { $c.Value }
    }
}

# _DenCacheOwnerFacts <path> - the Windows-only reads behind Test-CacheSafe's owner
# check: the file's owner (Get-Acl) and the current user's token (WindowsIdentity),
# as OwnerSid, OwnerName, UserSid, UserName, GroupSids. Kept apart so the tests can
# redefine it (and _OnWindows) and run Test-CacheSafe's Windows branch off Windows.
# GroupSids is read only when the owner is not the user. Throws when the owner
# cannot be read.
function _DenCacheOwnerFacts([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $userSid = $identity.User.Value
    $groupSids = @()
    if ($ownerSid -ne $userSid) {
        $groupSids = @(_DenTokenGroupSids $identity)
    }
    [pscustomobject]@{
        OwnerSid  = $ownerSid
        OwnerName = $acl.Owner
        UserSid   = $userSid
        UserName  = $identity.Name
        GroupSids = $groupSids
    }
}

# Test-CacheSafe <path> [-Reason <[ref]>] - verify generated cache file is safe to
# dot-source. On refusal, -Reason (optional) receives a one-line why, e.g. the
# owner that was refused, so the caller's warning is diagnosable.
function Test-CacheSafe([string]$Path, [ref]$Reason) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($null -ne $Reason) { $Reason.Value = 'not a regular file' }
        return $false
    }

    try {
        $cacheItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        if ($null -ne $Reason) { $Reason.Value = "cannot stat it ($($_.Exception.Message))" }
        return $false
    }

    if ($cacheItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        if ($null -ne $Reason) { $Reason.Value = 'it is a reparse point (symlink or junction)' }
        return $false
    }

    if (_OnWindows) {
        try {
            $f = _DenCacheOwnerFacts $Path
        } catch {
            if ($null -ne $Reason) { $Reason.Value = "cannot read its owner ($($_.Exception.Message))" }
            return $false
        }
        if (-not (_DenTrustedCacheOwner -OwnerSid $f.OwnerSid -UserSid $f.UserSid -UserGroupSids $f.GroupSids)) {
            if ($null -ne $Reason) {
                $Reason.Value = "owned by $($f.OwnerName) ($($f.OwnerSid)), expected $($f.UserName) ($($f.UserSid))"
            }
            return $false
        }
    }

    return $true
}

# Initialize-Cache <tool> <invokeArgs> [suffix='init'] - ensure a fresh, validated
# cache of `<tool> <invokeArgs>` output and RETURN its path (or nothing). The CALLER
# dot-sources the path at GLOBAL scope: an init/completion script that defines
# functions or registers completers (zoxide, docker's completion) must land in the
# session scope, so dot-sourcing inside THIS function would scope those away and the
# tool would silently fail. Regenerates only when the tool binary is newer, commits
# the cache only on success + non-empty output, and validates with Test-CacheSafe.
function Initialize-Cache([string]$Tool, [string[]]$InvokeArgs, [string]$Suffix = 'init') {
    $toolPath = Get-Command $Tool -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Source
    if ([string]::IsNullOrWhiteSpace($toolPath)) { return }

    $_cd = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'shell-cache'
    if (-not (Test-Path -LiteralPath $_cd -PathType Container)) {
        New-Item -ItemType Directory -Path $_cd -Force | Out-Null
    }

    $_cf = Join-Path $_cd "$Tool-$Suffix.ps1"
    $needsRegen = (-not (Test-Path -LiteralPath $_cf -PathType Leaf)) -or
        ((Get-Item -LiteralPath $_cf).LastWriteTime -lt (Get-Item -LiteralPath $toolPath).LastWriteTime)

    if ($needsRegen) {
        # Commit only when the command printed something. An empty run would write a
        # cache newer than the binary, so the freshness check would never regenerate
        # and the tool would stay broken until a reinstall. (Non-empty output is the
        # signal; $LASTEXITCODE is unreliable for shell scripts on non-Windows.)
        $out = & $toolPath @InvokeArgs 2>$null
        if ($out) {
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

    # Return the cache path for the caller to dot-source at GLOBAL scope (a prior good
    # cache is reused if regen was skipped above). A refused cache is kept until the
    # tool binary changes, so the warning names the remedy along with the reason.
    if (Test-Path -LiteralPath $_cf -PathType Leaf) {
        $why = $null
        if (Test-CacheSafe -Path $_cf -Reason ([ref]$why)) {
            return $_cf
        }
        Write-Warning "Initialize-Cache: refusing to source unsafe cache file '$_cf': $why; delete it to regenerate"
    }
}
