# functions.ps1 — Utility functions for PowerShell.
# Dot-sourced by Microsoft.PowerShell_profile.ps1.

# ===== File Utils =====

# digest → unified hash function (md5, sha256, sha512)
function digest {
  param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('md5', 'sha256', 'sha512')]
    [string]$Algorithm,
    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$Path
  )
  if (-not $Path -or $Path.Count -eq 0) {
    Write-Error "usage: digest {md5|sha256|sha512} <file...>"
    return
  }
  # One file prints the bare hash (scriptable); several print hash and name
  # per line so the lines stay attributable.
  $failed = 0
  foreach ($p in $Path) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
      Write-Error "digest: '$p' is not a file"
      $failed++
      continue
    }
    $h = (Get-FileHash -LiteralPath $p -Algorithm $Algorithm.ToUpper()).Hash
    if ($Path.Count -gt 1) { "$h  $p" } else { $h }
  }
  if ($failed) { Write-Error "digest: $failed of $($Path.Count) files failed" }
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
  # .NET resolves relative paths against the process directory, which
  # Set-Location never updates; resolve against the PowerShell location first.
  $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  $fs = [System.IO.File]::Create($Path)
  $fs.SetLength($bytes)
  $fs.Close()
  Write-Host "Created $Path ($Size → $bytes bytes)"
}

# _ArHave → guard one branch of extract/archive on the tool it needs. Reports
# "<caller>: <tool> is not installed" and returns $false when the tool is
# absent, so a missing compressor becomes that caller's own per-item failure
# instead of a CommandNotFoundException from the branch, and archive checks it
# BEFORE the redirection that would create the output.
function _ArHave([string]$Caller, [string]$Tool) {
  if (Get-Command $Tool -ErrorAction SilentlyContinue) { return $true }
  Write-Error "${Caller}: $Tool is not installed"
  return $false
}

# _ArRealPath → the filesystem path $Path names, with one symlink hop followed.
# Used to tell whether archive's output and its source are the same file.
# ResolveLinkTarget is 7.2+, so the link is read off .Target, which every pwsh
# 7 has (7.0 types it string[], later ones string; @()[0] takes either). A
# missing file or a broken link just yields the normalised path.
function _ArRealPath([string]$Path) {
  $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
  if ($item -and $item.Target) {
    $target = @($item.Target)[0]
    if ($target) {
      $full = [System.IO.Path]::GetFullPath($target, [System.IO.Path]::GetDirectoryName($full))
    }
  }
  return $full
}

# _ArCompressTo → run a stdout compressor and put its raw bytes in $Dest.
# gzip/bzip2/xz have no -o, and PowerShell only redirects a native command's
# stdout byte-for-byte from 7.4 on: before that the text pipeline re-encodes
# it, and every archive a '> $Dest' produced would be corrupt. den supports
# pwsh 7.0+ (shell/pwsh/parallel.ps1 gates on Major -lt 7), so the bytes are
# copied off the process's own stdout stream, which has no encoding step on
# any version. Letting the tool write its own '<source>.<ext>' next to the
# source and moving that onto $Dest would also avoid the redirect, but it
# destroys a pre-existing file of that name. Returns the tool's exit code.
function _ArCompressTo([string]$Tool, [string]$Source, [string]$Dest) {
  # .NET resolves relative paths against the process directory, which
  # Set-Location never updates; resolve against the PowerShell location first
  # (the same rule mkfile follows).
  $srcFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Source)
  $dstFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Dest)
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $Tool
  # ArgumentList passes each argument verbatim, no quoting round-trip. '--'
  # keeps a source named like a switch a path, as the tar branches do.
  foreach ($a in @('-k', '-c', '--', $srcFull)) { $psi.ArgumentList.Add($a) }
  $psi.RedirectStandardOutput = $true
  $psi.UseShellExecute = $false
  # stderr is deliberately NOT redirected: the tool's diagnostics reach the
  # console, and there is no second pipe to deadlock on while stdout drains.
  $proc = [System.Diagnostics.Process]::Start($psi)
  $fs = [System.IO.File]::Create($dstFull)
  try { $proc.StandardOutput.BaseStream.CopyTo($fs) } finally { $fs.Dispose() }
  $proc.WaitForExit()
  $code = $proc.ExitCode
  $proc.Dispose()
  return $code
}

# extract → auto-detect and extract archives
function extract {
  # Every argument is an archive; each is extracted in turn and a failure on
  # one does not hide the others. Failures are reported per archive and
  # summarized at the end with a (non-terminating) error; the function does
  # not throw.
  param([Parameter(ValueFromRemainingArguments)][string[]]$Paths)
  if (-not $Paths -or $Paths.Count -eq 0) {
    Write-Error "usage: extract <file...>"
    return
  }
  $failed = 0
  foreach ($Path in $Paths) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
      Write-Error "extract: '$Path' is not a file"
      $failed++
      continue
    }
    # Neutralise a leading dash before dispatching, so no branch's tool can
    # read the archive name as a switch (parity with the POSIX twin). The 7z
    # branch adds '@' to this; 7z alone reads that as a listfile.
    if ($Path.StartsWith('-')) { $Path = Join-Path '.' $Path }
    # Each archive's status is taken from ITS OWN command: $LASTEXITCODE is
    # only set by native tools (tar, gzip, 7z, unrar), so it is reset per
    # archive, and the cmdlet path (Expand-Archive) reports through an
    # exception instead.
    $global:LASTEXITCODE = 0
    $ok = $true
    switch -Regex ($Path) {
      '\.tar\.gz$|\.tgz$'    { tar xzf $Path; break }
      '\.tar\.bz2$|\.tbz2$'  { tar xjf $Path; break }
      '\.tar\.xz$|\.txz$'    { tar xJf $Path; break }
      # tar shells zstd out for these, so the guard is on zstd, not tar.
      '\.tar\.zst$|\.tzst$'   { if (_ArHave 'extract' 'zstd') { tar --zstd -xf $Path } else { $ok = $false }; break }
      '\.tar$'                { tar xf $Path; break }
      # Single file: each tool writes the decompressed file next to the
      # archive. gzip/bzip2/xz consume the archive and zstd keeps it — that is
      # each tool's own default, and the POSIX twin behaves the same way. The
      # name is './'-normalised above, so no branch needs a '--' marker.
      '\.gz$'                 { if (_ArHave 'extract' 'gzip')  { gzip -d $Path }  else { $ok = $false }; break }
      '\.bz2$'                { if (_ArHave 'extract' 'bzip2') { bzip2 -d $Path } else { $ok = $false }; break }
      '\.xz$'                 { if (_ArHave 'extract' 'xz')    { xz -d $Path }    else { $ok = $false }; break }
      '\.zst$'                { if (_ArHave 'extract' 'zstd')  { zstd -d $Path }  else { $ok = $false }; break }
      '\.zip$'                {
        try { Expand-Archive -LiteralPath $Path -DestinationPath . -Force -ErrorAction Stop }
        catch { Write-Error "extract: '$Path': $($_.Exception.Message)"; $ok = $false }
        break
      }
      '\.7z$'                 {
        # 7z also reads a leading '@' as a listfile — it would extract the
        # archives named INSIDE that file rather than the file itself. 7z is
        # in neither this image nor tests/shell/Dockerfile, so its '--' marker
        # cannot be exercised; './' neutralises the name without depending on
        # marker support, as archive() does.
        if ($Path.StartsWith('@')) { $Path = Join-Path '.' $Path }
        & 7z x $Path
        break
      }
      '\.rar$'                { & unrar x $Path; break }
      default                 { Write-Error "extract: unsupported format '$Path'"; $ok = $false }
    }
    if ($LASTEXITCODE -ne 0) { $ok = $false }
    if (-not $ok) { $failed++ }
  }
  if ($failed) { Write-Error "extract: $failed of $($Paths.Count) archives failed" }
}

# archive → create archive (format auto-detected from output filename)
function archive {
  param(
    [Parameter(Mandatory)][string]$Output,
    [Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Sources
  )
  # Every argument after $Output is a source, never an option. The '--' in
  # front of them stops the archiver's own option parsing, so a source whose
  # name looks like an option (a '--checkpoint-action=exec=...' that pwsh
  # globbed out of the directory, say) cannot be parsed as one and run; it
  # reaches a native command verbatim. Do not remove it.
  #
  # The output name gets the same treatment once, before dispatching, as the
  # POSIX twin's './' normalisation and as extract does with $Path: an archiver
  # would otherwise read a dash-leading relative name as a switch (7z), or
  # refuse it outright (zstd's -o rejects a value starting with '-').
  if ($Output.StartsWith('-')) { $Output = Join-Path '.' $Output }
  switch -Regex ($Output) {
    '\.tar\.gz$|\.tgz$'    { tar czf $Output -- @Sources; break }
    '\.tar\.bz2$|\.tbz2$'  { tar cjf $Output -- @Sources; break }
    '\.tar\.xz$|\.txz$'    { tar cJf $Output -- @Sources; break }
    # tar shells zstd out for these, so the guard is on zstd, not tar.
    '\.tar\.zst$|\.tzst$'   { if (_ArHave 'archive' 'zstd') { tar --zstd -cf $Output -- @Sources }; break }
    '\.tar$'                { tar cf $Output -- @Sources; break }
    # Single-file compression. Every '.tar.*' form and its 't*' alias is
    # matched above, so only a bare .gz/.bz2/.xz/.zst reaches here, and these
    # four tools compress exactly ONE file: several sources or a directory is a
    # usage error, not something to silently tar up first.
    '\.gz$|\.bz2$|\.xz$|\.zst$' {
      $tool = if     ($Output -match '\.gz$')  { 'gzip'  }
              elseif ($Output -match '\.bz2$') { 'bzip2' }
              elseif ($Output -match '\.xz$')  { 'xz'    }
              else                             { 'zstd'  }
      # Exactly one source, and it must already be a regular file. Testing
      # only for Container was false for a path that does not exist, so a
      # typo'd source got this far and the output was created or truncated
      # before the compressor failed on it.
      if ($Sources.Count -ne 1 -or -not (Test-Path -LiteralPath $Sources[0] -PathType Leaf)) {
        Write-Error "usage: archive <output.gz|.bz2|.xz|.zst> <one-file>"
        break
      }
      $src = $Sources[0]
      # The compressor's output is opened before it reads the source, so an
      # output that IS the source leaves a compressed empty stream where the
      # file this branch promised to keep used to be, and it reported success
      # while doing it. Paths are compared as the provider resolves them, one
      # symlink hop followed, so './out.gz' and a link aliasing the source are
      # caught too. Only Windows compares case-insensitively.
      $sameFile = if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        (_ArRealPath $Output) -eq  (_ArRealPath $src)
      } else {
        (_ArRealPath $Output) -ceq (_ArRealPath $src)
      }
      if ($sameFile) {
        Write-Error "archive: output '$Output' is the source file"
        break
      }
      if (-not (_ArHave 'archive' $tool)) { break }
      # '--' stops each tool's option parsing (all four support it), so a
      # source named like a switch reaches it as a path, as in the tar branches.
      if ($tool -eq 'zstd') {
        # zstd is the only one of the four with -o, and it PROMPTS before
        # clobbering an existing output; -f keeps the branch non-interactive
        # and overwriting, as every other branch is.
        & zstd -q -k -f -o $Output -- $src
      } else {
        # The others have no -o, so their stdout is captured as raw bytes and
        # written to $Output; see _ArCompressTo for why not '> $Output'. The
        # exit code goes where a native command would have left it, so the
        # branch reports failure like every other one.
        $global:LASTEXITCODE = _ArCompressTo $tool $src $Output
      }
      break
    }
    # The array goes in as a parameter value: splatting after a named parameter
    # binds only the first element and leaves the rest as unbindable positionals.
    # -LiteralPath also stops -Path from reading [ ] * ? in a name as a wildcard
    # and archiving whichever file that pattern happens to match.
    '\.zip$'                { Compress-Archive -LiteralPath $Sources -DestinationPath $Output -Force; break }
    # 7z is not in the test image (tests/shell/Dockerfile), so a '--' marker
    # here cannot be exercised; './' neutralises the two source names 7z reads
    # as something other than a path, without depending on any marker support
    # (parity with the POSIX twin). '-x' is a switch; '@list' is a listfile,
    # i.e. 7z archives the paths named INSIDE the file rather than the file.
    '\.7z$'                 {
      $safe = @($Sources | ForEach-Object {
        if ($_.StartsWith('-') -or $_.StartsWith('@')) { Join-Path '.' $_ } else { $_ }
      })
      & 7z a $Output @safe
      break
    }
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
