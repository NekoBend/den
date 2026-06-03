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

# ===== Parallel File Operations =====

# pcp → parallel copy (like cp, last arg is destination)
function pcp {
    param(
        [Parameter(Mandatory, ValueFromRemainingArguments)]
        [string[]]$Paths
    )

    if ($Paths.Count -lt 2) {
        Write-Error "usage: <src...> <dest>"
        return
    }

    $dest = $Paths[-1]
    $sources = $Paths[0..($Paths.Count - 2)]

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
        [Parameter(Mandatory, ValueFromRemainingArguments)]
        [string[]]$Paths
    )

    if ($Paths.Count -lt 2) {
        Write-Error "usage: <src...> <dest>"
        return
    }

    $dest = $Paths[-1]
    $sources = $Paths[0..($Paths.Count - 2)]

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
        [Parameter(Mandatory, ValueFromRemainingArguments)]
        [string[]]$Paths
    )

    if ($Paths.Count -eq 0) {
        Write-Error "usage: [-Force] <path...>"
        return
    }

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
        [Parameter(Mandatory, Position = 0)]
        [string]$Output,
        [Parameter(Mandatory, ValueFromRemainingArguments)]
        [string[]]$Sources
    )

    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        Write-Error "'tar' command not found"
        return
    }

    Write-Host "+ ptar: compressing → $Output"

    switch -Regex ($Output) {
        '\.tar\.gz$|\.tgz$'   { tar czf $Output @Sources; break }
        '\.tar\.bz2$|\.tbz2$' { tar cjf $Output @Sources; break }
        '\.tar\.xz$|\.txz$'   { tar cJf $Output @Sources; break }
        '\.tar$'               { tar cf  $Output @Sources; break }
        default                { Write-Error "unsupported format '$Output'" }
    }
}
