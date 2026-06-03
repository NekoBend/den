# python.ps1 — Python/uv helper functions for PowerShell.
# Dot-sourced by init.ps1.

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { return }

# ===== uv overrides =====

# uv → auto-inject --python for 'uv run' when venv is active
function uv {
  if ($env:VIRTUAL_ENV -and $env:_DOTFILES_VENV_PYTHON -and $Args.Count -ge 1 -and $Args[0] -eq 'run') {
    $rest = @($Args | Select-Object -Skip 1)
    & uv.exe run --python $env:_DOTFILES_VENV_PYTHON -- @rest
  }
  else {
    & uv.exe @Args
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
    & pip.exe @Args
  }
  elseif (Get-Command uv -ErrorAction SilentlyContinue) {
    Show-UvOnlyMessage "pip $($Args -join ' ')" "uv pip $($Args -join ' ')"
    & uv pip @Args
  }
  else {
    & pip.exe @Args
  }
}

# pip3 → uv pip (falls back to system pip3; bypassed in active venv)
function pip3 {
  if ($env:VIRTUAL_ENV) {
    & pip3.exe @Args
  }
  elseif (Get-Command uv -ErrorAction SilentlyContinue) {
    Show-UvOnlyMessage "pip3 $($Args -join ' ')" "uv pip $($Args -join ' ')"
    & uv pip @Args
  }
  else {
    & pip3.exe @Args
  }
}

# python → uv run python (uses venv version when active)
function python {
  if ($env:VIRTUAL_ENV -and $env:_DOTFILES_VENV_PYTHON -and (Get-Command uv -ErrorAction SilentlyContinue)) {
    & uv.exe run --python $env:_DOTFILES_VENV_PYTHON -- python @Args
  }
  elseif (Get-Command uv -ErrorAction SilentlyContinue) {
    Show-UvOnlyMessage "python $($Args -join ' ')" "uv run -- python $($Args -join ' ')"
    & uv.exe run -- python @Args
  }
  else {
    & python.exe @Args
  }
}

# python3 → uv run python (uses venv version when active)
function python3 {
  if ($env:VIRTUAL_ENV -and $env:_DOTFILES_VENV_PYTHON -and (Get-Command uv -ErrorAction SilentlyContinue)) {
    & uv.exe run --python $env:_DOTFILES_VENV_PYTHON -- python @Args
  }
  elseif (Get-Command uv -ErrorAction SilentlyContinue) {
    Show-UvOnlyMessage "python3 $($Args -join ' ')" "uv run -- python $($Args -join ' ')"
    & uv.exe run -- python @Args
  }
  else {
    & python3.exe @Args
  }
}

# py → uv run python (uses venv version when active)
function py {
  if ($env:VIRTUAL_ENV -and $env:_DOTFILES_VENV_PYTHON -and (Get-Command uv -ErrorAction SilentlyContinue)) {
    & uv.exe run --python $env:_DOTFILES_VENV_PYTHON -- python @Args
  }
  elseif (Get-Command uv -ErrorAction SilentlyContinue) {
    Show-UvOnlyMessage "py $($Args -join ' ')" "uv run -- python $($Args -join ' ')"
    & uv.exe run -- python @Args
  }
  else {
    & python.exe @Args
  }
}

# ===== venv management =====

# va → activate Python venv (default: .venv)
function va {
  param([string]$Name = '.venv')
  $activatePath = Join-Path $Name 'Scripts/Activate.ps1'
  if (-not (Test-Path $activatePath)) {
    Write-Error "activate script not found: $activatePath"
    return
  }
  . $activatePath
  $cfg = Join-Path $Name 'pyvenv.cfg'
  if (Test-Path $cfg) {
    $pyver = (Get-Content $cfg | Where-Object { $_ -match '^version_info\s*=' } | Select-Object -First 1) -replace '^version_info\s*=\s*' -replace '\s+$'
    # allowlist validation is required - pyvenv.cfg is untrusted (parity with posix python.sh)
    if ($pyver -match '^[0-9A-Za-z.+-]+$') {
      $env:_DOTFILES_VENV_PYTHON = $pyver
    }
    else {
      if ($pyver) { Write-Warning "va: rejecting suspicious version_info='$pyver' from pyvenv.cfg" }
      Remove-Item Env:\_DOTFILES_VENV_PYTHON -ErrorAction SilentlyContinue
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
  Remove-Item Env:\_DOTFILES_VENV_PYTHON -ErrorAction SilentlyContinue
}

# vv → uv venv (create only)
function vv {
  if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Error 'uv is not installed'
    return
  }
  & uv.exe venv @Args
}

# vva → uv venv + activate (default: .venv)
function vva {
  if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Error 'uv is not installed'
    return
  }
  $name = if ($Args.Count -ge 1) { $Args[0] } else { '.venv' }
  & uv.exe venv @Args
  if ($LASTEXITCODE -eq 0) { va $name }
}

# ===== Toggles =====

# toggle-uv → flip uv python/pip override on/off
function toggle-uv {
  if ($env:_DOTFILES_UV_OVERRIDE -ne '0') {
    Remove-Item Function:\uv -ErrorAction SilentlyContinue
    Remove-Item Function:\python -ErrorAction SilentlyContinue
    Remove-Item Function:\python3 -ErrorAction SilentlyContinue
    Remove-Item Function:\pip -ErrorAction SilentlyContinue
    Remove-Item Function:\pip3 -ErrorAction SilentlyContinue
    Remove-Item Function:\py -ErrorAction SilentlyContinue
    Remove-Item Function:\Show-UvOnlyMessage -ErrorAction SilentlyContinue
    $env:_DOTFILES_UV_OVERRIDE = '0'
    Write-Host 'uv override: ' -NoNewline
    Write-Host 'OFF' -ForegroundColor Yellow -NoNewline
    Write-Host ' (using system python/pip)'
  }
  else {
    $profileDir = Split-Path -Parent $PROFILE
    . "$profileDir\python.ps1"
    $env:_DOTFILES_UV_OVERRIDE = '1'
    Write-Host 'uv override: ' -NoNewline
    Write-Host 'ON' -ForegroundColor Green -NoNewline
    Write-Host ' (python/pip → uv)'
  }
}
