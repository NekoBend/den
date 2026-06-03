@echo off
if "%_DOTFILES_WRAPPERS%"=="0" goto :fallback
where lsd >nul 2>&1 && (lsd -a %*) || (dir /a %*)
exit /b
:fallback
dir /a %*
