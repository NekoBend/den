# functions.ps1 — Utility functions for PowerShell.
# Dot-sourced by Microsoft.PowerShell_profile.ps1.

# ===== File Utils =====

# digest → unified hash function (md5, sha256, sha512)
function digest {
  param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('md5', 'sha256', 'sha512')]
    [string]$Algorithm,
    [Parameter(Mandatory, Position = 1)]
    [string]$Path
  )
  (Get-FileHash $Path -Algorithm $Algorithm.ToUpper()).Hash
}

# mkfile → create a dummy file of specified size (e.g. mkfile 10M test.bin)
function mkfile {
  param(
    [Parameter(Mandatory)][string]$Size,
    [Parameter(Mandatory)][string]$Path
  )
  $mult = @{ 'K'=1KB; 'M'=1MB; 'G'=1GB; 'T'=1TB }
  $bytes = if ($Size -match '^(\d+)([KMGTkmgt])$') {
    [int64]$Matches[1] * $mult[$Matches[2].ToUpper()]
  } else {
    [int64]$Size
  }
  $fs = [System.IO.File]::Create($Path)
  $fs.SetLength($bytes)
  $fs.Close()
  Write-Host "Created $Path ($Size → $bytes bytes)"
}

# extract → auto-detect and extract archives
function extract {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path $Path)) {
    Write-Error "'$Path' not found"
    return
  }
  switch -Regex ($Path) {
    '\.tar\.gz$|\.tgz$'    { tar xzf $Path; break }
    '\.tar\.bz2$|\.tbz2$'  { tar xjf $Path; break }
    '\.tar\.xz$|\.txz$'    { tar xJf $Path; break }
    '\.tar\.zst$'           { tar --zstd -xf $Path; break }
    '\.tar$'                { tar xf $Path; break }
    '\.gz$'                 { gzip -d $Path; break }
    '\.zip$'                { Expand-Archive -Path $Path -DestinationPath . -Force; break }
    '\.7z$'                 { & 7z x $Path; break }
    '\.rar$'                { & unrar x $Path; break }
    default                 { Write-Error "unsupported format '$Path'" }
  }
}

# archive → create archive (format auto-detected from output filename)
function archive {
  param(
    [Parameter(Mandatory)][string]$Output,
    [Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Sources
  )
  switch -Regex ($Output) {
    '\.tar\.gz$|\.tgz$'    { tar czf $Output @Sources; break }
    '\.tar\.bz2$|\.tbz2$'  { tar cjf $Output @Sources; break }
    '\.tar\.xz$|\.txz$'    { tar cJf $Output @Sources; break }
    '\.tar\.zst$'           { tar --zstd -cf $Output @Sources; break }
    '\.tar$'                { tar cf $Output @Sources; break }
    '\.zip$'                { Compress-Archive -Path @Sources -DestinationPath $Output -Force; break }
    '\.7z$'                 { & 7z a $Output @Sources; break }
    default                 { Write-Error "unsupported format '$Output'" }
  }
}

# ===== System =====

# display $env:PATH entries one per line
function path {
  $sep = if ($IsWindows -or $env:OS -eq 'Windows_NT') { ';' } else { ':' }
  $env:PATH -split [regex]::Escape($sep) | Where-Object { $_ -ne '' }
}

# show listening TCP ports with process info
function ports {
  if ($IsLinux -or $IsMacOS) {
    if (Get-Command ss -ErrorAction SilentlyContinue) { ss -tlnp }
    elseif (Get-Command netstat -ErrorAction SilentlyContinue) { netstat -tlnp }
    else { Write-Warning "ports: ss/netstat not found" }
  } else {
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
      Sort-Object LocalPort |
      ForEach-Object {
        $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        [PSCustomObject]@{
          Port    = $_.LocalPort
          PID     = $_.OwningProcess
          Process = if ($proc) { $proc.ProcessName } else { '-' }
        }
      } |
      Sort-Object Port -Unique |
      Format-Table -AutoSize
  }
}

# ===== Navigation =====
# Dot-source zoxide's init HERE (global scope) so __zoxide_z reaches the session.
$_z = Initialize-Cache 'zoxide' @('init', 'powershell', '--no-cmd')
if ($_z) { . $_z }
Remove-Variable _z -ErrorAction SilentlyContinue
Remove-Item alias:cd -Force -ErrorAction SilentlyContinue

# cd → wrapper ON: __zoxide_z, OFF: Set-Location
function cd {
  param([Parameter(ValueFromRemainingArguments)]$Rest)
  if ($env:_DEN_WRAPPERS -ne '0' -and (Get-Command __zoxide_z -ErrorAction SilentlyContinue)) {
    __zoxide_z @Rest
  } else {
    if ($Rest.Count -eq 0) { Set-Location ~ } else { Set-Location @Rest }
  }
}

# cdi → wrapper ON: __zoxide_zi (interactive)
function cdi {
  param([Parameter(ValueFromRemainingArguments)]$Rest)
  if ($env:_DEN_WRAPPERS -ne '0' -and (Get-Command __zoxide_zi -ErrorAction SilentlyContinue)) {
    __zoxide_zi @Rest
  } else {
    Write-Warning 'cdi: wrappers are OFF or zoxide is not available'
  }
}

# zd → always __zoxide_z (ignores toggle)
function zd {
  param([Parameter(ValueFromRemainingArguments)]$Rest)
  if (-not (Get-Command __zoxide_z -ErrorAction SilentlyContinue)) {
    Write-Warning 'zoxide is not installed.'; return
  }
  __zoxide_z @Rest
}

# zdi → always __zoxide_zi (ignores toggle)
function zdi {
  param([Parameter(ValueFromRemainingArguments)]$Rest)
  if (-not (Get-Command __zoxide_zi -ErrorAction SilentlyContinue)) {
    Write-Warning 'zoxide is not installed.'; return
  }
  __zoxide_zi @Rest
}

# up N → go up N directories (default: 1)
function up {
  param([int]$N = 1)
  Set-Location (('../' * $N).TrimEnd('/'))
}

# .. / .1–.9 → shorthand for up
function .. { Set-Location .. }
1..9 | ForEach-Object {
  New-Item -Path "Function:\.$_" -Value ([scriptblock]::Create("up $_")) -Force | Out-Null
}

# clear screen
function c {
  Clear-Host
}

# fuzzy find and cd into a subdirectory (requires fzf)
function cdf {
  if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
    Write-Warning "fzf is not installed. Install: winget install junegunn.fzf"
    return
  }
  $dir = if (Get-Command fd -ErrorAction SilentlyContinue) {
    & fd --type d --hidden --exclude .git . | & fzf
  } else {
    [System.IO.Directory]::EnumerateDirectories($PWD.Path, '*', [System.IO.SearchOption]::AllDirectories) | & fzf
  }

  if (-not [string]::IsNullOrWhiteSpace($dir)) {
    Set-Location $dir
  }
}

# mkdir + cd in one step
function mkcd {
  param([string]$Name)
  if ([string]::IsNullOrWhiteSpace($Name)) {
    Write-Error "usage: <dir>"
    return
  }
  New-Item -ItemType Directory -Force -Path $Name | Out-Null
  Set-Location $Name
}

# yazi file manager (tracks cwd on exit, requires yazi)
function y {
  if (-not (Get-Command yazi -ErrorAction SilentlyContinue)) {
    Write-Warning "yazi is not installed. Install: winget install sxyazi.yazi"
    return
  }
  $tmp = [System.IO.Path]::GetTempFileName()
  & yazi @Args --cwd-file="$tmp"
  $cwd = Get-Content $tmp -ErrorAction SilentlyContinue
  if (-not [string]::IsNullOrWhiteSpace($cwd) -and $cwd -ne $PWD.Path) {
    Set-Location $cwd
  }
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

# ===== History / Replay =====

# again → re-run the Nth previous command (default N=1), -Sudo for sudo
function again {
  param(
    [switch]$Sudo,
    [int]$N = 1
  )
  if ($N -lt 1) { Write-Error 'usage: [-Sudo] [N]  (N=positive integer, default 1)'; return }
  # Skip again/sagain entries in history to find the real Nth command
  $history = @(Get-History -Count ($N + 20) | Where-Object { $_.CommandLine -notmatch '^s?again(\s|$)' })
  if ($history.Count -lt $N) { Write-Error "no command at position $N in history"; return }
  $cmd = $history[-$N].CommandLine
  if ($Sudo) {
    Write-Host "+ sudo $cmd"
    $ans = Read-Host 'Re-run with sudo? [Y/n]'
    if ($ans -eq 'n' -or $ans -eq 'N') { return }
    Invoke-Expression "sudo $cmd"
  } else {
    Write-Host "+ $cmd"
    $ans = Read-Host 'Re-run? [Y/n]'
    if ($ans -eq 'n' -or $ans -eq 'N') { return }
    Invoke-Expression $cmd
  }
}

# sagain → backward-compatible wrapper
function sagain {
  param([int]$N = 1)
  again -Sudo -N $N
}

# back → go back to the Nth previous directory (default N=1)
function back {
  param([int]$N = 1)
  if ($N -lt 1) { Write-Error 'usage: [N]  (N=positive integer, default 1)'; return }
  if ($N -ne 1) {
    Write-Error 'only N=1 is supported (uses Set-Location -)'
    Write-Host 'hint: use Push-Location / Pop-Location for deeper history' -ForegroundColor Yellow
    return
  }
  # pwsh keeps a location history that EVERY Set-Location updates (den's cd, up,
  # mkcd, cdf, and zoxide's __zoxide_z), so `Set-Location -` is the reliable `cd -`
  # parity -- the old manual _OLDPWD was only recorded by cd's wrappers-OFF branch.
  # With no history yet, `Set-Location -` is a silent no-op; the catch only fires on
  # a genuine failure (e.g. the previous directory was removed).
  try { Set-Location - -ErrorAction Stop } catch { Write-Error 'no previous directory' }
}
