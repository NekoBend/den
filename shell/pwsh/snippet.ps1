# snippet.ps1 - save favorite commands by name, then list / run them later. The pwsh
# port of shell/posix/snippet.sh, sharing the SAME store
# ($XDG_CONFIG_HOME/den/snippets; one "name<TAB>command" per line; LF + UTF-8) so a
# snippet saved from bash is usable from pwsh on the same machine, as far as its
# syntax is (save quotes words in the saving shell's syntax). run/pick
# Invoke-Expression the command in the CURRENT session (you saved it, so it is
# trusted), from inside a function (_DenReplay, _helpers.ps1). Unlike bash/zsh's
# eval, which sets the shell's own variables, that keeps a cd and $env: changes
# but not a variable, function or alias the command makes ($x = 1,
# function f {...}, Set-Alias) unless it is made global ($global:x,
# function global:f, -Scope Global), as shell/README.md tells users.
# Defining these functions has no side effects, so (like cheat.ps1) it is
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

# _SnippetGet <name> - the command saved under <name>, or $null. Names compare
# exactly, case included, here and in save and rm, as in bash/zsh: they can
# save two names that differ only in case. A line with no tab, which only a
# hand edit makes, holds no snippet.
function _SnippetGet([string]$Name) {
    foreach ($line in _SnippetLines) {
        $i = $line.IndexOf("`t")
        if ($i -lt 0) { continue }
        if ($line.Substring(0, $i) -ceq $Name) { return $line.Substring($i + 1) }
    }
    return $null
}

# _SnippetPick - fzf-pick one of the saved "name<TAB>command" lines, and output
# the command the store holds under the name on it. It outputs nothing when no
# line is picked, and nothing but a message on stderr when fzf or the snippets
# are missing or that name is no longer in the store. The command fzf prints
# back is not run, as it can come back changed: Windows PowerShell 5.1 pipes
# text into a program as ASCII ($OutputEncoding), so each character outside
# ASCII went into fzf, and came back, as ?, which Remove-Item and the other
# commands that take wildcards read as any one character; and on Windows both
# editions read what fzf prints in the console's code page (932 on Japanese
# Windows). A name is [A-Za-z0-9_-], which every encoding keeps. Both encodings
# are UTF-8 for the call, as in cdf (functions.ps1): fzf reads the list, and
# PowerShell its pick, as UTF-8. The $OutputEncoding set here ends with this
# function, as do its other variables, before snippet runs the command (see
# snippet); the console's encoding is put back. Only the lines that hold a
# snippet (see _SnippetGet) go to fzf, and the line picked is the last one fzf
# prints: FZF_DEFAULT_OPTS can add lines before it, the query (--print-query)
# or the key pressed (--expect), and with no line picked they are all fzf
# prints. A query can be another snippet's name, so a line with no tab picks
# nothing.
function _SnippetPick {
    if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine("snippet pick: fzf not found; use 'snippet run <name>'"); return
    }
    $lines = @(_SnippetLines | Where-Object { $_.Contains("`t") })
    if (-not $lines.Count) {
        [Console]::Error.WriteLine('snippet: no snippets (use: snippet save <name> <command...>)'); return
    }
    $consoleEncoding = [Console]::OutputEncoding
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    try {
        [Console]::OutputEncoding = $OutputEncoding
        $sel = @($lines | fzf --no-multi --prompt 'snippet> ')
        $fzfExit = $LASTEXITCODE
    } finally {
        [Console]::OutputEncoding = $consoleEncoding
    }
    # fzf exits 1 when nothing matched and 130 when aborted; what it printed
    # then is a query (--print-query), never a row, even one holding a tab.
    if ($fzfExit -ne 0 -or -not $sel.Count) { return }
    $picked = [string]$sel[-1]
    $i = $picked.IndexOf("`t")
    if ($i -lt 0) { return }
    $name = $picked.Substring(0, $i)
    $c = _SnippetGet $name
    if ($null -eq $c) {
        [Console]::Error.WriteLine("snippet pick: no such snippet '$name' (snippet ls)"); return
    }
    $c
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

# Echo the command (so you see what runs) then Invoke-Expression it in this session,
# as typed when snippet itself was (<typed>; see _DenTyped). The command reads
# variables through this function's scope, so its parameters have names no
# session uses (see snippet).
function _SnippetExec([string]$__cmd, [bool]$__typed) {
    [Console]::Error.WriteLine("+ $__cmd")
    _DenReplay $__cmd $__typed
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
# stderr; data (ls/show) goes to stdout, matching the posix version. run and pick
# replay the command from inside this function, through _SnippetExec and
# _DenReplay, and the command looks a variable up in their scopes and this one
# before the session's: a variable of theirs would hide the session's of that
# name, so a saved `Remove-Item -LiteralPath $name` would read the name pick
# chose. So pick looks the command up in _SnippetPick, whose variables end
# before it runs, and the variables the three functions hold when it runs are
# named $__x, which no session uses (PowerShell's own, such as the switch's $_
# and $Matches, aside).
function snippet {
    $__stdin = @($input)
    $__sub = if ($args.Count) { [string]$args[0] } else { 'pick' }
    # @() at assignment: an if-block that outputs a 1-element array unrolls it to a
    # scalar string, and then $__rest[0] would index the STRING (first char).
    $__rest = @($args | Select-Object -Skip 1)
    switch -Regex ($__sub) {
        '^save$' {
            if ($__rest.Count -eq 0) {
                [Console]::Error.WriteLine("usage: snippet save <name> '<command>' | <word...>"); return
            }
            $name = [string]$__rest[0]
            if ($name -notmatch '^[A-Za-z0-9_-]+$') {
                [Console]::Error.WriteLine('snippet save: name must match [A-Za-z0-9_-]'); return
            }
            $cmd = if ($__rest.Count -ge 3) {
                # Several words: each quoted again where it needs it (_SnippetQuote).
                # A $var or $(...) the user left unquoted was expanded before
                # snippet ran.
                @(for ($i = 1; $i -lt $__rest.Count; $i++) { _SnippetQuote $__rest[$i] -First:($i -eq 1) }) -join ' '
            } elseif ($__rest.Count -eq 2) {
                # One argument: the whole command, saved as typed.
                [string]$__rest[1]
            } else {
                # From stdin: take the FIRST line only, like posix `read -r` (no Trim).
                (($__stdin -join "`n") -split "`r?`n")[0]
            }
            if (-not $cmd) { [Console]::Error.WriteLine('snippet save: empty command'); return }
            if ($cmd -match "`n") {
                [Console]::Error.WriteLine('snippet save: command must be a single line'); return
            }
            # Replaces the snippet of exactly this name (see _SnippetGet).
            $lines = @(_SnippetLines | Where-Object { (_SnippetName $_) -cne $name })
            $lines += "$name`t$cmd"
            _SnippetWrite $lines
            # The several-words form prints the line it saved, with the quotes
            # it put back; the others saved what the user gave.
            if ($__rest.Count -ge 3) {
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
            if (-not $__rest.Count) { [Console]::Error.WriteLine('usage: snippet show <name>'); return }
            $c = _SnippetGet ([string]$__rest[0])
            if ($null -eq $c) { [Console]::Error.WriteLine("snippet show: no such snippet '$($__rest[0])'"); return }
            $c
        }
        '^(rm|remove)$' {
            if (-not $__rest.Count) { [Console]::Error.WriteLine('usage: snippet rm <name>'); return }
            $name = [string]$__rest[0]
            $lines = @(_SnippetLines)
            $kept = @($lines | Where-Object { (_SnippetName $_) -cne $name })
            if ($kept.Count -eq $lines.Count) {
                [Console]::Error.WriteLine("snippet rm: no such snippet '$name'"); return
            }
            _SnippetWrite $kept
            [Console]::Error.WriteLine("snippet: removed '$name'")
        }
        '^(run|exec)$' {
            if (-not $__rest.Count) { [Console]::Error.WriteLine('usage: snippet run <name>'); return }
            $__c = _SnippetGet ([string]$__rest[0])
            if ($null -eq $__c) {
                [Console]::Error.WriteLine("snippet run: no such snippet '$($__rest[0])' (snippet ls)"); return
            }
            _SnippetExec $__c (_DenTyped $MyInvocation.CommandOrigin)
        }
        '^pick$' {
            $__c = _SnippetPick
            if ($null -ne $__c) { _SnippetExec $__c (_DenTyped $MyInvocation.CommandOrigin) }
        }
        '^(-h|--help|help)$' { _SnippetUsage }
        default {
            [Console]::Error.WriteLine("snippet: unknown command '$__sub'")
            _SnippetUsage
        }
    }
}

Set-Alias snip snippet
