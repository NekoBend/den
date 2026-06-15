@echo off
if "%_DEN_WRAPPERS%"=="0" goto :fallback
where fd >nul 2>&1 && (fd %*) || (%SystemRoot%\System32\find.exe %*)
exit /b
:fallback
%SystemRoot%\System32\find.exe %*
