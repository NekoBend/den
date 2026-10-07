#!/usr/bin/env bash
# test_strict.sh - every den pwsh function, called from a script that runs
# Set-StrictMode -Version Latest.
#
# Set-StrictMode also applies inside the functions a script calls, so a user's
# script that sets it makes den's commands fail on each read strict mode
# forbids: a variable that was never set, a property the object does not have
# (.Source on Get-Command's empty result), an index past the end of an array,
# a function called like a method. The harness loads den the way a profile does
# (init.ps1, with stub tools on a PATH of its own and HOME/XDG dirs under WORK),
# lists every function and alias den defined, then runs a strict-mode script
# that calls each one in its usage, typical and error forms, and ends by calling
# every one of them with no argument at all. It fails on every strict-mode error
# that shows up, a den function's own catch block notwithstanding, and on every
# den function the calls never reached that is not in the script's skip list,
# so a new function needs a case here. Two more runs take the platform
# branches: pwsh 7 on Windows ($IsWindows set, and a stub coreutils for the
# coreutils tier), and Windows PowerShell 5.1 (a copy of shell/pwsh that reads
# its edition as Desktop and its version as 5, in a session without $IsWindows
# and the other platform variables). That copy still runs on pwsh 7's .NET, so a
# .NET API that Windows PowerShell lacks is out of its reach. A last run per
# platform loads den after strict mode is set, as a profile that sets it first
# does, and checks the load, the prompt and the directory history.
#
# Each case runs inside a try, so an error that would only end the statement in
# a den function (a .NET method throwing) ends the whole case there instead, and
# what the function would have run next goes unchecked.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

PWSH_BIN="$(command -v pwsh)"
TIMEOUT_BIN="$(command -v timeout)"
S="$WORK/strict"
STUBS="$S/stubs"
RUN="$S/run"

# =============================================================================
# Stub tools. The case script switches between these directories with
# Use-StrictPath: modern (bat/fd/lsd/rg), fzf, uv, bin (everything else, clear
# included: pwsh's Clear-Host, which c calls, reads .Definition off it), cmdbin
# (a code.cmd launcher) and sys (the real tar, gzip, ... and the native
# cat/ls/grep/find that the wrappers fall back to).
# =============================================================================
mkdir -p "$STUBS/modern" "$STUBS/fzf" "$STUBS/uv" "$STUBS/bin" "$STUBS/cmdbin" "$STUBS/sys" \
    "$STUBS/venv-template/bin"

# stub <dir> <name> [body] - a program that prints its name and arguments, or
# runs body instead.
stub() {
    local body="${3:-echo \"$2 \$*\"}"
    printf '#!/bin/sh\nPATH=/usr/bin:/bin\n%s\n' "$body" > "$1/$2"
    chmod +x "$1/$2"
}
for t in bat lsd rg; do stub "$STUBS/modern" "$t"; done
stub "$STUBS/modern" fd 'echo .'
# fzf picks the first line it is given.
stub "$STUBS/fzf" fzf 'n=0; while IFS= read -r l; do n=$((n + 1)); [ "$n" -eq 1 ] && f=$l; done; [ "$n" -gt 0 ] && printf "%s\n" "$f"'
# uv prints nothing for the completion script completion.ps1 caches, and
# `uv venv [name]` makes a venv from the template below.
stub "$STUBS/uv" uv "case \"\$1\" in
generate-shell-completion) exit 0 ;;
venv) cp -R '$STUBS/venv-template/.' \"\${2:-.venv}\"; exit 0 ;;
esac
echo \"uv \$*\""
for t in gitui code 7z unrar sudo ss xdg-open ffmpeg ffprobe pip pip3 python python3 coreutils clear; do
    stub "$STUBS/bin" "$t"
done
stub "$STUBS/bin" docker 'case "$1" in completion) exit 0 ;; esac; echo "docker $*"'
# va asks git whether the venv is tracked; a .tracked file in it says yes.
stub "$STUBS/bin" git 'if [ "$1" = -C ] && [ "$3" = ls-files ]; then [ -f "$2/.tracked" ] && echo pyvenv.cfg; exit 0; fi; echo "git $*"'
stub "$STUBS/bin" yazi 'for a; do case "$a" in --cwd-file=*) printf %s "$HOME" > "${a#--cwd-file=}" ;; esac; done'
stub "$STUBS/bin" denstrict-init 'echo "# den strict-mode fixture"'
stub "$STUBS/cmdbin" code.cmd
for t in tar gzip bzip2 xz zstd cat ls grep find; do
    p=$(command -v "$t") && ln -s "$p" "$STUBS/sys/$t"
done
STRICT_PATH="$STUBS/modern:$STUBS/fzf:$STUBS/uv:$STUBS/bin:$STUBS/sys"

cat > "$STUBS/venv-template/bin/Activate.ps1" <<'PS1'
$env:VIRTUAL_ENV = Split-Path -Parent $PSScriptRoot
function global:deactivate { Remove-Item Env:\VIRTUAL_ENV -ErrorAction SilentlyContinue }
PS1
printf 'home = /usr/bin\nversion_info = 3.12.3.final.0\n' > "$STUBS/venv-template/pyvenv.cfg"

# fresh_run - the per-run state: HOME, XDG dirs, TMPDIR and the play directory
# every case starts in, with its fixture files.
fresh_run() {
    rm -rf "$RUN"
    mkdir -p "$RUN/home" "$RUN/data" "$RUN/config" "$RUN/tmp" "$RUN/play"
    local p="$RUN/play"
    printf 'alpha\nbeta\ngamma\n' > "$p/a.txt"
    printf 'beta\ndelta\n' > "$p/b.txt"
    printf 'solo\n' > "$p/one.txt"
    : > "$p/empty.txt"
    printf 'test content' > "$p/hash.txt"
    mkdir -p "$p/sub" "$p/emptydir" "$p/dest"
    printf 'gamma\n' > "$p/sub/c.txt"
    ln -s a.txt "$p/link.txt"
    : > "$p/media.avi"
    : > "$p/x.7z"
    : > "$p/x.rar"
    printf 'x\n' > "$p/same.gz"
    local sha='6ae8a75555209fd6c44157c0aed8016e763ff435a19cf186f76863140143ff72'
    {
        echo "$sha  hash.txt"
        echo "9473fdd0d880a43c21b7778d34872157 *hash.txt"
        echo "SHA256 (hash.txt) = $sha"
        echo "0000000000000000000000000000000000000000000000000000000000000000  a.txt"
        echo "$sha  missing.txt"
        printf '\\%s  esc\\\\name\n' "$sha"
        echo "not a checksum line"
        echo "# a comment"
    } > "$p/sums.txt"
    cp -R "$STUBS/venv-template" "$p/venv"
    cp -R "$STUBS/venv-template" "$p/badver"
    printf 'version_info = not-a-version\n' > "$p/badver/pyvenv.cfg"
    cp -R "$STUBS/venv-template" "$p/tracked"
    : > "$p/tracked/.tracked"
    cp -R "$STUBS/venv-template" "$p/writable"
    chmod o+w "$p/writable/bin/Activate.ps1"
    printf '%s\n' ". (Join-Path \$env:STRICT_DEN 'init.ps1')" > "$RUN/profile.ps1"
}

# =============================================================================
# The driver: dot-sourced at global scope, as a profile loads den. Its own
# variables start with _Strict, so no den function reads one of them in place
# of a variable it never set.
# =============================================================================
DRIVER="$S/driver.ps1"
cat > "$DRIVER" <<'PS1'
$_StrictOut = [System.Collections.Generic.List[string]]::new()
$global:_StrictViolations = [System.Collections.Generic.List[string]]::new()
$global:_StrictIds = '^(VariableIsUndefined|PropertyNotFoundStrict|StrictModeFunctionCallWithParens|' +
    'System\.IndexOutOfRangeException|System\.ArgumentOutOfRangeException)(,|$)'

# _StrictRecord <label> - note each strict-mode error in $Error under label,
# including one that a function caught itself ($Error keeps those too).
function global:_StrictRecord([string]$StrictLabel) {
    foreach ($StrictErr in @($Error)) {
        $StrictRec = $null
        if ($StrictErr -is [System.Management.Automation.ErrorRecord]) { $StrictRec = $StrictErr }
        elseif ($StrictErr -is [System.Management.Automation.IContainsErrorRecord]) { $StrictRec = $StrictErr.ErrorRecord }
        if ($null -eq $StrictRec -or $StrictRec.FullyQualifiedErrorId -notmatch $global:_StrictIds) { continue }
        $StrictAt = $StrictRec.InvocationInfo
        $StrictWhere = if ($StrictAt -and $StrictAt.ScriptName) {
            '{0}:{1}' -f (Split-Path -Leaf $StrictAt.ScriptName), $StrictAt.ScriptLineNumber
        } else { ("$($StrictRec.ScriptStackTrace)" -split "`n")[0] }
        $StrictMsg = $StrictRec.Exception.Message -replace '\s+', ' '
        $global:_StrictViolations.Add("$StrictLabel | $($StrictRec.FullyQualifiedErrorId) | $StrictMsg | $StrictWhere")
    }
}

# Stand-ins, defined before the snapshot below so they do not count as den's:
# zoxide's functions (its init needs the real binary), and Read-Host, which
# -NonInteractive refuses (prm and again ask before they act).
function global:__zoxide_z { if ($args.Count) { Set-Location -LiteralPath $args[0] } else { Set-Location -LiteralPath $HOME } }
function global:__zoxide_zi { Set-Location -LiteralPath $HOME }
function global:Read-Host { $global:_StrictAnswer }
$global:_StrictAnswer = 'n'
# reload dot-sources $PROFILE, and again re-runs a command from the history.
$global:PROFILE = $env:STRICT_PROFILE
Add-History -InputObject ([pscustomobject]@{
    CommandLine = "Write-Output 'again ran'"; ExecutionStatus = 'Completed'
    StartExecutionTime = [datetime]::Now; EndExecutionTime = [datetime]::Now
})
if ($env:STRICT_AS_WINDOWS -eq '1') {
    # pwsh 7 on Windows, where _CoreutilsBin finds the stub coreutils.
    $env:OS = 'Windows_NT'
    Set-Variable -Name IsWindows -Value $true -Scope Global -Force
    Set-Variable -Name IsLinux -Value $false -Scope Global -Force
}
if ($env:STRICT_AS_DESKTOP -eq '1') {
    # Windows PowerShell 5.1: always Windows, and no platform variables at all.
    $env:OS = 'Windows_NT'
    foreach ($_StrictN in 'IsWindows', 'IsLinux', 'IsMacOS', 'IsCoreCLR') {
        Remove-Variable -Name $_StrictN -Scope Global -Force
    }
}

$_StrictFnBefore = @{}
foreach ($_StrictN in Get-ChildItem function:) { $_StrictFnBefore[$_StrictN.Name] = $_StrictN.Definition }
$_StrictAliasBefore = @{}
foreach ($_StrictN in Get-ChildItem alias:) { $_StrictAliasBefore[$_StrictN.Name] = $_StrictN.Definition }

if ($env:STRICT_AT_LOAD -eq '1') {
    # A profile that sets strict mode before it loads den: den's load code, and
    # the prompt afterwards, run under it too.
    Set-StrictMode -Version Latest
}
$Error.Clear()
. (Join-Path $env:STRICT_DEN 'init.ps1')
_StrictRecord 'loading den'
if ($env:STRICT_EXTRA) { . $env:STRICT_EXTRA }

# Den's functions: the new ones, and the ones it redefined (prompt).
$_StrictFunctions = @(Get-ChildItem function: |
    Where-Object { $_StrictFnBefore[$_.Name] -ne $_.Definition } | ForEach-Object Name | Sort-Object)
$_StrictAliases = @(Get-ChildItem alias: |
    Where-Object { $_StrictAliasBefore[$_.Name] -ne $_.Definition -and $_StrictFunctions -contains $_.Definition } |
    ForEach-Object Name | Sort-Object)

# A command breakpoint with an action does not stop; it notes the call.
$global:_StrictHit = @{}
foreach ($_StrictN in $_StrictFunctions + $_StrictAliases) {
    $null = Set-PSBreakpoint -Command $_StrictN -Action ([scriptblock]::Create("`$global:_StrictHit['$_StrictN'] = `$true"))
}
$global:_StrictSkip = @{}
$global:_StrictDone = $false
try { & $env:STRICT_CASES } catch { $_StrictOut.Add("CRASH $($_.Exception.Message)") }
Get-PSBreakpoint | Remove-PSBreakpoint
if (-not $global:_StrictDone) { $_StrictOut.Add('CRASH the case script stopped before its end') }

foreach ($_StrictN in $_StrictFunctions) { $_StrictOut.Add("FUNCTION $_StrictN") }
foreach ($_StrictN in $_StrictAliases) { $_StrictOut.Add("ALIAS $_StrictN") }
foreach ($_StrictN in $global:_StrictViolations) { $_StrictOut.Add("VIOLATION $_StrictN") }
foreach ($_StrictN in $_StrictFunctions + $_StrictAliases) {
    $_StrictSkipped = $global:_StrictSkip.ContainsKey($_StrictN)
    if ($global:_StrictHit.ContainsKey($_StrictN)) {
        if ($_StrictSkipped) { $_StrictOut.Add("REACHED-BUT-SKIPPED $_StrictN") }
    } elseif (-not $_StrictSkipped) {
        $_StrictOut.Add("UNCOVERED $_StrictN")
    }
}
foreach ($_StrictN in $global:_StrictSkip.Keys) {
    if ($_StrictFunctions + $_StrictAliases -notcontains $_StrictN) { $_StrictOut.Add("SKIP-UNKNOWN $_StrictN") }
    $_StrictOut.Add("SKIPPED ${_StrictN}: $($global:_StrictSkip[$_StrictN])")
}
$_StrictOut | Set-Content -LiteralPath $env:STRICT_OUT
PS1

# =============================================================================
# The cases: run by the driver as a user's script (& <path>), under strict mode.
# Each Case starts in the play directory and goes back to it; a den error that
# is not a strict-mode one (a usage error, a missing file) is expected and
# ignored. Variables here start with Strict for the driver's reason.
# =============================================================================
CASES="$S/cases.ps1"
cat > "$CASES" <<'PS1'
Set-StrictMode -Version Latest

# Den functions that cannot run here, each with the reason.
$global:_StrictSkip = @{
    '_DenCacheOwnerFacts' = 'Windows only: the file owner from Get-Acl and the user from WindowsIdentity'
}

# Case <label> <body> - run body and record each strict-mode error it raised.
function Case([string]$StrictLabel, [scriptblock]$StrictBody) {
    $Error.Clear()
    Push-Location -LiteralPath $env:STRICT_PLAY
    try { $null = & $StrictBody *>&1 } catch { $null = $_ } finally { Pop-Location }
    _StrictRecord $StrictLabel
}

# Use-StrictPath [dir...] - PATH made of these stub directories (none: the
# default one), and empty den command caches so it resolves again.
function Use-StrictPath([string[]]$StrictDirs) {
    if ($StrictDirs) {
        $env:PATH = @($StrictDirs | ForEach-Object { Join-Path $env:STRICT_ROOT $_ }) -join [IO.Path]::PathSeparator
    } else {
        $env:PATH = $env:STRICT_PATH
    }
    $global:_DenCmdCache = @{}
    $global:_DenCoreutils = $null
}

function Invoke-InVenv([scriptblock]$StrictBody) {
    $env:VIRTUAL_ENV = Join-Path $env:STRICT_PLAY 'venv'
    $env:_DEN_VENV_PYTHON = '3.12.3'
    try { & $StrictBody } finally { Remove-Item Env:\VIRTUAL_ENV, Env:\_DEN_VENV_PYTHON -ErrorAction SilentlyContinue }
}

function Invoke-WithoutZoxide([scriptblock]$StrictBody) {
    $StrictZ = ${function:__zoxide_z}
    $StrictZi = ${function:__zoxide_zi}
    Remove-Item Function:\__zoxide_z, Function:\__zoxide_zi
    try { & $StrictBody } finally {
        Set-Item Function:global:__zoxide_z $StrictZ
        Set-Item Function:global:__zoxide_zi $StrictZi
    }
}

if ($env:STRICT_SELFTEST -eq '1') {
    # The fixture functions from the driver's STRICT_EXTRA file.
    Case 'fx unset variable' { strict-fx-unset }
    Case 'fx missing property' { strict-fx-property }
    Case 'fx array index' { strict-fx-index }
    Case 'fx list index' { strict-fx-list }
    Case 'fx method-style call' { strict-fx-parens }
    Case 'fx caught by the function' { strict-fx-caught }
    Case 'fx clean' { strict-fx-clean }
    $global:_StrictDone = $true
    return
}

if ($env:STRICT_AT_LOAD -eq '1') {
    # Den loaded under strict mode (the driver has checked the load itself): the
    # prompt and the directory history, which run on what the load set up, and a
    # second load.
    Case 'prompt' { prompt }
    Case 'prompt, after a move' { Set-Location -LiteralPath sub; prompt }
    Case 'back -l' { back -l }
    Case 'back, then fwd' { back; fwd }
    Case 'proxy status' { proxy status }
    Case 'reload' { reload }
    Case 'prompt, after reload' { Set-Location -LiteralPath sub; prompt; back -l }
    $global:_StrictDone = $true
    return
}

$StrictSha256 = '6ae8a75555209fd6c44157c0aed8016e763ff435a19cf186f76863140143ff72'

# ===== _helpers.ps1 =====
Case '_WrapLog' { _WrapLog 'ls' 'lsd' }
Case '_WrapLog, silenced' { $env:_DEN_WRAPPER_LOG = '0'; try { _WrapLog 'ls' 'lsd' } finally { Remove-Item Env:\_DEN_WRAPPER_LOG } }
Case '_OnWindows' { _OnWindows }
Case '_DenInteractive' { _DenInteractive }
Case '_DenInteractive, from the launch switches' {
    $env:_DEN_FORCE_INTERACTIVE = '0'
    try { _DenInteractive } finally { $env:_DEN_FORCE_INTERACTIVE = '1' }
}
Case '_DenLaunchIsRepl, no switch' { _DenLaunchIsRepl -Arguments @() }
Case '_DenLaunchIsRepl, -noexit -command' { _DenLaunchIsRepl -Arguments @('-noexit', '-command', '. x') }
Case '_DenLaunchIsRepl, values and a script' { _DenLaunchIsRepl -Arguments @('/nop', '-ep', 'Bypass', 'script.ps1') }
Case '_DenLaunchIsRepl, -e' { _DenLaunchIsRepl -Arguments @('-e', 'abc') }
Case '_DenLaunchIsRepl, --version' { _DenLaunchIsRepl -Arguments @('--version') }
Case '_DenLaunchIsRepl, another dash' { _DenLaunchIsRepl -Arguments @(([string][char]0x2013) + 'noni') }
Case '_DenLaunchIsRepl, short arguments' { _DenLaunchIsRepl -Arguments @('', '-') }
Case '_ResolveCmd' { _ResolveCmd 'cat' 'App'; _ResolveCmd 'Get-Date' }
Case '_ResolveCmd, not found' { _ResolveCmd 'nonexistent-strict' 'App'; _ResolveCmd 'nonexistent-strict' }
Case '_CoreutilsBin' { _CoreutilsBin }
Case '_CoreutilsBin, disabled' { $env:_DEN_COREUTILS = '0'; try { _CoreutilsBin } finally { Remove-Item Env:\_DEN_COREUTILS } }
Case 'New-Wrapper' { New-Wrapper 'strict-w1' 'bat' '' 'cat' '' ''; strict-w1 a.txt }
Case 'New-Wrapper, native' { New-Wrapper 'strict-w2' 'nonexistent-strict' '' 'cat' '' ''; strict-w2 a.txt }
Case 'New-Wrapper, fallback' { New-Wrapper 'strict-w3' 'nonexistent-strict' '' 'find' '' '"fallback"'; strict-w3 }
Case 'New-Wrapper, no fallback' { New-Wrapper 'strict-w4' 'nonexistent-strict' '' '' '' ''; strict-w4 }
Case 'New-WrapperSuffix' { New-WrapperSuffix 'strict-s1' 'bat' ''; strict-s1 a.txt }
Case 'New-WrapperSuffix, not installed' { New-WrapperSuffix 'strict-s2' 'nonexistent-strict' ''; strict-s2 }
Case 'New-CoreutilsWrapper' { New-CoreutilsWrapper 'strict-c1' 'cp' 'Copy-Item @Args'; strict-c1 a.txt a-copy.txt }
Case 'toggle-wrapper' { toggle-wrapper; toggle-wrapper }
Case 'tgl-wr' { tgl-wr; tgl-wr }
Case '_DenTrustedCacheOwner' {
    _DenTrustedCacheOwner -OwnerSid '' -UserSid 'S-1-5-21-1' -UserGroupSids @()
    _DenTrustedCacheOwner -OwnerSid 'S-1-5-21-1' -UserSid 'S-1-5-21-1' -UserGroupSids @()
    _DenTrustedCacheOwner -OwnerSid 'S-1-5-18' -UserSid 'S-1-5-21-1' -UserGroupSids @()
    _DenTrustedCacheOwner -OwnerSid 'S-1-5-32-544' -UserSid 'S-1-5-21-1' -UserGroupSids @('S-1-5-32-544')
    _DenTrustedCacheOwner -OwnerSid 'S-1-5-32-544' -UserSid 'S-1-5-21-1' -UserGroupSids @('S-1-5-32-545')
}
Case '_DenTokenGroupSids' {
    _DenTokenGroupSids ([pscustomobject]@{
        Groups = @([pscustomobject]@{ Value = 'S-1-5-32-545' })
        Claims = @([pscustomobject]@{ Type = [System.Security.Claims.ClaimTypes]::DenyOnlySid; Value = 'S-1-5-32-544' },
            [pscustomobject]@{ Type = 'other'; Value = 'x' })
    })
}
Case 'Test-CacheSafe' { $StrictWhy = $null; Test-CacheSafe -Path a.txt -Reason ([ref]$StrictWhy) }
Case 'Test-CacheSafe, missing' { $StrictWhy = $null; Test-CacheSafe -Path missing.txt -Reason ([ref]$StrictWhy) }
Case 'Test-CacheSafe, a symlink' { $StrictWhy = $null; Test-CacheSafe -Path link.txt -Reason ([ref]$StrictWhy) }
Case 'Test-CacheSafe, no -Reason' { Test-CacheSafe -Path sub }
Case 'Initialize-Cache' { Initialize-Cache 'denstrict-init' @('init') }
Case 'Initialize-Cache, cached' { Initialize-Cache 'denstrict-init' @('init') }
Case 'Initialize-Cache, not installed' { Initialize-Cache 'nonexistent-strict' @('init') }

# ===== wrappers.ps1: modern tool, native command, PowerShell fallback =====
Case 'cat' { cat a.txt }
Case 'cat, piped' { 'x' | cat }
Case 'find' { find a }
Case 'grep' { grep alpha a.txt }
Case 'la' { la }
Case 'll' { ll }
Case 'lla' { lla }
Case 'llt' { llt }
Case 'ls' { ls }
Case 'lt' { lt }
Case 'ripgrep' { ripgrep alpha }
Case 'catw' { catw a.txt }
Case 'findw' { findw a }
Case 'grepw' { grepw alpha }
Case 'lsw' { lsw }
$env:_DEN_WRAPPERS = '0'
Case 'cat, native' { cat a.txt }
Case 'find, native' { find . -name a.txt }
Case 'grep, native' { grep alpha a.txt }
Case 'la, native' { la }
Case 'll, native' { ll }
Case 'lla, native' { lla }
Case 'llt, fallback' { llt }
Case 'ls, native' { ls }
Case 'lt, fallback' { lt }
Case 'ripgrep, none' { ripgrep alpha }
Remove-Item Env:\_DEN_WRAPPERS
# No modern tool, no native command, and no microsoft/coreutils either (the stub
# that the pwsh-7-on-Windows run finds), with _DEN_COREUTILS unset: stock
# Windows, where _CoreutilsBin also looks under Program Files.
Use-StrictPath 'fzf', 'uv'
Case '_CoreutilsBin, none installed' { _CoreutilsBin }
Case 'head, no coreutils installed' { head -n 1 a.txt }
Case 'wc -l, no coreutils installed' { wc -l a.txt }
Case 'cat, fallback' { cat a.txt }
Case 'cat, fallback, no argument' { cat }
Case 'cat, fallback, piped' { 'x' | cat }
Case 'find, fallback' { find }
Case 'find, fallback, -name -type f' { find . -name '*.txt' -type f }
Case 'find, fallback, -type d' { find . -type d }
Case 'find, fallback, no match' { find . -name 'nomatch*' }
Case 'grep, fallback' { grep alpha a.txt }
Case 'grep, fallback, -i two files' { grep -i ALPHA a.txt b.txt }
Case 'grep, fallback, -v' { grep -v alpha a.txt }
Case 'grep, fallback, -c' { grep -c beta a.txt }
Case 'grep, fallback, -c two files' { grep -c beta a.txt b.txt }
Case 'grep, fallback, -l' { grep -l beta a.txt b.txt }
Case 'grep, fallback, -n' { grep -n beta a.txt }
Case 'grep, fallback, -n two files' { grep -n beta a.txt b.txt }
Case 'grep, fallback, -r' { grep -r gamma }
Case 'grep, fallback, piped' { 'alpha' | grep alph }
Case 'grep, fallback, a pattern and a missing file' { grep beta '*.txt' missing.txt }
Case 'find, fallback, a missing directory' { find nodir }
Case 'la, fallback' { la }
Case 'll, fallback' { ll }
Case 'lla, fallback' { lla }
Case 'llt, fallback, no lsd' { llt }
Case 'ls, fallback' { ls }
Case 'ls, fallback, empty directory' { ls emptydir }
Case 'lt, fallback, no lsd' { lt }
Case 'catw, not installed' { catw a.txt }
Case 'findw, not installed' { findw }
Case 'grepw, not installed' { grepw x }
Case 'lsw, not installed' { lsw }
Use-StrictPath

# ===== wrappers.ps1: pwsh 7 on Windows only =====
if (Get-Command cp -CommandType Function -ErrorAction SilentlyContinue) {
    Case 'cp' { cp a.txt cp-copy.txt }
    Case 'mv' { mv cp-copy.txt mv-moved.txt }
    Case 'rm' { rm mv-moved.txt }
    Case 'mkdir' { mkdir made-by-mkdir }
    Case 'rmdir' { rmdir made-by-mkdir }
    $env:_DEN_COREUTILS = '0'
    Case 'cp, no coreutils' { cp a.txt cp-copy2.txt }
    Case 'mv, no coreutils' { mv cp-copy2.txt mv-moved2.txt }
    Case 'rm, no coreutils' { rm mv-moved2.txt }
    Case 'mkdir, no coreutils' { mkdir made-by-mkdir2 }
    Case 'rmdir, no coreutils' { rmdir made-by-mkdir2 }
    Remove-Item Env:\_DEN_COREUTILS
}

# ===== coreutils.ps1: the PowerShell versions, then microsoft/coreutils =====
$env:_DEN_COREUTILS = '0'
Case 'df' { df }
Case 'df <path>' { df / }
Case 'env' { env }
Case 'env VAR=value' { env STRICT_X=1 }
Case 'env VAR=value command' { env STRICT_X=1 Write-Output hi }
Case 'head' { head a.txt }
Case 'head -n N' { head -n 2 a.txt }
Case 'head -n -N' { head -n -1 a.txt }
Case 'head -N' { head -2 a.txt }
Case 'head, two files' { head a.txt b.txt }
Case 'head -q' { head -q a.txt b.txt }
Case 'head -v' { head -v a.txt }
Case 'head, piped' { 'x', 'y' | head -n 1 }
Case 'head -n -N, piped' { 'x', 'y' | head -n -1 }
Case 'head, missing file' { head missing.txt }
Case 'split -l' { split -l 2 a.txt l- }
Case 'split -n' { split -n 2 a.txt n- }
Case 'split -n l/N' { split -n l/2 a.txt nl- }
Case 'split -b' { split -b 4 a.txt b- }
Case 'split -b 1K -a 3' { split -b 1K -a 3 a.txt k- }
Case 'split, a one-line file' { split one.txt one- }
Case 'split, an empty file' { split empty.txt empty- }
Case 'split -n 0' { split -n 0 a.txt }
Case 'split -b 0' { split -b 0 a.txt }
Case 'split, no input' { split }
Case 'split, piped' { 'p', 'q', 'r' | split -l 2 }
Case 'split -b, piped' { 'p', 'q' | split -b 2 }
Case 'tail' { tail a.txt }
Case 'tail -n N' { tail -n 2 a.txt }
Case 'tail -n +N' { tail -n +2 a.txt }
Case 'tail -N' { tail -2 a.txt }
Case 'tail, two files' { tail a.txt b.txt }
Case 'tail -q' { tail -q a.txt b.txt }
Case 'tail -v' { tail -v a.txt }
Case 'tail -f, no file' { tail -f }
# Select-Object -First stops the pipeline, and so the follow, once it has both lines.
Case 'tail -f <file>' { tail -f -n 2 a.txt | Select-Object -First 2 }
Case 'tail, piped' { 'x', 'y' | tail -n 1 }
Case 'tail -n +N, piped' { 'x', 'y' | tail -n +2 }
Case 'touch, new file' { touch touched.txt }
Case 'touch, existing file' { touch a.txt }
Case 'touch, a pattern and one that matches nothing' {
    try { touch '*.txt' 'none*.log' } finally { Remove-Item -LiteralPath 'none*.log' -Force -ErrorAction SilentlyContinue }
}
Case 'touch, no argument' { touch }
Case 'touch, [ ] escaped as tab completion writes them' {
    $null = New-Item -ItemType Directory -Path 'br/[d]'
    try { touch 'br/`[d`]/x.txt' 'br/`[d`]/x.txt' 'br/`[e`].txt' } finally { Remove-Item -LiteralPath br -Recurse -Force }
}
Case 'wc' { wc a.txt }
Case 'wc -l' { wc -l a.txt }
Case 'wc -w -c' { wc -w -c a.txt }
Case 'wc -m' { wc -m a.txt }
Case 'wc, empty file' { wc empty.txt }
Case 'wc, a one-line file' { wc one.txt }
Case 'wc, two files' { wc a.txt b.txt }
Case 'wc -l, a missing file of two' { wc -l a.txt missing.txt }
Case 'wc, missing file' { wc missing.txt }
Case 'wc, piped' { 'a b', 'c' | wc }
Case 'wc -l, piped' { 'a' | wc -l }
Case 'wc, no input' { wc }
Case 'which' { which cat }
Case 'which -a' { which -a cat }
Case 'which, a cmdlet and a function' { which Get-Date dg }
Case 'which, not found' { which nonexistent-strict }
Case 'which, no argument' { which }
Remove-Item Env:\_DEN_COREUTILS
Case 'df, coreutils' { df }
Case 'env, coreutils' { env }
Case 'head, coreutils' { head a.txt }
Case 'split, coreutils' { split -l 2 a.txt cu- }
Case 'tail, coreutils' { tail a.txt }
Case 'touch, coreutils' { touch touched2.txt }
Case 'wc, coreutils' { wc a.txt }

# ===== functions.ps1: file utils =====
Case 'dg -h' { dg -h }
Case 'dg --help' { dg --help }
Case 'dg, no argument' { dg }
Case 'dg <file>' { dg hash.txt }
Case 'dg md5 <file>' { dg md5 hash.txt }
Case 'dg 512 <file> <file>' { dg 512 hash.txt a.txt }
Case "dg '--' <file>" { dg '--' hash.txt }
Case "dg sha256 '--' <file>" { dg sha256 '--' hash.txt }
Case 'dg, missing file' { dg missing.txt }
Case 'dg <file> <hash>' { dg hash.txt $StrictSha256 }
Case 'dg <file> sha256:<hash>' { dg hash.txt "sha256:$StrictSha256" }
Case 'dg <file> <wrong hash>' { dg hash.txt ('0' * 64) }
Case 'dg md5 <file> <sha256 hash>' { dg md5 hash.txt $StrictSha256 }
Case 'dg <missing file> <hash>' { dg missing.txt $StrictSha256 }
Case 'dg -e, same' { dg -e hash.txt hash.txt }
Case 'dg -e, different' { dg -e hash.txt a.txt }
Case 'dg -e, one operand' { dg -e hash.txt }
Case 'dg -e, missing file' { dg -e hash.txt missing.txt }
Case 'dg -e -c' { dg -e -c hash.txt }
Case 'dg -c' { dg -c sums.txt }
Case 'dg -c, no operand' { dg -c }
Case 'dg -c, missing sums file' { dg -c missing.sums }
Case 'dg -c md5' { dg -c md5 sums.txt }
Case 'dg -c, no checksum line' { dg -c empty.txt }
Case 'digest' { digest hash.txt }
Case 'mkfile' { mkfile 1K made.bin }
Case 'mkfile, bytes' { mkfile 16 made2.bin }
Case '_ArVolumeRelative' { _ArVolumeRelative 'C:\Users\x'; _ArVolumeRelative 'rel\path' }
Case '_ArLinkTarget' { _ArLinkTarget (Get-Item -LiteralPath a.txt); _ArLinkTarget (Get-Item -LiteralPath link.txt) }
Case '_ArSameFile' { _ArSameFile a.txt a.txt; _ArSameFile a.txt link.txt; _ArSameFile a.txt nothere.gz }
Case '_ArRegularFile' { _ArRegularFile a.txt; _ArRegularFile sub; _ArRegularFile missing.txt }
Case '_ArTool' { _ArTool 'gzip'; _ArTool 'nonexistent-strict' }
Case '_ArCompressTo' { _ArCompressTo (_ArTool 'gzip') one.txt direct.gz }
Case '_ArZipTo' { _ArZipTo @('a.txt', 'sub', 'emptydir') 'out.zip' 'direct.zip' }
Case '_ArZipTo, a missing source' { _ArZipTo @('missing.txt') 'out.zip' 'direct2.zip' }
Case '_ArDropOutput' { _ArDropOutput @('a.txt', './b.txt', 'sub') 'b.txt'; _ArDropOutput @('a.txt') '' }
Case '_ArDropOutput, only the output' { _ArDropOutput @('a.txt', 'link.txt') 'a.txt' }
Case 'archive .tar.gz' { archive out.tar.gz a.txt b.txt }
Case 'archive .tgz' { archive out.tgz a.txt }
Case 'archive .tar.bz2' { archive out.tar.bz2 a.txt }
Case 'archive .tar.xz' { archive out.tar.xz a.txt }
Case 'archive .tar.zst' { archive out.tar.zst a.txt }
Case 'archive .tar' { archive out.tar a.txt }
Case 'archive .gz' { archive s1.gz one.txt }
Case 'archive .bz2' { archive s2.bz2 one.txt }
Case 'archive .xz' { archive s3.xz one.txt }
Case 'archive .zst' { archive s4.zst one.txt }
Case 'archive .zip' { archive out.zip a.txt b.txt }
Case 'archive .zip, the output among the sources' { archive out.zip a.txt out.zip }
Case 'archive .7z' { archive out.7z a.txt '-x' }
Case 'archive .7z, only the output as a source' { archive out.7z ./out.7z }
Case 'archive, a dash-leading output' { archive '-dash.tar' a.txt }
Case 'archive, two sources for .gz' { archive two.gz a.txt b.txt }
Case 'archive, a directory for .gz' { archive dir.gz sub }
Case 'archive, output is the source' { archive same.gz same.gz }
Case 'archive, output is a directory' { archive sub a.txt }
Case 'archive, unsupported format' { archive out.rar a.txt }
Case 'pk' { pk out2.tar a.txt }
Case 'extract .tar.gz' { extract out.tar.gz }
Case 'extract .tgz' { extract out.tgz }
Case 'extract .tar.bz2' { extract out.tar.bz2 }
Case 'extract .tar.xz' { extract out.tar.xz }
Case 'extract .tar.zst' { extract out.tar.zst }
Case 'extract .tar' { extract out.tar }
Case 'extract .gz' { extract s1.gz }
Case 'extract .bz2' { extract s2.bz2 }
Case 'extract .xz' { extract s3.xz }
Case 'extract .zst' { extract s4.zst }
Case 'extract .zip' { extract out.zip }
Case 'extract .7z' { extract x.7z }
Case 'extract .rar' { extract x.rar }
Case 'extract, two archives' { extract out.tar out2.tar }
Case 'extract, unsupported format' { extract a.txt }
Case 'extract, missing file' { extract missing.tar }
Case 'extract, no argument' { extract }
Case 'xt' { xt out2.tar }

# ===== functions.ps1: system, navigation, history =====
Case 'path' { path }
Case 'ports' { ports }
Case 'ports, no ss or netstat' { Use-StrictPath 'sys'; try { ports } finally { Use-StrictPath } }
Case 'c' { c }
Case 'cd <dir>' { cd sub }
Case 'cd' { cd }
Case 'cd, wrappers off' { $env:_DEN_WRAPPERS = '0'; try { cd sub; cd } finally { Remove-Item Env:\_DEN_WRAPPERS } }
Case 'cdi' { cdi }
Case 'cdi, wrappers off' { $env:_DEN_WRAPPERS = '0'; try { cdi } finally { Remove-Item Env:\_DEN_WRAPPERS } }
Case 'zd' { zd sub }
Case 'zdi' { zdi }
Case 'zd, no zoxide' { Invoke-WithoutZoxide { zd sub } }
Case 'zdi, no zoxide' { Invoke-WithoutZoxide { zdi } }
Case 'up' { Set-Location -LiteralPath sub; up }
Case 'up N' { up 2 }
Case '..' { .. }
# & '.N': typed bare, .1 is the number 0.1, not a command.
Case '.1' { & '.1' }
Case '.2' { & '.2' }
Case '.3' { & '.3' }
Case '.4' { & '.4' }
Case '.5' { & '.5' }
Case '.6' { & '.6' }
Case '.7' { & '.7' }
Case '.8' { & '.8' }
Case '.9' { & '.9' }
Case 'cdf' { cdf }
Case 'cdf, no fd' { Use-StrictPath 'fzf', 'uv', 'bin', 'sys'; try { cdf } finally { Use-StrictPath } }
Case 'cdf, no fzf' { Use-StrictPath 'modern', 'uv', 'bin', 'sys'; try { cdf } finally { Use-StrictPath } }
Case 'mkcd' { mkcd made-dir }
Case 'mkcd, [ ] in the name' { mkcd 'made-[x]' }
Case 'mkcd -Name' { mkcd -Name made-named }
Case 'mkcd, no argument' { mkcd }
Case 'y' { y }
Case 'y, no yazi' { Use-StrictPath 'sys'; try { y } finally { Use-StrictPath } }
Case 'again' { $global:_StrictAnswer = 'y'; again }
Case 'again, declined' { $global:_StrictAnswer = 'n'; again }
Case 'again -N' { $global:_StrictAnswer = 'y'; again -N 1 }
Case 'again -Sudo' { $global:_StrictAnswer = 'y'; again -Sudo }
Case 'again -Sudo, declined' { $global:_StrictAnswer = 'n'; again -Sudo }
Case 'again -N 0' { again -N 0 }
Case 'again, past the history' { again -N 99 }
Case 'sagain' { $global:_StrictAnswer = 'y'; sagain }
$global:_StrictAnswer = 'n'
Case '_DenDirRecord' {
    Set-Location -LiteralPath sub; _DenDirRecord
    Set-Location -LiteralPath ../emptydir; _DenDirRecord
    Set-Location -LiteralPath ../dest; _DenDirRecord
}
Case 'back, then fwd' { back; fwd }
Case 'back N' { back 2 }
Case 'back -l' { back -l }
Case 'back -i' { back -i }
Case 'back -i, no fzf' { Use-StrictPath 'sys'; try { back -i } finally { Use-StrictPath } }
Case 'back, past the history' { back 99 }
Case 'back, a long N' { back 12345678901 }
Case 'back, not a number' { back abc }
Case 'fwd, past the history' { fwd 5 }
Case 'fwd, not a number' { fwd 0 }
Case 'back, to a directory that is gone' {
    $null = New-Item -ItemType Directory -Path gone
    Set-Location -LiteralPath gone; _DenDirRecord
    Set-Location -LiteralPath ..; _DenDirRecord
    Remove-Item -LiteralPath gone
    back
}
Case '_DenDirTilde' { _DenDirTilde $HOME; _DenDirTilde (Join-Path $HOME 'x'); _DenDirTilde '/elsewhere' }
Case '_DenDirSame' { _DenDirSame 'a' 'A' }
Case '_DenDirMoved' { _DenDirMoved $MyInvocation }
Case '_DenDirList' { _DenDirList }
Case '_DenDirGo' { _DenDirGo 'back' '1'; _DenDirGo 'fwd' '1' }
Case 'prompt' { prompt }
Case '_DenDirHookPrompt' { _DenDirHookPrompt }
Case '_DenDirHookPrompt, a prompt defined after it' {
    $StrictPrompt = ${function:prompt}
    $StrictHook = $global:_DenDirPrompt
    try { Set-Item Function:global:prompt { 'other> ' }; _DenDirHookPrompt; prompt } finally {
        Set-Item Function:global:prompt $StrictPrompt
        $global:_DenDirPrompt = $StrictHook
    }
}
Case '_DenDirHookPrompt, again around a wrapper of its wrapper' {
    $StrictPrompt = ${function:prompt}
    $StrictHook = $global:_DenDirPrompt
    $global:_StrictWrapped = $StrictPrompt
    try {
        Set-Item Function:global:prompt { 'vs:' + $global:_StrictWrapped.Invoke() }
        _DenDirHookPrompt; prompt
    } finally {
        Set-Item Function:global:prompt $StrictPrompt
        $global:_DenDirPrompt = $StrictHook
        Remove-Variable -Name _StrictWrapped -Scope Global
    }
}

# ===== aliases.ps1 =====
Case 'g' { g status }
Case 'ga' { ga a.txt }
Case 'gaa' { gaa }
Case 'gb' { gb }
Case 'gc' { gc -m x }
Case 'gcm' { gcm x }
Case 'gco' { gco main }
Case 'gd' { gd }
Case 'gds' { gds }
Case 'gf' { gf }
Case 'gl' { gl }
Case 'gpl' { gpl }
Case 'gps' { gps }
Case 'gst' { gst }
Case 'gsw' { gsw main }
Case 'd' { d ps }
Case 'dc' { dc ps }
Case 'dcb' { dcb }
Case 'dcd' { dcd }
Case 'dce' { dce web sh }
Case 'dcl' { dcl }
Case 'dcu' { dcu }
Case 'di' { di }
Case 'dps' { dps }
Case 'dri' { dri alpine }
Case 'drir' { drir alpine }
Case '_ShapeCmdArgs' { _ShapeCmdArgs @('a b', 'c\', 'plain') }
Case '_ShapeCmdArgs, a quote' { _ShapeCmdArgs @('bad"quote') }
Case 'code' { code a.txt }
Case 'code, the .cmd launcher' { Use-StrictPath 'cmdbin'; try { code 'a b' c } finally { Use-StrictPath } }
Case 'code, the .cmd launcher and a percent sign' { Use-StrictPath 'cmdbin'; try { code 'a%PATH%b' } finally { Use-StrictPath } }
Case 'code, not installed' { Use-StrictPath 'sys'; try { code } finally { Use-StrictPath } }
Case 'gu' { gu }
Case 'gu, not installed' { Use-StrictPath 'sys'; try { gu } finally { Use-StrictPath } }
Case 'open' { open }
Case 'open <file>' { open a.txt }

# ===== hwinfo.ps1 =====
Case 'refresh-hwinfo' { refresh-hwinfo }
Case 'toggle-hwinfo' { toggle-hwinfo; toggle-hwinfo }
Case 'tgl-hw' { tgl-hw; tgl-hw }

# ===== python.ps1 =====
Case 'uv' { uv --version }
Case 'uv run, in a venv' { Invoke-InVenv { uv run app.py } }
Case 'uv run <option>, in a venv' { Invoke-InVenv { uv run --with rich app.py } }
Case 'uv run, no argument, in a venv' { Invoke-InVenv { uv run } }
Case 'pip, in a venv' { Invoke-InVenv { pip list } }
Case 'pip3, in a venv' { Invoke-InVenv { pip3 list } }
Case 'python, in a venv' { Invoke-InVenv { python -V } }
Case 'python3, in a venv' { Invoke-InVenv { python3 -V } }
Case 'py, in a venv' { Invoke-InVenv { py -V } }
Case 'pip' { pip list }
Case 'pip3' { pip3 list }
Case 'python' { python -V }
Case 'python3' { python3 -V }
Case 'py' { py -V }
Case 'Show-UvOnlyMessage' { Show-UvOnlyMessage 'pip list ' 'uv pip list ' }
Case 'va, no .venv' { va }
Case 'va <venv>, then vd' { va venv; vd }
Case 'vd, no venv' { vd }
Case 'va, a bad version_info' { va badver; vd }
Case 'va, a venv tracked by git' { va tracked }
Case 'va, a world-writable activate script' { va writable }
Case 'va, not a venv' { va sub }
Case 'vv' { vv made-venv }
Case 'vva' { vva made-venv2; vd }
Case 'toggle-uv' { toggle-uv; toggle-uv }
Case 'tgl-uv' { tgl-uv; tgl-uv }
Use-StrictPath 'modern', 'fzf', 'bin', 'sys'
Case 'uv, no uv' { uv --version }
Case 'pip, no uv' { pip list }
Case 'pip3, no uv' { pip3 list }
Case 'python, no uv' { python -V }
Case 'python3, no uv' { python3 -V }
Case 'py, no uv' { py -V }
Case 'vv, no uv' { vv }
Case 'vva, no uv' { vva }
Case 'toggle-uv, no uv' { toggle-uv; toggle-uv }
Use-StrictPath
Case 'toggle-uv, back on' { toggle-uv }

# ===== ffmpeg.ps1 =====
foreach ($StrictF in 'tomp4:mp4', 'towebm:webm', 'tomp3:mp3', 'towav:wav', 'toflac:flac') {
    $StrictName, $StrictExt = $StrictF -split ':'
    foreach ($StrictArgs in '', 'media.avi', "media.avi out.$StrictExt", 'media.avi -c:v x',
        "media.avi out.$StrictExt -c:v x", 'media.avi other.avi', "media.avi out.$StrictExt stray.$StrictExt") {
        Case "$StrictName $StrictArgs" ([scriptblock]::Create("$StrictName $StrictArgs"))
    }
}
Case 'togif' { togif }
Case 'togif <in>' { togif media.avi }
Case 'togif <in> <out> <fps> <width>' { togif media.avi out.gif 15 640 }
Case 'togif <in> <options>' { togif media.avi -vf 'fps=5' }
Case 'togif, a second input' { togif media.avi other.avi }
Case 'minfo' { minfo }
Case 'minfo <in>' { minfo media.avi }
Case 'minfo <in> <in> <options>' { minfo media.avi other.avi -show_streams }
Case 'clip' { clip }
Case 'clip <in>' { clip media.avi }
Case 'clip <in> <start> <end>' { clip media.avi 0 1 }
Case 'clip <in> <start> <end> <out> <options>' { clip media.avi 0 1 out.avi -c:v x }
Case 'strip-audio' { strip-audio }
Case 'strip-audio <in>' { strip-audio media.avi }
Case 'strip-audio <in> <out> <options>' { strip-audio media.avi out.avi -c:v x }
Case 'strip-audio, a stray argument' { strip-audio media.avi out.avi stray.avi }
Case 'thumbnail' { thumbnail }
Case 'thumbnail <in>' { thumbnail media.avi }
Case 'thumbnail <in> <time>' { thumbnail media.avi 00:00:02 }
Case 'thumbnail <in> <time> <out> <options>' { thumbnail media.avi 1 out.png -q:v 2 }
Case 'thumbnail, a stray argument' { thumbnail media.avi 1 out.png stray.png }

# ===== parallel.ps1 =====
Case '_Batches' { _Batches @('a', 'b', 'c') 2; _Batches @('a') 8; _Batches @() 4 }
Case 'pcp' { pcp }
Case 'pcp <src>' { pcp a.txt }
Case 'pcp <src> <dest>' { pcp a.txt dest }
Case 'pcp <srcs> <dest>' { pcp a.txt b.txt sub dest }
Case 'pcp <glob> <dest>' { pcp '*.txt' dest }
Case 'pcp, dest not a directory' { pcp a.txt b.txt nodir }
Case 'pmv' { pmv }
Case 'pmv <src> <dest>' { Set-Content -LiteralPath mv1.txt -Value 1; pmv mv1.txt dest }
Case 'pmv, dest not a directory' { pmv a.txt b.txt nodir }
Case 'prm' { prm }
Case 'prm --force, no path' { prm --force }
Case 'prm --force' { Set-Content -LiteralPath rm1.txt -Value 1; prm --force rm1.txt }
Case 'prm -Force' { Set-Content -LiteralPath rm2.txt -Value 1; prm -Force rm2.txt }
Case 'prm, declined' { prm a.txt }
Case 'prm, confirmed' {
    Set-Content -LiteralPath rm3.txt -Value 1
    $global:_StrictAnswer = 'y'
    try { prm rm3.txt } finally { $global:_StrictAnswer = 'n' }
}
Case 'ptar' { ptar }
Case 'ptar <out>' { ptar pt.tar }
Case 'ptar .tar.gz' { ptar pt.tar.gz a.txt }
Case 'ptar .tar.bz2' { ptar pt.tar.bz2 a.txt }
Case 'ptar .tar.xz' { ptar pt.tar.xz a.txt }
Case 'ptar .tar' { ptar pt.tar a.txt }
Case 'ptar, unsupported format' { ptar pt.zip a.txt }
Case 'ptar, no tar' { Use-StrictPath 'bin'; try { ptar pt2.tar a.txt } finally { Use-StrictPath } }

# ===== cheat.ps1 =====
Case 'cheat, none installed' { cheat }
$StrictCheat = Join-Path $env:XDG_DATA_HOME 'den/cheatsheets'
$null = New-Item -ItemType Directory -Force -Path (Join-Path $StrictCheat 'sub')
Set-Content -LiteralPath (Join-Path $StrictCheat 'git.md') -Value '# git'
Set-Content -LiteralPath (Join-Path $StrictCheat 'docker.md') -Value '# docker'
Set-Content -LiteralPath (Join-Path $StrictCheat 'sub/git-extra.md') -Value '# git extra'
Case 'cheat -h' { cheat -h }
Case 'cheat ls' { cheat ls }
Case 'cheat <name>' { cheat git.md }
Case 'cheat <part of a name>' { cheat dock }
Case 'cheat <ambiguous>' { cheat git }
Case 'cheat <ambiguous>, no fzf' { Use-StrictPath 'modern', 'uv', 'bin', 'sys'; try { cheat git } finally { Use-StrictPath } }
Case 'cheat <no match>' { cheat nomatch }
Case 'cheat, fzf' { cheat }
Case 'cheat, no fzf' { Use-StrictPath 'modern', 'uv', 'bin', 'sys'; try { cheat } finally { Use-StrictPath } }
Case 'cheat <name>, no bat' { Use-StrictPath 'fzf', 'uv', 'bin', 'sys'; try { cheat git.md } finally { Use-StrictPath } }

# ===== proxy.ps1 (status, ls and off first: nothing has set the active profile yet) =====
Case 'proxy' { proxy }
Case 'proxy status' { proxy status }
Case 'proxy ls, no profile' { proxy ls }
Case 'proxy off, none on' { proxy off }
Case 'proxy add, no url' { proxy add work }
Case 'proxy add, a bad name' { proxy add 'bad name' http://127.0.0.1:9 }
Case 'proxy add' { proxy add work http://127.0.0.1:9 }
Case 'proxy add <no_proxy>' { proxy add home http://127.0.0.1:8 example.com }
Case 'proxy list' { proxy list }
Case 'proxy on, no name' { proxy on }
Case 'proxy on, no such profile' { proxy on nope }
Case 'proxy on' { proxy on work }
Case 'proxy status, on' { proxy status }
Case 'proxy ls, on' { proxy ls }
Case 'proxy rm, the active one' { proxy rm work }
Case 'proxy off' { proxy off }
Case 'proxy on <no_proxy>' { proxy on home; proxy off }
Case 'proxy rm, no name' { proxy rm }
Case 'proxy rm, no such profile' { proxy rm nope }
Case 'proxy help' { proxy help }
Case 'proxy, unknown command' { proxy bogus }
# What init.ps1's history handler asks about each line typed.
Case '_ProxySecretLine, a password' { _ProxySecretLine "proxy add c 'http://al:pw@127.0.0.1:9'" }
Case '_ProxySecretLine, a user only' { _ProxySecretLine 'proxy add c http://al@127.0.0.1:9' }
Case '_ProxySecretLine, no proxy add' { _ProxySecretLine 'Get-Date' }

# ===== snippet.ps1 =====
Case 'snippet help' { snippet help }
Case 'snippet ls, none saved' { snippet ls }
Case 'snippet pick, none saved' { snippet pick }
Case 'snippet save, no name' { snippet save }
Case 'snippet save, a bad name' { snippet save 'bad name' x }
Case 'snippet save' { snippet save hi Write-Output 'snippet ran' }
Case 'snippet save, piped' { 'Write-Output piped' | snippet save piped }
Case 'snippet save, empty' { snippet save empty }
Case 'snippet ls' { snippet ls }
Case 'snippet list' { snippet list }
Case 'snip' { snip ls }
Case 'snippet show' { snippet show hi }
Case 'snippet cat' { snippet cat hi }
Case 'snippet show, no such snippet' { snippet show nope }
Case 'snippet show, no name' { snippet show }
Case 'snippet run' { snippet run hi }
Case 'snippet exec' { snippet exec hi }
Case 'snippet run, no such snippet' { snippet run nope }
Case 'snippet run, no name' { snippet run }
Case 'snippet pick' { snippet pick }
Case 'snippet' { snippet }
Case 'snippet pick, no fzf' { Use-StrictPath 'bin'; try { snippet pick } finally { Use-StrictPath } }
Case 'snippet rm' { snippet rm piped }
Case 'snippet remove, no such snippet' { snippet remove nope }
Case 'snippet rm, no name' { snippet rm }
Case 'snippet, unknown command' { snippet bogus }

# ===== every den function and alias again, with no argument =====
# Not reload (its case is last), nor the toggles: a toggle has no other form, and
# the cases above run each one twice, so its switch ends where it began.
$StrictNoArgSkip = 'reload', 'toggle-wrapper', 'tgl-wr', 'toggle-uv', 'tgl-uv', 'toggle-hwinfo', 'tgl-hw'
foreach ($StrictFn in $global:_StrictFunctions + $global:_StrictAliases) {
    if ($StrictNoArgSkip -contains $StrictFn -or $global:_StrictSkip.ContainsKey($StrictFn)) { continue }
    Case "$StrictFn, no argument" ([scriptblock]::Create("& '$StrictFn'"))
}
Case 'vd, the .venv that vva made' { vd }

# ===== init.ps1 (last: it loads den again) =====
Case 'reload' { reload }

$global:_StrictDone = $true
PS1

# Fixture functions for the self-test: each strict-mode error the harness
# records, one that the function catches itself, one clean function, and one
# that no case calls.
EXTRA="$S/selftest.ps1"
cat > "$EXTRA" <<'PS1'
function strict-fx-unset { $global:_StrictNeverSet }
function strict-fx-property { $o = [pscustomobject]@{ A = 1 }; $o.B }
function strict-fx-index { $a = @(1); $a[3] }
function strict-fx-list { $l = [System.Collections.Generic.List[string]]::new(); $l[0] }
function strict-fx-parens { function strict-fx-inner($x, $y) { $x }; strict-fx-inner(1, 2) }
function strict-fx-caught { try { $o = [pscustomobject]@{}; $o.Missing } catch { 'handled' } }
function strict-fx-clean { 'fine' }
function strict-fx-uncovered { 'never called' }
PS1

# run_strict <den dir> <report> [VAR=value...] - load den from <den dir> in a
# fresh run directory and write the driver's report.
run_strict() {
    local den="$1" report="$2"
    shift 2
    fresh_run
    (cd "$RUN/play" && env -u _DEN_WRAPPERS -u _DEN_WRAPPER_LOG -u _DEN_COREUTILS -u _DEN_UV_OVERRIDE \
        -u _DEN_HWINFO_HIDDEN -u VIRTUAL_ENV -u _DEN_VENV_PYTHON -u http_proxy -u https_proxy -u all_proxy \
        -u no_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
        HOME="$RUN/home" XDG_DATA_HOME="$RUN/data" XDG_CONFIG_HOME="$RUN/config" TMPDIR="$RUN/tmp" \
        PATH="$STRICT_PATH" _DEN_FORCE_INTERACTIVE=1 \
        STRICT_DEN="$den" STRICT_OUT="$report" STRICT_ROOT="$STUBS" STRICT_PATH="$STRICT_PATH" \
        STRICT_PLAY="$RUN/play" STRICT_PROFILE="$RUN/profile.ps1" STRICT_CASES="$CASES" "$@" \
        "$TIMEOUT_BIN" 600 "$PWSH_BIN" -NoProfile -NonInteractive -Command ". '$DRIVER'" \
        < /dev/null > "$report.log" 2>&1)
    [ -f "$report" ] || echo "CRASH no report (see $report.log)" > "$report"
}

# report_lines <report> <kind...> - the report's lines of these kinds.
report_lines() {
    local report="$1"
    shift
    local kinds
    kinds=$(IFS='|'; echo "$*")
    grep -E "^($kinds) " "$report" || true
}

# =============================================================================
# Self-test: the harness records each kind of strict-mode error and a function
# no case reaches.
# =============================================================================
echo "[pwsh] the strict-mode harness records each strict-mode error and each uncalled function"
SELF_REPORT="$S/selftest.txt"
run_strict "$DOTFILES/shell/pwsh" "$SELF_REPORT" STRICT_SELFTEST=1 STRICT_EXTRA="$EXTRA"
assert_eq "pwsh/strict harness self-test ran to its end" "" "$(report_lines "$SELF_REPORT" CRASH)"
actual=$(report_lines "$SELF_REPORT" VIOLATION | cut -d'|' -f1-2 | sed 's/^VIOLATION //; s/ *$//')
assert_eq "pwsh/strict harness records each kind" "fx unset variable | VariableIsUndefined
fx missing property | PropertyNotFoundStrict
fx array index | System.IndexOutOfRangeException
fx list index | System.ArgumentOutOfRangeException
fx method-style call | StrictModeFunctionCallWithParens
fx caught by the function | PropertyNotFoundStrict" "$actual"
actual=$(report_lines "$SELF_REPORT" UNCOVERED | grep 'strict-fx' || true)
assert_eq "pwsh/strict harness flags the uncalled function only" "UNCOVERED strict-fx-uncovered" "$actual"

# =============================================================================
# pwsh 7: every den function from a strict-mode script
# =============================================================================
echo "[pwsh] every den function and alias works from a script under Set-StrictMode -Version Latest"
REPORT="$S/report.txt"
run_strict "$DOTFILES/shell/pwsh" "$REPORT"
assert_eq "pwsh/strict run reached its end" "" "$(report_lines "$REPORT" CRASH)"
# One name from each file, so a load that defined nothing cannot pass the rest.
missing=""
for name in _ResolveCmd cat wc dg gst toggle-hwinfo uv tomp4 pcp cheat proxy snippet reload prompt digest; do
    report_lines "$REPORT" FUNCTION ALIAS | grep -qx "\(FUNCTION\|ALIAS\) $name" || missing="$missing $name"
done
assert_eq "pwsh/strict inventory holds a function from every file" "" "$missing"
echo "  inventory: $(report_lines "$REPORT" FUNCTION | wc -l) functions, $(report_lines "$REPORT" ALIAS | wc -l) aliases"
report_lines "$REPORT" SKIPPED | sed 's/^/  /'
assert_eq "pwsh/strict no strict-mode error in den" "" "$(report_lines "$REPORT" VIOLATION)"
assert_eq "pwsh/strict every den function is called or skipped with a reason" "" \
    "$(report_lines "$REPORT" UNCOVERED REACHED-BUT-SKIPPED SKIP-UNKNOWN)"

# =============================================================================
# The platform branches: pwsh 7 on Windows (with the coreutils tier), and
# Windows PowerShell 5.1
# =============================================================================
echo "[pwsh] den's functions under Set-StrictMode, as pwsh 7 on Windows"
WINDOWS_REPORT="$S/report-windows.txt"
run_strict "$DOTFILES/shell/pwsh" "$WINDOWS_REPORT" STRICT_AS_WINDOWS=1
assert_eq "pwsh/strict run as pwsh 7 on Windows reached its end" "" "$(report_lines "$WINDOWS_REPORT" CRASH)"
assert_eq "pwsh/strict no strict-mode error in den, as pwsh 7 on Windows" "" \
    "$(report_lines "$WINDOWS_REPORT" VIOLATION)"
assert_eq "pwsh/strict every den function is called, as pwsh 7 on Windows" "" \
    "$(report_lines "$WINDOWS_REPORT" UNCOVERED)"

echo "[pwsh] den's functions under Set-StrictMode, as Windows PowerShell 5.1"
DESKTOP_DEN="$S/pwsh-desktop"
mkdir -p "$DESKTOP_DEN"
for f in "$DOTFILES"/shell/pwsh/*.ps1; do
    sed "s/[\$]PSVersionTable[.]PSEdition/'Desktop'/g; s/[\$]PSVersionTable[.]PSVersion[.]Major/5/g" "$f" \
        > "$DESKTOP_DEN/$(basename "$f")"
done
DESKTOP_REPORT="$S/report-desktop.txt"
run_strict "$DESKTOP_DEN" "$DESKTOP_REPORT" STRICT_AS_DESKTOP=1
assert_eq "pwsh/strict run as 5.1 reached its end" "" "$(report_lines "$DESKTOP_REPORT" CRASH)"
assert_eq "pwsh/strict no strict-mode error in den, as 5.1" "" "$(report_lines "$DESKTOP_REPORT" VIOLATION)"
assert_eq "pwsh/strict every den function is called, as 5.1" "" "$(report_lines "$DESKTOP_REPORT" UNCOVERED)"

# =============================================================================
# Den loaded after Set-StrictMode, as by a profile that sets it first
# =============================================================================
for platform in 'pwsh 7' 'pwsh 7 on Windows' '5.1'; do
    echo "[pwsh] den loaded under Set-StrictMode, as $platform"
    LOAD_DEN="$DOTFILES/shell/pwsh"
    LOAD_AS=()
    case "$platform" in
        '5.1') LOAD_DEN="$DESKTOP_DEN"; LOAD_AS=(STRICT_AS_DESKTOP=1) ;;
        *Windows) LOAD_AS=(STRICT_AS_WINDOWS=1) ;;
    esac
    LOAD_REPORT="$S/report-load-${platform// /-}.txt"
    run_strict "$LOAD_DEN" "$LOAD_REPORT" STRICT_AT_LOAD=1 "${LOAD_AS[@]}"
    assert_eq "pwsh/strict run loading den under strict mode reached its end, as $platform" "" \
        "$(report_lines "$LOAD_REPORT" CRASH)"
    assert_eq "pwsh/strict no strict-mode error loading den or at its prompt, as $platform" "" \
        "$(report_lines "$LOAD_REPORT" VIOLATION)"
done

print_summary "test_strict"
[ "$FAIL" -eq 0 ]
