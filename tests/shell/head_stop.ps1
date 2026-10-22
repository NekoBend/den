# head_stop.ps1 - check that head (shell/pwsh/coreutils.ps1) stops the commands
# before it once the Nth piped object is out, under the PowerShell that runs this
# script.
#
# PowerShell has no public way for a function to stop the commands before it, so
# head does it through PowerShell internals it looks up by reflection (see the
# comment on head). Where one is missing it falls back: it reads what comes after
# the Nth object and drops it, and a producer that never ends then never lets it
# return. The Linux tests (test_coreutils.sh) check the stop under pwsh 7 and run
# this script there too; CI runs it on Windows under Windows PowerShell 5.1 and
# pwsh 7.
#
# coreutils.ps1 is loaded as test_coreutils.sh loads it: _OnWindows and
# _DenAddClean are stand-ins, the _DenInteractive guard is left out, and
# _CoreutilsBin finds no microsoft/coreutils, so head is den's PowerShell one.
# Each check runs in a runspace of its own, as a host runs a line typed at its
# prompt, and is stopped when it has not ended after -Seconds. Its producer counts
# the objects it makes: N when head stops it, all of them when head falls back.
# When head did not stop it, the script says whether head fell back and lists the
# internals head looks up as this PowerShell has them. A coreutils.ps1 that does
# not define head (one that does not parse, say) stops the script before the
# checks, with its load errors: head would otherwise be any head on PATH, which
# reads all its input as the fallback does. Exit code 0 when every check passes,
# 1 otherwise.
# This file must stay ASCII and parse on Windows PowerShell 5.1.
param(
    # The coreutils.ps1 to test; by default the one in this checkout.
    [string]$Coreutils = '',
    # How long a check may run before it is stopped and fails.
    [int]$Seconds = 30
)

$ErrorActionPreference = 'Stop'
if (-not $Coreutils) {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $Coreutils = [System.IO.Path]::Combine($root, 'shell', 'pwsh', 'coreutils.ps1')
}
$version = '{0} {1}' -f $(if ($PSVersionTable.PSEdition -eq 'Desktop') { 'Windows PowerShell' } else { 'pwsh' }), $PSVersionTable.PSVersion
'head_stop: ' + $version

# ReadAllLines reads UTF-8, which Windows PowerShell 5.1 does not assume for a
# file without a BOM (the text of coreutils.ps1 outside its comments is ASCII).
$lines = [System.IO.File]::ReadAllLines((Convert-Path -LiteralPath $Coreutils))
$source = (@('function _OnWindows { $true }', 'function _DenAddClean { }') +
    @($lines | Where-Object { $_ -notmatch '_DenInteractive' })) -join "`n"

# Every check is this prelude, its line, and one output line per $Error entry
# after it, so a check also fails when head leaves an error behind. A load that
# did not define head ends the line with the load errors on one line before
# $Error.Clear() erases them (a ParseException ends only its own statement).
# Get-Command's -ErrorAction Ignore keeps its own error out of $Error.
$prelude = @'
param($Source)
. ([scriptblock]::Create($Source))
function _CoreutilsBin { }
if (-not (Get-Command head -CommandType Function -ErrorAction Ignore)) { throw ('coreutils.ps1 did not define head: ' + ((@($Error) | ForEach-Object { "$_" }) -join '; ' -replace '\s+', ' ')) }
$Error.Clear()

'@
$epilogue = @'

foreach ($e in $Error) { 'error: ' + $e }
'@

# Invoke-Line <line> <limit> - run the line in a runspace of its own and return
# its output as strings, or one line that says how it ended when it threw or did
# not end within <limit> seconds.
function Invoke-Line([string]$Line, [int]$Limit) {
    $ps = [powershell]::Create()
    $null = $ps.AddScript($prelude + $Line + $epilogue).AddArgument($source)
    $run = $ps.BeginInvoke()
    if (-not $run.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($Limit))) {
        # Stopped as Ctrl+C stops a line. Disposing of one that is still running
        # waits for it to stop, so one that has not stopped after 10 s is left.
        $stop = $ps.BeginStop($null, $null)
        if ($stop.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds(10))) { $ps.Dispose() }
        return '(still running after {0} s, then stopped)' -f $Limit
    }
    try {
        $out = @($ps.EndInvoke($run) | ForEach-Object { "$_" })
    } catch {
        $e = $_.Exception
        if ($e.InnerException) { $e = $e.InnerException }
        $out = @('(the line ended with {0}: {1})' -f $e.GetType().Name, $e.Message)
    }
    $ps.Dispose()
    $out
}

# Show-Lookup - the internals head looks up (see the comment on head), as this
# PowerShell has them; one that is MISSING is enough for head to fall back.
function Show-Lookup {
    $bf = [System.Reflection.BindingFlags]'Instance, NonPublic'
    $sma = [psobject].Assembly
    $context = $sma.GetType('System.Management.Automation.ExecutionContext')
    $processor = $sma.GetType('System.Management.Automation.CommandProcessorBase')
    $stop = $sma.GetType('System.Management.Automation.StopUpstreamCommandsException')
    $found = [ordered]@{
        'EngineIntrinsics field of type ExecutionContext' = @([System.Management.Automation.EngineIntrinsics].GetFields($bf) |
            Where-Object { $null -ne $context -and $_.FieldType -eq $context })[0]
        'ExecutionContext.CurrentCommandProcessor' = $(if ($context) { $context.GetProperty('CurrentCommandProcessor', $bf) })
        'CommandProcessorBase.Command' = $(if ($processor) { $processor.GetProperty('Command', $bf) })
        'CommandProcessorBase.ManageInvocationException' = $(if ($processor) { $processor.GetMethod('ManageInvocationException', $bf) })
        'StopUpstreamCommandsException' = $(if ($stop) { 'base ' + $stop.BaseType.Name + ', ' + (@($stop.GetConstructors()) -join '; ') })
    }
    foreach ($name in $found.Keys) {
        $what = $found[$name]
        if ($null -eq $what) { $what = 'MISSING' }
        '  {0}: {1}' -f $name, $what
    }
}

# Each check: a name, the line, and the output it must give. A producer that
# makes all 10 objects ran into the fallback.
$checks = @(
    @{
        Name = 'head -n 1: the producer makes 1 object'
        Line = @'
$global:made = 0
$out = @(1..10 | ForEach-Object { $global:made++; $_ } | head -n 1)
'{0} made {1}' -f ($out -join ','), $global:made
'@
        Want = @('1 made 1')
    }
    @{
        Name = 'head -n 3: 3 objects, and the producer makes 3'
        Line = @'
$global:made = 0
$out = @(1..10 | ForEach-Object { $global:made++; $_ } | head -n 3)
'{0} made {1}' -f ($out -join ','), $global:made
'@
        Want = @('1,2,3 made 3')
    }
    @{
        Name = 'a command after head gets its end: Measure-Object counts 3'
        Line = @'
$global:made = 0
$m = 1..10 | ForEach-Object { $global:made++; $_ } | head -n 3 | Measure-Object
'counted {0} made {1}' -f $m.Count, $global:made
'@
        Want = @('counted 3 made 3')
    }
    @{
        Name = 'the statements after the line run, in a script block and a function'
        Line = @'
function Get-Two { & { foreach ($i in 1..10) { $i } } | head -n 2; 'then the function' }
$r = & {
    & { foreach ($i in 1..10) { $i } } | head -n 1
    'then the script block'
}
$r -join ', '
(Get-Two) -join ', '
'then the next line'
'@
        Want = @('1, then the script block', '1, 2, then the function', 'then the next line')
    }
    @{
        Name = 'head -n 1 returns from a producer that never ends'
        Line = @'
$out = @(& { while ($true) { 'tick'; Start-Sleep -Milliseconds 50 } } | head -n 1)
'{0}, then the next line' -f ($out -join ',')
'@
        Want = @('tick, then the next line')
    }
)

# The prelude alone gives no output when coreutils.ps1 loads cleanly. Any
# output (a load error, or a line coreutils.ps1 wrote while loading) means no
# check can tell the stop from the fallback, so the script stops here.
$load = @(Invoke-Line '' $Seconds)
if ($load.Count -gt 0) {
    '::error::head_stop: coreutils.ps1 did not load cleanly on {0} (loading it gave output), so no check ran: {1}' -f $version, ($load -join ' ')
    exit 1
}

$total = 0
$failed = 0
$first = @()
foreach ($c in $checks) {
    $total++
    $got = @(Invoke-Line $c.Line $Seconds)
    if ($total -eq 1) { $first = $got }
    $want = @($c.Want)
    $same = $got.Count -eq $want.Count
    for ($i = 0; $same -and $i -lt $want.Count; $i++) { $same = $got[$i] -ceq $want[$i] }
    if ($same) {
        'ok   ' + $c.Name
        continue
    }
    $failed++
    '::error::head_stop: {0}: other output' -f $c.Name
    for ($i = 0; $i -lt [Math]::Max($want.Count, $got.Count); $i++) {
        $w = if ($i -lt $want.Count) { '<' + $want[$i] + '>' } else { '(none)' }
        $g = if ($i -lt $got.Count) { '<' + $got[$i] + '>' } else { '(none)' }
        '  {0} [{1}] want {2}' -f $(if ($w -ceq $g) { ' ' } else { '!' }), $i, $w
        '  {0} [{1}] got  {2}' -f $(if ($w -ceq $g) { ' ' } else { '!' }), $i, $g
    }
}

# The verdict on the stop, from the first check.
if ($first.Count -gt 0 -and $first[0] -ceq '1 made 1') {
    'head_stop: the stop ran: head -n 1 ended its producer at the first object'
} else {
    if ($first.Count -gt 0 -and $first[0] -ceq '1 made 10') {
        '::error::head_stop: FALLBACK on {0}: head -n 1 passed the first object on, then read the other 9 and dropped them; the stop did not run' -f $version
    } else {
        '::error::head_stop: neither the stop nor the fallback on {0}: head -n 1 gave <{1}>' -f $version, ($first -join '|')
    }
    'head_stop: the internals head looks up, on {0}:' -f $version
    Show-Lookup
}

if ($failed) {
    'head_stop: {0} of {1} checks failed' -f $failed, $total
    exit 1
}
'head_stop: all {0} checks passed' -f $total
exit 0
