# relaunch_argv.ps1 - check that the arguments reload starts PowerShell again with
# reach the new process whole, under the native argument passing of the host that
# runs this script.
#
# reload (shell/pwsh/init.ps1) runs (Get-Process -Id $PID).Path with
# @(_DenRelaunchArgs -CommandLineArgs <argv> [-Legacy]), -Legacy when
# _DenLegacyArgPassing says this host passes native arguments the legacy way. This
# script does the same for representative launch arguments and starts the same
# executable, which prints the arguments it got ([Environment]::GetCommandLineArgs()
# after argv[0], one per line) and its directory. Each check passes when that list
# is the launch arguments minus argv[0] and minus the -WorkingDirectory that reload
# leaves out, and the new process is in this one's directory.
#
# The new process runs `-NoProfile -NonInteractive -Command <probe> #` first; every
# argument after that joins the command text behind the '#', so the arguments under
# test can be anything, -noexit and -command included, without being run.
#
# CI runs it on Windows under Windows PowerShell 5.1 (legacy passing, with the
# quoting bug that _DenRelaunchArgs works around) and pwsh 7 (its default passing,
# then Standard and Legacy); the Linux shell tests run it under pwsh 7. Exit code 0
# when every check passes, 1 otherwise, with each difference printed.
# This file must stay ASCII and parse on Windows PowerShell 5.1.
param(
    # The _helpers.ps1 to test; by default the one in this checkout.
    [string]$Helpers = ''
)

$ErrorActionPreference = 'Stop'
if (-not $Helpers) {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $Helpers = [System.IO.Path]::Combine($root, 'shell', 'pwsh', '_helpers.ps1')
}
. $Helpers

$desktop = $PSVersionTable.PSEdition -eq 'Desktop'
$hostArgv = [Environment]::GetCommandLineArgs()
$exe = (Get-Process -Id $PID).Path
'relaunch_argv: {0} {1}' -f $(if ($desktop) { 'Windows PowerShell' } else { 'pwsh' }), $PSVersionTable.PSVersion
'relaunch_argv: this host: argv[0] = {0}' -f $hostArgv[0]
'relaunch_argv: this host: executable = {0}' -f $exe

# Scratch directories with spaces in their names: the probe script lives in one,
# the new processes start in another, and -WorkingDirectory names a third.
$base = $env:RUNNER_TEMP
if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
$tmp = Join-Path $base ('relaunch argv ' + [guid]::NewGuid().ToString('N'))
$probeDir = Join-Path $tmp 'probe dir'
$here = Join-Path $tmp 'cwd here'
$start = Join-Path $tmp 'start dir'
foreach ($d in $probeDir, $here, $start) { [void](New-Item -ItemType Directory -Path $d) }
$probe = Join-Path $probeDir 'probe.ps1'
Set-Content -LiteralPath $probe -Encoding ASCII -Value @(
    '$a = [Environment]::GetCommandLineArgs()'
    '"ARGV0=" + $a[0]'
    '"PWD=" + (Split-Path -Leaf $PWD.ProviderPath)'
    'for ($i = 1; $i -lt $a.Count; $i++) { "<" + $a[$i] + ">" }'
)
$probeCmd = 'try { . "' + $probe + '" } catch { "PROBE-FAILED: $_" } #'
$prefix = @('-NoProfile', '-NonInteractive', '-Command', $probeCmd)

# Each check: a name, the launch arguments after argv[0], and the arguments the new
# process must get (the same unless given).
$vscodePath = 'C:\Program Files\Microsoft VS Code\resources\app\out\vs\workbench\contrib\terminal\common\scripts\shellIntegration.ps1'
$checks = @(
    @{ Name = 'vscode payload'; Args = $prefix + @('-noexit', '-command', ('try { . "' + $vscodePath + '" } catch {}')) }
    @{ Name = 'dot-source payload'; Args = $prefix + @('-noexit', '-command', '. "C:\Program Files\x\shellIntegration.ps1"') }
    @{ Name = 'spaces'; Args = $prefix + @('C:\dir with space\s.ps1', 'a b', 'two  spaces', "tab`there", ' lead', 'trail ') }
    @{ Name = 'empty'; Args = $prefix + @('', 'x', '') }
    @{ Name = 'backslashes'; Args = $prefix + @('C:\dir\', 'C:\dir with space\', 'x\\', 'a\b c\', '\\server\share dir\') }
    @{ Name = 'quotes'; Args = $prefix + @('x"y', '"quoted"', 'say "hi there" now', 'a\"b', 'q"\', 'sp q" \\', 'end \"', '""') }
    @{
        Name = 'working directory left out'
        Args = @('-NoProfile', '-RemoveWorkingDirectoryTrailingCharacter', '-WorkingDirectory', "$start!", '-wd', $start,
            '-NonInteractive', '-Command', $probeCmd, '-wd', $start)
        Want = $prefix + @('-wd', $start)
    }
)
# Every whitespace in this one follows an odd number of quotes, so Windows
# PowerShell 5.1 does not quote it, and it arrives split (see _DenRelaunchArgs).
$oddQuotes = @{ Name = 'quoted path with a space'; Args = $prefix + @('"C:\a b"') }
if ($desktop) { $oddQuotes.Want = $prefix + @('"C:\a', 'b"'); $oddQuotes.Name += ' (5.1 splits it, as documented)' }
$checks += $oddQuotes

# The passing styles to try: this host's own, then (pwsh 7.3+) Standard and
# Legacy, where the host's own is another.
$styles = @('')
$own = Get-Variable -Name PSNativeCommandArgumentPassing -ValueOnly -ErrorAction SilentlyContinue
if ($null -ne $own) { $styles += @('Standard', 'Legacy' | Where-Object { $_ -ne "$own" }) }

$total = 0
$failed = 0
Push-Location -LiteralPath $here
try {
    foreach ($style in $styles) {
        if ($style) { $PSNativeCommandArgumentPassing = $style }
        $legacy = _DenLegacyArgPassing
        $passing = Get-Variable -Name PSNativeCommandArgumentPassing -ValueOnly -ErrorAction SilentlyContinue
        if ($null -eq $passing) { $passing = 'legacy (no $PSNativeCommandArgumentPassing)' }
        $label = '{0} passing, {1}' -f $passing, $(if ($legacy) { 'pre-quoted (-Legacy)' } else { 'not pre-quoted' })
        foreach ($c in $checks) {
            $total++
            $want = @($c.Args)
            if ($c.ContainsKey('Want')) { $want = @($c.Want) }
            $sent = @(_DenRelaunchArgs -CommandLineArgs (@($hostArgv[0]) + $c.Args) -Legacy:$legacy)
            # stderr joins the output, so an error shows up in the differences below;
            # 'Continue' keeps Windows PowerShell 5.1 from stopping at its first line.
            $ErrorActionPreference = 'Continue'
            $out = @(& $exe @sent 2>&1 | ForEach-Object { "$_" })
            $rc = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
            $argv0 = @($out | Where-Object { $_ -like 'ARGV0=*' }) -join ' '
            $cwd = @($out | Where-Object { $_ -like 'PWD=*' }) -join ' '
            $got = @($out | Where-Object { $_ -notlike 'ARGV0=*' -and $_ -notlike 'PWD=*' })
            $same = $rc -eq 0 -and $cwd -eq 'PWD=cwd here' -and $got.Count -eq $want.Count
            for ($i = 0; $same -and $i -lt $want.Count; $i++) { $same = $got[$i] -ceq ('<' + $want[$i] + '>') }
            if ($same) {
                'ok   [{0}] {1}' -f $label, $c.Name
                continue
            }
            $failed++
            '::error::relaunch_argv: [{0}] {1}: the new process got other arguments' -f $label, $c.Name
            if (-not $argv0) { $argv0 = 'ARGV0=(not printed)' }
            if (-not $cwd) { $cwd = 'PWD=(not printed)' }
            '  exit code {0}; new process {1}; {2} (want PWD=cwd here)' -f $rc, $argv0, $cwd
            '  sent to the call operator: ' + (($sent | ForEach-Object { '<' + $_ + '>' }) -join ' ')
            for ($i = 0; $i -lt [Math]::Max($want.Count, $got.Count); $i++) {
                $w = if ($i -lt $want.Count) { '<' + $want[$i] + '>' } else { '(none)' }
                $g = if ($i -lt $got.Count) { $got[$i] } else { '(none)' }
                '  {0} [{1}] want {2}' -f $(if ($w -ceq $g) { ' ' } else { '!' }), $i, $w
                '  {0} [{1}] got  {2}' -f $(if ($w -ceq $g) { ' ' } else { '!' }), $i, $g
            }
        }
        if ($style) { Remove-Variable -Name PSNativeCommandArgumentPassing -Scope Script }
    }
    'relaunch_argv: this host: last new process {0}' -f $argv0
} finally {
    Pop-Location
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed) {
    'relaunch_argv: {0} of {1} checks failed' -f $failed, $total
    exit 1
}
'relaunch_argv: all {0} checks passed' -f $total
exit 0
