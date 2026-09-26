# functions.ps1 — Utility functions for PowerShell.
# Dot-sourced by Microsoft.PowerShell_profile.ps1.

# ===== File Utils =====

# _DgUsage → dg's usage text, one string per line. dg -h prints it; a refusal
# carries it as its error message.
function _DgUsage {
  'usage: dg [algo] <file...>        hash; one file prints the bare hash'
  '       dg [algo] <file> <hash>    check a file against an expected hash'
  '       dg -e [algo] <a> <b>       do a and b have the same content?'
  '       dg -c <sumsfile...>        verify checksum files (GNU or BSD lines)'
  "algo: md5|sha256|sha512 or 5|256|512; default sha256, or the one the"
  "<hash>'s length implies. '--' (quoted: PowerShell eats a bare --) ends algo"
  "parsing. digest = dg."
}

# _DgAlgo → the algorithm an algo token names (md5, sha256, sha512; 5, 256 and
# 512 are short for them), or $null when $Token is not one. The table's keys
# are case-insensitive, as the old ValidateSet was.
function _DgAlgo([string]$Token) {
  $algos = @{ 'md5' = 'md5'; '5' = 'md5'; 'sha256' = 'sha256'; '256' = 'sha256'; 'sha512' = 'sha512'; '512' = 'sha512' }
  return $algos[$Token]
}

# _DgByLength → the algorithm whose hex digest is $Length characters long.
function _DgByLength([int]$Length) {
  switch ($Length) { 32 { 'md5' } 64 { 'sha256' } 128 { 'sha512' } }
}

# _DgExpected → $Text read as an expected hash: trimmed, lowercased and with an
# optional "md5:" / "sha256:" / "sha512:" prefix taken off (blanks after it
# too, as in "SHA256: <hex>"), it must be 32, 64 or 128 hex digits. Returns Hex and Prefix (the prefix's algorithm, or ''),
# or $null when it is not a hash.
function _DgExpected([string]$Text) {
  $t = $Text.Trim().ToLowerInvariant()
  $prefix = ''
  if ($t -match '^(md5|sha256|sha512):(.*)$') {
    $prefix = $Matches[1]
    $t = $Matches[2].Trim()
  }
  if ($t -notmatch '^[0-9a-f]+$' -or -not (_DgByLength $t.Length)) { return $null }
  [pscustomobject]@{ Hex = $t; Prefix = $prefix }
}

# _DgSumsLine → one checksum-file line: GNU "<hash>  <name>" or "<hash> *<name>",
# or BSD "SHA256 (<name>) = <hash>" (MD5, SHA512 alike). Returns $null for a
# blank or # comment line; otherwise Algo (from the tag or the hash's length),
# Hash (lowercase) and Name, with Algo $null when the line is malformed.
function _DgSumsLine([string]$Line) {
  $l = $Line.TrimEnd("`r")
  if ($l.Trim() -eq '' -or $l.StartsWith('#')) { return $null }
  $malformed = [pscustomobject]@{ Algo = $null; Hash = $null; Name = $null }
  # GNU starts a line with a backslash when it escaped the name in it.
  $escaped = $l.StartsWith('\')
  if ($escaped) { $l = $l.Substring(1) }
  # The greedy name makes the LAST ") = " end it, so a name may hold one.
  if ($l -cmatch '^(MD5|SHA256|SHA512) \((.+)\) = ([0-9A-Fa-f]+)$') {
    $tag = $Matches[1].ToLowerInvariant(); $name = $Matches[2]; $hash = $Matches[3]
  } elseif ($l -match '^([0-9A-Fa-f]+) [ *](.+)$') {
    $tag = $null; $hash = $Matches[1]; $name = $Matches[2]
  } else {
    return $malformed
  }
  $algo = _DgByLength $hash.Length
  # A BSD tag has to agree with the hash's length.
  if (-not $algo -or ($tag -and $tag -ne $algo)) { return $malformed }
  if ($escaped) {
    # Undo GNU's escaping (\\, \n, \r); NUL stands in for a real backslash
    # meanwhile, as no file name can hold one.
    $name = $name.Replace('\\', "`0").Replace('\n', "`n").Replace('\r', "`r").Replace("`0", '\')
  }
  [pscustomobject]@{ Algo = $algo; Hash = $hash.ToLowerInvariant(); Name = $name }
}

# dg → file hashes (md5, sha256, sha512): print them, check a file against an
# expected hash, compare two files, or verify checksum files. See _DgUsage for
# the forms; digest is an alias for it.
function dg {
  # No hand-written "dg: " prefix on any error here: PowerShell already
  # attributes an error to the function that RAISED it, so one would reach
  # stderr as "dg: dg: ..." (same reason extract/archive dropped theirs). The
  # _Dg helpers raise none for the same reason; they would name themselves.
  #
  # -e and -c are declared as aliases, so they bind by exact name. As a mere
  # prefix, -e would also match the common -ErrorAction / -ErrorVariable,
  # which an advanced function has too (pwsh 7 settles that for -Equal; the
  # alias does not depend on it). -c matches no common parameter and has its
  # alias for symmetry.
  param(
    [Alias('e')][switch]$Equal,
    [Alias('c')][switch]$Check,
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]]$Operand
  )
  $ops = @($Operand | Where-Object { $null -ne $_ })
  if ($ops.Count -and ($ops[0] -eq '-h' -or $ops[0] -eq '--help')) { _DgUsage; return }
  if ($Equal -and $Check) { Write-Error '-e and -c cannot be combined' -ErrorAction Stop }
  # PowerShell's binder removes a bare --, so only a quoted '--' gets here; it
  # ends algo parsing, so `dg '--' 256` hashes a file named 256.
  $i = 0
  $algo = $null
  if ($ops.Count -gt $i -and $ops[$i] -eq '--') {
    $i++
  } elseif ($ops.Count -gt $i) {
    $algo = _DgAlgo $ops[$i]
    if ($algo) {
      $i++
      if ($ops.Count -gt $i -and $ops[$i] -eq '--') { $i++ }
    }
  }
  $rest = @()
  if ($ops.Count -gt $i) { $rest = @($ops[$i..($ops.Count - 1)]) }
  $usage = (_DgUsage) -join "`n"

  # The failures below that must reach the process status are terminating
  # errors: a plain Write-Error inside a function leaves `pwsh -Command '...'`
  # exiting 0, and automation reads that as success. Per-item errors stay
  # non-terminating, so one bad item does not hide the rest.
  if ($Check) {
    if ($algo) { Write-Error '-c takes no algo (each line names its own)' -ErrorAction Stop }
    if (-not $rest.Count) { Write-Error $usage -ErrorAction Stop }
    $ok = 0; $bad = 0; $miss = 0; $unread = 0
    foreach ($sums in $rest) {
      $lines = $null
      if (Test-Path -LiteralPath $sums -PathType Leaf) {
        try { $lines = @(Get-Content -LiteralPath $sums -Encoding UTF8 -ErrorAction Stop) } catch { $lines = $null }
      }
      if ($null -eq $lines) {
        Write-Error "'$sums' is not a readable file"
        $unread++
        continue
      }
      $malformed = 0
      foreach ($line in $lines) {
        $entry = _DgSumsLine $line
        if ($null -eq $entry) { continue }
        if (-not $entry.Algo) { $malformed++; continue }
        # Names are relative to the current location, as with sha256sum -c.
        $name = $entry.Name
        if (-not (Test-Path -LiteralPath $name)) { "${name}: MISSING"; $miss++; continue }
        $h = $null
        try {
          $h = (Get-FileHash -LiteralPath $name -Algorithm $entry.Algo.ToUpper() -ErrorAction Stop).Hash
        } catch {
          Write-Error "'$name': $($_.Exception.Message)"
        }
        # -eq ignores case, and Get-FileHash answers in uppercase.
        if ($h -and $h -eq $entry.Hash) { "${name}: OK"; $ok++ } else { "${name}: FAILED"; $bad++ }
      }
      if ($malformed) { [Console]::Error.WriteLine("dg: '$sums': $malformed malformed line(s) ignored") }
    }
    $total = $ok + $bad + $miss
    if (-not $total) { Write-Error 'no checksum lines found' -ErrorAction Stop }
    if ($bad + $miss + $unread) {
      $msg = "$bad FAILED, $miss MISSING of $total checked"
      if ($unread) { $msg += ", $unread sums file(s) unreadable" }
      Write-Error $msg -ErrorAction Stop
    }
    return
  }

  if ($Equal) {
    if ($rest.Count -ne 2) { Write-Error 'usage: dg -e [algo] <a> <b>' -ErrorAction Stop }
    if (-not $algo) { $algo = 'sha256' }
    $hashes = @()
    foreach ($p in $rest) {
      if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        Write-Error "'$p' is not a file"
        continue
      }
      try {
        $hashes += (Get-FileHash -LiteralPath $p -Algorithm $algo.ToUpper() -ErrorAction Stop).Hash.ToLowerInvariant()
      } catch {
        Write-Error "'$p': $($_.Exception.Message)"
      }
    }
    $a = $rest[0]; $b = $rest[1]
    if ($hashes.Count -ne 2) { Write-Error "cannot compare '$a' and '$b'" -ErrorAction Stop }
    if ($hashes[0] -eq $hashes[1]) { "SAME  $a  $b"; return }
    "DIFFERENT  $a  $b"
    "  $($hashes[0])  $a"
    "  $($hashes[1])  $b"
    Write-Error "'$a' and '$b' differ" -ErrorAction Stop
  }

  # Two operands where the second is no path but reads as a hash: check the
  # first against it, with the algorithm the hash's length implies.
  $expected = $null
  if ($rest.Count -eq 2) {
    $expected = _DgExpected $rest[1]
    if ($expected -and (Test-Path -LiteralPath $rest[1])) { $expected = $null }
  }
  if ($expected) {
    $f = $rest[0]
    $byLength = _DgByLength $expected.Hex.Length
    foreach ($named in @($algo, $expected.Prefix)) {
      if ($named -and $named -ne $byLength) {
        Write-Error "the expected hash is $($expected.Hex.Length) hex digits ($byLength), not $named" -ErrorAction Stop
      }
    }
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Write-Error "'$f' is not a file" -ErrorAction Stop }
    try {
      $h = (Get-FileHash -LiteralPath $f -Algorithm $byLength.ToUpper() -ErrorAction Stop).Hash.ToLowerInvariant()
    } catch {
      Write-Error "'$f': $($_.Exception.Message)" -ErrorAction Stop
    }
    if ($h -eq $expected.Hex) { "OK  $f"; return }
    "MISMATCH  $f"
    "  expected $($expected.Hex)"
    "  actual   $h"
    Write-Error "'$f' does not match the expected hash" -ErrorAction Stop
  }

  if (-not $rest.Count) { Write-Error $usage -ErrorAction Stop }
  if (-not $algo) { $algo = 'sha256' }
  # One file prints the bare hash (scriptable); several print hash and name
  # per line so the lines stay attributable.
  #
  # The per-file errors are non-terminating, so one bad path does not swallow
  # the hashes of the files after it; the final summary IS terminating, which
  # is what carries the failure into the process status. Same shape as
  # extract.
  $failed = 0
  foreach ($p in $rest) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
      Write-Error "'$p' is not a file"
      $failed++
      continue
    }
    # A file that exists can still not be readable, and Get-FileHash reports
    # that non-terminatingly: without this the loop would print an empty line
    # for it and count it as a success.
    try {
      $h = (Get-FileHash -LiteralPath $p -Algorithm $algo.ToUpper() -ErrorAction Stop).Hash
    } catch {
      Write-Error "'$p': $($_.Exception.Message)"
      $failed++
      continue
    }
    if ($rest.Count -gt 1) { "$h  $p" } else { $h }
  }
  # Terminating, so the process status is nonzero. It fires after the loop, so
  # a failure on one file still does not stop the rest. $LASTEXITCODE cannot
  # carry this -- PowerShell does not use it for the process status unless the
  # last command was a native one -- and `exit` would end an interactive
  # session.
  if ($failed) { Write-Error "$failed of $($rest.Count) files failed" -ErrorAction Stop }
}

# digest → dg under its older name; every form works the same.
Set-Alias digest dg

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

# _ArRegularFile → is $Path an existing REGULAR file? Test-Path -PathType Leaf
# only means "not a container", so a FIFO, a character device or a socket all
# pass it, and `archive out.zst /dev/zero` then runs until the disk is full.
# The POSIX twin gets this right for free with [ -f ], so on Unix this asks the
# same question the same way: 'test -f' follows a symlink to its target and is
# true only for a regular file. PowerShell's own UnixMode cannot stand in for
# it -- measured on 7.6.3, a FIFO reports "-rw-r--r--", the same leading '-' as
# a regular file -- so it is only the fallback for a system with no /bin/sh,
# where it at least rules out devices, sockets and directories.
function _ArRegularFile([string]$Path) {
  $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  # Rules out a directory and a path that is not there at all, on every OS.
  if (-not [System.IO.File]::Exists($full)) { return $false }
  if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    $attrs = [System.IO.File]::GetAttributes($full)
    return -not ($attrs.HasFlag([System.IO.FileAttributes]::Device) -or
                 $attrs.HasFlag([System.IO.FileAttributes]::Directory))
  }
  if (Test-Path -LiteralPath '/bin/sh' -PathType Leaf) {
    & /bin/sh -c 'test -f "$1"' _ $full
    return ($LASTEXITCODE -eq 0)
  }
  $mode = (Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue).UnixMode
  if ($mode) { return $mode.StartsWith('-') }
  return $true
}

# _ArSameFile → do $A and $B name the same file? Comparing resolved path
# strings is not enough, and here that matters: on a case-insensitive volume
# (macOS by default) 'self.gz' and 'SELF.GZ' are ONE directory entry, so a
# case-sensitive compare says they differ and the staged output is renamed over
# the source, which was supposed to be kept. Hard links and symlink chains fold
# the same way. Ask the filesystem instead -- 'test -ef' compares device and
# inode, exactly what the POSIX twin uses -- and keep the string compare only
# as a fast path that answers the common case without a fork. Windows has no
# such test; NTFS is case-insensitive, so comparing full paths that way is the
# right question there.
# _ArVolumeRelative → a Windows path with its volume root dropped, so a full
# path can be compared with the volume-relative names a hard link reports.
function _ArVolumeRelative([string]$Path) {
  $root = try { [System.IO.Path]::GetPathRoot($Path) } catch { '' }
  if ($root -and $Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
    return '\' + $Path.Substring($root.Length).TrimStart('\', '/')
  }
  return '\' + $Path.TrimStart('\', '/')
}

# _ArLinkTarget → what a symlink points at, else the item's own path.
# ResolveLinkTarget is 7.2+; .Target is the one-hop stand-in on 7.0/7.1.
function _ArLinkTarget($Item) {
  try {
    if ($Item.LinkType -eq 'SymbolicLink') {
      if ($Item | Get-Member -Name ResolveLinkTarget) {
        $t = $Item.ResolveLinkTarget($true)
        if ($t) { return $t.FullName }
      }
      $t = @($Item.Target)[0]
      if ($t) {
        return [System.IO.Path]::GetFullPath($t, [System.IO.Path]::GetDirectoryName($Item.FullName))
      }
    }
  } catch { }
  return $Item.FullName
}

function _ArSameFile([string]$A, [string]$B) {
  $fa = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($A)
  $fb = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($B)
  if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    if ($fa -ceq $fb) { return $true }
    # -ef needs both to exist; an output that is not there yet collides with
    # nothing, and skipping the fork is the common case.
    if (-not (Test-Path -LiteralPath $fb)) { return $false }
    if (-not (Test-Path -LiteralPath '/bin/sh' -PathType Leaf)) { return $false }
    & /bin/sh -c 'test "$1" -ef "$2"' _ $fa $fb
    return ($LASTEXITCODE -eq 0)
  }
  # Windows. The case-insensitive compare settles the spellings people type,
  # NTFS being case-insensitive, and is only the fast path: Windows has hard
  # links and symlinks too, and no -ef to ask about them.
  if ($fa -eq $fb) { return $true }
  if (-not (Test-Path -LiteralPath $fb)) { return $false }
  $ia = Get-Item -LiteralPath $fa -Force -ErrorAction SilentlyContinue
  $ib = Get-Item -LiteralPath $fb -Force -ErrorAction SilentlyContinue
  if (-not $ia -or -not $ib) { return $false }
  # A symlink names another path: compare what each one actually points at.
  $ra = _ArLinkTarget $ia
  $rb = _ArLinkTarget $ib
  if ($ra -eq $rb) { return $true }
  # A hard link is one file under several names, and on Windows .Target
  # enumerates the OTHER names for LinkType 'HardLink'. They come back
  # volume-relative, so both sides are compared with the root dropped;
  # -contains is case-insensitive, which is what NTFS wants.
  foreach ($side in @(@($ia, $rb), @($ib, $ra))) {
    $item = $side[0]
    $other = _ArVolumeRelative $side[1]
    if ($item.LinkType -eq 'HardLink' -and $item.Target) {
      $names = @($item.Target | ForEach-Object { _ArVolumeRelative $_ })
      if ($names -contains $other) { return $true }
    }
  }
  return $false
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
        # not in tests/shell/Dockerfile, so its '--' marker cannot be
        # exercised in CI; './' neutralises the name without depending on
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
      # Exactly one source, and it must already be a REGULAR file -- see
      # _ArRegularFile for why "not a container" was not enough.
      if ($Sources.Count -ne 1 -or -not (_ArRegularFile $Sources[0])) {
        Write-Error "usage: archive <output.gz|.bz2|.xz|.zst> <one-file>" -ErrorAction Stop
      }
      $src = $Sources[0]
      # Naming the source as the output is refused. Staging keeps the source
      # readable while the archive is built, but the final rename still lands
      # ON the output, so where the output and the source are one directory
      # entry -- a case-insensitive volume, most obviously -- the source would
      # be replaced by its own compressed form despite the promise to keep it.
      # _ArSameFile settles that by device and inode, not by path text.
      if (_ArSameFile $src $Output) {
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

# xt / pk → short names for extract / archive. Aliases (as `snip` is for
# snippet), not wrapper functions: an alias invokes the long function itself, so
# parameter binding (-Output/-Sources, common parameters), tab completion, the
# terminating errors, $? and the "extract:"/"archive:" error prefix are exactly
# those of the long name. A PowerShell alias also works outside the prompt,
# unlike a bash one.
Set-Alias xt extract
Set-Alias pk archive

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
  _DenDirMoved $MyInvocation
}

# cdi → wrapper ON: __zoxide_zi (interactive)
function cdi {
  param([Parameter(ValueFromRemainingArguments)]$Rest)
  if ($env:_DEN_WRAPPERS -ne '0' -and (Get-Command __zoxide_zi -ErrorAction SilentlyContinue)) {
    __zoxide_zi @Rest
    _DenDirMoved $MyInvocation
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
  _DenDirMoved $MyInvocation
}

# zdi → always __zoxide_zi (ignores toggle)
function zdi {
  param([Parameter(ValueFromRemainingArguments)]$Rest)
  if (-not (Get-Command __zoxide_zi -ErrorAction SilentlyContinue)) {
    Write-Warning 'zoxide is not installed.'; return
  }
  __zoxide_zi @Rest
  _DenDirMoved $MyInvocation
}

# up N → go up N directories (default: 1)
function up {
  param([int]$N = 1)
  Set-Location (('../' * $N).TrimEnd('/'))
  _DenDirMoved $MyInvocation
}

# .. / .1–.9 → shorthand for up
# (.N records the move itself: up, called from it, is not typed at the prompt)
function .. { Set-Location ..; _DenDirMoved $MyInvocation }
1..9 | ForEach-Object {
  New-Item -Path "Function:\.$_" -Value ([scriptblock]::Create("up $_; _DenDirMoved `$MyInvocation")) -Force | Out-Null
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
    _DenDirMoved $MyInvocation
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
  _DenDirMoved $MyInvocation
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
    _DenDirMoved $MyInvocation
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

# ===== Directory History (back / fwd) =====
# Browser-style history for this session, never written to disk.
# $global:_DenDirBack / _DenDirFwd hold locations nearest first, and _DenDirLast
# is the location the history saw last. A move pushes the location it left onto
# the back list and clears the forward list, as a browser does. What counts as a
# move is where the session is at each prompt (_DenDirHookPrompt, which init.ps1
# installs), whatever took it there (den's cd, Set-Location, Push-/Pop-Location,
# mkcd, up, cdf, y), as bash does from PROMPT_COMMAND: two Set-Location on one
# line are one move, and a script counts only by where it leaves the session,
# not by the moves it makes on the way (LocationChangedAction, PowerShell 6.1+,
# is not used: it fires for each of those). den's navigation commands typed at
# the prompt also record at once (_DenDirMoved), so several on one line are each
# kept. back/fwd walk the lists themselves. The state is $global:, not $script:
# like _helpers.ps1's caches: den's commands also run inside scripts, and there
# $script: names the running script's scope.
if ($null -eq $global:_DenDirBack) {
  $global:_DenDirBack = [System.Collections.Generic.List[string]]::new()
  $global:_DenDirFwd = [System.Collections.Generic.List[string]]::new()
  $global:_DenDirLast = $PWD.Path
}

# _DenDirSame <a> <b> - the same location? Windows paths compare case-insensitively.
function _DenDirSame([string]$A, [string]$B) {
  $cmp = if (_OnWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  [string]::Equals($A, $B, $cmp)
}

# _DenDirRecord - note a change of location (at the prompt, or from _DenDirMoved).
function _DenDirRecord {
  $here = $PWD.Path
  if (_DenDirSame $here $global:_DenDirLast) { return }
  if ($global:_DenDirLast) {
    # A consecutive duplicate is kept once, and only the nearest 50 entries are
    # kept at all.
    $back = $global:_DenDirBack
    if ($back.Count -eq 0 -or -not (_DenDirSame $back[0] $global:_DenDirLast)) {
      $back.Insert(0, $global:_DenDirLast)
      if ($back.Count -gt 50) { $back.RemoveRange(50, $back.Count - 50) }
    }
    $global:_DenDirFwd.Clear()
  }
  $global:_DenDirLast = $here
}

# _DenDirMoved <invocation> - den's navigation commands (cd, cdi, zd, zdi, up, ..,
# .1-.9, cdf, mkcd, y) call this with their $MyInvocation once they have moved.
# Typed at the prompt (CommandOrigin Runspace), the move is recorded now; run by
# a script or another function (Internal), it is left to the prompt, so that
# script's moves stay net.
function _DenDirMoved([System.Management.Automation.InvocationInfo]$Invocation) {
  if ($Invocation.CommandOrigin -eq 'Runspace') { _DenDirRecord }
}

# _DenDirGo <back|fwd> <N> - move N entries along that list (N already
# validated). Returns an error message, or nothing on success, so the caller
# writes the error under its own name. The entries passed over and the location
# being left go to the other list, nearest first, so `back 3` then `fwd 3`
# returns to the start.
function _DenDirGo([string]$List, [string]$N) {
  _DenDirRecord  # a move made since the last prompt comes first
  if ($List -eq 'back') {
    $from = $global:_DenDirBack; $to = $global:_DenDirFwd; $word = 'back'
  } else {
    $from = $global:_DenDirFwd; $to = $global:_DenDirBack; $word = 'forward'
  }
  if ($N.Length -gt 9 -or [int]$N -gt $from.Count) {
    $noun = if ($from.Count -eq 1) { 'entry' } else { 'entries' }
    return "history has $($from.Count) $word $noun, cannot go $word $N"
  }
  $count = [int]$N
  $target = $from[$count - 1]
  if (-not (Test-Path -LiteralPath $target -PathType Container)) {
    $from.RemoveAt($count - 1)
    return "$target no longer exists, dropped from history"
  }
  $here = $PWD.Path
  try {
    Set-Location -LiteralPath $target -ErrorAction Stop
  } catch {
    return $_.Exception.Message
  }
  $global:_DenDirLast = $PWD.Path
  $to.Insert(0, $here)
  for ($i = 0; $i -lt $count - 1; $i++) { $to.Insert(0, $from[$i]) }
  $from.RemoveRange(0, $count)
}

# _DenDirTilde <path> - $HOME shown as ~, for back -l
function _DenDirTilde([string]$Path) {
  $h = "$HOME".TrimEnd('\', '/')
  if ($h) {
    if (_DenDirSame $Path $h) { return '~' }
    if ($Path.Length -gt $h.Length -and ($Path[$h.Length] -eq '\' -or $Path[$h.Length] -eq '/') -and
        (_DenDirSame $Path.Substring(0, $h.Length) $h)) {
      return '~' + $Path.Substring($h.Length)
    }
  }
  $Path
}

# _DenDirList - back -l: back entries farthest first, then the current location
# as *, then forward entries as +1, +2 ...
function _DenDirList {
  for ($i = $global:_DenDirBack.Count; $i -ge 1; $i--) {
    '{0,3}  {1}' -f $i, (_DenDirTilde $global:_DenDirBack[$i - 1])
  }
  '{0,3}  {1}' -f '*', (_DenDirTilde $PWD.Path)
  for ($i = 1; $i -le $global:_DenDirFwd.Count; $i++) {
    '{0,3}  {1}' -f "+$i", (_DenDirTilde $global:_DenDirFwd[$i - 1])
  }
}

# back → go back N entries in the directory history (default 1); -List (-l)
# shows the history, -Interactive (-i) picks an entry with fzf. Errors are
# terminating (-ErrorAction Stop) so `pwsh -Command 'back 5'` exits 1, as
# digest's summary error does.
function back {
  param([string]$N = '1', [switch]$List, [switch]$Interactive)
  if ($List) { _DenDirRecord; _DenDirList; return }
  if ($Interactive) {
    if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
      Write-Error 'fzf is not installed. Install: winget install junegunn.fzf' -ErrorAction Stop
    }
    _DenDirRecord
    # --tac shows the list in `back -l` order; the label in front of the pick
    # says which move reaches it.
    $pick = _DenDirList | & fzf --tac --no-sort --prompt 'back> '
    if (-not $pick) { return }
    $label = ("$pick".Trim() -split '\s+')[0]
    if ($label -eq '*') { return }
    if ($label.StartsWith('+')) { fwd $label.Substring(1) } else { back $label }
    return
  }
  if ($N -notmatch '^[1-9][0-9]*\z') { Write-Error 'usage: [N | -l | -i]  (N=positive integer, default 1)' -ErrorAction Stop }
  $err = _DenDirGo 'back' $N
  if ($err) { Write-Error $err -ErrorAction Stop }
}

# fwd → go forward N entries in the directory history (default 1), undoing back
function fwd {
  param([string]$N = '1')
  if ($N -notmatch '^[1-9][0-9]*\z') { Write-Error 'usage: [N]  (N=positive integer, default 1)' -ErrorAction Stop }
  $err = _DenDirGo 'fwd' $N
  if ($err) { Write-Error $err -ErrorAction Stop }
}

# _DenDirHookPrompt - the recorder: wrap the prompt so each prompt records a
# change of location made since the last one. init.ps1 calls it after starship,
# whose init replaces the prompt function; called again (on reload) it wraps the
# new prompt, never its own wrapper.
function _DenDirHookPrompt {
  if ($null -ne $global:_DenDirPrompt -and $function:prompt -eq $global:_DenDirPrompt) { return }
  $global:_DenDirPromptOld = $function:prompt
  function global:prompt {
    # Record first, then hand the wrapped prompt the $? it would have seen, so
    # it still shows the last command's status (starship reads $?).
    $ok = $global:?
    _DenDirRecord
    if (-not $ok) { Write-Error '' -ErrorAction Ignore }
    if ($global:_DenDirPromptOld) { & $global:_DenDirPromptOld }
  }
  $global:_DenDirPrompt = $function:prompt
}
