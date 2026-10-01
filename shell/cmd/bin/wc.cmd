@echo off
setlocal
set "_ARG1=%~1"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "Get-Content -LiteralPath $env:_ARG1 | Measure-Object -Line -Word -Character"
endlocal
