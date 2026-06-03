@echo off
rem pip — uv-aware pip wrapper
rem If VIRTUAL_ENV is set or override disabled, use pip.exe directly; else delegate to uv pip

where uv.exe >nul 2>&1 || goto :system
if defined VIRTUAL_ENV goto :system
if "%_DOTFILES_UV_OVERRIDE%"=="0" goto :system

echo pip %* → uv pip %* >&2
uv.exe pip %*
exit /b

:system
pip.exe %*
