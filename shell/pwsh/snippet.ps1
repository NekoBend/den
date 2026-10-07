# snippet.ps1 - save favorite commands by name, then list / run them later. The pwsh
# port of shell/posix/snippet.sh, sharing the SAME store
# ($XDG_CONFIG_HOME/den/snippets; one "name<TAB>command" per line; LF + UTF-8) so a
# snippet saved from bash is usable from pwsh on the same machine, as far as its
# syntax is (save quotes words in the saving shell's syntax). run/pick
# Invoke-Expression the command in the CURRENT session (you saved it, so it is
# trusted). Defining these functions has no side effects, so (like cheat.ps1) it is
# not gated on an interactive session. The store is written by _DenWritePrivate
# (_helpers.ps1, which init.ps1 loads first): 0600 in a 0700 directory off
# Windows, and through a symlink, as snippet.sh does.

function _SnippetFile {
    $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    Join-Path $base 'den/snippets'
}

# The store as an array of "name<TAB>command" lines (empty array if none). A
# symlink whose target does not exist yet is none too; any other read error
# ends the caller, so save never rewrites a store it could not read.
function _SnippetLines {
    $f = _SnippetFile
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return @() }
    try { $text = [IO.File]::ReadAllText($f) }
    catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] { return @() }
    catch { throw }
    @(($text -replace "`r", '') -split "`n" | Where-Object { $_ -ne '' })
}

# Lines defaults to @() rather than $null, whose .Count is an error under a
# caller's Set-StrictMode.
function _SnippetWrite([string[]]$Lines = @()) {
    # LF + UTF-8 (no BOM) so posix can read the shared store.
    $text = if ($Lines.Count) { ($Lines -join "`n") + "`n" } else { '' }
    _DenWritePrivate (_SnippetFile) $text
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

# _SnippetQuote <word> [-First] - one word of `snippet save <name> <word...>` as
# PowerShell source. PowerShell took its quotes off and run/pick
# Invoke-Expression the saved line, so a word with anything but
# [A-Za-z0-9_./:\=+-] in it (or empty) goes back in single quotes, a ' in it
# doubled. So does a string that starts like a number ('007', '1kb', '.5'),
# which PowerShell would read back as one; a number typed bare keeps the text
# it was typed as. A string that starts with '-' ('-Verbose', '--') is quoted
# too, or it would come back as a parameter or the end of them. A parameter
# typed bare (-Recurse, -Path:) carries the hidden <CommandParameterName> note
# PowerShell puts on $args for splatting, and goes back as typed, whatever
# dash it starts with. $true/$false and a { } block come back as themselves,
# and an array (a,b) as its items joined by commas. A quoted first word would
# be a string, not a command, so it gets the call operator.
function _SnippetQuote($Word, [switch]$First) {
    if ($Word -is [array]) { return (@($Word | ForEach-Object { _SnippetQuote $_ }) -join ',') }
    if ($Word -is [bool]) { return $(if ($Word) { '$true' } else { '$false' }) }
    if ($Word -is [scriptblock]) { return '{' + $Word + '}' }
    $s = [string]$Word
    if ($null -ne $Word -and $null -ne $Word.PSObject.Properties['<CommandParameterName>']) { return $s }
    if ($s -match '^[A-Za-z0-9_./:\\=+-]+\z' -and -not ($Word -is [string] -and $s -match '^(\.?\d|-)')) { return $s }
    $q = "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($s) + "'"
    if ($First) { "& $q" } else { $q }
}

# Echo the command (so you see what runs) then Invoke-Expression it in this session.
function _SnippetExec([string]$Cmd) {
    [Console]::Error.WriteLine("+ $Cmd")
    Invoke-Expression $Cmd
}

function _SnippetUsage {
    @(
        'usage: snippet <command>   (alias: snip)'
        '  save <name> ''<command>''   save a command as typed (or pipe it in, first line only)'
        '  save <name> <word...>     save the words, each quoted again if it needs it'
        '                            (an unquoted $var or $(...) is expanded on save)'
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
                [Console]::Error.WriteLine("usage: snippet save <name> '<command>' | <word...>"); return
            }
            $name = [string]$rest[0]
            if ($name -notmatch '^[A-Za-z0-9_-]+$') {
                [Console]::Error.WriteLine('snippet save: name must match [A-Za-z0-9_-]'); return
            }
            $cmd = if ($rest.Count -ge 3) {
                # Several words: each quoted again where it needs it (_SnippetQuote).
                # A $var or $(...) the user left unquoted was expanded before
                # snippet ran.
                @(for ($i = 1; $i -lt $rest.Count; $i++) { _SnippetQuote $rest[$i] -First:($i -eq 1) }) -join ' '
            } elseif ($rest.Count -eq 2) {
                # One argument: the whole command, saved as typed.
                [string]$rest[1]
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
            # The several-words form prints the line it saved, with the quotes
            # it put back; the others saved what the user gave.
            if ($rest.Count -ge 3) {
                [Console]::Error.WriteLine("snippet: saved '$name' -> $cmd")
            } else {
                [Console]::Error.WriteLine("snippet: saved '$name'")
            }
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
