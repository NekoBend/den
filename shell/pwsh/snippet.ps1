# snippet.ps1 - save favorite commands by name, then list / run them later. The pwsh
# port of shell/posix/snippet.sh, sharing the SAME store
# ($XDG_CONFIG_HOME/den/snippets; one "name<TAB>command" per line; LF + UTF-8) so a
# snippet saved from bash is usable from pwsh on the same machine. run/pick
# Invoke-Expression the command in the CURRENT session (you saved it, so it is
# trusted). Defining these functions has no side effects, so (like cheat.ps1) it is
# not gated on an interactive session.

function _SnippetFile {
    $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    Join-Path $base 'den/snippets'
}

# The store as an array of "name<TAB>command" lines (empty array if none).
function _SnippetLines {
    $f = _SnippetFile
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return @() }
    $text = [IO.File]::ReadAllText($f)
    @(($text -replace "`r", '') -split "`n" | Where-Object { $_ -ne '' })
}

function _SnippetWrite([string[]]$Lines) {
    $f = _SnippetFile
    $dir = Split-Path -Parent $f
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # LF + UTF-8 (no BOM) via WriteAllText so posix can read the shared store.
    $text = if ($Lines.Count) { ($Lines -join "`n") + "`n" } else { '' }
    [IO.File]::WriteAllText($f, $text, [Text.UTF8Encoding]::new($false))
}

function _SnippetName([string]$Line) {
    $i = $Line.IndexOf("`t")
    if ($i -lt 0) { $Line } else { $Line.Substring(0, $i) }
}

function _SnippetGet([string]$Name) {
    foreach ($line in _SnippetLines) {
        $i = $line.IndexOf("`t")
        if ($i -ge 0 -and $line.Substring(0, $i) -eq $Name) { return $line.Substring($i + 1) }
    }
    return $null
}

# Echo the command (so you see what runs) then Invoke-Expression it in this session.
function _SnippetExec([string]$Cmd) {
    [Console]::Error.WriteLine("+ $Cmd")
    Invoke-Expression $Cmd
}

function _SnippetUsage {
    @(
        'usage: snippet <command>   (alias: snip)'
        '  save <name> <command...>  save a command (or pipe it in)'
        '  ls                        list saved snippets'
        '  show <name>               print a snippet (no run)'
        '  run <name>                run a snippet'
        '  rm <name>                 delete a snippet'
        '  pick                      fzf-select a snippet and run it (default)'
    ) | ForEach-Object { [Console]::Error.WriteLine($_) }
}

# snippet - save / list / run named command snippets (alias: snip). Messages go to
# stderr; data (ls/show) goes to stdout, matching the posix version.
function snippet {
    $stdin = @($input)
    $sub = if ($args.Count) { [string]$args[0] } else { 'pick' }
    # @() at assignment: an if-block that outputs a 1-element array unrolls it to a
    # scalar string, and then $rest[0] would index the STRING (first char).
    $rest = @($args | Select-Object -Skip 1)
    switch -Regex ($sub) {
        '^save$' {
            if ($rest.Count -eq 0) {
                [Console]::Error.WriteLine('usage: snippet save <name> <command...>'); return
            }
            $name = [string]$rest[0]
            if ($name -notmatch '^[A-Za-z0-9_-]+$') {
                [Console]::Error.WriteLine('snippet save: name must match [A-Za-z0-9_-]'); return
            }
            $cmd = if ($rest.Count -ge 2) {
                ($rest[1..($rest.Count - 1)] -join ' ')
            } else {
                # From stdin: take the FIRST line only, like posix `read -r` (no Trim).
                (($stdin -join "`n") -split "`r?`n")[0]
            }
            if (-not $cmd) { [Console]::Error.WriteLine('snippet save: empty command'); return }
            if ($cmd -match "`n") {
                [Console]::Error.WriteLine('snippet save: command must be a single line'); return
            }
            $lines = @(_SnippetLines | Where-Object { (_SnippetName $_) -ne $name })
            $lines += "$name`t$cmd"
            _SnippetWrite $lines
            [Console]::Error.WriteLine("snippet: saved '$name'")
        }
        '^(ls|list)$' {
            $lines = @(_SnippetLines)
            if (-not $lines.Count) {
                [Console]::Error.WriteLine('snippet: no snippets (use: snippet save <name> <command...>)'); return
            }
            $lines
        }
        '^(show|cat)$' {
            if (-not $rest.Count) { [Console]::Error.WriteLine('usage: snippet show <name>'); return }
            $c = _SnippetGet ([string]$rest[0])
            if ($null -eq $c) { [Console]::Error.WriteLine("snippet show: no such snippet '$($rest[0])'"); return }
            $c
        }
        '^(rm|remove)$' {
            if (-not $rest.Count) { [Console]::Error.WriteLine('usage: snippet rm <name>'); return }
            $name = [string]$rest[0]
            $lines = @(_SnippetLines)
            $kept = @($lines | Where-Object { (_SnippetName $_) -ne $name })
            if ($kept.Count -eq $lines.Count) {
                [Console]::Error.WriteLine("snippet rm: no such snippet '$name'"); return
            }
            _SnippetWrite $kept
            [Console]::Error.WriteLine("snippet: removed '$name'")
        }
        '^(run|exec)$' {
            if (-not $rest.Count) { [Console]::Error.WriteLine('usage: snippet run <name>'); return }
            $c = _SnippetGet ([string]$rest[0])
            if ($null -eq $c) {
                [Console]::Error.WriteLine("snippet run: no such snippet '$($rest[0])' (snippet ls)"); return
            }
            _SnippetExec $c
        }
        '^pick$' {
            if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
                [Console]::Error.WriteLine("snippet pick: fzf not found; use 'snippet run <name>'"); return
            }
            $lines = @(_SnippetLines)
            if (-not $lines.Count) {
                [Console]::Error.WriteLine('snippet: no snippets (use: snippet save <name> <command...>)'); return
            }
            $sel = $lines | fzf --no-multi --prompt 'snippet> '
            if (-not $sel) { return }
            $i = $sel.IndexOf("`t")
            if ($i -ge 0) { _SnippetExec $sel.Substring($i + 1) }
        }
        '^(-h|--help|help)$' { _SnippetUsage }
        default {
            [Console]::Error.WriteLine("snippet: unknown command '$sub'")
            _SnippetUsage
        }
    }
}

Set-Alias snip snippet
