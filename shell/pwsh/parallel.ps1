# parallel.ps1 — Parallel file operation helpers for PowerShell.
# Dot-sourced by init.ps1. Requires PowerShell 7+.

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warning "parallel.ps1 requires PowerShell 7+ (ForEach-Object -Parallel). Skipping."
    return
}

# _CountEntries → count files/dirs recursively for display. .NET resolves a
# relative path against the process directory, which Set-Location never
# updates, so each path is resolved against the PowerShell location first:
# prm's confirmation used to say "1 entries" for a relative directory, or
# count a different directory of the same name.
function _CountEntries {
    param([string[]]$Paths)
    $limit = 10000
    $total = 0
    foreach ($p in $Paths) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            try {
                $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p)
                foreach ($e in [IO.Directory]::EnumerateFileSystemEntries($full, '*', [IO.SearchOption]::AllDirectories)) {
                    $total++
                    if ($total -gt $limit) { return "${limit}+" }
                }
                $total++
            } catch {
                $total++
            }
        } else {
            $total++
        }
        if ($total -gt $limit) { return "${limit}+" }
    }
    return $total
}

# Each command below expands its wildcard operands with _ResolvePaths
# (_helpers.ps1, which init.ps1 loads first): a function receives `pcp *.md d`
# unexpanded, and every call below uses -LiteralPath.

# _Batches → split $Items round-robin into at most $Count lists, one list per
# ForEach-Object -Parallel item. One item per path made `pcp *.jpg dest` 4x
# slower than a plain Copy-Item: dispatching an item costs far more than
# copying a small file. Each list goes to the pipeline whole (the leading
# comma), so the parallel block receives the list, not its paths one by one.
function _Batches {
    param([string[]]$Items = @(), [int]$Count = 1)
    $n = [math]::Max(1, [math]::Min($Count, $Items.Count))
    $lists = @(for ($i = 0; $i -lt $n; $i++) { , [System.Collections.Generic.List[string]]::new() })
    for ($i = 0; $i -lt $Items.Count; $i++) { $lists[$i % $n].Add($Items[$i]) }
    foreach ($l in $lists) { if ($l.Count -gt 0) { , $l } }
}

# ===== Parallel File Operations =====

# Every refusal below (a usage line, a destination that is not a directory, a
# declined prm, no tar, an unsupported format) is a terminating error, as a
# failure is. A plain Write-Error and return left $? true and `pwsh -Command`
# exiting 0, so `pcp a b nodir && prm -Force a b` removed both files after pcp
# had refused and copied nothing. The posix twins return 1 for each of them.

# pcp → parallel copy (like cp, last arg is destination)
function pcp {
    # Not Mandatory: a bare `pcp` must print the usage line, not open an
    # interactive "Paths[0]:" prompt (posix parity).
    param(
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Paths = @()
    )

    if ($Paths.Count -lt 2) {
        Write-Error "usage: <src...> <dest>" -ErrorAction Stop
    }

    $dest = $Paths[-1]
    $sources = _ResolvePaths $Paths[0..($Paths.Count - 2)]

    if ($sources.Count -gt 1 -and -not (Test-Path -LiteralPath $dest -PathType Container)) {
        Write-Error "'$dest' is not a directory" -ErrorAction Stop
    }

    $jobs = [Environment]::ProcessorCount
    $entries = _CountEntries $sources
    Write-Host "+ pcp: $($sources.Count) paths ($entries entries) → $dest ($jobs jobs)"

    _Batches $sources $jobs | ForEach-Object -Parallel {
        foreach ($p in $_) { Copy-Item -LiteralPath $p -Destination $using:dest -Recurse -Force }
    } -ThrottleLimit $jobs -ErrorVariable failed
    # A path that failed wrote its error from a parallel worker, and none of
    # those reached $? or the process status: `pcp a b dest && prm -Force a b`
    # went on to remove a file that was never copied. -ErrorVariable collects
    # the workers' errors; any at all is terminating, as ptar's tar check is
    # (a plain Write-Error inside a function leaves `pwsh -Command` exiting 0).
    # It counts errors, not paths: one unreadable file can report two.
    if ($failed.Count) { Write-Error "$($failed.Count) error(s)" -ErrorAction Stop }
}

# pmv → parallel move (like mv, last arg is destination)
function pmv {
    param(
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Paths = @()
    )

    if ($Paths.Count -lt 2) {
        Write-Error "usage: <src...> <dest>" -ErrorAction Stop
    }

    $dest = $Paths[-1]
    $sources = _ResolvePaths $Paths[0..($Paths.Count - 2)]

    if ($sources.Count -gt 1 -and -not (Test-Path -LiteralPath $dest -PathType Container)) {
        Write-Error "'$dest' is not a directory" -ErrorAction Stop
    }

    $jobs = [Environment]::ProcessorCount
    $entries = _CountEntries $sources
    Write-Host "+ pmv: $($sources.Count) paths ($entries entries) → $dest ($jobs jobs)"

    _Batches $sources $jobs | ForEach-Object -Parallel {
        foreach ($p in $_) { Move-Item -LiteralPath $p -Destination $using:dest -Force }
    } -ThrottleLimit $jobs -ErrorVariable failed
    # Terminating when any path failed: see pcp.
    if ($failed.Count) { Write-Error "$($failed.Count) error(s)" -ErrorAction Stop }
}

# prm → parallel remove with interactive confirmation by default
function prm {
    param(
        [switch]$Force,
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Paths = @()
    )

    # posix parity: `--force` (the long form its usage advertises) is accepted
    # only as the leading word, like the posix parser.
    if ($Paths.Count -gt 0 -and $Paths[0] -eq '--force') {
        $Force = $true
        $Paths = @($Paths | Select-Object -Skip 1)
    }
    if ($Paths.Count -eq 0) {
        Write-Error "usage: [-Force|--force] <path...>" -ErrorAction Stop
    }
    $Paths = _ResolvePaths $Paths

    $jobs = [Environment]::ProcessorCount
    $entries = _CountEntries $Paths

    if (-not $Force) {
        $reply = Read-Host "prm: remove $($Paths.Count) paths ($entries entries)? [y/N] "
        if ($reply -notmatch '^[yY]$') {
            Write-Error "aborted" -ErrorAction Stop
        }
    }

    Write-Host "+ prm: removing $($Paths.Count) paths ($entries entries, $jobs jobs)"

    # -Force in both modes: the [y/N] above IS the safety check, as it is for
    # the posix twin's `rm -r`. Without it Remove-Item refuses hidden items
    # (every dotfile on Linux/macOS, Hidden-attribute ones such as .git on
    # Windows), so a confirmed prm deleted everything else in a tree and then
    # stopped, leaving the hidden entries and their parent directories behind.
    _Batches $Paths $jobs | ForEach-Object -Parallel {
        foreach ($p in $_) { Remove-Item -LiteralPath $p -Recurse -Force }
    } -ThrottleLimit $jobs -ErrorVariable failed
    # Terminating when any path failed: see pcp.
    if ($failed.Count) { Write-Error "$($failed.Count) error(s)" -ErrorAction Stop }
}

# ptar → compress using tar (available on Windows 10+)
function ptar {
    param(
        [Parameter(Position = 0)]
        [string]$Output,
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Sources = @()
    )

    if (-not $Output -or $Sources.Count -eq 0) {
        Write-Error "usage: <output.tar|.tar.gz|.tgz|.tar.bz2|.tbz2|.tar.xz|.txz> <src...>" -ErrorAction Stop
    }
    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        Write-Error "'tar' command not found" -ErrorAction Stop
    }

    Write-Host "+ ptar: compressing → $Output"

    $flag = switch -Regex ($Output) {
        '\.tar\.gz$|\.tgz$'   { '-z'; break }
        '\.tar\.bz2$|\.tbz2$' { '-j'; break }
        '\.tar\.xz$|\.txz$'   { '-J'; break }
        '\.tar$'               { ''; break }
        default                { Write-Error "unsupported format '$Output'" -ErrorAction Stop }
    }
    if (Test-Path -LiteralPath $Output -PathType Container) {
        Write-Error "output '$Output' is a directory" -ErrorAction Stop
    }
    # GNU tar cannot tell that it is reading its own archive when it
    # compresses (it writes to the compressor through a pipe), so a rerun of
    # `ptar backup.tgz .` stored the previous archive, and the one being
    # written, inside the new one, and a failed tar left a cut archive where
    # the old one had been. As in the posix twin and in archive, tar writes
    # into a staging folder beside the output, which it leaves out by its
    # random name (letters and digits, so no pattern to tar), and an existing
    # output waits in that folder while tar runs. The new archive takes the
    # output's name only once tar has succeeded; on failure the old one is put
    # back, or, when even that fails, kept there and named. The folder is made
    # before tar starts, so nothing new appears in a folder tar is reading
    # (GNU tar exits 1 on "file changed as we read it"). File.Move never
    # replaces anything, so neither archive can land INSIDE a directory made
    # at the output meanwhile. A source that is the output itself
    # (`ptar all.tgz *` run again) is dropped first: moved aside, it is a name
    # tar cannot find. On Windows one spelled like the output but for case is
    # the output in an ordinary folder, but a file of its own in a
    # case-sensitive one (WSL makes them), and was dropped without a word
    # there: _DenOneEntry asks the folder, and a source it cannot tell about
    # is refused, naming both.
    $sess = $ExecutionContext.SessionState.Path
    $outFull = $sess.GetUnresolvedProviderPathFromPSPath($Output)
    $onWindows = ($env:OS -eq 'Windows_NT' -or $IsWindows)
    $outThere = $null -ne (Get-Item -LiteralPath $Output -Force -ErrorAction SilentlyContinue)
    $srcs = @(foreach ($s in $Sources) {
        $full = $sess.GetUnresolvedProviderPathFromPSPath($s)
        if ($full -ceq $outFull) { continue }
        if ($onWindows -and $outThere -and
            [string]::Equals($full, $outFull, [System.StringComparison]::OrdinalIgnoreCase) -and
            $null -ne (Get-Item -LiteralPath $s -Force -ErrorAction SilentlyContinue)) {
            $one = try { _DenOneEntry $full $outFull } catch { Write-Error $_.Exception.Message -ErrorAction Stop }
            if ($one) { continue }
        }
        $s
    })
    if ($srcs.Count -eq 0) { Write-Error "no source besides the output '$Output'" -ErrorAction Stop }
    $stageName = '.ptar.' + ([System.IO.Path]::GetRandomFileName() -replace '\.', '')
    $parent = Split-Path -Path $Output -Parent
    $stage = if ($parent) { Join-Path $parent $stageName } else { $stageName }
    $tmp = Join-Path $stage 'archive'
    $prev = Join-Path $stage 'previous'
    # .NET resolves relative paths against the process directory, which
    # Set-Location never updates (hence $outFull above too).
    $stageFull = $sess.GetUnresolvedProviderPathFromPSPath($stage)
    $tmpFull = $sess.GetUnresolvedProviderPathFromPSPath($tmp)
    $prevFull = $sess.GetUnresolvedProviderPathFromPSPath($prev)
    if ([System.IO.Directory]::Exists($stageFull) -or [System.IO.File]::Exists($stageFull)) {
        Write-Error "cannot create a temporary directory '$stage'" -ErrorAction Stop
    }
    try { $null = [System.IO.Directory]::CreateDirectory($stageFull) }
    catch { Write-Error "cannot create a temporary directory '$stage': $($_.Exception.GetBaseException().Message)" -ErrorAction Stop }
    $aside = $false
    if ($null -ne (Get-Item -LiteralPath $Output -Force -ErrorAction SilentlyContinue)) {
        try { [System.IO.File]::Move($outFull, $prevFull) }
        catch {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            Write-Error "cannot move '$Output' aside: $($_.Exception.GetBaseException().Message)" -ErrorAction Stop
        }
        $aside = $true
    }
    # `--` before the sources, as the posix twin does: a source that starts
    # with '-' is a file, never a tar option.
    $tarArgs = @('-c')
    if ($flag) { $tarArgs += $flag }
    $tarArgs += @('-f', $tmp, "--exclude=$stageName", '--') + $srcs
    $global:LASTEXITCODE = 0
    $done = $false
    try {
        tar @tarArgs
        # tar's own status: a source it could not read left a partial archive
        # and ptar still succeeded. Terminating, because a plain Write-Error
        # inside a function leaves `pwsh -Command` exiting 0 (posix parity).
        if ($LASTEXITCODE -ne 0) { Write-Error "tar exited $LASTEXITCODE" -ErrorAction Stop }
        try { [System.IO.File]::Move($tmpFull, $outFull) }
        catch { Write-Error "cannot put the archive at '$Output': $($_.Exception.GetBaseException().Message)" -ErrorAction Stop }
        $done = $true
    } finally {
        if (-not $done -and $aside) { try { [System.IO.File]::Move($prevFull, $outFull) } catch { } }
        if (-not $done -and $aside -and $null -ne (Get-Item -LiteralPath $prev -Force -ErrorAction SilentlyContinue)) {
            # Not terminating: the error on its way out is the one that failed.
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Write-Error "previous '$Output' kept at $prev" -ErrorAction Continue
        } else {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
