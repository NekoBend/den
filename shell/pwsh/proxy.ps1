# proxy.ps1 - named proxy profiles with easy on/off (session env vars only). The pwsh
# port of shell/posix/proxy.sh, sharing the SAME store
# ($XDG_CONFIG_HOME/den/proxy.conf; "name<TAB>url<TAB>no_proxy" per line; LF + UTF-8).
# `proxy on <name>` sets the standard proxy env vars (lower + upper case) in the
# CURRENT session; `proxy off` clears them. The active profile is tracked per-session
# in $global:_DEN_PROXY_ACTIVE (not exported), never in global tool config. Loading
# it only defines these functions and that variable, so (like cheat.ps1) it is not
# gated. A url may carry a password (http://user:password@host:port): the store is
# written by _DenWritePrivate (_helpers.ps1, which init.ps1 loads first), 0600 in a
# 0700 directory off Windows, and add/on/ls/status print it as user:***@host.

# The variable exists from load on, empty until `proxy on`: a caller's Set-StrictMode
# makes reading one that was never set an error. Tested rather than assigned, so a
# reload keeps the profile that is on.
if (-not (Test-Path Variable:global:_DEN_PROXY_ACTIVE)) { $global:_DEN_PROXY_ACTIVE = $null }

function _ProxyFile {
    $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    Join-Path $base 'den/proxy.conf'
}

function _ProxyLines {
    $f = _ProxyFile
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return @() }
    @(([IO.File]::ReadAllText($f) -replace "`r", '') -split "`n" | Where-Object { $_ -ne '' })
}

# Lines defaults to @() rather than $null, whose .Count is an error under a
# caller's Set-StrictMode.
function _ProxyWrite([string[]]$Lines = @()) {
    $text = if ($Lines.Count) { ($Lines -join "`n") + "`n" } else { '' }
    _DenWritePrivate (_ProxyFile) $text
}

# _ProxyShow <url> - the url as add/on/ls/status print it: the password of a
# user:password@ part shows as ***. The store and the env vars keep it. The
# userinfo ends at the last @, the user at its first :, as in proxy.sh.
function _ProxyShow([string]$Url) {
    $i = $Url.IndexOf('://')
    $pre = if ($i -ge 0) { $Url.Substring(0, $i + 3) } else { '' }
    $rest = $Url.Substring($pre.Length)
    $at = $rest.LastIndexOf('@')
    $colon = $rest.IndexOf(':')
    if ($at -lt 0 -or $colon -lt 0 -or $colon -gt $at) { return $Url }
    $pre + $rest.Substring(0, $colon) + ':***' + $rest.Substring($at)
}

function _ProxyFields([string]$Line) {
    $p = $Line -split "`t", 3
    [pscustomobject]@{
        Name = $p[0]
        Url  = if ($p.Count -gt 1) { $p[1] } else { '' }
        No   = if ($p.Count -gt 2) { $p[2] } else { '' }
    }
}

function _ProxyUsage {
    @(
        'usage: proxy <command>'
        '  add <name> <url> [no_proxy]   register/overwrite a profile'
        '  rm <name>                     remove a profile'
        '  ls                            list profiles (* = active this shell)'
        '  on <name>                     set proxy env vars from <name>'
        '  off                           unset proxy env vars (this session)'
        '  status                        show active profile + env (default)'
    ) | ForEach-Object { [Console]::Error.WriteLine($_) }
}

# proxy - register named proxy profiles and toggle them on/off (env vars only).
function proxy {
    $sub = if ($args.Count) { [string]$args[0] } else { 'status' }
    # @() at assignment: an if-block that outputs a 1-element array unrolls it to a
    # scalar string, and then $rest[0] would index the STRING (first char).
    $rest = @($args | Select-Object -Skip 1)
    switch -Regex ($sub) {
        '^add$' {
            if ($rest.Count -lt 2 -or -not [string]$rest[1]) {
                # Require a non-empty url, like posix ([ -z "$2" ] rejects it).
                [Console]::Error.WriteLine('usage: proxy add <name> <url> [no_proxy]'); return
            }
            $name = [string]$rest[0]
            if ($name -notmatch '^[A-Za-z0-9_-]+$') {
                [Console]::Error.WriteLine('proxy add: name must match [A-Za-z0-9_-]'); return
            }
            $url = [string]$rest[1]
            $no = if ($rest.Count -ge 3) { [string]$rest[2] } else { '' }
            $lines = @(_ProxyLines | Where-Object { (_ProxyFields $_).Name -ne $name })
            $lines += "$name`t$url`t$no"
            _ProxyWrite $lines
            [Console]::Error.WriteLine("proxy: saved '$name' -> $(_ProxyShow $url)")
        }
        '^rm$' {
            if (-not $rest.Count) { [Console]::Error.WriteLine('usage: proxy rm <name>'); return }
            $name = [string]$rest[0]
            $lines = @(_ProxyLines)
            $kept = @($lines | Where-Object { (_ProxyFields $_).Name -ne $name })
            if ($kept.Count -eq $lines.Count) {
                [Console]::Error.WriteLine("proxy rm: no such profile '$name'"); return
            }
            _ProxyWrite $kept
            [Console]::Error.WriteLine("proxy: removed '$name'")
            if ($global:_DEN_PROXY_ACTIVE -eq $name) {
                [Console]::Error.WriteLine("proxy: '$name' is still active in this shell; run 'proxy off'")
            }
        }
        '^(ls|list)$' {
            $lines = @(_ProxyLines)
            if (-not $lines.Count) {
                [Console]::Error.WriteLine('proxy: no profiles (use: proxy add <name> <url> [no_proxy])'); return
            }
            foreach ($line in $lines) {
                $f = _ProxyFields $line
                $mark = if ($f.Name -eq $global:_DEN_PROXY_ACTIVE) { '*' } else { ' ' }
                if ($f.No) { "$mark $($f.Name)`t$(_ProxyShow $f.Url)`t(no_proxy: $($f.No))" }
                else { "$mark $($f.Name)`t$(_ProxyShow $f.Url)" }
            }
        }
        '^on$' {
            if (-not $rest.Count) { [Console]::Error.WriteLine('usage: proxy on <name>'); return }
            $name = [string]$rest[0]
            $prof = _ProxyLines | ForEach-Object { _ProxyFields $_ } |
                Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if (-not $prof) {
                [Console]::Error.WriteLine("proxy on: no such profile '$name' (proxy ls to list)"); return
            }
            # Loopback is always excluded; a profile's own no_proxy adds to it. The
            # sole exception is "*" (bypass everything), which stays standalone.
            $no = $prof.No
            if (-not $no) { $no = 'localhost,127.0.0.1,::1' }
            elseif ($no -ne '*') { $no = "localhost,127.0.0.1,::1,$no" }
            foreach ($v in 'http_proxy', 'https_proxy', 'all_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY') {
                Set-Item "env:$v" $prof.Url
            }
            $env:no_proxy = $no
            $env:NO_PROXY = $no
            $global:_DEN_PROXY_ACTIVE = $name
            [Console]::Error.WriteLine("proxy: on ($name -> $(_ProxyShow $prof.Url))")
        }
        '^off$' {
            foreach ($v in 'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy',
                'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY') {
                Remove-Item "env:$v" -ErrorAction SilentlyContinue
            }
            if ($global:_DEN_PROXY_ACTIVE) {
                [Console]::Error.WriteLine("proxy: off (was $global:_DEN_PROXY_ACTIVE)")
            } else {
                [Console]::Error.WriteLine('proxy: off')
            }
            $global:_DEN_PROXY_ACTIVE = $null
        }
        '^status$' {
            $active = if ($global:_DEN_PROXY_ACTIVE) { $global:_DEN_PROXY_ACTIVE } else { '(none)' }
            "active: $active"
            "http_proxy=$(_ProxyShow $env:http_proxy)"
            "https_proxy=$(_ProxyShow $env:https_proxy)"
            "all_proxy=$(_ProxyShow $env:all_proxy)"
            "no_proxy=$($env:no_proxy)"
        }
        '^(-h|--help|help)$' { _ProxyUsage }
        default {
            [Console]::Error.WriteLine("proxy: unknown command '$sub'")
            _ProxyUsage
        }
    }
}
