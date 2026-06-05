@echo off
if "%_DOTFILES_WRAPPERS%"=="0" goto :fallback
where rg >nul 2>&1 && (rg %*) || (%SystemRoot%\System32\findstr.exe %*)
exit /b
:fallback
%SystemRoot%\System32\findstr.exe %*
