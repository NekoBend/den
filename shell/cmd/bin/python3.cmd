@echo off
rem python3 - uv-aware python3 wrapper
rem If VIRTUAL_ENV is set or override disabled, use python3.exe directly; else delegate to uv run
rem Inside a venv that is the venv's python.exe: a Windows venv has no python3.exe,
rem so python3.exe found another Python (or the Microsoft Store stub) instead.
rem CRLF line endings: with LF only, cmd can miss a goto label.

setlocal
set "_uv="
for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $PATH:uv.exe 2^>nul') do if not defined _uv set "_uv=%%p"
if not defined _uv goto :system
if defined VIRTUAL_ENV goto :system
if "%_DEN_UV_OVERRIDE%"=="0" goto :system

echo python3 %* → uv run -- python %* >&2
"%_uv%" run -- python %*
exit /b

:system
if defined VIRTUAL_ENV if exist "%VIRTUAL_ENV%\Scripts\python.exe" goto :venv
python3.exe %*
exit /b

:venv
"%VIRTUAL_ENV%\Scripts\python.exe" %*
