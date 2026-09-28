# parallel.ps1 — Parallel file operation helpers for PowerShell.
# Dot-sourced by init.ps1. Requires PowerShell 7+.

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warning "parallel.ps1 requires PowerShell 7+ (ForEach-Object -Parallel). Skipping."
    return
}

function _CountEntries {
    param([string[]]$Paths)
    $limit = 10000
    $total = 0
    foreach ($p in $Paths) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            try {
                foreach ($e in [IO.Directory]::EnumerateFileSystemEntries($p, '*', [IO.SearchOption]::AllDirectories)) {
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

# ===== Parallel File Operations =====

# pcp → parallel copy (like cp, last arg is destination)
function pcp {
    # Not Mandatory: a bare `pcp` must print the usage line, not open an
    # interactive "Paths[0]:" prompt (posix parity).
    param(
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Paths = @()
    )

    if ($Paths.Count -lt 2) {
        Write-Error "usage: <src...> <dest>"
        return
    }

    $dest = $Paths[-1]
    $sources = _ResolvePaths $Paths[0..($Paths.Count - 2)]

    if ($sources.Count -gt 1 -and -not (Test-Path -LiteralPath $dest -PathType Container)) {
        Write-Error "'$dest' is not a directory"
        return
    }

    $jobs = [Environment]::ProcessorCount
    $entries = _CountEntries $sources
    Write-Host "+ pcp: $($sources.Count) paths ($entries entries) → $dest ($jobs jobs)"

    $sources | ForEach-Object -Parallel {
        Copy-Item -LiteralPath $_ -Destination $using:dest -Recurse -Force
    } -ThrottleLimit $jobs
}

# pmv → parallel move (like mv, last arg is destination)
function pmv {
    param(
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Paths = @()
    )

    if ($Paths.Count -lt 2) {
        Write-Error "usage: <src...> <dest>"
        return
    }

    $dest = $Paths[-1]
    $sources = _ResolvePaths $Paths[0..($Paths.Count - 2)]

    if ($sources.Count -gt 1 -and -not (Test-Path -LiteralPath $dest -PathType Container)) {
        Write-Error "'$dest' is not a directory"
        return
    }

    $jobs = [Environment]::ProcessorCount
    $entries = _CountEntries $sources
    Write-Host "+ pmv: $($sources.Count) paths ($entries entries) → $dest ($jobs jobs)"

    $sources | ForEach-Object -Parallel {
        Move-Item -LiteralPath $_ -Destination $using:dest -Force
    } -ThrottleLimit $jobs
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
        Write-Error "usage: [-Force|--force] <path...>"
        return
    }
    $Paths = _ResolvePaths $Paths

    $jobs = [Environment]::ProcessorCount
    $entries = _CountEntries $Paths

    if (-not $Force) {
        $reply = Read-Host "prm: remove $($Paths.Count) paths ($entries entries)? [y/N] "
        if ($reply -notmatch '^[yY]$') {
            Write-Error "aborted"
            return
        }
    }

    Write-Host "+ prm: removing $($Paths.Count) paths ($entries entries, $jobs jobs)"

    if ($Force) {
        $Paths | ForEach-Object -Parallel {
            Remove-Item -LiteralPath $_ -Recurse -Force
        } -ThrottleLimit $jobs
    }
    else {
        $Paths | ForEach-Object -Parallel {
            Remove-Item -LiteralPath $_ -Recurse
        } -ThrottleLimit $jobs
    }
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
        Write-Error "usage: <output.tar|.tar.gz|.tgz|.tar.bz2|.tbz2|.tar.xz|.txz> <src...>"
        return
    }
    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        Write-Error "'tar' command not found"
        return
    }

    Write-Host "+ ptar: compressing → $Output"

    # `--` before the sources, as the posix twin does: a source that starts
    # with '-' is a file, never a tar option.
    switch -Regex ($Output) {
        '\.tar\.gz$|\.tgz$'   { tar czf $Output -- @Sources; break }
        '\.tar\.bz2$|\.tbz2$' { tar cjf $Output -- @Sources; break }
        '\.tar\.xz$|\.txz$'   { tar cJf $Output -- @Sources; break }
        '\.tar$'               { tar cf  $Output -- @Sources; break }
        default                { Write-Error "unsupported format '$Output'" }
    }
}
