@echo off
rem path - print PATH, one entry per line. With arguments, cmd's own PATH
rem command runs instead and sets PATH, as it does without den.
setlocal
set _args=%*
if not defined _args goto list
endlocal & path %*
exit /b
:list
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "($env:PATH -split ';') -ne '' | ForEach-Object { $_ }"
