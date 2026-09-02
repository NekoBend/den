# aliases.ps1 — Shell aliases (git, docker, editor).
# Requires: wrappers.ps1, coreutils.ps1, and functions.ps1 loaded first.
# Dot-sourced by init.ps1.

# Skip in non-interactive sessions to avoid breaking scripts
if (-not (_DenInteractive)) { return }

# Drop the built-in aliases that would otherwise outrank our same-named git/gitui
# FUNCTIONS below (alias beats function in command resolution): gc=Get-Content,
# gcm=Get-Command, gl=Get-Location, gps=Get-Process, gu=Get-Unique. These are
# default aliases on every platform; -EA SilentlyContinue is a no-op if absent.
foreach ($a in 'gc', 'gcm', 'gl', 'gps', 'gu') {
    Remove-Item "alias:$a" -Force -ErrorAction SilentlyContinue
}

# ===== Git =====

function g {
  & git @Args
}

function ga {
  & git add @Args
}

function gaa {
  & git add --all
}

function gb {
  & git branch @Args
}

function gc {
  & git commit @Args
}

function gcm {
  & git commit -m @Args
}

function gco {
  & git checkout @Args
}

function gd {
  & git diff @Args
}

function gds {
  & git diff --staged @Args
}

function gf {
  & git fetch --all --prune
}

function gl {
  & git log --oneline --graph @Args
}

function gpl {
  & git pull @Args
}

function gps {
  & git push @Args
}

function gst {
  & git status -sb
}

function gsw {
  & git switch @Args
}

# ===== Docker =====

function d {
  & docker @Args
}

function dc {
  & docker compose @Args
}

function dcb {
  & docker compose build @Args
}

function dcd {
  & docker compose down @Args
}

function dce {
  & docker compose exec @Args
}

function dcl {
  & docker compose logs @Args
}

function dcu {
  & docker compose up @Args
}

function di {
  & docker images @Args
}

function dps {
  & docker ps @Args
}

function dri {
  & docker run -it @Args
}

function drir {
  & docker run -it --rm @Args
}

# ===== Editor =====

# code → code-insiders (falls back to code stable)
# Resolve the real EXECUTABLE (_ResolveCmd <name> App) rather than calling a bare
# name: this function is itself named `code`, so a bare `code` would recurse, and
# probing only `code.cmd` -- a Windows-only launcher name -- meant Linux/macOS
# pwsh with stable VS Code installed reported "not installed" instead of opening it.
function code {
  $exe = _ResolveCmd 'code-insiders' 'App'
  if (-not $exe) { $exe = _ResolveCmd 'code' 'App' }
  if (-not $exe) { $exe = _ResolveCmd 'code.cmd' 'App' }
  if (-not $exe) {
    Write-Warning "VS Code is not installed."
    return
  }
  # PowerShell passes arguments to a .cmd/.bat file as ONE raw command line that
  # cmd.exe re-parses (VS Code ships bin\code.cmd on Windows), so an `&` inside a
  # space-free filename would end the command and start a second one. cmd does not
  # split inside quotes, and PowerShell already quotes an argument that contains
  # whitespace -- a second pair would split THAT one -- so quote exactly the
  # arguments it would pass bare, doubling a trailing backslash so the closing
  # quote survives the final argv parse. An argument containing a quote is refused
  # rather than escaped: a Windows filename cannot hold one, and a wrong escape
  # here reopens the hole.
  if ($exe -match '\.(cmd|bat)$') {
    $quoted = @()
    foreach ($a in $Args) {
      $s = [string]$a
      if ($s.Contains('"')) {
        Write-Error "code: refusing an argument that contains a quote: $s"
        return
      }
      if ($s -match '\s') { $quoted += $s }
      else { $quoted += '"' + ($s -replace '(\\+)$', '$1$1') + '"' }
    }
    & $exe @quoted
    return
  }
  & $exe @Args
}

# gu → gitui (terminal git UI)
function gu {
  if (Get-Command gitui -ErrorAction SilentlyContinue) {
    & gitui @Args
  }
  else {
    Write-Warning "gitui is not installed. Install: winget install gitui"
  }
}

# ===== OS Integration =====

# open → open file/directory with default application (macOS-style)
function open {
  param([string]$Path = '.')
  Invoke-Item $Path
}

