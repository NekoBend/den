@echo off
rem pip — uv-aware pip wrapper
rem If VIRTUAL_ENV is set or override disabled, use pip.exe directly; else delegate to uv pip

setlocal
set "_uv="
for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $PATH:uv.exe 2^>nul') do if not defined _uv set "_uv=%%p"
if not defined _uv goto :system
if defined VIRTUAL_ENV goto :system
if "%_DEN_UV_OVERRIDE%"=="0" goto :system

echo pip %* → uv pip %* >&2
"%_uv%" pip %*
exit /b

:system
pip.exe %*
