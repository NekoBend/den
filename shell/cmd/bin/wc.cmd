@echo off
rem wc - line, word and character counts of a file, read once as raw text and
rem counted as den's pwsh wc counts characters: lines are line feeds (blank
rem lines too), words runs of non-blanks, characters the text's length with
rem its line ends. Printed as Measure-Object prints them.
setlocal
set "_ARG1=%~1"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "$t = Get-Content -Raw -LiteralPath $env:_ARG1; if ($null -eq $t) { $t = '' }; [pscustomobject]@{ Lines = [regex]::Matches($t, '\n').Count; Words = [regex]::Matches($t, '\S+').Count; Characters = $t.Length; Property = $null }"
endlocal
