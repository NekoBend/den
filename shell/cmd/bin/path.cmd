@echo off
rem path - print PATH, one entry per line. den defines no alias for it: typed
rem `path` on cmd stays cmd's own PATH command (see COMMANDS.md).
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "($env:PATH -split ';') -ne '' | ForEach-Object { $_ }"
