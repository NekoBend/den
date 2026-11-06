# python.ps1 — Python/uv helper functions for PowerShell.
# Dot-sourced by init.ps1.

if (-not (_ResolveCmd 'uv' 'App')) { return }

# ===== uv overrides =====

# This file's functions hand their arguments on to a program through
# _DenPyArgs and _DenPyCall, so that a quoted word reaches it as it is on Linux
# and macOS too (`pip install 'pkg[extra]'`), where pwsh expanded every word
# of @Args (see _DenArgs in _helpers.ps1). Both are defined global: and fall
# back to @Args in a session whose _helpers.ps1 predates _DenArgs: toggle-uv ON
# reads this file again after den is updated in place, while the session keeps
# the _helpers.ps1 it loaded (see the helpers python calls, below).

# _DenPyArgs <invocation> <args> - <args> as the words to hand a program
# (_DenArgs), or as they are in such a session.
function global:_DenPyArgs($Invocation, [object[]]$Arguments) {
  if (Get-Command _DenArgs -CommandType Function -ErrorAction Ignore) { return , @(_DenArgs $Invocation $Arguments) }
  return , @($Arguments)
}

# _DenPyCall <program> <words> - run <program> with <words> (_DenCall), or
# with @words in such a session.
function global:_DenPyCall($Program, [object[]]$Words) {
  if (Get-Command _DenCall -CommandType Function -ErrorAction Ignore) { _DenCall $Program $Words; return }
  & $Program @Words
}

# uv → auto-inject --python for 'uv run' when venv is active
function uv {
  $words = _DenPyArgs $MyInvocation $Args
  if ($env:VIRTUAL_ENV -and $env:_DEN_VENV_PYTHON -and $words.Count -ge 1 -and "$($words[0])" -eq 'run') {
    $rest = @($words | Select-Object -Skip 1)
    # `--` ends uv's OWN option parsing, so injecting it unconditionally turned
    # every `uv run` option into the command to spawn (`uv run --with rich app.py`
    # -> "Failed to spawn: --with"). Only separate when the first user argument
    # cannot be mistaken for a uv option. Parity with posix python.sh.
    $words = @('run', '--python', $env:_DEN_VENV_PYTHON)
    if (-not ($rest.Count -ge 1 -and "$($rest[0])".StartsWith('-'))) { $words += '--' }
    $words += $rest
  }
  _DenPyCall (_ResolveCmd 'uv' 'App') $words
}

# Show-UvOnlyMessage → display warning that direct python/pip is disabled
function Show-UvOnlyMessage {
  param([string]$Original, [string]$RedirectedTo)
  Write-Host "$($Original.TrimEnd()) → $($RedirectedTo.TrimEnd())" -ForegroundColor DarkYellow
}

# pip → the active venv's own pip when it has one, else uv pip, which installs
# into the active venv: a venv made by uv (vv, vva) has no pip, and a PATH
# lookup then found another Python's pip, which installed there. With no venv
# active, pip runs nothing: uv pip would pick an environment itself, the .venv
# in this directory or one above it, and run the python in it, which may be one
# a cloned repository committed. va activates a venv after checking that it did
# not come with the clone. Parity with posix python.sh.
# uv pip reads only your own uv settings, as pip reads no uv.toml or
# pyproject.toml: uv reads them from this directory and the ones above it, and
# a clone's settings there can have it run a python the clone ships ([pip]
# python) or install a package from the clone's own files (find-links). uv
# --config-file reads the one file _DenUvConfig names in place of all of
# those, and with none, uv --no-config reads none. The line says which, and
# typed uv pip reads them all.
function pip {
  if (-not $env:VIRTUAL_ENV) {
    Write-Error "no venv is active; activate one with va, or type $((@('uv', 'pip') + $Args) -join ' ') directly"
    return
  }
  $venvPip = @('Scripts/pip.exe', 'bin/pip') | ForEach-Object { Join-Path $env:VIRTUAL_ENV $_ } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if ($venvPip) { _DenPyCall $venvPip (_DenPyArgs $MyInvocation $Args); return }
  $uv = _ResolveCmd 'uv' 'App'
  if (-not $uv) { Write-Error "the active venv has no pip and uv is not on PATH: $env:VIRTUAL_ENV"; return }
  $cfg = _DenUvConfig
  if ($cfg) {
    $options = @('--config-file', $cfg)
    $reads = 'reads your uv settings, not a uv.toml or pyproject.toml here or above, which a clone can ship; type uv pip to read those'
  }
  else {
    $options = @('--no-config')
    $reads = 'reads no uv.toml or pyproject.toml here or above, which a clone can ship; type uv pip to read those'
  }
  Show-UvOnlyMessage "pip $($Args -join ' ')" "$((@('uv') + $options + @('pip') + $Args) -join ' ') ($reads)"
  _DenPyCall $uv (@($options) + @('pip') + (_DenPyArgs $MyInvocation $Args))
}

# pip3 → the same, with an active venv's own pip3
function pip3 {
  if (-not $env:VIRTUAL_ENV) {
    Write-Error "no venv is active; activate one with va, or type $((@('uv', 'pip') + $Args) -join ' ') directly"
    return
  }
  $venvPip = @('Scripts/pip3.exe', 'bin/pip3') | ForEach-Object { Join-Path $env:VIRTUAL_ENV $_ } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if ($venvPip) { _DenPyCall $venvPip (_DenPyArgs $MyInvocation $Args); return }
  $uv = _ResolveCmd 'uv' 'App'
  if (-not $uv) { Write-Error "the active venv has no pip3 and uv is not on PATH: $env:VIRTUAL_ENV"; return }
  $cfg = _DenUvConfig
  if ($cfg) {
    $options = @('--config-file', $cfg)
    $reads = 'reads your uv settings, not a uv.toml or pyproject.toml here or above, which a clone can ship; type uv pip to read those'
  }
  else {
    $options = @('--no-config')
    $reads = 'reads no uv.toml or pyproject.toml here or above, which a clone can ship; type uv pip to read those'
  }
  Show-UvOnlyMessage "pip3 $($Args -join ' ')" "$((@('uv') + $options + @('pip') + $Args) -join ' ') ($reads)"
  _DenPyCall $uv (@($options) + @('pip') + (_DenPyArgs $MyInvocation $Args))
}

# The helpers python, python3 and py call are defined global:. toggle-uv
# ON dot-sources this file inside itself and copies to global scope only the
# names on its own list, and a session that loaded an older python.ps1 runs that
# file's toggle-uv, whose list may not have them: a plain definition then ended
# with the call, and python found no _DenPyRun.

# _DenPyMarker - the pyproject.toml, .venv, pyvenv.cfg, uv.toml or
# .python-version that uv run would read from here: the first one in the
# current directory or a directory above it ($null when there is none). uv
# takes a directory that holds a pyvenv.cfg for a venv, whatever its name, and
# runs the python in it; a uv.toml's settings can have it install and run a
# python the clone ships; and it runs the program a .python-version names to
# ask its version (a .python-versions as well, which it reads the same way). A
# .python-version counts only when it names a path, comment (#) and blank lines
# aside: a line with / or \ in it, or one that, trimmed of white space as uv
# trims it, names a file or directory in the current directory. uv looks such
# a name up there, not beside the file, and takes a directory for a venv and
# runs its python. One that holds version requests alone (3.13, cpython@3.13)
# does not count, so a pyenv ~/.python-version leaves home alone, unless the
# current directory holds something of the same name. Windows hands uv the
# directory as PowerShell has it; Linux and macOS resolve its symbolic links
# first, so there a linked directory's target is searched as well.
# _DenPyMarker <dir> <cwd> - the same for uv started elsewhere (see
# _DenUvMarker): the walk starts from <dir>, and a bare name is
# looked up in <cwd>, the directory uv runs in. Not one of the overrides that
# toggle-uv removes: vv and vva ask it with them off as well.
function global:_DenPyMarker([string]$Start, [string]$Here) {
  # The directory uv runs in, where it looks a name up: PowerShell's location,
  # unless vv names another.
  if (-not $Here) { $Here = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath }
  # The white space uv trims off a line: Rust's str::trim takes the Unicode
  # White_Space characters. Listed, as .Trim()'s own set follows the Unicode
  # tables of the runtime it runs on.
  $ws = [char[]]@(9, 10, 11, 12, 13, 0x20, 0x85, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
    0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000)
  $starts = [System.Collections.Generic.List[string]]::new()
  $starts.Add($(if ($Start) { $Start } else { $Here }))
  for ($i = 0; $i -lt $starts.Count -and $i -lt 16; $i++) {
    $dir = $starts[$i]
    while ($dir) {
      foreach ($name in 'pyproject.toml', '.venv', 'pyvenv.cfg', 'uv.toml', '.python-version', '.python-versions') {
        $path = [System.IO.Path]::Combine($dir, $name)
        # Every string test here is ordinal: one by culture passes over
        # characters such as U+200B, U+00AD and U+0001 (-like and -eq too).
        if (-not $name.StartsWith('.python-version', [System.StringComparison]::Ordinal)) {
          if ([System.IO.File]::Exists($path) -or [System.IO.Directory]::Exists($path)) { return $path }
          continue
        }
        if (-not [System.IO.File]::Exists($path)) { continue }
        if (-not (_OnWindows)) {
          # A regular file, as uv reads: a link to /dev/zero or a FIFO, whose
          # size reads 0, would not end. ResolveLinkTarget is .NET 6 (pwsh 7.2).
          $file = [System.IO.FileInfo]::new($path)
          try { $target = $file.ResolveLinkTarget($true); if ($target) { $file = $target } } catch { $null = $_ }
          try { if ($file.Length -eq 0) { continue } } catch { continue }
        }
        # uv reads the file as UTF-8 and keeps a byte order mark, which
        # ReadAllText drops, and splits the lines at \n alone. A line that
        # starts with U+200B or a byte order mark and then # is no comment
        # to uv.
        try { $text = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($path)) } catch { continue }
        $n = 0
        foreach ($line in $text -split "`n") {
          if (-not $line -or $line.StartsWith('#', [System.StringComparison]::Ordinal)) { continue }
          # A line over 128 characters, or a 65th one, counts without the
          # checks below, as in python.sh, where trimming such lines would
          # take seconds: no version request is that long, nor is a file of
          # them.
          if (++$n -gt 64 -or $line.Length -gt 128) { return $path }
          $lead = $line.TrimStart(' ')
          if ($lead.StartsWith('#', [System.StringComparison]::Ordinal)) { continue }
          if ($lead.IndexOfAny([char[]]'/\') -ge 0) { return $path }
          $bare = $line.Trim($ws)
          if (-not $bare -or $bare.StartsWith('#', [System.StringComparison]::Ordinal)) { continue }
          try {
            # A drive-relative C:name, on Windows, would resolve here from
            # this process's own directory on that drive, not from $Here as
            # uv's does: it counts as it is.
            if ([System.IO.Path]::IsPathRooted($bare)) { return $path }
            $entry = [System.IO.Path]::Combine($Here, $bare)
            if ([System.IO.File]::Exists($entry) -or [System.IO.Directory]::Exists($entry)) { return $path }
          } catch { $null = $_ }
        }
      }
      if (-not (_OnWindows)) {
        # ResolveLinkTarget is .NET 6 (pwsh 7.2); before it, links are not followed.
        try {
          $target = [System.IO.DirectoryInfo]::new($dir).ResolveLinkTarget($true)
          if ($target) { $starts.Add($target.FullName) }
        } catch { $null = $_ }
      }
      $dir = [System.IO.Path]::GetDirectoryName($dir)
    }
  }
  return $null
}

# _DenUvConfig - the uv.toml of your own that uv reads besides a project's,
# for uv --config-file to read in place of them all ($null when there is
# none): the file UV_CONFIG_FILE names (uv reads it even under UV_NO_CONFIG);
# else, unless UV_NO_CONFIG is true, the user one, uv\uv.toml in %APPDATA% on
# Windows, and elsewhere $XDG_CONFIG_HOME/uv/uv.toml (an absolute
# XDG_CONFIG_HOME only, as uv takes) or ~/.config/uv/uv.toml; else, unless
# UV_NO_SYSTEM_CONFIG is true, the system one, uv\uv.toml in
# %SYSTEMDRIVE%\ProgramData on Windows, and elsewhere uv/uv.toml in the first
# of $XDG_CONFIG_DIRS (/etc/xdg) that has one, else /etc/uv/uv.toml. uv reads
# an XDG_CONFIG_DIRS entry that is not absolute from the current directory,
# where a clone can ship one: such entries are skipped here. uv merges the
# user and the system file, and --config-file reads one: with both, the user
# one, and the system one's settings are left out. Not one of the overrides
# that toggle-uv removes: vv and vva ask it with them off as well. Parity with
# posix python.sh.
function global:_DenUvConfig {
  if ($env:UV_CONFIG_FILE) { return $env:UV_CONFIG_FILE }
  # The values uv takes for true, in any case.
  $truthy = '1', 'y', 'yes', 't', 'true', 'on'
  if ($env:UV_NO_CONFIG -and $truthy -ccontains $env:UV_NO_CONFIG.ToLowerInvariant()) { return $null }
  if (_OnWindows) {
    # Without APPDATA, uv asks Windows for the roaming application data folder.
    $base = if ($env:APPDATA) { $env:APPDATA } else { [Environment]::GetFolderPath('ApplicationData') }
  }
  elseif ($env:XDG_CONFIG_HOME -and $env:XDG_CONFIG_HOME.StartsWith('/', [System.StringComparison]::Ordinal)) {
    $base = $env:XDG_CONFIG_HOME
  }
  else {
    $userHome = if ($env:HOME) { $env:HOME } else { [Environment]::GetFolderPath('UserProfile') }
    $base = [System.IO.Path]::Combine($userHome, '.config')
  }
  if ($base) {
    $path = [System.IO.Path]::Combine($base, 'uv', 'uv.toml')
    if ([System.IO.File]::Exists($path)) { return $path }
  }
  if ($env:UV_NO_SYSTEM_CONFIG -and $truthy -ccontains $env:UV_NO_SYSTEM_CONFIG.ToLowerInvariant()) { return $null }
  if (_OnWindows) {
    $system = @(if ($env:SYSTEMDRIVE) { [System.IO.Path]::Combine("$env:SYSTEMDRIVE\", 'ProgramData', 'uv', 'uv.toml') })
  }
  else {
    $dirs = if ($env:XDG_CONFIG_DIRS) { $env:XDG_CONFIG_DIRS } else { '/etc/xdg' }
    $system = @($dirs.Split(':') | Where-Object { $_.StartsWith('/', [System.StringComparison]::Ordinal) } |
        ForEach-Object { [System.IO.Path]::Combine($_, 'uv', 'uv.toml') }) + '/etc/uv/uv.toml'
  }
  foreach ($path in $system) {
    if ([System.IO.File]::Exists($path)) { return $path }
  }
  return $null
}

# _DenPyExe - the python to run in uv run's place when no venv's own runs: the
# system Python uv finds, else one uv installed (uv python install); $null when
# there is none. --system skips the .venv here, and --no-config the
# .python-version, uv.toml and pyproject.toml here: a .python-version may name a
# program in the repository, which uv would run to ask its version.
function global:_DenPyExe {
  $uv = _ResolveCmd 'uv' 'App'
  if (-not $uv) { return $null }
  foreach ($kind in '--no-managed-python', '--managed-python') {
    # uv prints the path, or nothing on stdout when it finds none.
    $found = @(& $uv python find --system --no-config $kind 2>$null)
    $path = if ($found.Count -ge 1) { [string]$found[0] } else { '' }
    if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
  }
  return $null
}

# _DenUvMarker <uv-args> - what _DenPyMarker finds where uv reads, given those
# of uv's options (vv's and vva's; python's none, as its own arguments follow
# a --) and UV_WORKING_DIR, UV_WORKING_DIRECTORY and UV_PROJECT, as
# @{ Marker; At; There; Here }: Marker is the file ($null when there is none);
# At says where the walk started, 'here or above' or 'in or above <dir>', and
# There is 'here or above' or 'there or above', for vv's warning; Here is the
# directory uv runs in, '' when that is the current location, and $null when
# it cannot be told (uv cannot enter it, or the way there passes /proc/self).
# uv first enters the directory --directory names (else UV_WORKING_DIR, else
# UV_WORKING_DIRECTORY) and reads from there as it would from here. --project
# (else UV_PROJECT) names the directory its walk starts from instead, or a
# pyproject.toml in it, taken from the one uv runs in, where a
# .python-version's bare name is still looked up. The options count as uv
# 0.13.6 parses them: as --directory DIR or --directory=DIR; uv refuses a
# second one, and a value that starts with -, so no other option's value is
# one. PowerShell drops a typed -- from $Args, so uv gets none. Not one of the
# overrides that toggle-uv removes: vv and vva ask it with them off as well.
# Parity with posix python.sh (_den_uv_where and _den_uv_marker).
function global:_DenUvMarker([object[]]$UvArgs = @()) {
  $UvArgs = @($UvArgs)
  $dir = if ($env:UV_WORKING_DIR) { $env:UV_WORKING_DIR } else { $env:UV_WORKING_DIRECTORY }
  $project = $env:UV_PROJECT
  for ($i = 0; $i -lt $UvArgs.Count; $i++) {
    $arg = [string]$UvArgs[$i]
    if ($arg -ceq '--') { break }
    if ($arg -ceq '--directory') { $dir = if (++$i -lt $UvArgs.Count) { [string]$UvArgs[$i] } }
    elseif ($arg -ceq '--project') { $project = if (++$i -lt $UvArgs.Count) { [string]$UvArgs[$i] } }
    elseif ($arg.StartsWith('--directory=', [System.StringComparison]::Ordinal)) { $dir = $arg.Substring(12) }
    elseif ($arg.StartsWith('--project=', [System.StringComparison]::Ordinal)) { $project = $arg.Substring(10) }
  }
  $found = @{ Marker = $null; At = 'here or above'; There = 'here or above'; Here = '' }
  if (-not $dir -and -not $project) {
    $found['Marker'] = _DenPyMarker
    return $found
  }
  $found['Here'] = $null
  # The directory uv runs in, as the system reads it back to uv, worked out
  # without setting the process's current directory, which every runspace
  # of the process shares (ForEach-Object -Parallel, Start-ThreadJob). uv
  # starts in this location and enters the --directory from there. Windows
  # keeps a directory by name, as GetFullPath makes it; Windows PowerShell
  # 5.1, whose .NET has no GetFullPath(path, basePath), takes a \name or a
  # C:name from the process's own drive and directory there. Linux and
  # macOS resolve each symbolic link on the way, and a .. after one goes up
  # from where it led (.NET's SetCurrentDirectory takes a path by name
  # first, and read <link>/.. back as the directory that holds the link):
  # read here name by name, each link replaced with its target
  # (FileSystemInfo.LinkTarget, .NET 6, pwsh 7.2), at most 40 to a path, as
  # Linux follows. pwsh 7.0 and 7.1 have no LinkTarget and take the path by
  # name. Where a name is no directory, uv cannot enter it either, and stops
  # before it reads anything. GetFullPath takes a relative --project from
  # there, normalized by name, as uv does.
  $procrel = $null
  try {
    $base = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
    if ((_OnWindows) -or -not [System.IO.FileSystemInfo].GetProperty('LinkTarget')) {
      $here = if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($base, "$dir"))
      }
      else { [System.IO.Path]::GetFullPath("$dir", $base) }
      if (-not [System.IO.Directory]::Exists($here)) { return $found }
      $root = [System.IO.Path]::GetPathRoot($here)
      if ($here.Length -gt $root.Length) {
        $here = $here.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
      }
    }
    else {
      $here = '/'
      :paths foreach ($path in $base, "$dir") {
        if ($path.StartsWith('/', [System.StringComparison]::Ordinal)) { $here = '/' }
        $parts = [System.Collections.Generic.List[string]]::new([string[]]$path.Split('/'))
        $links = 0
        while ($parts.Count -gt 0) {
          $part = $parts[0]
          $parts.RemoveAt(0)
          if (-not $part -or $part -ceq '.') { continue }
          if ($part -ceq '..') {
            $here = $here.Substring(0, [Math]::Max(1, $here.LastIndexOf('/')))
            continue
          }
          $next = $here.TrimEnd('/') + '/' + $part
          # /proc/self names the process that reads it: here this one, for
          # uv uv itself, which starts in this location and not in this
          # process's directory. A way through it (a clone's link to
          # /proc/self/cwd) leads uv elsewhere than this walk, so vv takes
          # --no-config, as for a marker.
          if ($next -cmatch '^/proc/(self|thread-self)$') { $procrel = $next; break paths }
          $target = [System.IO.FileInfo]::new($next).LinkTarget
          if ($target) {
            if (++$links -gt 40) { return $found }
            if ($target.StartsWith('/', [System.StringComparison]::Ordinal)) { $here = '/' }
            $parts.InsertRange(0, [string[]]$target.Split('/'))
          }
          elseif ([System.IO.Directory]::Exists($next)) { $here = $next }
          else { return $found }
        }
      }
    }
    $start = $here
    if ($project) {
      $start = if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($here, $project))
      }
      else { [System.IO.Path]::GetFullPath($project, $here) }
      $root = [System.IO.Path]::GetPathRoot($start)
      if ($start.Length -gt $root.Length) {
        $start = $start.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
      }
      if ([System.IO.Path]::GetFileName($start) -ceq 'pyproject.toml' -and [System.IO.File]::Exists($start)) {
        $start = [System.IO.Path]::GetDirectoryName($start)
      }
    }
  }
  catch { return $found }
  $found['There'] = 'there or above'
  if ($procrel) {
    $found['Marker'] = $procrel
    $found['At'] = 'on the way there, which uv reads for its own process'
  }
  else {
    $found['Here'] = if ($dir) { $here } else { '' }
    $found['At'] = "in or above $start"
    $found['Marker'] = _DenPyMarker $start $here
  }
  return $found
}

# _DenPyRun <name> <args> - what python, python3 and py run: uv run python, with
# the version of the venv va activated, and outside a venv a line that says so.
# Not where uv run would build or run code that came with a clone: with one of
# _DenPyMarker's files where uv run reads, this directory or one above it, or
# where UV_WORKING_DIR, UV_WORKING_DIRECTORY or UV_PROJECT moves it
# (_DenUvMarker), uv run builds that project (its build backend is the
# repository's own code) or runs a python it names, even for `python
# --version`. There a python runs directly, for --version and -V too: the
# active venv's own, with no warning, as on cmd, else, after a warning, the one
# _DenPyExe names. Elsewhere --version and -V go through uv run as well, so
# they name the python that `python x.py` runs. With uv gone since den loaded,
# the python on PATH. Parity with posix python.sh.
# Returns @{ Exe; Args }, or @{ Error } for the caller to write under its own
# name; the caller reads them as ['Error'], since reading a missing key as
# .Error is an error under a caller's Set-StrictMode.
function global:_DenPyRun([string]$Name, [object[]]$PyArgs = @()) {
  $PyArgs = @($PyArgs)
  $uv = _ResolveCmd 'uv' 'App'
  if (-not $uv) {
    $exe = _ResolveCmd $(if ($Name -eq 'python3') { 'python3' } else { 'python' }) 'App'
    if (-not $exe) { return @{ Error = 'no python on PATH, and uv is not on PATH either' } }
    return @{ Exe = $exe; Args = $PyArgs }
  }
  $marker = (_DenUvMarker)['Marker']
  if ($marker) {
    if ($env:VIRTUAL_ENV) {
      foreach ($rel in 'Scripts/python.exe', 'bin/python') {
        $path = Join-Path $env:VIRTUAL_ENV $rel
        if (Test-Path -LiteralPath $path -PathType Leaf) { return @{ Exe = $path; Args = $PyArgs } }
      }
    }
    $exe = _DenPyExe
    if (-not $exe) { return @{ Error = 'no Python found to run in place of uv run; uv python install installs one' } }
    Write-Warning "${Name}: running $exe, not uv run: uv run would build or run code from $marker"
    return @{ Exe = $exe; Args = $PyArgs }
  }
  if ($env:VIRTUAL_ENV -and $env:_DEN_VENV_PYTHON) {
    return @{ Exe = $uv; Args = @('run', '--python', $env:_DEN_VENV_PYTHON, '--', 'python') + $PyArgs }
  }
  Show-UvOnlyMessage "$Name $($PyArgs -join ' ')" "uv run -- python $($PyArgs -join ' ')"
  return @{ Exe = $uv; Args = @('run', '--', 'python') + $PyArgs }
}

# python → _DenPyRun
function python {
  $run = _DenPyRun 'python' (_DenPyArgs $MyInvocation $Args)
  if ($run['Error']) { Write-Error $run['Error']; return }
  _DenPyCall $run['Exe'] $run['Args']
}

# python3 → _DenPyRun
function python3 {
  $run = _DenPyRun 'python3' (_DenPyArgs $MyInvocation $Args)
  if ($run['Error']) { Write-Error $run['Error']; return }
  _DenPyCall $run['Exe'] $run['Args']
}

# py → _DenPyRun
function py {
  $run = _DenPyRun 'py' (_DenPyArgs $MyInvocation $Args)
  if ($run['Error']) { Write-Error $run['Error']; return }
  _DenPyCall $run['Exe'] $run['Args']
}

# toggle-uv leaves _DEN_UV_OVERRIDE in the environment, so a reload (a new pwsh)
# or a child pwsh inherits its OFF: drop the overrides again, as toggle-uv left
# them, or its next call would take the OFF branch again and change nothing.
# toggle-uv's ON sets it to 1 before it reads this file. Parity with python.sh,
# down to the helpers python, python3 and py call: the same names as toggle-uv,
# which keeps _DenPyMarker, _DenUvMarker and _DenUvConfig for vv and vva.
if ($env:_DEN_UV_OVERRIDE -eq '0') {
  foreach ($_uvOverride in 'uv', 'python', 'python3', 'pip', 'pip3', 'py', 'Show-UvOnlyMessage', '_DenPyExe', '_DenPyRun') {
    Remove-Item "Function:\$_uvOverride" -ErrorAction SilentlyContinue
  }
  Remove-Variable _uvOverride -ErrorAction SilentlyContinue
}

# ===== venv management =====

# va → activate Python venv (default: .venv)
# No message here writes a "va: " prefix of its own: PowerShell attributes an
# error to the function that RAISED it, so one would reach stderr as
# "va: va: ...".
function va {
  param([string]$Name = '.venv')
  # Scripts/ on Windows, bin/ on Linux/macOS. python -m venv writes Activate.ps1,
  # uv and virtualenv write activate.ps1: a case-sensitive file system (Linux,
  # case-sensitive macOS) needs both spellings, and the standard one wins when
  # both exist. -LiteralPath keeps wildcard chars in $Name (*, ?, []) from
  # glob-expanding to an unintended script that would then be dot-sourced;
  # -PathType Leaf requires a file.
  $activatePath = $null
  foreach ($rel in 'Scripts/Activate.ps1', 'Scripts/activate.ps1', 'bin/Activate.ps1', 'bin/activate.ps1') {
    $candidate = Join-Path $Name $rel
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $activatePath = $candidate; break }
  }
  if (-not $activatePath) {
    Write-Error "activate script not found under '$Name' (Scripts/ or bin/)"
    return
  }
  # The activate script is dot-sourced into THIS session, so the venv's own content
  # is checked the way pyvenv.cfg below already is. A venv you create is untracked;
  # a venv COMMITTED to a repo (git tracks .venv happily, even force-added past a
  # .gitignore) is code that arrived with the clone. Not a git repo, or no git,
  # means nothing to check: pass. So the check covers git checkouts only: a venv
  # that came in an archive or a shared folder is dot-sourced as it is, as a
  # typed . would dot-source it. Parity with posix python.sh.
  # A venv tool makes Scripts/ or bin/ and the activate script a real directory
  # and file. A symlink or junction there reads the script from elsewhere, and git
  # reports only the link itself, not a tracked file behind it: refuse it. A
  # symlinked venv directory (.venv -> ~/venvs/proj) is fine; git -C follows it
  # into the venv's own repository. LinkType, not the ReparsePoint attribute,
  # which OneDrive also sets on its files.
  foreach ($p in (Split-Path -Parent $activatePath), $activatePath) {
    $linkItem = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if ($linkItem -and $linkItem.PSObject.Properties['LinkType'] -and $linkItem.LinkType -in 'SymbolicLink', 'Junction') {
      Write-Error "'$Name': $p is a symlink or junction, which no venv tool makes; dot-source it yourself if you trust it: . $activatePath"
      return
    }
  }
  $gitExe = _ResolveCmd 'git' 'App'
  if ($gitExe) {
    # Ask from inside the activate script's directory, about all of it: git then
    # learns the directory's name from the file system (Git for Windows asks it for
    # the stored name), so "." lists what is tracked there under a spelling the
    # file system folds and :(icase), which folds ASCII only, does not. The ../
    # pathspecs cover Scripts/, bin/ and pyvenv.cfg as before.
    # Test-Path above ignores case on NTFS and default APFS and git pathspecs do not,
    # so :(icase) also catches a committed SCRIPTS/Activate.ps1. The exact names
    # still match when GIT_LITERAL_PATHSPECS=1 makes :(icase) a plain file name.
    # safe.bareRepository=explicit: a venv committed with a HEAD, objects/, refs/
    # and a config of its own is a repository git would read instead, with an
    # empty index (nothing tracked) and a core.fsmonitor it runs. Git then refuses,
    # and the refusal below fails closed. Git before 2.38 ignores the key and
    # cannot be kept out of such a repository.
    # core.fsmonitor= (empty, off): the enclosing repository's .git/config, which
    # an archive or a shared folder can deliver with the tree, may name a program
    # git runs when it reads the index, even for a venv it then refuses. Empty,
    # not false: git 2.36 and later read the key as a boolean first
    # (fsmonitor-settings.c, lookup_fsmonitor_settings), and an empty value is
    # false; git 2.16 to 2.35 read it as the path of a hook alone and take an
    # empty one for none (config.c, git_config_get_fsmonitor), where false names
    # a program to run. Git before 2.16 has no fsmonitor. The other programs
    # such a config can name (hooks, filters, diff.external, core.sshCommand)
    # do not run for ls-files, and its pager runs on a terminal only, which
    # these calls' output never is.
    # Without git's variables that pick a repository, an index or where the
    # search for one stops: the question is whether the venv's own directory
    # sits in a checkout, which git finds by searching up from there. A
    # GIT_CEILING_DIRECTORIES at the checkout's top, a GIT_DIR that is empty,
    # relative or not there, a GIT_OBJECT_DIRECTORY that is not there, an
    # absolute GIT_INDEX_FILE (git sets one in the shell `git commit -a` starts
    # for its editor) or the GIT_DIR and GIT_WORK_TREE of a yadm or vcsh
    # "enter" shell made git answer "not a git repository" or nothing tracked,
    # and va dot-sourced a committed activate script. Removed for the two calls
    # and put back after them: Remove-Item, as an empty value (what
    # [Environment]::SetEnvironmentVariable($n, $null) leaves a child on Linux)
    # is a GIT_DIR that git cannot open, and the session keeps its own.
    $activateDir = Split-Path -Parent $activatePath
    $pathspecs = @('.') + ('Scripts', 'bin', 'pyvenv.cfg' | ForEach-Object { "../$_"; ":(icase)../$_" })
    $gitVars = [ordered]@{}
    foreach ($n in 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'GIT_CEILING_DIRECTORIES', 'GIT_IMPLICIT_WORK_TREE',
      'GIT_OBJECT_DIRECTORY', 'GIT_NAMESPACE', 'GIT_DISCOVERY_ACROSS_FILESYSTEM') {
      $gitVars[$n] = [Environment]::GetEnvironmentVariable($n)
      Remove-Item -LiteralPath "Env:$n" -ErrorAction SilentlyContinue
    }
    try {
      $tracked = & $gitExe -c core.fsmonitor= -c safe.bareRepository=explicit -C $activateDir ls-files -- $pathspecs 2>$null
      if ($LASTEXITCODE -ne 0) {
        # Fail closed: only "not a git repository" means nothing to check. Any
        # other failure, such as a checkout git will not open for dubious
        # ownership, leaves a committed venv possible. LC_ALL=C keeps git's
        # message in English. Any line of git's, as trace lines may come first,
        # and only from its start, as other messages quote a path that may hold
        # the same words.
        $lcAll = $env:LC_ALL
        $env:LC_ALL = 'C'
        try { $why = @(& $gitExe -c core.fsmonitor= -c safe.bareRepository=explicit -C $activateDir ls-files -- . 2>&1 | ForEach-Object { "$_" }) }
        catch { $why = @("$_") }
        finally { $env:LC_ALL = $lcAll }
        if (-not ($why -match '^fatal: not a git repository')) {
          # Show git's fatal line, else its first.
          $reason = @(@($why -match '^fatal:') + $why) | Select-Object -First 1
          Write-Error "'$Name': git could not tell whether the venv is committed ($reason); dot-source it yourself if you trust it: . $activatePath"
          return
        }
        $tracked = $null
      }
    }
    finally {
      foreach ($n in $gitVars.Keys) {
        if ($null -ne $gitVars[$n]) { Set-Item -LiteralPath "Env:$n" -Value $gitVars[$n] }
      }
    }
    if ($tracked) {
      # Name what git actually reports: the match may be pyvenv.cfg alone, so a
      # message about the activate script would be wrong. git names paths from the
      # activate script's directory; name them from the venv, as it always has.
      $activateDirName = Split-Path -Leaf $activateDir
      $trackedList = (@($tracked | ForEach-Object { if ($_.StartsWith('../')) { $_.Substring(3) } else { "$activateDirName/$_" } }) -join ', ')
      Write-Error "'$Name': venv content is tracked by git ($trackedList) - a venv committed to the repo; dot-source it yourself if you trust it: . $activatePath"
      return
    }
  }
  # Anyone-can-rewrite is the other way this file stops being ours. UnixMode is a
  # pwsh 7 property on Linux/macOS only (position 9 is the other-write bit);
  # Windows has no equivalent bit, so the check is skipped there.
  $item = Get-Item -LiteralPath $activatePath -ErrorAction SilentlyContinue
  $unixMode = if ($item -and $item.PSObject.Properties['UnixMode']) { [string]$item.UnixMode } else { '' }
  if ($unixMode.Length -ge 9 -and $unixMode[8] -eq 'w') {
    Write-Error "'$activatePath' is world-writable - dot-source it yourself if you trust it: . $activatePath"
    return
  }
  # Each activate script undoes only its own kind of venv before it activates:
  # python's keeps the old PATH in $env:_OLD_VIRTUAL_PATH, uv's and virtualenv's in
  # a global variable, so switching between the two kinds without vd kept the
  # first venv's bin/ on PATH for good. The active venv's own deactivate knows.
  if ($env:VIRTUAL_ENV -and (Get-Command deactivate -CommandType Function -ErrorAction SilentlyContinue)) {
    deactivate
  }
  # The version is read below for the venv being activated. Without a pyvenv.cfg
  # there (posix va unsets it too), or when its activate script fails, the previous
  # venv's version must not stay behind.
  Remove-Item Env:\_DEN_VENV_PYTHON -ErrorAction SilentlyContinue
  . $activatePath
  $cfg = Join-Path $Name 'pyvenv.cfg'
  if (Test-Path -LiteralPath $cfg) {
    $pyverRaw = (Get-Content -LiteralPath $cfg | Where-Object { $_ -match '^version_info\s*=' } | Select-Object -First 1) -replace '^version_info\s*=\s*' -replace '\s+$'
    # virtualenv (tox, nox, the virtualenv CLI) writes all five version_info fields,
    # e.g. "3.12.3.final.0", which uv reads as an executable NAME and rejects; keep
    # the MAJOR.MINOR.PATCH prefix uv understands.
    $pyver = (($pyverRaw -split '\.') | Select-Object -First 3) -join '.'
    # allowlist validation is required - pyvenv.cfg is untrusted (parity with posix python.sh)
    if ($pyver -match '^[0-9]+(\.[0-9]+)*$') {
      $env:_DEN_VENV_PYTHON = $pyver
    }
    else {
      if ($pyverRaw) { Write-Warning "va: rejecting suspicious version_info='$pyverRaw' from pyvenv.cfg" }
      Remove-Item Env:\_DEN_VENV_PYTHON -ErrorAction SilentlyContinue
    }
  }
}

# vd → deactivate Python venv
function vd {
  if (-not $env:VIRTUAL_ENV) {
    Write-Error 'No active venv'
    return
  }
  deactivate
  Remove-Item Env:\_DEN_VENV_PYTHON -ErrorAction SilentlyContinue
}

# _DenUvVenvOptions <name> <args> [found] - the options vv and vva put before
# venv, given the arguments they put after it: none, but where _DenUvMarker
# finds a file (<found>, when the caller has it already), as python runs no uv
# run there, --no-config, after a warning: uv venv runs the program a
# .python-version names to ask its version, and a uv.toml's or
# pyproject.toml's settings can have it run a python the clone ships, or
# install one from the clone's own files and run it, --python 3.13 given or
# not. --no-config skips those files, and with them a .python-version that
# only pins a version, yours in uv's config directory too: the warning says
# to pick a python with --python, or to type uv venv. With a uv.toml of your
# own (_DenUvConfig), --config-file reads it, as --no-config alone would not,
# and still no .python-version. The walk starts where uv's does
# (_DenUvMarker). Parity with posix python.sh.
# _DenUvVenvOptions, vv and vva are defined global:, as the helpers python
# calls are (see above): toggle-uv ON dot-sources this file inside itself, and
# in a session whose toggle-uv came from an older python.ps1, a plain
# definition ended with the call, and that file's vv, which reads a clone's
# settings, stayed.
function global:_DenUvVenvOptions([string]$Name, [object[]]$UvArgs = @(), [hashtable]$Found = $null) {
  if (-not $Found) { $Found = _DenUvMarker $UvArgs }
  $marker = $Found['Marker']
  if (-not $marker) { return }
  $at = $Found['At']
  $there = $Found['There']
  $cfg = _DenUvConfig
  if ($cfg) {
    Write-Warning "${Name}: uv --no-config --config-file $cfg venv, as $marker is $at (reads your uv settings, not a .python-version, uv.toml or pyproject.toml $there, which a clone can ship, nor your global .python-version; pick a python with --python, or type uv venv to read those)"
    '--no-config', '--config-file', $cfg
  }
  else {
    Write-Warning "${Name}: uv --no-config venv, as $marker is $at (reads no .python-version, uv.toml or pyproject.toml $there, which a clone can ship, nor your global .python-version; pick a python with --python, or type uv venv to read those)"
    '--no-config'
  }
}

# vv → uv venv (create only)
function global:vv {
  if (-not (_ResolveCmd 'uv' 'App')) {
    Write-Error 'uv is not installed'
    return
  }
  $options = @(_DenUvVenvOptions 'vv' $Args)
  _DenPyCall (_ResolveCmd 'uv' 'App') (@($options) + @('venv') + (_DenPyArgs $MyInvocation $Args))
}

# vva [name] [uv venv options] → uv venv + activate (default: .venv). The
# venv's name is the first argument when it is not an option, else .venv,
# and vva hands it to uv venv itself, so that it activates the venv uv just
# made: it took the first argument for the name, an option too (`vva --python
# 3.13 x` dot-sourced a --python/bin/activate.ps1 that could be there, not
# x's), and took the name from here where --directory, UV_WORKING_DIR or
# UV_WORKING_DIRECTORY had uv make it elsewhere. A second name after an option
# is uv's to refuse, as is a venv already there unless you have uv replace it:
# uv venv then fails, and vva activates nothing. A relative name is taken from
# the directory uv runs in as _DenUvMarker reads it, link by link: PowerShell
# would take a .. after a link by name, elsewhere than uv. Where uv succeeds,
# vva activates the venv only when nothing was at its path before uv venv ran
# (a link that leads nowhere counts as something; Get-Item finds one where
# Test-Path may not) and one of va's activate scripts is there after: uv also
# succeeds when it makes no venv (--help, -h) or keeps or remakes the one
# there (--allow-existing, --clear), and vva then activated a venv that was
# already there, such as a .venv that came in an archive, for a typed `vva
# --help`. It now activates nothing then, and says so in an error; va <path>
# activates a venv that was there, with va's own checks. Parity with posix
# python.sh.
function global:vva {
  if (-not (_ResolveCmd 'uv' 'App')) {
    Write-Error 'uv is not installed'
    return
  }
  # [object[]], not @(): _DenPyArgs returns its words as one array.
  $words = [object[]](_DenPyArgs $MyInvocation $Args)
  if ($null -eq $words) { $words = @() }
  $name = '.venv'
  if ($words.Count -ge 1 -and "$($words[0])" -and -not "$($words[0])".StartsWith('-', [System.StringComparison]::Ordinal)) {
    $name = $words[0]
    $words = @($words | Select-Object -Skip 1)
  }
  $words = @(, $name) + $words
  $found = _DenUvMarker $words
  $options = @(_DenUvVenvOptions 'vva' $words $found)
  # The path va gets: $null where vva cannot tell it.
  $target = "$name"
  if (-not ([System.IO.Path]::IsPathRooted($target) -or $target.StartsWith('~', [System.StringComparison]::Ordinal))) {
    if ($null -eq $found['Here']) { $target = $null }
    elseif ($found['Here']) { $target = [System.IO.Path]::Combine($found['Here'], $target) }
  }
  $was = $null -ne $target -and ((Test-Path -LiteralPath $target) -or $null -ne (Get-Item -LiteralPath $target -Force -ErrorAction Ignore))
  _DenPyCall (_ResolveCmd 'uv' 'App') (@($options) + @('venv') + $words)
  if ($LASTEXITCODE -ne 0) { return }
  if ($null -eq $target) {
    Write-Error "uv venv made '$name' where vva cannot tell; activate it with va <its path>"
    return
  }
  if ($was) {
    Write-Error "'$target' was there before uv venv ran, so vva activates nothing; activate it with va '$target'"
    return
  }
  $made = $false
  foreach ($rel in 'Scripts/Activate.ps1', 'Scripts/activate.ps1', 'bin/Activate.ps1', 'bin/activate.ps1') {
    if (Test-Path -LiteralPath (Join-Path $target $rel) -PathType Leaf) { $made = $true; break }
  }
  if (-not $made) {
    Write-Error "uv venv made no activate script under '$target' (Scripts/ or bin/), so vva activates nothing"
    return
  }
  va $target
}

# ===== Toggles =====

# toggle-uv → flip uv python/pip override on/off
function toggle-uv {
  # The overrides and the helpers python, python3 and py call, as posix
  # toggle-uv unsets them. ON copies each from the file it reads, and the file
  # defines the helpers global: itself, so after den install updated python.ps1
  # in place python runs with that file's helpers, not the ones this session
  # loaded before. That holds also in a session whose toggle-uv came from an
  # older python.ps1, whose list names no helper. A new helper goes here and in
  # the list above, and is defined global: too. _DenPyMarker and
  # _DenUvMarker, which python calls, and _DenUvConfig, which pip and pip3
  # call, are not on the list: vv and vva ask them with the overrides off as
  # well, and ON defines them global: when it reads the file, as it does vv,
  # vva and _DenUvVenvOptions.
  $overrides = 'uv', 'python', 'python3', 'pip', 'pip3', 'py', 'Show-UvOnlyMessage', '_DenPyExe', '_DenPyRun'
  if ($env:_DEN_UV_OVERRIDE -ne '0') {
    foreach ($name in $overrides) { Remove-Item "Function:\$name" -ErrorAction SilentlyContinue }
    $env:_DEN_UV_OVERRIDE = '0'
    Write-Host 'uv override: ' -NoNewline
    Write-Host 'OFF' -ForegroundColor Yellow -NoNewline
    Write-Host ' (using system python/pip)'
  }
  else {
    # Re-read the python.ps1 this function came from ($PSScriptRoot, where
    # init.ps1 loaded it), not the one next to $PROFILE: that is another copy,
    # or none, when init.ps1 runs from a checkout.
    $src = Join-Path $PSScriptRoot 'python.ps1'
    # Set before the file is read: it drops the overrides again while this is 0.
    $env:_DEN_UV_OVERRIDE = '1'
    if (Test-Path -LiteralPath $src) { . $src }
    # Dot-sourcing from inside a function defines everything in THIS function's
    # scope, gone once toggle-uv returns; copy the overrides to global scope so
    # they outlive the call (posix functions are always global, hence no such
    # step in python.sh).
    $restored = @()
    foreach ($name in $overrides) {
      $fn = Get-Item "Function:\$name" -ErrorAction SilentlyContinue
      if ($fn) {
        Set-Item -Path "Function:global:$name" -Value $fn.ScriptBlock
        $restored += $fn
      }
    }
    # Typed at the prompt only, as at load (see _DenScopeOverrides): a session
    # that started with the overrides OFF never recorded these names, and its
    # scripts would get den's python/pip/uv from here on.
    _DenRecordOverrides $restored
    # python.ps1 defines nothing once uv stops resolving (its first line), so
    # claiming ON here would leave plain python/pip behind an ON message.
    if ($restored.Count -eq 0) {
      $env:_DEN_UV_OVERRIDE = '0'
      Write-Warning "toggle-uv: could not load the uv overrides from $src (is uv on PATH?); still OFF"
      return
    }
    Write-Host 'uv override: ' -NoNewline
    Write-Host 'ON' -ForegroundColor Green -NoNewline
    # Double quotes: Windows PowerShell 5.1 reads this BOM-less file in the ANSI
    # code page, where the arrow's last byte is a curly ' that would end a
    # single-quoted string and leave the whole file unparsable.
    Write-Host " (python/pip → uv)"
  }
}

# tgl-uv → short name for toggle-uv
function tgl-uv {
  toggle-uv @Args
}
