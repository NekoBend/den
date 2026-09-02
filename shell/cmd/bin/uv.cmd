@echo off
rem uv — auto-inject --python for 'uv run' when venv is active
rem Calls uv.exe explicitly to avoid infinite recursion

if not defined VIRTUAL_ENV goto :passthrough
if not defined _DEN_VENV_PYTHON goto :passthrough
if /i not "%~1"=="run" goto :passthrough

rem Build remaining args after "run" (shift doesn't affect %* in cmd)
setlocal enabledelayedexpansion
set "_args="
shift

rem `--` ends uv's OWN option parsing, so it must not precede the user's own uv
rem options: `uv run --with rich app.py` became "Failed to spawn: --with". Keep the
rem separator only when the first remaining argument cannot be read as an option.
set "_sep= --"
if "%~1"=="" goto :argloop
set "_first=%~1"
if "!_first:~0,1!"=="-" set "_sep="

:argloop
if "%~1"=="" goto :exec
set "_args=!_args! %1"
shift
goto :argloop
:exec
endlocal & uv.exe run --python "%_DEN_VENV_PYTHON%"%_sep%%_args%
exit /b

:passthrough
uv.exe %*
