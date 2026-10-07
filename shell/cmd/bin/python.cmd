@echo off
rem python — uv-aware python wrapper
rem If VIRTUAL_ENV is set or override disabled, use python.exe directly; else delegate to uv run

setlocal
set "_uv="
for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $PATH:uv.exe 2^>nul') do if not defined _uv set "_uv=%%p"
if not defined _uv goto :system
if defined VIRTUAL_ENV goto :system
if "%_DEN_UV_OVERRIDE%"=="0" goto :system

echo python %* → uv run -- python %* >&2
"%_uv%" run -- python %*
exit /b

:system
python.exe %*
