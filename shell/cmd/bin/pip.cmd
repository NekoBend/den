@echo off
rem pip - the active venv's own pip, else uv pip into that venv
rem Inside a venv (VIRTUAL_ENV) pip is the venv's own Scripts\pip.exe. A venv
rem made by uv has none, and there `uv pip` runs instead, which installs into
rem that venv (a pip.exe found on PATH belongs to another Python). With no
rem venv active, pip runs nothing and says what to do: `uv pip` would pick an
rem environment itself, the .venv in the current directory or one above it,
rem and run the python in it, which a cloned repository may have committed.
rem With the uv override off (_DEN_UV_OVERRIDE=0, toggle-uv) or no uv, it is
rem the first pip.exe on PATH. Programs come from PATH, through System32's
rem where.exe, or from a full path, never from the current directory.
rem CRLF line endings: with LF only, cmd can miss a goto label.
setlocal EnableExtensions DisableDelayedExpansion
set "_pip="
set "_uv="
if not "%_DEN_UV_OVERRIDE%"=="0" for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $PATH:uv.exe 2^>nul') do if not defined _uv set "_uv=%%p"
if not defined _uv goto plain
if not defined VIRTUAL_ENV goto refuse
if exist "%VIRTUAL_ENV%\Scripts\pip.exe" set "_pip=%VIRTUAL_ENV%\Scripts\pip.exe"
if defined _pip goto run
echo pip %* → uv pip %* >&2
"%_uv%" pip %*
exit /b
:refuse
if "%~1"=="" goto refuse_bare
>&2 echo pip: no venv is active; activate a venv you made (its Scripts\activate), or type uv pip %* directly
exit /b 1
:refuse_bare
>&2 echo pip: no venv is active; activate a venv you made (its Scripts\activate), or type uv pip directly
exit /b 1
:plain
for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $PATH:pip.exe 2^>nul') do if not defined _pip set "_pip=%%p"
if defined _pip goto run
>&2 echo pip: pip.exe is not on PATH
exit /b 9009
:run
"%_pip%" %*
exit /b
