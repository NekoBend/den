@echo off
rem python3 — uv-aware python3 wrapper
rem If VIRTUAL_ENV is set or override disabled, use python3.exe directly; else delegate to uv run

where uv.exe >nul 2>&1 || goto :system
if defined VIRTUAL_ENV goto :system
if "%_DEN_UV_OVERRIDE%"=="0" goto :system

echo python3 %* → uv run -- python %* >&2
uv.exe run -- python %*
exit /b

:system
python3.exe %*
