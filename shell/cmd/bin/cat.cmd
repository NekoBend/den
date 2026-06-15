@echo off
if "%_DEN_WRAPPERS%"=="0" goto :fallback
where bat >nul 2>&1 && (bat --style=plain --paging=never %*) || (type %*)
exit /b
:fallback
type %*
