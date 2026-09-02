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

# pip → uv pip (falls back to system pip; bypassed in active venv)
function pip {
  if ($env:VIRTUAL_ENV) {
    & (_ResolveCmd 'pip' 'App') @Args
  }
  elseif (_ResolveCmd 'uv' 'App') {
    Show-UvOnlyMessage "pip $($Args -join ' ')" "uv pip $($Args -join ' ')"
    & uv pip @Args
  }
  else {
    & (_ResolveCmd 'pip' 'App') @Args
  }
}

# pip3 → uv pip (falls back to system pip3; bypassed in active venv)
function pip3 {
  if ($env:VIRTUAL_ENV) {
    & (_ResolveCmd 'pip3' 'App') @Args
  }
  elseif (_ResolveCmd 'uv' 'App') {
    Show-UvOnlyMessage "pip3 $($Args -join ' ')" "uv pip $($Args -join ' ')"
    & uv pip @Args
  }
  else {
    & (_ResolveCmd 'pip3' 'App') @Args
  }
}

# python → uv run python (uses venv version when active)
function python {
  if ($env:VIRTUAL_ENV -and $env:_DEN_VENV_PYTHON -and (_ResolveCmd 'uv' 'App')) {
    & (_ResolveCmd 'uv' 'App') run --python $env:_DEN_VENV_PYTHON -- python @Args
  }
  elseif (_ResolveCmd 'uv' 'App') {
    Show-UvOnlyMessage "python $($Args -join ' ')" "uv run -- python $($Args -join ' ')"
    & (_ResolveCmd 'uv' 'App') run -- python @Args
  }
  else {
    & (_ResolveCmd 'python' 'App') @Args
  }
}

# python3 → uv run python (uses venv version when active)
function python3 {
  if ($env:VIRTUAL_ENV -and $env:_DEN_VENV_PYTHON -and (_ResolveCmd 'uv' 'App')) {
    & (_ResolveCmd 'uv' 'App') run --python $env:_DEN_VENV_PYTHON -- python @Args
  }
  elseif (_ResolveCmd 'uv' 'App') {
    Show-UvOnlyMessage "python3 $($Args -join ' ')" "uv run -- python $($Args -join ' ')"
    & (_ResolveCmd 'uv' 'App') run -- python @Args
  }
  else {
    & (_ResolveCmd 'python3' 'App') @Args
  }
}

# py → uv run python (uses venv version when active)
function py {
  if ($env:VIRTUAL_ENV -and $env:_DEN_VENV_PYTHON -and (_ResolveCmd 'uv' 'App')) {
    & (_ResolveCmd 'uv' 'App') run --python $env:_DEN_VENV_PYTHON -- python @Args
  }
  elseif (_ResolveCmd 'uv' 'App') {
    Show-UvOnlyMessage "py $($Args -join ' ')" "uv run -- python $($Args -join ' ')"
    & (_ResolveCmd 'uv' 'App') run -- python @Args
  }
  else {
    & (_ResolveCmd 'python' 'App') @Args
  }
}

# ===== venv management =====

# va → activate Python venv (default: .venv)
function va {
  param([string]$Name = '.venv')
  # Scripts/ on Windows, bin/ on Linux/macOS (uv/venv place Activate.ps1 there).
  # -LiteralPath keeps wildcard chars in $Name (*, ?, []) from glob-expanding to an
  # unintended script that would then be dot-sourced; -PathType Leaf requires a file.
  $activatePath = Join-Path $Name 'Scripts/Activate.ps1'
  if (-not (Test-Path -LiteralPath $activatePath -PathType Leaf)) {
    $activatePath = Join-Path $Name 'bin/Activate.ps1'
  }
  if (-not (Test-Path -LiteralPath $activatePath -PathType Leaf)) {
    Write-Error "activate script not found under '$Name' (Scripts/ or bin/)"
    return
  }
  # The activate script is dot-sourced into THIS session, so the venv's own content
  # is checked the way pyvenv.cfg below already is. A venv you create is untracked;
  # a venv COMMITTED to a repo (git tracks .venv happily, even force-added past a
  # .gitignore) is code that arrived with the clone. Not a git repo, or no git,
  # means nothing to check: pass. Parity with posix python.sh.
  $gitExe = _ResolveCmd 'git' 'App'
  if ($gitExe) {
    $tracked = & $gitExe -C $Name ls-files -- Scripts/Activate.ps1 bin/Activate.ps1 bin/activate pyvenv.cfg 2>$null
    if ($tracked) {
      Write-Error "va: '$activatePath' is tracked by git (a venv committed to the repo) - dot-source it yourself if you trust it: . $activatePath"
      return
    }
  }
  # Anyone-can-rewrite is the other way this file stops being ours. UnixMode is a
  # pwsh 7 property on Linux/macOS only (position 9 is the other-write bit);
  # Windows has no equivalent bit, so the check is skipped there.
  $item = Get-Item -LiteralPath $activatePath -ErrorAction SilentlyContinue
  $unixMode = if ($item -and $item.PSObject.Properties['UnixMode']) { [string]$item.UnixMode } else { '' }
  if ($unixMode.Length -ge 9 -and $unixMode[8] -eq 'w') {
    Write-Error "va: '$activatePath' is world-writable - dot-source it yourself if you trust it: . $activatePath"
    return
  }
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
  if ($env:_DEN_UV_OVERRIDE -ne '0') {
    Remove-Item Function:\uv -ErrorAction SilentlyContinue
    Remove-Item Function:\python -ErrorAction SilentlyContinue
    Remove-Item Function:\python3 -ErrorAction SilentlyContinue
    Remove-Item Function:\pip -ErrorAction SilentlyContinue
    Remove-Item Function:\pip3 -ErrorAction SilentlyContinue
    Remove-Item Function:\py -ErrorAction SilentlyContinue
    Remove-Item Function:\Show-UvOnlyMessage -ErrorAction SilentlyContinue
    $env:_DEN_UV_OVERRIDE = '0'
    Write-Host 'uv override: ' -NoNewline
    Write-Host 'OFF' -ForegroundColor Yellow -NoNewline
    Write-Host ' (using system python/pip)'
  }
  else {
    $profileDir = Split-Path -Parent $PROFILE
    . "$profileDir\python.ps1"
    $env:_DEN_UV_OVERRIDE = '1'
    Write-Host 'uv override: ' -NoNewline
    Write-Host 'ON' -ForegroundColor Green -NoNewline
    Write-Host ' (python/pip → uv)'
  }
}
