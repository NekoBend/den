@echo off
setlocal
set "_ARG1=%~1"
powershell -NoProfile -Command "Get-Content -LiteralPath $env:_ARG1 | Measure-Object -Line -Word -Character"
endlocal
