# cheat.ps1 - browse den's bundled cheatsheets (deployed by `den install cheatsheets`).
# Dot-sourced by init.ps1. Cheatsheets live under $XDG_DATA_HOME/den/cheatsheets
# (default ~/.local/share/den/cheatsheets), matching den's Python installer. `cheat`
# fzf-picks one (or takes a name substring) and renders it with bat, else Get-Content.
# Defining the function has no side effects, so (unlike completion.ps1) it is not
# gated on an interactive session.

function _CheatDir {
    $base = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $HOME '.local/share' }
    Join-Path $base 'den/cheatsheets'
}

function _CheatList([string]$Dir) {
    Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -ne '.pyc' -and $_.FullName -notmatch '__pycache__' } |
        ForEach-Object { $_.FullName.Substring($Dir.Length + 1).Replace('\', '/') } |
        Sort-Object
}

function _CheatRender([string]$Dir, [string]$Rel) {
    $path = Join-Path $Dir $Rel
    if (Get-Command bat -ErrorAction SilentlyContinue) {
        bat --style=plain --paging=auto -- $path
    } else {
        Get-Content -LiteralPath $path
    }
}

function cheat {
    $name = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
    $dir = _CheatDir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Write-Error 'cheat: no cheatsheets installed. Run: den install cheatsheets'
        return
    }
    if ($name -in @('-h', '--help', 'help')) {
        Write-Host 'usage: cheat [name|ls]   (no name: fzf-pick a cheatsheet)'
        return
    }
    $all = @(_CheatList $dir)
    if ($name -in @('ls', 'list')) { $all; return }

    $sel = $null
    if (-not $name) {
        if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
            Write-Error "cheat: fzf not found; use 'cheat <name>' or 'cheat ls'"
            return
        }
        $sel = $all | fzf --no-multi --prompt 'cheat> '
    } else {
        $hit = @($all | Where-Object { $_ -eq $name })
        if ($hit.Count -eq 0) { $hit = @($all | Where-Object { $_ -like "*$name*" }) }
        if ($hit.Count -eq 0) {
            Write-Error "cheat: no cheatsheet matching '$name'"
            return
        } elseif ($hit.Count -eq 1) {
            $sel = $hit[0]
        } elseif (Get-Command fzf -ErrorAction SilentlyContinue) {
            $sel = $hit | fzf --no-multi --prompt 'cheat> '
        } else {
            Write-Error "cheat: '$name' is ambiguous:"
            $hit | ForEach-Object { Write-Host "  $_" }
            return
        }
    }
    if ($sel) { _CheatRender $dir $sel }
}
