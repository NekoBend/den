# python.ps1 — Python/uv helper functions for PowerShell.
# Dot-sourced by init.ps1.

if (-not (_ResolveCmd 'uv' 'App')) { return }

# ===== uv overrides =====

# uv → auto-inject --python for 'uv run' when venv is active
function uv {
  if ($env:VIRTUAL_ENV -and $env:_DEN_VENV_PYTHON -and $Args.Count -ge 1 -and $Args[0] -eq 'run') {
    $rest = @($Args | Select-Object -Skip 1)
    # `--` ends uv's OWN option parsing, so injecting it unconditionally turned
    # every `uv run` option into the command to spawn (`uv run --with rich app.py`
    # -> "Failed to spawn: --with"). Only separate when the first user argument
    # cannot be mistaken for a uv option. Parity with posix python.sh.
    if ($rest.Count -ge 1 -and ([string]$rest[0]).StartsWith('-')) {
      & (_ResolveCmd 'uv' 'App') run --python $env:_DEN_VENV_PYTHON @rest
    }
    else {
      & (_ResolveCmd 'uv' 'App') run --python $env:_DEN_VENV_PYTHON -- @rest
    }
  }
  else {
    & (_ResolveCmd 'uv' 'App') @Args
  }
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
function pip {
  if (-not $env:VIRTUAL_ENV) {
    Write-Error "no venv is active; activate one with va, or type $((@('uv', 'pip') + $Args) -join ' ') directly"
    return
  }
  $venvPip = @('Scripts/pip.exe', 'bin/pip') | ForEach-Object { Join-Path $env:VIRTUAL_ENV $_ } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if ($venvPip) { & $venvPip @Args; return }
  if (-not (_ResolveCmd 'uv' 'App')) { Write-Error "the active venv has no pip and uv is not on PATH: $env:VIRTUAL_ENV"; return }
  Show-UvOnlyMessage "pip $($Args -join ' ')" "uv pip $($Args -join ' ')"
  & uv pip @Args
}

# pip3 → the same, with an active venv's own pip3
function pip3 {
  if (-not $env:VIRTUAL_ENV) {
    Write-Error "no venv is active; activate one with va, or type $((@('uv', 'pip') + $Args) -join ' ') directly"
    return
  }
  $venvPip = @('Scripts/pip3.exe', 'bin/pip3') | ForEach-Object { Join-Path $env:VIRTUAL_ENV $_ } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if ($venvPip) { & $venvPip @Args; return }
  if (-not (_ResolveCmd 'uv' 'App')) { Write-Error "the active venv has no pip3 and uv is not on PATH: $env:VIRTUAL_ENV"; return }
  Show-UvOnlyMessage "pip3 $($Args -join ' ')" "uv pip $($Args -join ' ')"
  & uv pip @Args
}

# The three helpers python, python3 and py call are defined global:. toggle-uv
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
# .python-version counts only when it names a path: a line with / or \ in it,
# comment (#) and blank lines aside. One that holds version requests alone
# (3.13, cpython@3.13) does not, so a pyenv ~/.python-version leaves home
# alone. Windows hands uv the directory as PowerShell has it; Linux and macOS
# resolve its symbolic links first, so there a linked directory's target is
# searched as well.
function global:_DenPyMarker {
  $starts = [System.Collections.Generic.List[string]]::new()
  $starts.Add($ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath)
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
        foreach ($line in $text -split "`n") {
          $line = $line.TrimStart(' ')
          if (-not $line.StartsWith('#', [System.StringComparison]::Ordinal) -and $line.IndexOfAny([char[]]'/\') -ge 0) { return $path }
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

# _DenPyRun <name> <args> - what python, python3 and py run: uv run python, with
# the version of the venv va activated, and outside a venv a line that says so.
# Not where uv run would build or run code that came with a clone: with one of
# _DenPyMarker's files in this directory or one above it, uv run builds that
# project (its build backend is the repository's own code) or runs a python it
# names, even for `python --version`. There a python runs directly, for
# --version and -V too: the active venv's own, with no warning, as on cmd, else,
# after a warning, the one _DenPyExe names. Elsewhere --version and -V go
# through uv run as well, so they name the python that `python x.py` runs. With
# uv gone since den loaded, the python on PATH. Parity with posix python.sh.
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
  $marker = _DenPyMarker
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
  $run = _DenPyRun 'python' $Args
  if ($run['Error']) { Write-Error $run['Error']; return }
  $runArgs = $run['Args']
  & $run['Exe'] @runArgs
}

# python3 → _DenPyRun
function python3 {
  $run = _DenPyRun 'python3' $Args
  if ($run['Error']) { Write-Error $run['Error']; return }
  $runArgs = $run['Args']
  & $run['Exe'] @runArgs
}

# py → _DenPyRun
function py {
  $run = _DenPyRun 'py' $Args
  if ($run['Error']) { Write-Error $run['Error']; return }
  $runArgs = $run['Args']
  & $run['Exe'] @runArgs
}

# toggle-uv leaves _DEN_UV_OVERRIDE in the environment, so a reload (a new pwsh)
# or a child pwsh inherits its OFF: drop the overrides again, as toggle-uv left
# them, or its next call would take the OFF branch again and change nothing.
# toggle-uv's ON sets it to 1 before it reads this file. Parity with python.sh,
# down to the helpers python, python3 and py call: the same names as toggle-uv.
if ($env:_DEN_UV_OVERRIDE -eq '0') {
  foreach ($_uvOverride in 'uv', 'python', 'python3', 'pip', 'pip3', 'py', 'Show-UvOnlyMessage', '_DenPyMarker', '_DenPyExe', '_DenPyRun') {
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
  # means nothing to check: pass. Parity with posix python.sh.
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
    $activateDir = Split-Path -Parent $activatePath
    $pathspecs = @('.') + ('Scripts', 'bin', 'pyvenv.cfg' | ForEach-Object { "../$_"; ":(icase)../$_" })
    $tracked = & $gitExe -c safe.bareRepository=explicit -C $activateDir ls-files -- $pathspecs 2>$null
    if ($LASTEXITCODE -ne 0) {
      # Fail closed: only "not a git repository" means nothing to check. Any other
      # failure, such as a checkout git will not open for dubious ownership, leaves
      # a committed venv possible. LC_ALL=C keeps git's message in English. Any
      # line of git's, as trace lines may come first, and only from its start, as
      # other messages quote a path that may hold the same words.
      $lcAll = $env:LC_ALL
      $env:LC_ALL = 'C'
      try { $why = @(& $gitExe -c safe.bareRepository=explicit -C $activateDir ls-files -- . 2>&1 | ForEach-Object { "$_" }) }
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

# vv → uv venv (create only)
function vv {
  if (-not (_ResolveCmd 'uv' 'App')) {
    Write-Error 'uv is not installed'
    return
  }
  & (_ResolveCmd 'uv' 'App') venv @Args
}

# vva → uv venv + activate (default: .venv)
function vva {
  if (-not (_ResolveCmd 'uv' 'App')) {
    Write-Error 'uv is not installed'
    return
  }
  $name = if ($Args.Count -ge 1) { $Args[0] } else { '.venv' }
  & (_ResolveCmd 'uv' 'App') venv @Args
  if ($LASTEXITCODE -eq 0) { va $name }
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
  # the list above, and is defined global: too.
  $overrides = 'uv', 'python', 'python3', 'pip', 'pip3', 'py', 'Show-UvOnlyMessage', '_DenPyMarker', '_DenPyExe', '_DenPyRun'
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
