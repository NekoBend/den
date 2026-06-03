@echo off
if "%_DOTFILES_WRAPPERS%"=="0" goto :fallback
where bat >nul 2>&1 && (bat --style=plain --paging=never %*) || (type %*)
exit /b
:fallback
type %*
