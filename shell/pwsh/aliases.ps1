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

# _ShapeCmdArgs <arguments> — shape an argument array for a .cmd/.bat launcher, or
# throw when an argument cannot be handed to one safely. PowerShell passes the
# arguments of a .cmd/.bat file as ONE raw command line that cmd.exe re-parses
# (VS Code ships bin\code.cmd on Windows), so a bare `&` inside a space-free
# filename would end the command and start a second one. Pure function, no I/O:
# the branch only fires on Windows, so this is what the Linux test suite exercises.
function _ShapeCmdArgs([object[]]$Arguments) {
  $shaped = @()
  foreach ($a in $Arguments) {
    $s = [string]$a
    # Two characters cmd re-parsing cannot be protected from, so refuse them: `"`
    # ends a quoted run, and `%VAR%` is expanded from the environment -- inside
    # quotes too -- before the batch file ever runs, with no escape at the command
    # line (`%%` only works INSIDE a batch file). `%` IS legal in a Windows file
    # name, so refusing it is a deliberate limit of forwarding through the .cmd
    # shim rather than a filesystem rule; the caller's message says so and points
    # at another way to open the file.
    if ($s.Contains('"')) { throw "argument contains a quote: $s" }
    if ($s.Contains('%')) { throw "argument contains a percent sign: $s" }
    # cmd does not split inside quotes, and PowerShell already quotes an argument
    # that contains whitespace -- a second pair would split THAT one -- so quote
    # exactly the arguments it would otherwise pass bare, doubling a trailing
    # backslash so the closing quote survives the final argv parse.
    if ($s -match '\s') { $shaped += $s }
    else { $shaped += '"' + ($s -replace '(\\+)$', '$1$1') + '"' }
  }
  return ,$shaped
}

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
  # Windows resolves `code` to the bin\code.cmd shim, whose arguments cmd.exe
  # re-parses. Bypassing the shim for the sibling Code.exe is NOT equivalent --
  # the shim runs it as the Node CLI entry point, which is what makes `--wait`
  # (git's editor), `--version` and `--list-extensions` behave -- so keep the
  # shim and shape what is handed to it.
  if ($exe -match '\.(cmd|bat)$') {
    try { $shaped = _ShapeCmdArgs $Args }
    catch {
      Write-Error "code: $($_.Exception.Message) - cmd.exe would re-parse it. Open the file from inside VS Code, or call the launcher yourself."
      return
    }
    & $exe @shaped
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

