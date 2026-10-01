@echo off
rem tail - the last N lines of a file (default 10). Get-Content -Tail reads
rem from the end of the file, as den's pwsh tail does, instead of passing
rem every line through the pipeline.
setlocal
set "_ARG1=%~1"
if "%~2"=="" (
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "Get-Content -LiteralPath $env:_ARG1 -Tail 10"
) else (
    set "_ARG2=%~2"
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "Get-Content -LiteralPath $env:_ARG1 -Tail $env:_ARG2"
)
endlocal
