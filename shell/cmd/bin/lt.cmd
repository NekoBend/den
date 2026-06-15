@echo off
if "%_DEN_WRAPPERS%"=="0" goto :fallback
where lsd >nul 2>&1 && (lsd --tree %*) || (%SystemRoot%\System32\tree.com /f %*)
exit /b
:fallback
%SystemRoot%\System32\tree.com /f %*
