# _helpers.ps1 — DRY helpers for den PowerShell config.
# Dot-sourced first by init.ps1.

# ========== what the session had before den ==========

# The aliases and functions this session has before den defines anything, for
# _DenScopeOverrides: a den command that took over one of these names runs that one
# when a script calls it. Taken first thing here, on every load of this file; on a
# load after the first one it holds den's own commands too, which
# _DenScopeOverrides recognizes by name. The provider is read directly rather than
# through Get-ChildItem, whose module would load here, before den needs it.
$global:_DenPreload = @{ Alias = @{}; Function = @{} }
foreach ($_denItem in @($ExecutionContext.InvokeProvider.ChildItem.Get('Alias:', $false))) {
    $global:_DenPreload.Alias[$_denItem.Name] = $_denItem.Definition
}
foreach ($_denItem in @($ExecutionContext.InvokeProvider.ChildItem.Get('Function:', $false))) {
    $global:_DenPreload.Function[$_denItem.Name] = $_denItem.ScriptBlock
}
Remove-Variable -Name _denItem -ErrorAction SilentlyContinue

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
# in New-Wrapper) on every Windows host, 5.1 included. The edition is tested first,
# so 5.1 never reads $IsWindows: a user's script that runs Set-StrictMode and then
# calls den's commands would make that read an error inside them.
function _OnWindows {
    [bool]($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows)
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

# _DenLaunchSwitches <args> - read pwsh launch arguments the way pwsh does (checked
# against pwsh 7.6 and its CommandLineParameterParser.cs), for _DenLaunchIsRepl and
# _DenRelaunchArgs. Returns one hashtable per switch, in order, up to the payload:
# Index (its position in <args>), Name (its full name in lower case, '' for a script
# path) and Kind:
#   value    takes one value, the argument at Index + 1 (which gets no entry)
#   encoded  a payload in one value (-EncodedCommand), at Index + 1
#   rest     the rest of the line is the payload (-Command, -CommandWithArgs, -File)
#   script   the script path of pwsh's implicit -File; the rest are its arguments
#   flag     takes no value, and so do noexit and noninteractive
#   exit     prints and exits (-Version, -Help)
# A rest or script entry is the last one: nothing after it is a switch, however it
# is spelled.
# - A switch starts with -, --, / or a Unicode dash (en dash, em dash, horizontal
#   bar), and is named by any prefix of its name down to its shortest form, or by an
#   alias: -noe, -noexit, --noexit and /noexit are all -NoExit.
# - The first argument that is not a known switch (a script path, an unknown switch,
#   an empty string, a colon form such as -ExecutionPolicy:Bypass) is a script path.
# Windows PowerShell 5.1 differs in -Version, which takes a value there.
# -RemoveWorkingDirectoryTrailingCharacter exists on Windows only; elsewhere pwsh
# refuses to start with it.
# Arguments defaults to @(): left $null, its .Count below is an error under a
# caller's Set-StrictMode (the same holds for _DenLaunchIsRepl and _DenRelaunchArgs).
function _DenLaunchSwitches([string[]]$Arguments = @()) {
    $versionKind = 'exit'
    if ($PSVersionTable.PSEdition -eq 'Desktop') { $versionKind = 'value' }
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
        @{ Name = 'custompipename'; Min = 'cus'; Alias = @(); Kind = 'value' }
        @{ Name = 'settingsfile'; Min = 'settings'; Alias = @(); Kind = 'value' }
        @{ Name = 'noexit'; Min = 'noe'; Alias = @(); Kind = 'noexit' }
        @{ Name = 'noninteractive'; Min = 'noni'; Alias = @(); Kind = 'noninteractive' }
        @{ Name = 'nologo'; Min = 'nol'; Alias = @(); Kind = 'flag' }
        @{ Name = 'noprofile'; Min = 'nop'; Alias = @(); Kind = 'flag' }
        @{ Name = 'noprofileloadtime'; Min = 'noprofileloadtime'; Alias = @(); Kind = 'flag' }
        @{ Name = 'removeworkingdirectorytrailingcharacter'; Min = 'removeworkingdirectorytrailingcharacter'; Alias = @(); Kind = 'flag' }
        @{ Name = 'interactive'; Min = 'i'; Alias = @(); Kind = 'flag' }
        @{ Name = 'login'; Min = 'l'; Alias = @(); Kind = 'flag' }
        @{ Name = 'sta'; Min = 'sta'; Alias = @(); Kind = 'flag' }
        @{ Name = 'mta'; Min = 'mta'; Alias = @(); Kind = 'flag' }
        @{ Name = 'version'; Min = 'v'; Alias = @(); Kind = $versionKind }
        @{ Name = 'help'; Min = 'h'; Alias = @('?'); Kind = 'exit' }
    )
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $name = ''
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
                        $name = $s.Name
                        $kind = $s.Kind
                        break
                    }
                }
            }
        }
        @{ Index = $i; Name = $name; Kind = $kind }
        if ($kind -eq 'rest' -or $kind -eq 'script') { return }
        if ($kind -eq 'value' -or $kind -eq 'encoded') { $i++ }
    }
}

# _DenLaunchIsRepl <args> - whether pwsh launched with these arguments ends in a
# REPL, reading them with _DenLaunchSwitches. A payload (script, command, encoded
# command) ends the session unless -NoExit comes before it: VS Code's shell
# integration starts every terminal as `pwsh -noexit -command ". <shellIntegration.ps1>"`,
# which IS followed by a REPL. -NonInteractive always wins, even with -NoExit;
# -Version and -Help print and exit.
function _DenLaunchIsRepl([string[]]$Arguments = @()) {
    $payload = $false
    $noExit = $false
    foreach ($s in @(_DenLaunchSwitches -Arguments $Arguments)) {
        if ($s.Kind -eq 'noninteractive' -or $s.Kind -eq 'exit') { return $false }
        if ($s.Kind -eq 'noexit') { $noExit = $true }
        elseif ($s.Kind -eq 'encoded' -or $s.Kind -eq 'rest' -or $s.Kind -eq 'script') { $payload = $true }
    }
    return (-not $payload) -or $noExit
}

# _DenRelaunchArgs <argv> [-Legacy] - the arguments that start PowerShell again the
# way this session was started, for reload. <argv> is what
# [Environment]::GetCommandLineArgs() returns (a parameter, so the tests can call
# this). Its first element names the program, in a form that differs by host
# (/opt/microsoft/powershell/7/pwsh.dll on Linux pwsh 7.6; not checked on Windows),
# so it is always dropped and never used: reload runs (Get-Process -Id $PID).Path.
# -WorkingDirectory is dropped too, with its value, in every spelling
# _DenLaunchSwitches reads (-wd, -wo, --workingdirectory, /wd, ...), and so is
# -RemoveWorkingDirectoryTrailingCharacter, which Explorer's "Open here" entry for
# pwsh passes with -WorkingDirectory "%V!": the new shell starts in the directory
# reload runs in, which it inherits. Only switches go; the same words inside a
# -Command, -File or script payload stay.
# -Legacy prepares each argument for a host that passes native arguments the legacy
# way (see _DenLegacyArgPassing). Such a host joins them into one command line,
# drops an empty one, and puts double quotes around one when its check finds
# whitespace outside quotes, escaping no quote inside it. So every quote here is
# escaped (\", with the backslashes before it doubled), and an argument with
# whitespace gets no quotes of its own: the host's check finds the whitespace and
# quotes it. With quotes of its own, Windows PowerShell 5.1 could quote it again,
# since its check counts an escaped quote as a quote (pwsh 6 fixed that in
# PowerShell/PowerShell commit 8bca1f50c5), and VS Code's
# `try { . "<path>" } catch {}` payload reached the new shell split at the spaces
# of <path>. Trailing backslashes go doubled into a quoted pair of their own ("\\")
# at the end, so that the argument does not end in one: pwsh 6 and later double
# the trailing backslashes of an argument they quote, and 5.1 does not. An empty
# argument goes as "". One case still breaks on 5.1: an argument whose every
# whitespace follows an odd number of quotes (such as "C:\a b", quotes included),
# which 5.1 leaves unquoted, so the new shell gets it split at its spaces.
function _DenRelaunchArgs([string[]]$CommandLineArgs = @(), [switch]$Legacy) {
    $count = @($CommandLineArgs).Count
    $launch = @()
    if ($count -gt 1) { $launch = @($CommandLineArgs[1..($count - 1)]) }
    $drop = @{}
    foreach ($s in @(_DenLaunchSwitches -Arguments $launch)) {
        if ($s.Name -eq 'workingdirectory') { $drop[$s.Index] = $true; $drop[$s.Index + 1] = $true }
        elseif ($s.Name -eq 'removeworkingdirectorytrailingcharacter') { $drop[$s.Index] = $true }
    }
    for ($i = 0; $i -lt $launch.Count; $i++) {
        if ($drop.ContainsKey($i)) { continue }
        $a = [string]$launch[$i]
        if ($Legacy -and $a.Length -eq 0) {
            $a = '""'
        } elseif ($Legacy -and $a -match '[\s"]') {
            $a = $a -replace '(\\*)"', '$1$1\"'
            $body = $a.TrimEnd([char]'\')
            $tail = $a.Length - $body.Length
            if ($tail -gt 0) { $a = $body + '"' + ('\' * (2 * $tail)) + '"' }
        }
        $a
    }
}

# _DenLaunchMissingFile <args> <dir> - the first file named in these launch arguments
# that pwsh, started in <dir>, would not find, or $null. pwsh reads the path given
# to -File (or as a script path), -SettingsFile and -ConfigurationFile from its
# working directory as it starts, and exits (64, or 70 for -ConfigurationFile) when
# no file is there. For reload, whose new shell starts in the current directory: a
# relative path that named a file where this session started may name none there,
# and the new shell's exit would end this session. The path is read as pwsh reads
# it (CommandLineParameterParser.NormalizeFilePath: the other slash turned into
# this system's, then made full), from <dir>. -File - (commands from stdin) names
# no file.
function _DenLaunchMissingFile([string[]]$Arguments = @(), [string]$Directory) {
    $unix = [System.IO.Path]::DirectorySeparatorChar -eq [char]'/'
    foreach ($s in @(_DenLaunchSwitches -Arguments $Arguments)) {
        $at = -1
        if ($s.Kind -eq 'script') { $at = $s.Index }
        elseif ('file', 'settingsfile', 'configurationfile' -contains $s.Name) { $at = $s.Index + 1 }
        if ($at -lt 0 -or $at -ge $Arguments.Count) { continue }
        $path = [string]$Arguments[$at]
        if ($s.Name -eq 'file' -and $path -eq '-') { continue }
        if ($unix) { $normal = $path.Replace('\', '/') } else { $normal = $path.Replace('/', '\') }
        $found = $false
        try {
            $found = [System.IO.File]::Exists([System.IO.Path]::GetFullPath([System.IO.Path]::Combine($Directory, $normal)))
        } catch {
            $found = $false
        }
        if (-not $found) { return $path }
    }
    return $null
}

# _DenLegacyArgPassing - whether this host passes native-command arguments the
# legacy way: Windows PowerShell 5.1, pwsh before 7.3 (where
# $PSNativeCommandArgumentPassing is absent), or that variable set to 'Legacy'.
# 'Windows', the 7.3+ default on Windows, is legacy only for batch files and a few
# named programs, and pwsh is not one of them.
function _DenLegacyArgPassing {
    if ($PSVersionTable.PSVersion.Major -lt 7) { return $true }
    $style = Get-Variable -Name PSNativeCommandArgumentPassing -ValueOnly -ErrorAction SilentlyContinue
    return ($null -eq $style) -or ("$style" -eq 'Legacy')
}

# _DenVSCodeEnv - the environment variables VS Code's shell integration took out of
# this session, as a hashtable of name = value, for reload to hand back to the shell
# it starts. The integration script copies VSCODE_NONCE, VSCODE_STABLE,
# VSCODE_A11Y_MODE and VSCODE_SHELL_ENV_REPORTING into $Global:__VSCodeState and
# deletes them from the environment, so the new shell's copy of the script would
# find them gone: VS Code would not trust the command lines it reports (they carry
# the nonce), and PSReadLine would not get the screen reader mode VS Code asked
# for. VSCODE_ENV_REPLACE, _PREPEND and _APPEND stay out: the script has applied
# them to the environment already, which the new shell inherits. Empty outside
# VS Code.
function _DenVSCodeEnv {
    $vars = @{}
    if (-not (Test-Path -Path variable:global:__VSCodeState)) { return $vars }
    $state = $Global:__VSCodeState
    if ($state -isnot [System.Collections.IDictionary]) { return $vars }
    $keys = @{ VSCODE_NONCE = 'Nonce'; VSCODE_STABLE = 'IsStable'; VSCODE_A11Y_MODE = 'IsA11yMode' }
    foreach ($name in $keys.Keys) {
        $value = "$($state[$keys[$name]])"
        if ($value) { $vars[$name] = $value }
    }
    $report = @($state['EnvVarsToReport'] | Where-Object { $_ })
    if ($report.Count -gt 0) { $vars['VSCODE_SHELL_ENV_REPORTING'] = $report -join ',' }
    return $vars
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
# mid-session is picked up after `reload` (which starts a new session, and so an
# empty cache). Value is the resolved path/name, or '' = absent. App-lookup keys also
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
            # No .Source on an empty result: a caller's Set-StrictMode makes that an error.
            $app = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($app) { $val = $app.Source }
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
    # Edition first, as in _OnWindows: 5.1 has no $IsWindows to read.
    if ($PSVersionTable.PSEdition -ne 'Core' -or $IsWindows -ne $true) { return $null }
    if ($null -eq $global:_DenCoreutils) {
        $found = ''
        if ($env:_DEN_COREUTILS) {
            $g = Get-Command $env:_DEN_COREUTILS -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($g) { $found = $g.Source }
            elseif (Test-Path -LiteralPath $env:_DEN_COREUTILS -PathType Leaf) { $found = $env:_DEN_COREUTILS }
        }
        if (-not $found) {
            $g = Get-Command 'coreutils' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($g) { $found = $g.Source }
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

# ========== den's commands at the prompt only ==========

# A command den defines in place of one the session already had (ls, cat, cd, rm,
# gc, gps, python, uv, clip, ...) runs den's version only when it is typed at the
# prompt of an interactive session (CommandOrigin Runspace), or run directly by a
# line that a typed `again` or `snippet` replays. Called from anywhere else (a
# script, a module, a function, a script block such as ForEach-Object's, a
# pwsh -File or -Command run), the name means what it meant before den loaded, with
# the same arguments and pipeline input: `ls dist | Remove-Item` in a script gets
# Get-ChildItem's objects on Windows, and `gps` in a script is Get-Process, not
# git push. A command den adds whose name meant nothing before (archive, proxy,
# mkcd, ...) runs everywhere den loaded it.
# init.ps1 calls _DenScopeOverrides once den has loaded. It records what each
# name den defined meant before (an alias, such as Windows' ls, cat, rm, gc or cd;
# a function, such as Windows' mkdir; or else, looked up the first time a call
# needs it, an application or script on the PATH den loaded with) and installs
# _DenLookupHook as PostCommandLookupAction, which PowerShell runs after it has
# looked up a command. When that lookup found den's own definition for a call that
# was not typed, the hook hands PowerShell the earlier command instead. A function
# of the same name that is not den's (a script's or a module's own, or one defined
# at the prompt after den) is left alone. Names that start with _ are den's
# internal helpers and are not recorded.
# The records persist across loads of this file (a second `. $PROFILE`): a name is
# recorded the first time den defines it.
if (-not (Test-Path -Path Variable:global:_DenOverrides)) {
    $global:_DenOverrides = @{}    # name -> @{ Kind = 'Alias'|'Function'|'App'; Value; [DenAlias] }
    $global:_DenOwnText = [System.Collections.Generic.HashSet[string]]::new()
    $global:_DenLoadPath = $env:PATH
    $global:_DenTypedSession = $false
    $global:_DenLookupNext = $null
    $global:_DenLookupInstalled = $null
    $global:_DenInLookup = $false
}
$global:_DenReplayDepth = 0

# _DenScopeOverrides - record, for every function and alias den defined since this
# file was loaded, what its name meant before (see above), note whether this
# session is interactive, and install _DenLookupHook. A PostCommandLookupAction
# that something else set first is kept and runs before den's.
function _DenScopeOverrides {
    _DenRecordOverrides (@($ExecutionContext.InvokeProvider.ChildItem.Get('Function:', $false)) +
        @($ExecutionContext.InvokeProvider.ChildItem.Get('Alias:', $false)))
    $global:_DenTypedSession = [bool](_DenInteractive)
    $current = $ExecutionContext.InvokeCommand.PostCommandLookupAction
    if ($null -ne $current -and -not [object]::ReferenceEquals($current, $global:_DenLookupInstalled)) {
        $global:_DenLookupNext = $current
    }
    $ExecutionContext.InvokeCommand.PostCommandLookupAction = $global:_DenLookupHook
    $global:_DenLookupInstalled = $ExecutionContext.InvokeCommand.PostCommandLookupAction
}

# _DenRecordOverrides <items> - for _DenScopeOverrides, and for toggle-uv, which
# defines python, pip and uv after den has loaded when the session started with
# them OFF: record what the name of each of these functions and aliases meant
# before den. One that a module defined is not den's (fhx, gcb, scb and gtz come
# with modules that load while den does), and neither is one that was there
# before den. A name already recorded keeps its record.
function _DenRecordOverrides($Items) {
    $pre = $global:_DenPreload
    foreach ($item in $Items) {
        $name = $item.Name
        if ($name.StartsWith('_') -or $name -eq 'prompt' -or $item.ModuleName) { continue }
        $rec = @{ Kind = 'App'; Value = $null }
        if ($item -is [System.Management.Automation.AliasInfo]) {
            if ($pre.Alias.ContainsKey($name) -and $pre.Alias[$name] -eq $item.Definition) { continue }
            $rec.DenAlias = $item.Definition
        } else {
            if ($pre.Function.ContainsKey($name) -and [object]::ReferenceEquals($pre.Function[$name], $item.ScriptBlock)) { continue }
            [void]$global:_DenOwnText.Add($item.Definition)
        }
        if ($global:_DenOverrides.ContainsKey($name)) { continue }
        if ($pre.Alias.ContainsKey($name)) { $rec.Kind = 'Alias'; $rec.Value = $pre.Alias[$name] }
        elseif ($pre.Function.ContainsKey($name)) { $rec.Kind = 'Function'; $rec.Value = $pre.Function[$name] }
        $global:_DenOverrides[$name] = $rec
    }
}

# _DenLookupHook - PowerShell runs it after every command lookup in the session, so
# it reads one hashtable and returns for every name den did not define; _DenLookup
# does the rest. _DenInLookup keeps the lookups _DenLookup itself makes out of it.
$global:_DenLookupHook = {
    param($Name, $Lookup)
    if ($null -ne $global:_DenLookupNext) { $global:_DenLookupNext.Invoke($Name, $Lookup) }
    if ($null -ne $global:_DenOverrides[$Name] -and -not $global:_DenInLookup) { _DenLookup $Name $Lookup }
}

# _DenLookup <name> <lookup> - for _DenLookupHook: when the lookup found den's own
# definition of <name> for a call that was not typed, put the command the name
# meant before den in its place. When there was none, or it cannot be found now,
# den's definition stays. A failure here never fails the lookup.
function _DenLookup([string]$Name, $Lookup) {
    $rec = $global:_DenOverrides[$Name]
    if ($null -eq $Lookup -or $null -eq $rec) { return }
    $global:_DenInLookup = $true
    try {
        if ($global:_DenTypedSession -and (_DenTyped $Lookup.CommandOrigin 1)) { return }
        $found = $Lookup.Command
        if ($found -is [System.Management.Automation.FunctionInfo]) {
            if (-not $global:_DenOwnText.Contains($found.Definition)) { return }
        } elseif ($found -is [System.Management.Automation.AliasInfo]) {
            if (-not $rec.ContainsKey('DenAlias') -or $found.Definition -ne $rec.DenAlias) { return }
        } else {
            return
        }
        $original = $null
        if ($rec.Kind -eq 'Function') {
            $Lookup.CommandScriptBlock = $rec.Value
            return
        } elseif ($rec.Kind -eq 'Alias') {
            $original = $ExecutionContext.InvokeCommand.GetCommand($rec.Value, [System.Management.Automation.CommandTypes]::All)
        } elseif (_DenHadApp $Name $rec) {
            $original = $ExecutionContext.InvokeCommand.GetCommand($Name, [System.Management.Automation.CommandTypes]'Application, ExternalScript')
        }
        if ($null -ne $original) { $Lookup.Command = $original }
    } catch {
        $null = $_
    } finally {
        $global:_DenInLookup = $false
    }
}

# _DenHadApp <name> <record> - whether <name> named an application, or a script, on
# the PATH den loaded with. Looked up once, the first time a call needs it, and
# kept in the record: listing every PATH directory when den loads would cost each
# start of PowerShell, for names that scripts seldom call. den's own cmd shims
# (%LOCALAPPDATA%\clink\bin, which den's Clink script puts on cmd's PATH, so a
# pwsh started from cmd has it too) are den's commands, not what a name meant
# before den: that directory is skipped.
function _DenHadApp([string]$Name, [hashtable]$Record = @{}) {
    if (-not $Name) { return $false }
    if ($null -eq $Record['Value']) {
        $exts = @('.ps1')
        if (_OnWindows) { $exts += @("$env:PATHEXT" -split ';' | Where-Object { $_ }) } else { $exts += '' }
        $shims = ''
        if ($env:LOCALAPPDATA) { $shims = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'clink', 'bin').TrimEnd('\', '/') }
        $hit = $false
        foreach ($dir in @("$global:_DenLoadPath" -split [System.IO.Path]::PathSeparator)) {
            $dir = $dir.Trim().Trim('"')
            if (-not $dir) { continue }
            if ($shims -and [string]::Equals($dir.TrimEnd('\', '/'), $shims, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            foreach ($ext in $exts) {
                try { $hit = [System.IO.File]::Exists([System.IO.Path]::Combine($dir, $Name + $ext)) } catch { $hit = $false }
                if ($hit) { break }
            }
            if ($hit) { break }
        }
        $Record['Value'] = $hit
    }
    return [bool]$Record['Value']
}

# _DenTyped <origin> [hops] - whether a call counts as typed at the prompt: its
# CommandOrigin is Runspace, or it comes straight from a line that _DenReplay runs
# for a typed `again` or `snippet` (a script or a function that line runs does
# not). <origin> is $MyInvocation.CommandOrigin of the den function asking, which
# calls this itself; [hops] counts the frames between that function and this one
# (_DenLookup, run by the lookup hook, passes 1 for itself).
function _DenTyped([string]$Origin, [int]$Hops = 0) {
    if ($Origin -eq 'Runspace') { return $true }
    if ($global:_DenReplayDepth -le 0) { return $false }
    return @(Get-PSCallStack).Count -eq $global:_DenReplayDepth + 3 + $Hops
}

# _DenReplay <line> <typed> - Invoke-Expression <line>, for again and snippet. When
# the command replaying it was typed (<typed>), the commands the line calls itself
# count as typed too (see _DenTyped), as they did when the line was first typed.
function _DenReplay([string]$Line, [bool]$Typed) {
    $outer = $global:_DenReplayDepth
    $global:_DenReplayDepth = 0
    if ($Typed) { $global:_DenReplayDepth = @(Get-PSCallStack).Count }
    try { Invoke-Expression $Line } finally { $global:_DenReplayDepth = $outer }
}

# ========== path operands ==========

# _ResolvePaths <operand...> - the paths a function's file operands stand for,
# for the grep and find fallbacks (wrappers.ps1) and pcp/pmv/prm/ptar
# (parallel.ps1), which pass them on with -LiteralPath. A function receives
# `pcp *.md d` unexpanded, so an operand that exists is that path, taken
# literally ([ ] in app/[slug] are not wildcards); any other is a wildcard
# pattern and stands for what it matches. One that matches nothing is passed on
# as it is, so that the command reading it reports it missing.
function _ResolvePaths([string[]]$Patterns) {
    $out = @()
    foreach ($p in $Patterns) {
        if (Test-Path -LiteralPath $p) { $out += $p; continue }
        $hits = @(Convert-Path -Path $p -ErrorAction SilentlyContinue)
        if ($hits.Count -eq 0) { $out += $p } else { $out += $hits }
    }
    return ,$out
}

# ========== wrapper generator ==========

# The functions these generators define pass the call on to the tool they pick
# through a steppable pipeline: each object piped in reaches the tool as it
# arrives, and what the tool prints comes back as it prints it, so
# `tail -f log | grep x` shows each match at once. A call with nothing piped in
# runs the tool directly, so its stdin stays the console's (rg searches the
# current directory rather than an empty stdin, and `rm -i` can ask). The
# generated body reads its arguments as $__a, and the scriptblock in $__run is
# the one command the call runs (a steppable pipeline holds exactly one).

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
    # The fallback runs in the function itself when nothing is piped in, so an
    # error it writes is the function's ("lt: ..."). With input piped in, it runs
    # as a scriptblock of its own, which sees the call's arguments as $Args and
    # what was piped in as $input, all at once.
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
begin {
    `$__a = `$args
    if (`$env:_DEN_WRAPPERS -ne '0' -and (_ResolveCmd '$Modern')) {
        _WrapLog '$FuncName' '$Modern'
        `$__run = { & '$Modern' $ModernFlags @__a }
    } else {
        `$__cu = if ('$NativeCmd') { _CoreutilsBin } else { `$null }
        `$__nc = if (-not `$__cu -and ($nativeGuard)) { _ResolveCmd '$NativeCmd' 'App' } else { `$null }
        if (`$__cu) {
            `$__run = { & `$__cu $NativeCmd $NativeCmdFlags @__a }
        } elseif (`$__nc) {
            `$__run = { & `$__nc $NativeCmdFlags @__a }
        } elseif (`$MyInvocation.ExpectingInput) {
            `$__fb = { $fallbackCode }
            `$__run = { & `$__fb @__a }
        } else {
            `$__run = `$null
        }
    }
    `$__sp = `$null
    if (`$null -ne `$__run -and `$MyInvocation.ExpectingInput) {
        `$__sp = `$__run.GetSteppablePipeline()
        `$__sp.Begin(`$true)
    }
}
process { if (`$null -ne `$__sp) { `$__sp.Process(`$_) } }
end {
    if (`$null -ne `$__sp) { `$__sp.End() }
    elseif (`$null -ne `$__run) { & `$__run }
    else {
        $fallbackCode
    }
}
"@)
    Set-Item -Path "function:global:$FuncName" -Value $sb
}

# New-WrapperSuffix <func> <modern> <modernFlags> — always use modern (w-suffix)
function New-WrapperSuffix([string]$FuncName, [string]$Modern, [string]$ModernFlags) {
    $sb = [scriptblock]::Create(@"
begin {
    `$__a = `$args
    `$__run = `$null
    `$__sp = `$null
    if (_ResolveCmd '$Modern') {
        `$__run = { & '$Modern' $ModernFlags @__a }
        if (`$MyInvocation.ExpectingInput) {
            `$__sp = `$__run.GetSteppablePipeline()
            `$__sp.Begin(`$true)
        }
    } else {
        Write-Warning "${FuncName}: $Modern is not installed."
    }
}
process { if (`$null -ne `$__sp) { `$__sp.Process(`$_) } }
end { if (`$null -ne `$__sp) { `$__sp.End() } elseif (`$null -ne `$__run) { & `$__run } }
"@)
    Set-Item -Path "function:global:$FuncName" -Value $sb
}

# New-CoreutilsWrapper <func> <cmdName> <builtinCmd> - for commands with no modern
# tool: prefer microsoft/coreutils on Windows, else the PowerShell builtin. Used for
# the destructive coreutils (cp/mv/rm/mkdir/rmdir). <builtinCmd> is the cmdlet with
# any fixed arguments ('Copy-Item', 'New-Item -ItemType Directory'); it gets the
# call's arguments and its pipeline input, so `Get-ChildItem *.log | rm` removes
# those files as Remove-Item does. On non-Windows _CoreutilsBin is $null so these
# collapse to the builtin, matching the stock PowerShell aliases.
function New-CoreutilsWrapper([string]$FuncName, [string]$CmdName, [string]$BuiltinCmd) {
    $sb = [scriptblock]::Create(@"
begin {
    `$__a = `$args
    `$__cu = _CoreutilsBin
    if (`$__cu) {
        `$__run = { & `$__cu $CmdName @__a }
    } else {
        `$__run = { $BuiltinCmd @__a }
    }
    `$__sp = `$null
    if (`$MyInvocation.ExpectingInput) {
        `$__sp = `$__run.GetSteppablePipeline()
        `$__sp.Begin(`$true)
    }
}
process { if (`$null -ne `$__sp) { `$__sp.Process(`$_) } }
end { if (`$null -ne `$__sp) { `$__sp.End() } else { & `$__run } }
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
    if ($null -eq $Identity) { return }  # .Groups on $null: an error under strict mode
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
