@echo off
setlocal
set "_ARG1=%~1"
if "%~2"=="" (
    powershell -NoProfile -Command "Get-Content -LiteralPath $env:_ARG1 | Select-Object -Last 10"
) else (
    set "_ARG2=%~2"
    powershell -NoProfile -Command "Get-Content -LiteralPath $env:_ARG1 | Select-Object -Last $env:_ARG2"
)
endlocal
