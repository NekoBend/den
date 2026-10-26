@echo off
rem uv - inject --python for `uv run` inside a venv den's `va` activated
rem `va` on bash/zsh or pwsh sets _DEN_VENV_PYTHON to the venv's Python
rem version; cmd has no `va`, so the variable only arrives from such a parent
rem shell. With it and VIRTUAL_ENV set, `uv run ...` becomes
rem `uv run --python <version> [--] ...` as on the other shells, the `--` only
rem when the first argument after `run` is not an option. The rest of the line
rem reaches uv.exe as typed: it is cut from the raw argument text, never split
rem into arguments and joined again, so quoted & | < > and = , ; ! and ""
rem arrive unchanged. uv.exe comes from PATH, through System32's where.exe:
rem never one in the current directory, and never this shim.
rem CRLF line endings: with LF only, cmd can miss a goto label.
setlocal EnableExtensions DisableDelayedExpansion
set "_uv="
for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $PATH:uv.exe 2^>nul') do if not defined _uv set "_uv=%%p"
if defined _uv goto found
>&2 echo uv: uv.exe is not on PATH
exit /b 9009
:found
if not defined VIRTUAL_ENV goto passthrough
if not defined _DEN_VENV_PYTHON goto passthrough
if /i not "%~1"=="run" goto passthrough
if not "%1"=="%~1" goto passthrough
rem The version is inherited: pass it on only when it is digits and dots.
setlocal EnableDelayedExpansion
set "_v=x!_DEN_VENV_PYTHON!"
for %%d in (0 1 2 3 4 5 6 7 8 9 .) do set "_v=!_v:%%d=!"
if not "!_v!"=="x" goto passthrough
setlocal DisableDelayedExpansion
set _raw=%*
set "_first=%~2"
set "_sep= --"
if defined _first if "%_first:~0,1%"=="-" set "_sep="
setlocal EnableDelayedExpansion
set "_rest=!_raw:*run=!"
"!_uv!" run --python "!_DEN_VENV_PYTHON!"!_sep!!_rest!
exit /b
:passthrough
setlocal DisableDelayedExpansion
"%_uv%" %*
