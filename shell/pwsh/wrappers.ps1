# wrappers.ps1 — CLI tool wrapper functions (modern tool → native → PowerShell fallback).
# Dot-sourced by init.ps1. Requires _helpers.ps1 loaded first.

# Skip in non-interactive sessions
if (-not [Environment]::UserInteractive) { return }

# Drop the built-in aliases that would otherwise outrank our same-named wrapper
# FUNCTIONS (alias beats function in command resolution). On Windows `ls` and
# `cat` are aliases (Get-ChildItem / Get-Content); -EA SilentlyContinue makes
# this a no-op where they do not exist (e.g. Linux/macOS).
foreach ($a in 'ls', 'cat') { Remove-Item "alias:$a" -Force -ErrorAction SilentlyContinue }

# Guard: ensure _helpers.ps1 is loaded
if (-not (Get-Command New-Wrapper -ErrorAction SilentlyContinue)) {
    $hf = Join-Path $PSScriptRoot '_helpers.ps1'
    if (Test-Path $hf) { . $hf }
}

# ===== PowerShell-only fallback helpers (Windows / no-native-command environments) =====

# _grep_ps_fallback — Unix-compatible grep via Select-String (text output)
function _grep_ps_fallback {
    $fl=@{};$pa="";$fp=@()
    foreach($a in $Args){
        if($a -match "^-([viclnr]+)$"){foreach($c in $Matches[1].ToCharArray()){$fl["$c"]=$true}}
        elseif($pa -eq ""){$pa=$a}
        else{$fp+=$a}
    }
    $ss=@{Pattern=$pa}
    if(-not $fl.ContainsKey("i")){$ss.CaseSensitive=$true}
    if($fl.ContainsKey("v")){$ss.NotMatch=$true}
    if($fp.Count -gt 0){$r=Select-String @ss -Path $fp}
    elseif($fl.ContainsKey("r")){$r=Get-ChildItem -Recurse -File|Select-String @ss}
    else{$r=$input|Select-String @ss}
    $mf=$fp.Count -gt 1 -or $fl.ContainsKey("r")
    if($fl.ContainsKey("l")){$r|ForEach-Object{$_.Path}|Sort-Object -Unique}
    elseif($fl.ContainsKey("c")){
        if($mf){$r|Group-Object Path|ForEach-Object{"$($_.Name):$($_.Count)"}}
        else{@($r).Count}
    }
    elseif($fl.ContainsKey("n")){
        if($mf){$r|ForEach-Object{"$($_.Path):$($_.LineNumber):$($_.Line)"}}
        else{$r|ForEach-Object{"$($_.LineNumber):$($_.Line)"}}
    }
    else{
        if($mf){$r|ForEach-Object{"$($_.Path):$($_.Line)"}}
        else{$r|ForEach-Object{$_.Line}}
    }
}

# _find_ps_fallback — Unix-compatible find via Get-ChildItem (text output)
function _find_ps_fallback {
    $fp=".";$nm="";$ty="";$i=0
    while($i -lt $Args.Count){
        $a=$Args[$i]
        if($a -eq "-name" -and $i+1 -lt $Args.Count){$nm=$Args[$i+1];$i+=2}
        elseif($a -eq "-type" -and $i+1 -lt $Args.Count){$ty=$Args[$i+1];$i+=2}
        elseif($a -notmatch "^-"){$fp=$a;$i++}
        else{$i++}
    }
    $p=@{Path=$fp;Recurse=$true}
    if($nm){$p.Filter=$nm}
    if($ty -eq "f"){$p.File=$true}
    elseif($ty -eq "d"){$p.Directory=$true}
    (Get-ChildItem @p).FullName
}

# ===== Toggle-aware wrappers: modern → native → PS fallback =====
# New-Wrapper <func> <modern> <modernFlags> <nativeCmd> <nativeCmdFlags> <fallbackExpr>

New-Wrapper 'cat'     'bat' '--style=plain --paging=never' 'cat'  ''                'if ($Args.Count) { Get-Content @Args } else { $input }'
New-Wrapper 'find'    'fd'  ''                              'find' ''                '_find_ps_fallback @Args'
New-Wrapper 'grep'    'rg'  ''                              'grep' '--color=auto'    '$input | _grep_ps_fallback @Args'
New-Wrapper 'la'      'lsd' '-a'                            'ls'   '-A --color=auto' 'Get-ChildItem -Force @Args'
New-Wrapper 'll'      'lsd' '-l'                            'ls'   '-lF --color=auto' 'Get-ChildItem @Args | Format-Table Mode, LastWriteTime, Length, Name'
New-Wrapper 'lla'     'lsd' '-la'                           'ls'   '-laF --color=auto' 'Get-ChildItem -Force @Args | Format-Table Mode, LastWriteTime, Length, Name'
New-Wrapper 'llt'     'lsd' '-l --tree'                     ''     ''                'Get-ChildItem -Recurse @Args | Select-Object Mode, LastWriteTime, Length, @{N="Name";E={[IO.Path]::GetRelativePath($PWD.Path, $_.FullName)}}'
New-Wrapper 'ls'      'lsd' ''                              'ls'   '--color=auto'    '(Get-ChildItem @Args).Name'
New-Wrapper 'lt'      'lsd' '--tree'                        ''     ''                'Get-ChildItem -Recurse @Args | ForEach-Object { [IO.Path]::GetRelativePath($PWD.Path, $_.FullName) }'
New-Wrapper 'ripgrep' 'rg'  ''                              ''     ''                ''

# ===== Always-modern w-suffix bypasses (New-WrapperSuffix) =====

New-WrapperSuffix 'catw'  'bat' '--style=plain --paging=never'
New-WrapperSuffix 'findw' 'fd'  ''
New-WrapperSuffix 'grepw' 'rg'  ''
New-WrapperSuffix 'lsw'   'lsd' ''

# ===== Destructive coreutils: microsoft/coreutils on Windows, else PS builtin =====
# Windows-only. On Linux/macOS `cp`/`mv`/`rm`/`mkdir`/`rmdir` keep their stock
# PowerShell-alias behavior (the builtin cmdlets). With microsoft/coreutils installed
# these gain real Unix flags (`rm -rf`, `cp -r`, ...); without it they fall back to
# the same builtin cmdlet, so this never changes the no-coreutils Windows baseline.
if ($IsWindows) {
    # cp/mv/rm/rmdir are built-in PowerShell ALIASES on Windows (-> Copy-Item /
    # Move-Item / Remove-Item), and an alias outranks a function in command
    # resolution, so the alias must be removed first or the wrapper below never
    # runs (same reason `ls`/`cd` aliases are removed above / in functions.ps1).
    # `mkdir` is a function on Windows, not an alias, so a function redefines it.
    foreach ($a in 'cp', 'mv', 'rm', 'rmdir') {
        Remove-Item "alias:$a" -Force -ErrorAction SilentlyContinue
    }
    New-CoreutilsWrapper 'cp'    'cp'    'Copy-Item @Args'
    New-CoreutilsWrapper 'mv'    'mv'    'Move-Item @Args'
    New-CoreutilsWrapper 'rm'    'rm'    'Remove-Item @Args'
    New-CoreutilsWrapper 'mkdir' 'mkdir' 'New-Item -ItemType Directory @Args'
    New-CoreutilsWrapper 'rmdir' 'rmdir' 'Remove-Item @Args'
}
