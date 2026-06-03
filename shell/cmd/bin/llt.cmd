@echo off
if "%_DOTFILES_WRAPPERS%"=="0" goto :fallback
where lsd >nul 2>&1 && (lsd -l --tree %*) || (%SystemRoot%\System32\tree.com /f %*)
exit /b
:fallback
%SystemRoot%\System32\tree.com /f %*
