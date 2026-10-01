@echo off
setlocal
set "_ARG1=%~1"
if "%~2"=="" (
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "Get-Content -LiteralPath $env:_ARG1 | Select-Object -First 10"
) else (
    set "_ARG2=%~2"
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "Get-Content -LiteralPath $env:_ARG1 | Select-Object -First $env:_ARG2"
)
endlocal
