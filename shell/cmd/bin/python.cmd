@echo off
rem python / python3 - uv-aware python. python3.cmd is a copy of this file,
rem and the name it runs under tells the two apart.
rem `python ...` runs `uv run -- python ...` and says so on stderr, except
rem where uv run would build or run code that came with a clone: with a
rem pyproject.toml, a .venv, a pyvenv.cfg, a uv.toml or a .python-version
rem that names a path in the current directory or one above it, uv run
rem builds that project (its build backend is the repository's own code) or
rem runs a python it names: uv takes a directory that holds a pyvenv.cfg for
rem a venv, whatever its name, a uv.toml's settings can have it install and
rem run a python the clone ships, and it runs the program a .python-version
rem names to ask its version. There, after a line on stderr that says so, and
rem for --version or -V anywhere, a python runs directly: the system Python
rem uv finds, else one uv installed (uv python install). --system skips any
rem venv here, and --no-config the .python-version, uv.toml and
rem pyproject.toml here: a .python-version may name a program in the
rem repository, which uv would run to ask its version.
rem Inside a venv (VIRTUAL_ENV) it is the venv's python.exe, for python3 too
rem (a Windows venv has no python3.exe). With the uv override off
rem (_DEN_UV_OVERRIDE=0, toggle-uv) or no uv, it is the first python.exe
rem (python3.exe) on PATH. Programs come from PATH, through System32's
rem where.exe, or from a full path, never from the current directory.
rem CRLF line endings: with LF only, cmd can miss a goto label.
setlocal EnableExtensions DisableDelayedExpansion
set "_n=%~n0"
set "_py="
set "_m="
if defined VIRTUAL_ENV if exist "%VIRTUAL_ENV%\Scripts\python.exe" set "_py=%VIRTUAL_ENV%\Scripts\python.exe"
if defined _py goto run
set "_uv="
if not "%_DEN_UV_OVERRIDE%"=="0" for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $PATH:uv.exe 2^>nul') do if not defined _uv set "_uv=%%p"
if not defined _uv goto plain
rem The file uv run would read: here, then each directory up. A
rem .python-version counts when it names a path: a line with / or \ in it,
rem comment (#) lines aside. One that holds version requests alone (3.13,
rem cpython@3.13) does not, so a pyenv .python-version in the user's folder
rem leaves that folder alone. findstr reads the file, so no line of it
rem reaches cmd's parser.
set "_d=%CD%"
:walk
if "%_d:~-1%"=="\" set "_d=%_d:~0,-1%"
if exist "%_d%\pyproject.toml" set "_m=%_d%\pyproject.toml"
if not defined _m if exist "%_d%\.venv" set "_m=%_d%\.venv"
if not defined _m if exist "%_d%\pyvenv.cfg" set "_m=%_d%\pyvenv.cfg"
if not defined _m if exist "%_d%\uv.toml" set "_m=%_d%\uv.toml"
if not defined _m if exist "%_d%\.python-version" "%SystemRoot%\System32\findstr.exe" /r /c:"^ *[/\\]" /c:"^ *[^# ].*[/\\]" "%_d%\.python-version" >nul 2>&1 && set "_m=%_d%\.python-version"
if defined _m goto direct
for %%u in ("%_d%\..") do set "_u=%%~fu"
if "%_u:~-1%"=="\" set "_u=%_u:~0,-1%"
if /i "%_u%"=="%_d%" goto probe
set "_d=%_u%"
goto walk
:probe
if "%~1"=="--version" goto direct
if "%~1"=="-V" goto direct
echo %_n% %* → uv run -- python %* >&2
"%_uv%" run -- python %*
exit /b
:direct
rem `call` starts the line the for /f command runs, so cmd /c keeps the
rem quotes around a uv path with spaces; the child expands _uv itself.
for /f "delims=" %%p in ('call "%%_uv%%" python find --system --no-config --no-managed-python 2^>nul') do if not defined _py set "_py=%%p"
if defined _py if not exist "%_py%" set "_py="
if not defined _py for /f "delims=" %%p in ('call "%%_uv%%" python find --system --no-config --managed-python 2^>nul') do if not defined _py set "_py=%%p"
if defined _py if not exist "%_py%" set "_py="
if not defined _py goto nopython
if defined _m call :warn
goto run
:plain
for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $PATH:%_n%.exe 2^>nul') do if not defined _py set "_py=%%p"
if defined _py goto run
>&2 echo %_n%: %_n%.exe is not on PATH
exit /b 9009
:nopython
>&2 echo %_n%: no Python found to run in place of uv run; uv python install installs one
exit /b 1
:warn
rem The paths are read with delayed expansion, after cmd has parsed the line,
rem so a directory named with & or ) cannot end the echo early.
setlocal EnableDelayedExpansion
>&2 echo(!_n!: running !_py!, not uv run: uv run would build or run code from !_m!
endlocal
exit /b 0
:run
"%_py%" %*
exit /b
