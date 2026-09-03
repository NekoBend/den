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

# _ArTool → the PROGRAM $Tool resolves to on PATH, or $null. The path, not a
# yes/no, because a branch that then invokes the bare name with & would run a
# same-named PowerShell function or alias instead of the program that was
# checked for; callers run what this returns. -CommandType Application is what
# makes it a program: _ArCompressTo starts it through ProcessStartInfo, which
# cannot launch a function anyway. No message is written here — PowerShell
# attributes an error to the function that RAISED it, so it would reach stderr
# as "_ArTool: ..." instead of "archive: ...". Each caller reports its own,
# which is also what lets archive make it terminating while extract keeps going
# through the rest of its archives. _ResolveCmd in _helpers.ps1 draws the same
# Application line for the wrappers; it is not reused because its cache is
# keyed for wrapper resolution and would go on reporting a compressor missing
# after it was installed later in the session.
function _ArTool([string]$Tool) {
  $cmd = Get-Command $Tool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd) { return $cmd.Source }
  return $null
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
function _ArCompressTo([string]$ToolPath, [string]$Source, [string]$Dest) {
  # .NET resolves relative paths against the process directory, which
  # Set-Location never updates; resolve against the PowerShell location first
  # (the same rule mkfile follows).
  $srcFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Source)
  $dstFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Dest)
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $ToolPath
  # ArgumentList passes each argument verbatim, no quoting round-trip. '--'
  # keeps a source named like a switch a path, as the tar branches do.
  foreach ($a in @('-k', '-c', '--', $srcFull)) { $psi.ArgumentList.Add($a) }
  $psi.RedirectStandardOutput = $true
  $psi.UseShellExecute = $false
  # stderr is deliberately NOT redirected: the tool's diagnostics reach the
  # console, and there is no second pipe to deadlock on while stdout drains.
  # Open the destination BEFORE starting the compressor. The other order left
  # a started child with nobody draining its pipe whenever File.Create threw --
  # an unwritable directory, a path that does not exist -- and only the file
  # stream was in a finally, so the process was never waited on or disposed.
  $fs = [System.IO.File]::Create($dstFull)
  try {
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
      $proc.StandardOutput.BaseStream.CopyTo($fs)
      $proc.WaitForExit()
      $code = $proc.ExitCode
    } finally {
      # Reached on every path out, CopyTo throwing included: a child still
      # running at this point is one nothing will ever read from again.
      # HasExited can go true between the test and the call, and that race is
      # exactly the outcome wanted, so the kill is allowed to fail.
      try { if (-not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit() } } catch { }
      $proc.Dispose()
    }
  } finally {
    $fs.Dispose()
  }
  return $code
}

# extract → auto-detect and extract archives
function extract {
  # Every argument is an archive; each is extracted in turn and a failure on
  # one does not hide the others: the per-archive errors are non-terminating,
  # so the loop runs to the end. The final summary IS terminating, which is
  # what carries the failure into the process status -- a plain Write-Error
  # inside a function leaves `pwsh -Command` exiting 0. Callers that want to
  # survive it can catch, as they would any terminating error.
  param([Parameter(ValueFromRemainingArguments)][string[]]$Paths)
  if (-not $Paths -or $Paths.Count -eq 0) {
    Write-Error "usage: extract <file...>" -ErrorAction Stop
  }
  $failed = 0
  foreach ($Path in $Paths) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
      Write-Error "'$Path' is not a file"
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
      # tar spawns zstd itself, in its own process, so a PowerShell function
      # cannot shadow that one and there is no path to hand tar; the resolved
      # path is only used where THIS shell does the invoking.
      '\.tar\.zst$|\.tzst$'   { if (_ArTool 'zstd') { tar --zstd -xf $Path } else { Write-Error 'zstd is not installed'; $ok = $false }; break }
      '\.tar$'                { tar xf $Path; break }
      # Single file: each tool writes the decompressed file next to the
      # archive. gzip/bzip2/xz consume the archive and zstd keeps it — that is
      # each tool's own default, and the POSIX twin behaves the same way. The
      # name is './'-normalised above, so no branch needs a '--' marker.
      '\.gz$'   { $t = _ArTool 'gzip';  if ($t) { & $t -d $Path } else { Write-Error 'gzip is not installed';  $ok = $false }; break }
      '\.bz2$'  { $t = _ArTool 'bzip2'; if ($t) { & $t -d $Path } else { Write-Error 'bzip2 is not installed'; $ok = $false }; break }
      '\.xz$'   { $t = _ArTool 'xz';    if ($t) { & $t -d $Path } else { Write-Error 'xz is not installed';    $ok = $false }; break }
      '\.zst$'  { $t = _ArTool 'zstd';  if ($t) { & $t -d $Path } else { Write-Error 'zstd is not installed';  $ok = $false }; break }
      '\.zip$'                {
        try { Expand-Archive -LiteralPath $Path -DestinationPath . -Force -ErrorAction Stop }
        catch { Write-Error "'$Path': $($_.Exception.Message)"; $ok = $false }
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
      default                 { Write-Error "unsupported format '$Path'"; $ok = $false }
    }
    if ($LASTEXITCODE -ne 0) { $ok = $false }
    if (-not $ok) { $failed++ }
  }
  # Terminating, so the process status is nonzero: a plain Write-Error inside
  # a function leaves `pwsh -Command '... extract bad.zip'` exiting 0, and
  # automation reads that as success. It fires after the loop, so a failure on
  # one archive still does not stop the rest. $LASTEXITCODE cannot carry this —
  # PowerShell does not use it for the process status unless the last command
  # was a native one — and `exit` would end an interactive session.
  if ($failed) { Write-Error "$failed of $($Paths.Count) archives failed" -ErrorAction Stop }
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
  # A directory already sitting at the output path is not an output. Checked
  # for every format, before any of them starts: the single-file branch's
  # Move-Item would otherwise put the temporary INSIDE that directory and
  # report success with no archive written at all, and Compress-Archive -Force
  # deletes the directory before failing on it.
  if (Test-Path -LiteralPath $Output -PathType Container) {
    Write-Error "output '$Output' is a directory" -ErrorAction Stop
  }
  switch -Regex ($Output) {
    '\.tar\.gz$|\.tgz$'    { tar czf $Output -- @Sources; break }
    '\.tar\.bz2$|\.tbz2$'  { tar cjf $Output -- @Sources; break }
    '\.tar\.xz$|\.txz$'    { tar cJf $Output -- @Sources; break }
    # tar shells zstd out for these, so the guard is on zstd, not tar.
    '\.tar\.zst$|\.tzst$'   { if (_ArTool 'zstd') { tar --zstd -cf $Output -- @Sources } else { Write-Error 'zstd is not installed' -ErrorAction Stop }; break }
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
        Write-Error "usage: archive <output.gz|.bz2|.xz|.zst> <one-file>" -ErrorAction Stop
      }
      $src = $Sources[0]
      # Naming the source as the output is refused outright, for the clear
      # message. Comparing the paths the provider resolves them to catches the
      # spellings people actually type ('out.gz' vs './out.gz'); it does NOT
      # establish file identity — a hard link or a chain of symlinks has a
      # different path and the same inode — so it is not what makes this safe.
      # The staging below is. Only Windows compares case-insensitively.
      $outResolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
      $srcResolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($src)
      $sameFile = if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        $outResolved -eq  $srcResolved
      } else {
        $outResolved -ceq $srcResolved
      }
      if ($sameFile) {
        Write-Error "output '$Output' is the source file" -ErrorAction Stop
      }
      $toolPath = _ArTool $tool
      if (-not $toolPath) { Write-Error "$tool is not installed" -ErrorAction Stop }
      # Compress into a temporary sibling of the output and rename that into
      # place only once the compressor has succeeded. The file being written is
      # never the source under any name, so nothing can truncate the source
      # before it is read; a failed run leaves an existing output exactly as it
      # was; and the rename is atomic because the temporary is in the output's
      # own directory. Move-Item reads -Destination literally, so a name
      # holding [ ] * ? still lands where it says.
      # '--' stops each tool's option parsing (all four support it), so a
      # source named like a switch reaches it as a path, as in the tar branches.
      $tmp = "$Output.tmp." + [System.IO.Path]::GetRandomFileName()
      $moved = $false
      try {
        if ($tool -eq 'zstd') {
          # zstd is the only one of the four with -o; the others have none, so
          # _ArCompressTo captures their stdout as raw bytes instead. Both run
          # the resolved program path, never the bare name.
          & $toolPath -q -k -f -o $tmp -- $src
        } else {
          # A .NET exception out of _ArCompressTo (destination unopenable, say)
          # is only STATEMENT-terminating, so on its own it would leave
          # `pwsh -Command` exiting 0 -- the same hole the refusals had.
          # Re-raise it as this function's own terminating error.
          try { $global:LASTEXITCODE = _ArCompressTo $toolPath $src $tmp }
          catch { Write-Error $_.Exception.Message -ErrorAction Stop }
        }
        # A compressor that started and then failed used to leave archive
        # reporting success: the move was skipped, finally deleted the
        # temporary, and nothing was raised. Move-Item was non-terminating
        # too, so a failed publish still set $moved and left no trace. Both
        # terminate now, or the caller is told an archive exists that does not.
        $code = $LASTEXITCODE
        if ($code -ne 0) { Write-Error "$tool exited $code" -ErrorAction Stop }
        Move-Item -LiteralPath $tmp -Destination $Output -Force -ErrorAction Stop
        $moved = $true
      } finally {
        if (-not $moved) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
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
    default                 { Write-Error "unsupported format '$Output'" -ErrorAction Stop }
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
