# coreutils.ps1 — Unix-like utility commands for PowerShell.
# Dot-sourced by init.ps1.

# Skip in non-interactive sessions to avoid breaking scripts
if (-not (_DenInteractive)) { return }

# Windows only: these fill a gap that Windows has (COMMANDS.md, "Unix coreutils").
# Linux and macOS have the real tools, which these would only replace with slower
# PowerShell versions that read fewer of their flags.
if (-not (_OnWindows)) { return }

# The functions that can hand a call to microsoft/coreutils pass what is piped in
# on through a steppable pipeline, as the generated wrappers do (see the wrapper
# generator in _helpers.ps1): each object reaches the binary as it arrives, the
# binary writes to the function's own output, a call with nothing piped in runs
# the binary directly, its stdin the console's, and on PowerShell 7.3 and later a
# clean block (added at the end of this file) ends a pipeline that a stopped line
# left open. Their PowerShell versions read piped input in a process block, an
# object at a time.

# ===== Unix-like Utilities =====

# df → disk free space
# Usage: df [path ...]; flags (-h, -T, ...) are ignored rather than read as paths.
# df reads no input, so microsoft/coreutils gets none.
function df {
  $__cu = _CoreutilsBin
  if ($__cu) { & $__cu df @Args; return }
  $paths = @($Args | Where-Object { "$_" -notlike '-*' })
  $result = Get-PSDrive -PSProvider FileSystem |
    Select-Object Name,
      @{N='Used(GB)';  E={[math]::Round($_.Used / 1GB, 1)}},
      @{N='Free(GB)';  E={[math]::Round($_.Free / 1GB, 1)}},
      @{N='Total(GB)'; E={[math]::Round(($_.Used + $_.Free) / 1GB, 1)}},
      Root
  if ($paths.Count -gt 0) {
    $result = $result | Where-Object {
      foreach ($p in $paths) { if ($_.Root -like "$p*" -or $_.Name -like "$p*") { return $true } }
      return $false
    }
  }
  $result | Format-Table -AutoSize
}

# env → list environment variables / run command with modified env
# Usage: env [VAR=val ...] [command [args ...]], no args = print all
function env {
  begin {
    $__sp = $null
    $__cu = _CoreutilsBin
    $__a = $args
    if ($__cu -and $MyInvocation.ExpectingInput) {
      $__sp = { & $__cu env @__a }.GetSteppablePipeline()
      $__sp.Begin($true, $ExecutionContext)
    }
  }
  process { if ($null -ne $__sp) { $__sp.Process($_) } }
  end {
    if ($null -ne $__sp) { $__s = $__sp; $__sp = $null; $__s.End(); return }
    if ($__cu) { & $__cu env @__a; return }
    $assigns = @(); $cmd = $null; $cmdArgs = @()
    $i = 0
    while ($i -lt $__a.Count) {
      $a = $__a[$i]
      if ($null -eq $cmd -and $a -match '^([^=]+)=(.*)$') {
        $assigns += @{ Name = $Matches[1]; Value = $Matches[2] }
      } elseif ($null -eq $cmd) {
        $cmd = $a
      } else {
        $cmdArgs += $a
      }
      $i++
    }
    if ($null -ne $cmd) {
      $saved = @{}
      foreach ($kv in $assigns) {
        $saved[$kv.Name] = [Environment]::GetEnvironmentVariable($kv.Name)
        [Environment]::SetEnvironmentVariable($kv.Name, $kv.Value)
      }
      try { & $cmd @cmdArgs }
      finally {
        foreach ($kv in $assigns) {
          if ($null -eq $saved[$kv.Name]) { [Environment]::SetEnvironmentVariable($kv.Name, $null) }
          else { [Environment]::SetEnvironmentVariable($kv.Name, $saved[$kv.Name]) }
        }
      }
    } else {
      Get-ChildItem Env: | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }
    }
  }
}

# head → first N lines of a file (default: 10)
# Usage: head [-n N] [-n -N] [-N] [-q] [-v] [file ...], supports pipe input
# Piped input is read an object at a time: the first N come out as they arrive,
# and once the Nth is out head stops the commands before it, as Select-Object
# -First does, so `Get-Content -Wait log | head -n 1` returns and a producer
# makes no more than N; -n -N holds back only the last N, and reads to the end.
# PowerShell has no public way for a function to stop the commands before it.
# Select-Object -First throws an internal StopUpstreamCommandsException naming
# its own command processor; that processor records it with the pipeline
# (ManageInvocationException) and throws the PipelineStoppedException the
# commands before it see, and the pipeline then ends only the commands after
# the one named. head does the same through reflection: begin, while head's own
# processor is the current one, builds the exception naming it, and process
# hands it to that processor's ManageInvocationException once the Nth is out.
# Thrown as it is, the exception is not caught on its way up through a script
# block that pipes into head, and ends the script around the line. Select-Object
# -First run inside head (through a steppable pipeline) stops the commands
# before head too, but names a processor the pipeline does not hold, so no
# command after head gets its end: `head -n 2 | Measure-Object` printed nothing.
# The internals are the same in PowerShell's first open-source release, in 6.0
# and in 7.6; where one is missing, head reads what comes after the Nth and
# drops it, as it did before.
# With coreutils, head is a program, and the commands before it run to their end
# after it exits, as they do before any program (pwsh 7.6 on Linux).
function head {
  begin {
    $__sp = $null
    $__cu = _CoreutilsBin
    $__in = $MyInvocation.ExpectingInput
    $__a = $args
    if ($__cu) {
      if ($__in) { $__sp = { & $__cu head @__a }.GetSteppablePipeline(); $__sp.Begin($true, $ExecutionContext) }
      return
    }
    $lines = 10; $excludeLast = 0; $files = @(); $quiet = $false; $verbose = $false; $i = 0
    while ($i -lt $__a.Count) {
      $a = $__a[$i]
      if ($a -eq '-n' -and ($i + 1) -lt $__a.Count) {
        $v = $__a[$i + 1]
        if ($v -match '^-(\d+)$') { $excludeLast = [int]$Matches[1]; $lines = 0 }
        else { $lines = [int]$v; $excludeLast = 0 }
        $i += 2
      }
      elseif ($a -match '^-(\d+)$') { $lines = [int]$Matches[1]; $i++ }
      elseif ($a -eq '-q' -or $a -eq '--quiet') { $quiet = $true; $i++ }
      elseif ($a -eq '-v' -or $a -eq '--verbose') { $verbose = $true; $i++ }
      else { $files += $a; $i++ }
    }
    $seen = 0
    $held = [System.Collections.Generic.Queue[object]]::new()
    # The stop (see above): $__stop holds head's processor, its
    # ManageInvocationException and the exception, or $null.
    $__stop = $null
    if ($__in -and $files.Count -eq 0 -and $excludeLast -eq 0) {
      try {
        $bf = [System.Reflection.BindingFlags]'Instance, NonPublic'
        $ctxField = @([System.Management.Automation.EngineIntrinsics].GetFields($bf) |
          Where-Object { $_.FieldType.FullName -eq 'System.Management.Automation.ExecutionContext' })[0]
        $ctx = $ctxField.GetValue($ExecutionContext)
        $proc = $ctx.GetType().GetProperty('CurrentCommandProcessor', $bf).GetValue($ctx)
        $cmd = $proc.GetType().GetProperty('Command', $bf).GetValue($proc)
        $manage = $proc.GetType().GetMethod('ManageInvocationException', $bf)
        $type = [psobject].Assembly.GetType('System.Management.Automation.StopUpstreamCommandsException', $true)
        if ($null -ne $manage) {
          $__stop = @{ Processor = $proc; Manage = $manage; Exception = [Activator]::CreateInstance($type, @($cmd)) }
        }
      } catch { $__stop = $null }
    }
  }
  process {
    if ($null -ne $__sp) { $__sp.Process($_); return }
    if ($__cu -or -not $__in -or $files.Count -gt 0) { return }
    if ($excludeLast -gt 0) {
      $held.Enqueue($_)
      if ($held.Count -gt $excludeLast) { $held.Dequeue() }
    } else {
      if ($seen -lt $lines) {
        $_
        $seen++
      }
      if ($seen -ge $lines -and $null -ne $__stop) {
        throw $__stop.Manage.Invoke($__stop.Processor, @($__stop.Exception))
      }
    }
  }
  end {
    if ($null -ne $__sp) { $__s = $__sp; $__sp = $null; $__s.End(); return }
    if ($__cu) { & $__cu head @__a; return }
    $showHeader = ($files.Count -gt 1 -and -not $quiet) -or $verbose
    for ($fi = 0; $fi -lt $files.Count; $fi++) {
      $f = $files[$fi]
      if ($showHeader) { Write-Host "==> $f <==" }
      if ($excludeLast -gt 0) {
        Get-Content -LiteralPath $f | Select-Object -SkipLast $excludeLast
      } else {
        Get-Content -LiteralPath $f -TotalCount $lines
      }
      if ($fi -lt $files.Count - 1 -and -not $quiet) { Write-Host "" }
    }
  }
}

# split → split a file into chunks
# Usage: split [-l N] [-n l/N] [-b SIZE] [-a LEN] [file] [prefix]
function split {
  begin {
    $__sp = $null
    $__cu = _CoreutilsBin
    $__in = $MyInvocation.ExpectingInput
    $__a = $args
    $__piped = [System.Collections.Generic.List[object]]::new()
    if ($__cu -and $__in) { $__sp = { & $__cu split @__a }.GetSteppablePipeline(); $__sp.Begin($true, $ExecutionContext) }
  }
  process {
    if ($null -ne $__sp) { $__sp.Process($_) }
    elseif ($__in -and -not $__cu) { $__piped.Add($_) }
  }
  end {
    if ($null -ne $__sp) { $__s = $__sp; $__sp = $null; $__s.End(); return }
    if ($__cu) { & $__cu split @__a; return }
    # Every captured operand is cast to [string]. PowerShell binds a bare
    # numeric argument as a NUMBER, and "$x -ne ''" coerces the right side to
    # the left side's type, so [int]'' is 0 and `-n 0` compared equal to "not
    # given": the invalid-chunk-count guard below was unreachable and
    # `split -n 0` silently fell through to the 1000-line default instead of
    # being refused. The same held for `-b 0`, and for a file literally named
    # "0", which "$path -eq ''" read as "no file, use stdin".
    $path = ''; $lines = 0; $chunks = ''; $bytes = ''; $prefix = 'x'; $suffixLen = 2; $i = 0
    while ($i -lt $__a.Count) {
      $a = [string]$__a[$i]
      if ($a -eq '-l' -and ($i + 1) -lt $__a.Count) { $lines = [int]$__a[$i + 1]; $i += 2 }
      elseif ($a -eq '-n' -and ($i + 1) -lt $__a.Count) { $chunks = [string]$__a[$i + 1]; $i += 2 }
      elseif ($a -eq '-b' -and ($i + 1) -lt $__a.Count) { $bytes = [string]$__a[$i + 1]; $i += 2 }
      elseif ($a -eq '-a' -and ($i + 1) -lt $__a.Count) { $suffixLen = [int]$__a[$i + 1]; $i += 2 }
      else {
        if ($path -eq '') { $path = $a } else { $prefix = $a }
        $i++
      }
    }
    if ($path -eq '') {
      $content = $__piped.ToArray()
      if ($content.Count -eq 0) { Write-Error "usage: [-l N] [-n l/N] [-b SIZE] <file> [prefix]"; return }
    }

    # Generate suffix: aa, ab, ... like GNU split
    function _suffix([int]$idx, [int]$len) {
      $s = ''; for ($j = $len - 1; $j -ge 0; $j--) {
        $s = [char](97 + ($idx % 26)) + $s; $idx = [math]::Floor($idx / 26)
      }; $s
    }

    # .NET resolves relative paths against the process directory, which
    # Set-Location never updates, so the input and every output name are
    # resolved against the PowerShell location first (literally: no wildcards).
    $sess = $ExecutionContext.SessionState.Path
    $full = ''
    if ($path -ne '') {
      $full = $sess.GetUnresolvedProviderPathFromPSPath($path)
      if (-not [System.IO.File]::Exists($full)) { Write-Error "cannot open '$path' for reading: No such file"; return }
    }

    if ($bytes -ne '') {
      # Byte splitting
      $mult = @{ 'K'=1KB; 'M'=1MB; 'G'=1GB }
      $sz = if ($bytes -match '^(\d+)([KMG])$') { [long]$Matches[1] * $mult[$Matches[2]] } else { [long]$bytes }
      # A size of 0 advances the write loop by 0 bytes for ever, so it has to be
      # refused rather than run. It was unreachable while `-b 0` was read as
      # "-b not given"; the [string] cast above is what makes it reachable.
      if ($sz -lt 1) { Write-Error "invalid byte size '$bytes'"; return }
      # Streamed through one reusable buffer. ReadAllBytes plus a range slice
      # per part ($data[$a..$b], an object[] of boxed bytes) took about 50x the
      # file size in memory and ran some 250x slower than native split, so a
      # multi-GB file could not be split at all.
      $in = if ($full) { [System.IO.File]::OpenRead($full) }
            else { [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes(($content -join "`n") + "`n")) }
      $buf = New-Object byte[] ([int][math]::Min($sz, 1MB))
      $idx = 0
      try {
        while ($true) {
          $n = $in.Read($buf, 0, [int][math]::Min([long]$buf.Length, $sz))
          if ($n -le 0) { break }
          $out = [System.IO.File]::Create($sess.GetUnresolvedProviderPathFromPSPath("${prefix}$(_suffix $idx $suffixLen)"))
          try {
            $out.Write($buf, 0, $n)
            $left = $sz - $n
            while ($left -gt 0) {
              $n = $in.Read($buf, 0, [int][math]::Min([long]$buf.Length, $left))
              if ($n -le 0) { break }
              $out.Write($buf, 0, $n)
              $left -= $n
            }
          } finally { $out.Dispose() }
          $idx++
        }
      } finally { $in.Dispose() }
      Write-Host "Split into $idx files"
      return
    }

    if ($chunks -ne '') {
      $n = [int]($chunks -replace '^l/', '')
      if ($n -lt 1) { Write-Error "invalid chunk count '$chunks'"; return }
    }

    if ($full) {
      # A file is split on its raw bytes, cut after each LF, so the parts put
      # back together (cat x*) are the file again, as with GNU split. Reading
      # lines with Get-Content and writing them with Set-Content decoded them
      # (a non-UTF-8 byte became U+FFFD), rewrote the line endings and added a
      # final newline the file did not have. The chunk sizes are den's own:
      # -l N lines per part, -n N parts of ceil(lines/N) lines each.
      $buf = New-Object byte[] 65536
      if ($chunks -ne '') {
        # Count the lines first: every LF, plus a last line without one.
        $count = 0; $last = [byte]10
        $in = [System.IO.File]::OpenRead($full)
        try {
          while (($got = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $p = 0
            while (($p = [Array]::IndexOf($buf, [byte]10, $p, $got - $p)) -ge 0) { $count++; $p++ }
            $last = $buf[$got - 1]
          }
        } finally { $in.Dispose() }
        if ($last -ne 10) { $count++ }
        $lines = [math]::Ceiling($count / $n)
      }
      if ($lines -lt 1) { $lines = 1000 }
      $idx = 0; $inChunk = 0; $out = $null
      $in = [System.IO.File]::OpenRead($full)
      try {
        while (($got = $in.Read($buf, 0, $buf.Length)) -gt 0) {
          $p = 0
          while ($p -lt $got) {
            if ($null -eq $out) {
              $out = [System.IO.File]::Create($sess.GetUnresolvedProviderPathFromPSPath("${prefix}$(_suffix $idx $suffixLen)"))
              $idx++
            }
            $nl = [Array]::IndexOf($buf, [byte]10, $p, $got - $p)
            if ($nl -lt 0) { $out.Write($buf, $p, $got - $p); break }
            $out.Write($buf, $p, $nl + 1 - $p)
            $p = $nl + 1
            $inChunk++
            if ($inChunk -ge $lines) { $out.Dispose(); $out = $null; $inChunk = 0 }
          }
        }
      } finally {
        if ($null -ne $out) { $out.Dispose() }
        $in.Dispose()
      }
      if ($idx -eq 0) { Write-Host "Split into 0 files"; return }
      Write-Host "Split into $idx files (${prefix}$(_suffix 0 $suffixLen) .. ${prefix}$(_suffix ($idx-1) $suffixLen))"
      return
    }

    # Piped input arrives as strings, already decoded: it is written back as
    # lines. $content is @() above, so .Count and the slice are strict-safe.
    if ($chunks -ne '') { $lines = [math]::Ceiling($content.Count / $n) }
    if ($lines -lt 1) { $lines = 1000 }
    $total = [math]::Ceiling($content.Count / $lines)
    for ($idx = 0; $idx -lt $total; $idx++) {
      $start = $idx * $lines
      $outFile = "${prefix}$(_suffix $idx $suffixLen)"
      $content[$start..([math]::Min($start + $lines, $content.Count) - 1)] | Set-Content -LiteralPath $outFile
    }
    Write-Host "Split into $total files (${prefix}$(_suffix 0 $suffixLen) .. ${prefix}$(_suffix ($total-1) $suffixLen))"
  }
}

# tail → last N lines of a file (default: 10)
# Usage: tail [-n N] [-n +N] [-N] [-f] [-q] [-v] [file ...], supports pipe input
# Piped input is read an object at a time: -n +N passes each line on as it
# arrives, and -n N holds only the last N.
function tail {
  begin {
    $__sp = $null
    $__cu = _CoreutilsBin
    $__in = $MyInvocation.ExpectingInput
    $__a = $args
    if ($__cu) {
      if ($__in) { $__sp = { & $__cu tail @__a }.GetSteppablePipeline(); $__sp.Begin($true, $ExecutionContext) }
      return
    }
    $lines = 10; $fromLine = 0; $files = @(); $follow = $false; $quiet = $false; $verbose = $false; $i = 0
    while ($i -lt $__a.Count) {
      $a = $__a[$i]
      if ($a -eq '-n' -and ($i + 1) -lt $__a.Count) {
        $v = $__a[$i + 1]
        if ($v -match '^\+(\d+)$') { $fromLine = [int]$Matches[1]; $lines = 0 }
        else { $lines = [int]$v; $fromLine = 0 }
        $i += 2
      }
      elseif ($a -eq '-f') { $follow = $true; $i++ }
      elseif ($a -match '^-(\d+)$') { $lines = [int]$Matches[1]; $i++ }
      elseif ($a -eq '-q' -or $a -eq '--quiet') { $quiet = $true; $i++ }
      elseif ($a -eq '-v' -or $a -eq '--verbose') { $verbose = $true; $i++ }
      else { $files += $a; $i++ }
    }
    $seen = 0
    $held = [System.Collections.Generic.Queue[object]]::new()
  }
  process {
    if ($null -ne $__sp) { $__sp.Process($_); return }
    if ($__cu -or -not $__in -or $files.Count -gt 0) { return }
    if ($fromLine -gt 0) {
      $seen++
      if ($seen -ge $fromLine) { $_ }
    } else {
      $held.Enqueue($_)
      if ($held.Count -gt $lines) { [void]$held.Dequeue() }
    }
  }
  end {
    if ($null -ne $__sp) { $__s = $__sp; $__sp = $null; $__s.End(); return }
    if ($__cu) { & $__cu tail @__a; return }
    $showHeader = ($files.Count -gt 1 -and -not $quiet) -or $verbose
    if ($follow -and $files.Count -ge 1) {
      Get-Content -LiteralPath $files[0] -Tail $lines -Wait
    } elseif ($files.Count -eq 0) {
      if ($fromLine -le 0) { $held.ToArray() }
    } else {
      for ($fi = 0; $fi -lt $files.Count; $fi++) {
        $f = $files[$fi]
        if ($showHeader) { Write-Host "==> $f <==" }
        if ($fromLine -gt 0) {
          Get-Content -LiteralPath $f | Select-Object -Skip ($fromLine - 1)
        } else {
          Get-Content -LiteralPath $f -Tail $lines
        }
        if ($fi -lt $files.Count - 1 -and -not $quiet) { Write-Host "" }
      }
    }
  }
}

# touch → create empty file or update timestamp
# Usage: touch <file...>
function touch {
  $__cu = _CoreutilsBin
  if ($__cu) { & $__cu touch @Args; return }
  if ($Args.Count -eq 0) { Write-Error "usage: <file...>"; return }
  foreach ($a in $Args) {
    # A name is taken literally: [ ] in pages/[id].tsx are not wildcards (New-Item
    # never read them as such). Tab completion writes them escaped, though
    # ('./pages/`[id`].tsx'), so where the name as given does not exist, the
    # unescaped name is taken instead when that exists.
    # Otherwise a name with an unescaped * or ? is a pattern, which a function
    # receives unexpanded (`touch *.md`), and touch updates each file it matches,
    # as a shell expands it; one that matches nothing is created as it is, as
    # bash passes it on. [ ] stay literal in a name without * or ?, so a new
    # pages/[slug].tsx does not stand for pages/s.tsx.
    # Else, where only the unescaped name's parent directory exists (a new file
    # in a tab-completed app/`[slug`]), the file is created there.
    $f = "$a"
    if (-not (Test-Path -LiteralPath $f)) {
      $u = [System.Management.Automation.WildcardPattern]::Unescape($f)
      if ($u -ne $f -and (Test-Path -LiteralPath $u)) {
        $f = $u
      } else {
        if (($f -replace '`.', '') -match '[*?]') {
          $hits = @(Convert-Path -Path $f -ErrorAction SilentlyContinue)
          if ($hits.Count -gt 0) {
            foreach ($h in $hits) { (Get-Item -LiteralPath $h).LastWriteTime = Get-Date }
            continue
          }
        }
        if ($u -ne $f) {
          $fParent = Split-Path -Path $f -Parent
          $uParent = Split-Path -Path $u -Parent
          if ($fParent -and $uParent -and -not (Test-Path -LiteralPath $fParent) -and (Test-Path -LiteralPath $uParent)) {
            $f = $u
          }
        }
      }
    }
    if (Test-Path -LiteralPath $f) { (Get-Item -LiteralPath $f).LastWriteTime = Get-Date }
    else { New-Item -ItemType File -Path $f | Out-Null }
  }
}

function _wcOne {
  param([string]$Path, [hashtable]$mo, [bool]$needChar)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

  $raw = Get-Content -Raw -LiteralPath $Path -ErrorAction SilentlyContinue
  if ($null -eq $raw) { $raw = '' }

  # @(): the if-block's output reaches $lines as $null for an empty file, and a
  # caller's Set-StrictMode makes the .Length read below an error.
  $lines = @(if ($raw.Length -gt 0) { $raw -split "`n" })
  if ($lines.Length -gt 0 -and $lines[-1] -eq '') {
    $lines = if ($lines.Length -eq 1) { @() } else { $lines[0..($lines.Length - 2)] }
  }

  $r = $lines | Measure-Object @mo
  if ($needChar) {
    $r | Add-Member -NotePropertyName 'Characters' -NotePropertyValue $raw.Length -Force
  }
  $r
}

# wc → line, word, and character count (supports -l, -w, -c flags)
# Usage: wc [-l] [-w] [-c|-m] [file ...], supports pipe input
# Piped input is counted an object at a time, not held: Measure-Object takes
# each one as it arrives, and the characters (with a newline after each line,
# as in a file) are added up alongside.
function wc {
  begin {
    $__sp = $null
    $__cu = _CoreutilsBin
    $__in = $MyInvocation.ExpectingInput
    $__a = $args
    if ($__cu) {
      if ($__in) { $__sp = { & $__cu wc @__a }.GetSteppablePipeline(); $__sp.Begin($true, $ExecutionContext) }
      return
    }
    $flags = @(); $files = @()
    foreach ($a in $__a) {
      if ($a -match '^-[lwcm]+$') { $flags += $a }
      else { $files += $a }
    }
    $needChar = $false
    $mo = @{}
    if ($flags.Count -eq 0) {
      $mo['Line'] = $true; $mo['Word'] = $true; $mo['Character'] = $true
      $needChar = $true
    } else {
      $all = ($flags -join '').Replace('-', '')
      if ($all -match 'l') { $mo['Line'] = $true }
      if ($all -match 'w') { $mo['Word'] = $true }
      if ($all -match '[cm]') { $mo['Character'] = $true; $needChar = $true }
    }
    $count = $null
    if ($files.Count -eq 0) {
      $count = { Measure-Object @mo }.GetSteppablePipeline()
      $count.Begin($true)
    }
    $seen = 0
    $chars = 0
  }
  process {
    if ($null -ne $__sp) { $__sp.Process($_); return }
    if ($__cu -or -not $__in -or $files.Count -gt 0) { return }
    $null = $count.Process($_)
    $seen++
    $chars += "$_".Length + 1
  }
  end {
    if ($null -ne $__sp) { $__s = $__sp; $__sp = $null; $__s.End(); return }
    if ($__cu) { & $__cu wc @__a; return }
    if ($files.Count -eq 0) {
      $r = $count.End()
      if ($needChar -and $seen -gt 0) {
        $r | Add-Member -NotePropertyName 'Characters' -NotePropertyValue $chars -Force
      }
      $r
    } elseif ($files.Count -eq 1) {
      $r = _wcOne $files[0] $mo $needChar
      $r
    } else {
      $results = @()
      $totals = @{
        Lines = 0
        Words = 0
        Characters = 0
      }
      foreach ($f in $files) {
        $r = _wcOne $f $mo $needChar
        if ($null -eq $r) { continue }
        $r | Add-Member -NotePropertyName 'File' -NotePropertyValue $f -Force
        if ($r.PSObject.Properties['Lines']) { $totals['Lines'] += $r.Lines }
        if ($r.PSObject.Properties['Words']) { $totals['Words'] += $r.Words }
        if ($r.PSObject.Properties['Characters']) { $totals['Characters'] += $r.Characters }
        $results += $r
      }

      $total = [pscustomobject]@{}
      if ($mo.ContainsKey('Line')) {
        $total | Add-Member -NotePropertyName 'Lines' -NotePropertyValue $totals['Lines'] -Force
      }
      if ($mo.ContainsKey('Word')) {
        $total | Add-Member -NotePropertyName 'Words' -NotePropertyValue $totals['Words'] -Force
      }
      if ($needChar) {
        $total | Add-Member -NotePropertyName 'Characters' -NotePropertyValue $totals['Characters'] -Force
      }
      $total | Add-Member -NotePropertyName 'File' -NotePropertyValue 'total' -Force
      $results += $total
      $results | Format-Table -AutoSize
    }
  }
}

# which → show command location
# Usage: which [-a] <name...>
function which {
  $all = $false; $names = @()
  foreach ($a in $Args) {
    if ($a -eq '-a') { $all = $true } else { $names += $a }
  }
  if ($names.Count -eq 0) { Write-Error "usage: [-a] <name...>"; return }
  foreach ($n in $names) {
    if ($all) {
      Get-Command $n -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source }
    } else {
      Get-Command $n -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    }
  }
}

# The clean block for the functions above that run microsoft/coreutils through a
# steppable pipeline (see _DenSpClean in _helpers.ps1).
_DenAddClean 'env', 'head', 'split', 'tail', 'wc'
