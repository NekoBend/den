@echo off
rem python — uv-aware python wrapper
rem If VIRTUAL_ENV is set or override disabled, use python.exe directly; else delegate to uv run

where uv.exe >nul 2>&1 || goto :system
if defined VIRTUAL_ENV goto :system
if "%_DOTFILES_UV_OVERRIDE%"=="0" goto :system

echo python %* → uv run -- python %* >&2
uv.exe run -- python %*
exit /b

:system
python.exe %*
