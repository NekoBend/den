# hwinfo.ps1 — Detect CPU/GPU and export STARSHIP_* env vars for starship prompt.
# Dot-sourced by Microsoft.PowerShell_profile.ps1.
# Uses env var caching — skips detection if STARSHIP_* vars are already set.

# ===== Hardware info (for starship) =====
# Validate inherited STARSHIP_* values before trusting them.
$_hwVars = @(
  'STARSHIP_CPU_INTEL',
  'STARSHIP_CPU_AMD',
  'STARSHIP_GPU_NVIDIA',
  'STARSHIP_GPU_AMD',
  'STARSHIP_GPU_INTEL'
)
$_isPrintable = {
  param($s)
  ($null -ne $s) -and ($s -match '^[\x20-\x7E]+$') -and $s.Length -le 100
}
foreach ($v in $_hwVars) {
  $cur = [Environment]::GetEnvironmentVariable($v)
  if ($cur -and -not (& $_isPrintable $cur)) {
    Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
  }
}
Remove-Variable _isPrintable -ErrorAction SilentlyContinue

# Uses env var caching — skips detection if STARSHIP_* vars are already set
# (e.g. nested shell, Windows Terminal tab inheritance).
if (-not ($env:STARSHIP_CPU_INTEL -or $env:STARSHIP_CPU_AMD -or
          $env:STARSHIP_GPU_NVIDIA -or $env:STARSHIP_GPU_AMD -or $env:STARSHIP_GPU_INTEL)) {
  $_hwCache = [IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'shell-cache', "hwinfo-cache.$env:COMPUTERNAME.ps1")
  if ((Test-Path -LiteralPath $_hwCache -PathType Leaf) -and
      (Get-Command Test-CacheSafe -ErrorAction SilentlyContinue) -and
      (Test-CacheSafe -Path $_hwCache)) {
    . $_hwCache
  }

  if (-not ($env:STARSHIP_CPU_INTEL -or $env:STARSHIP_CPU_AMD -or
            $env:STARSHIP_GPU_NVIDIA -or $env:STARSHIP_GPU_AMD -or $env:STARSHIP_GPU_INTEL)) {
    if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
      try {
        $cpuName = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -Name ProcessorNameString -ErrorAction Stop).ProcessorNameString.Trim()
        $cpuShort = ($cpuName -replace '\(R\)' -replace '\(TM\)' -replace '\d+\w+ Gen ' -replace 'Genuine ' -replace 'Intel ' -replace 'AMD ' -replace 'Core ' -replace ' CPU.*$' -replace ' \d+-Core Processor' -replace '\s+', ' ').Trim()
        if ($cpuName -match 'Intel') { $env:STARSHIP_CPU_INTEL = $cpuShort }
        elseif ($cpuName -match 'AMD') { $env:STARSHIP_CPU_AMD = $cpuShort }

        # Prefer nvidia-smi for NVIDIA GPUs (more accurate than Win32_VideoController)
        $gpuName = ''
        if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
          $gpuName = (nvidia-smi --query-gpu=gpu_name --format=csv,noheader 2>$null | Select-Object -First 1)?.Trim()
        }
        if (-not $gpuName) {
          $gpuName = (Get-CimInstance Win32_VideoController -ErrorAction Stop | Select-Object -First 1).Name.Trim()
        }
        $gpuShort = ($gpuName -replace 'NVIDIA\s+GeForce\s*' -replace 'AMD\s+' -replace 'Intel\(R\)\s*' -replace '\s+', ' ').Trim()
        if ($gpuName -match 'NVIDIA') { $env:STARSHIP_GPU_NVIDIA = $gpuShort }
        elseif ($gpuName -match 'AMD|Radeon') { $env:STARSHIP_GPU_AMD = $gpuShort }
        elseif ($gpuName -match 'Intel') { $env:STARSHIP_GPU_INTEL = $gpuShort }
      } catch {}
      Remove-Variable cpuName, cpuShort, gpuName, gpuShort -ErrorAction SilentlyContinue
    }

    $lines = @()
    foreach ($v in $_hwVars) {
      $val = [Environment]::GetEnvironmentVariable($v)
      if ($val) {
        $escapedValue = $val.Replace("'", "''")
        $lines += "`$env:$v = '$escapedValue'"
      }
    }

    if ($lines.Count -gt 0) {
      $tmp = $_hwCache + '.tmp.' + [guid]::NewGuid().ToString('N')
      $null = New-Item -ItemType Directory -Path (Split-Path -Parent $_hwCache) -Force -ErrorAction SilentlyContinue
      try {
        $lines -join "`n" | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $_hwCache -Force
      } finally {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) {
          Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
      }
    }
  }
}

# refresh-hwinfo → clear hardware info cache
function refresh-hwinfo {
  Remove-Item -Path ([IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'shell-cache', "hwinfo-cache.$env:COMPUTERNAME.ps1")) -Force -ErrorAction SilentlyContinue
  Write-Host 'hwinfo cache cleared. Restart shell to refresh.'
}

# toggle-hwinfo → flip hardware info display in starship prompt on/off
function toggle-hwinfo {
  if ($env:_DOTFILES_HWINFO_HIDDEN -ne '1') {
    $env:_DOTFILES_SAVED_CPU_INTEL  = $env:STARSHIP_CPU_INTEL
    $env:_DOTFILES_SAVED_CPU_AMD    = $env:STARSHIP_CPU_AMD
    $env:_DOTFILES_SAVED_GPU_NVIDIA = $env:STARSHIP_GPU_NVIDIA
    $env:_DOTFILES_SAVED_GPU_AMD    = $env:STARSHIP_GPU_AMD
    $env:_DOTFILES_SAVED_GPU_INTEL  = $env:STARSHIP_GPU_INTEL
    Remove-Item Env:\STARSHIP_CPU_INTEL  -ErrorAction SilentlyContinue
    Remove-Item Env:\STARSHIP_CPU_AMD    -ErrorAction SilentlyContinue
    Remove-Item Env:\STARSHIP_GPU_NVIDIA -ErrorAction SilentlyContinue
    Remove-Item Env:\STARSHIP_GPU_AMD    -ErrorAction SilentlyContinue
    Remove-Item Env:\STARSHIP_GPU_INTEL  -ErrorAction SilentlyContinue
    $env:_DOTFILES_HWINFO_HIDDEN = '1'
    Write-Host 'hwinfo: ' -NoNewline
    Write-Host 'OFF' -ForegroundColor Yellow -NoNewline
    Write-Host ' (hidden from prompt)'
  }
  else {
    $env:STARSHIP_CPU_INTEL  = $env:_DOTFILES_SAVED_CPU_INTEL
    $env:STARSHIP_CPU_AMD    = $env:_DOTFILES_SAVED_CPU_AMD
    $env:STARSHIP_GPU_NVIDIA = $env:_DOTFILES_SAVED_GPU_NVIDIA
    $env:STARSHIP_GPU_AMD    = $env:_DOTFILES_SAVED_GPU_AMD
    $env:STARSHIP_GPU_INTEL  = $env:_DOTFILES_SAVED_GPU_INTEL
    Remove-Item Env:\_DOTFILES_SAVED_CPU_INTEL  -ErrorAction SilentlyContinue
    Remove-Item Env:\_DOTFILES_SAVED_CPU_AMD    -ErrorAction SilentlyContinue
    Remove-Item Env:\_DOTFILES_SAVED_GPU_NVIDIA -ErrorAction SilentlyContinue
    Remove-Item Env:\_DOTFILES_SAVED_GPU_AMD    -ErrorAction SilentlyContinue
    Remove-Item Env:\_DOTFILES_SAVED_GPU_INTEL  -ErrorAction SilentlyContinue
    $env:_DOTFILES_HWINFO_HIDDEN = '0'
    Write-Host 'hwinfo: ' -NoNewline
    Write-Host 'ON' -ForegroundColor Green -NoNewline
    Write-Host ' (visible in prompt)'
  }
}

Remove-Variable _hwCache, _hwVars, cur, escapedValue, lines, tmp, v, val -ErrorAction SilentlyContinue
