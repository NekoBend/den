# coreutils.ps1 — Unix-like utility commands for PowerShell.
# Dot-sourced by init.ps1.

# Skip in non-interactive sessions to avoid breaking scripts
if (-not [Environment]::UserInteractive) { return }

# ===== Unix-like Utilities =====

# df → disk free space
# Usage: df [path ...]
function df {
  $paths = @($Args)
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
  $assigns = @(); $cmd = $null; $cmdArgs = @()
  $i = 0
  while ($i -lt $Args.Count) {
    $a = $Args[$i]
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

# head → first N lines of a file (default: 10)
# Usage: head [-n N] [-n -N] [-N] [-q] [-v] [file ...], supports pipe input
function head {
  $lines = 10; $excludeLast = 0; $files = @(); $quiet = $false; $verbose = $false; $i = 0
  while ($i -lt $Args.Count) {
    $a = $Args[$i]
    if ($a -eq '-n' -and ($i + 1) -lt $Args.Count) {
      $v = $Args[$i + 1]
      if ($v -match '^-(\d+)$') { $excludeLast = [int]$Matches[1]; $lines = 0 }
      else { $lines = [int]$v; $excludeLast = 0 }
      $i += 2
    }
    elseif ($a -match '^-(\d+)$') { $lines = [int]$Matches[1]; $i++ }
    elseif ($a -eq '-q' -or $a -eq '--quiet') { $quiet = $true; $i++ }
    elseif ($a -eq '-v' -or $a -eq '--verbose') { $verbose = $true; $i++ }
    else { $files += $a; $i++ }
  }
  $showHeader = ($files.Count -gt 1 -and -not $quiet) -or $verbose
  if ($files.Count -eq 0) {
    if ($excludeLast -gt 0) { $input | Select-Object -SkipLast $excludeLast }
    else { $input | Select-Object -First $lines }
  } else {
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
  $path = ''; $lines = 0; $chunks = ''; $bytes = ''; $prefix = 'x'; $suffixLen = 2; $i = 0
  while ($i -lt $Args.Count) {
    $a = $Args[$i]
    if ($a -eq '-l' -and ($i + 1) -lt $Args.Count) { $lines = [int]$Args[$i + 1]; $i += 2 }
    elseif ($a -eq '-n' -and ($i + 1) -lt $Args.Count) { $chunks = $Args[$i + 1]; $i += 2 }
    elseif ($a -eq '-b' -and ($i + 1) -lt $Args.Count) { $bytes = $Args[$i + 1]; $i += 2 }
    elseif ($a -eq '-a' -and ($i + 1) -lt $Args.Count) { $suffixLen = [int]$Args[$i + 1]; $i += 2 }
    else {
      if ($path -eq '') { $path = $a } else { $prefix = $a }
      $i++
    }
  }
  if ($path -eq '') {
    $content = @($input)
    if ($content.Count -eq 0) { Write-Error "usage: [-l N] [-n l/N] [-b SIZE] <file> [prefix]"; return }
  }

  # Generate suffix: aa, ab, ... like GNU split
  function _suffix([int]$idx, [int]$len) {
    $s = ''; for ($j = $len - 1; $j -ge 0; $j--) {
      $s = [char](97 + ($idx % 26)) + $s; $idx = [math]::Floor($idx / 26)
    }; $s
  }

  if ($bytes -ne '') {
    # Byte splitting
    $mult = @{ 'K'=1KB; 'M'=1MB; 'G'=1GB }
    $sz = if ($bytes -match '^(\d+)([KMG])$') { [long]$Matches[1] * $mult[$Matches[2]] } else { [long]$bytes }
    if ($path -eq '') {
      $data = [System.Text.Encoding]::UTF8.GetBytes(($content -join "`n") + "`n")
    } else {
      $data = [System.IO.File]::ReadAllBytes((Resolve-Path $path))
    }
    $idx = 0; $off = 0
    while ($off -lt $data.Length) {
      $chunk = [math]::Min($sz, $data.Length - $off)
      $outFile = Join-Path $PWD.Path "${prefix}$(_suffix $idx $suffixLen)"
      [System.IO.File]::WriteAllBytes($outFile, $data[$off..($off + $chunk - 1)])
      $off += $chunk; $idx++
    }
    Write-Host "Split into $idx files"
    return
  }

  if ($path -ne '') { $content = Get-Content -LiteralPath $path }
  if ($chunks -ne '') {
    $n = [int]($chunks -replace '^l/', '')
    if ($n -lt 1) { Write-Error "invalid chunk count '$chunks'"; return }
    $lines = [math]::Ceiling($content.Count / $n)
  }
  if ($lines -lt 1) { $lines = 1000 }
  $total = [math]::Ceiling($content.Count / $lines)
  for ($idx = 0; $idx -lt $total; $idx++) {
    $start = $idx * $lines
    $outFile = "${prefix}$(_suffix $idx $suffixLen)"
    $content[$start..($start + $lines - 1)] | Set-Content $outFile
  }
  Write-Host "Split into $total files (${prefix}$(_suffix 0 $suffixLen) .. ${prefix}$(_suffix ($total-1) $suffixLen))"
}

# tail → last N lines of a file (default: 10)
# Usage: tail [-n N] [-n +N] [-N] [-f] [-q] [-v] [file ...], supports pipe input
function tail {
  $lines = 10; $fromLine = 0; $files = @(); $follow = $false; $quiet = $false; $verbose = $false; $i = 0
  while ($i -lt $Args.Count) {
    $a = $Args[$i]
    if ($a -eq '-n' -and ($i + 1) -lt $Args.Count) {
      $v = $Args[$i + 1]
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
  $showHeader = ($files.Count -gt 1 -and -not $quiet) -or $verbose
  if ($follow -and $files.Count -ge 1) {
    Get-Content -LiteralPath $files[0] -Tail $lines -Wait
  } elseif ($files.Count -eq 0) {
    if ($fromLine -gt 0) { $input | Select-Object -Skip ($fromLine - 1) }
    else { $input | Select-Object -Last $lines }
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

# touch → create empty file or update timestamp
# Usage: touch <file...>
function touch {
  if ($Args.Count -eq 0) { Write-Error "usage: <file...>"; return }
  foreach ($f in $Args) {
    if (Test-Path $f) { (Get-Item $f).LastWriteTime = Get-Date }
    else { New-Item -ItemType File -Path $f | Out-Null }
  }
}

function _wcOne {
  param([string]$Path, [hashtable]$mo, [bool]$needChar)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

  $raw = Get-Content -Raw -LiteralPath $Path -ErrorAction SilentlyContinue
  if ($null -eq $raw) { $raw = '' }

  $lines = if ($raw.Length -eq 0) { @() } else { $raw -split "`n" }
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
function wc {
  $flags = @(); $files = @()
  foreach ($a in $Args) {
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
  if ($files.Count -eq 0) {
    $lines = @($input)
    $r = $lines | Measure-Object @mo
    if ($needChar -and $lines.Count -gt 0) {
      $raw = ($lines -join "`n") + "`n"
      $r | Add-Member -NotePropertyName 'Characters' -NotePropertyValue $raw.Length -Force
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
