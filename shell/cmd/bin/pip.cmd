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
rem uv pip reads only your own uv settings, as pip reads no uv.toml or
rem pyproject.toml: uv reads them from the current directory and the ones
rem above it, and a clone's settings there can have it run a python the clone
rem ships ([pip] python) or install a package from the clone's own files
rem (find-links). uv --config-file reads one file in place of all of those:
rem the one UV_CONFIG_FILE names (uv reads it even under UV_NO_CONFIG); else,
rem unless UV_NO_CONFIG is true, %APPDATA%\uv\uv.toml; else, unless
rem UV_NO_SYSTEM_CONFIG is true, %SYSTEMDRIVE%\ProgramData\uv\uv.toml, which
rem uv merges with the user one and --config-file leaves out when there are
rem both. With none, uv --no-config reads none. The line on stderr says
rem which, and typed uv pip reads them all.
rem CRLF line endings: with LF only, cmd can miss a goto label.
setlocal EnableExtensions DisableDelayedExpansion
rem The lookup reads PATH's absolute entries alone (a drive's or a UNC
rem path, quotes dropped): an empty or relative entry (., ..\bin, tools) is
rem the current directory or a folder in it, whose program would run. Each
rem entry is read with delayed expansion off, so a "!" in it survives, and
rem tested with it on; the list leaves that setlocal through for /f.
set "_abs=x"
set "_ar="
if defined PATH set "_ar=%PATH:"=%"
if defined _ar for %%e in ("%_ar:;=" "%") do (
    set "_ae=x%%~e"
    setlocal EnableDelayedExpansion
    if "!_ae:~2,2!"==":\" set "_abs=!_abs!!_ae:~1!;"
    if "!_ae:~2,2!"==":/" set "_abs=!_abs!!_ae:~1!;"
    if "!_ae:~1,2!"=="\\" set "_abs=!_abs!!_ae:~1!;"
    for /f "delims=" %%v in ("!_abs!") do endlocal & set "_abs=%%v"
)
set "_abs=%_abs:~1,-1%"
set "_pip="
set "_uv="
if not "%_DEN_UV_OVERRIDE%"=="0" for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $_abs:uv.exe 2^>nul') do if not defined _uv set "_uv=%%p"
if not defined _uv goto plain
if not defined VIRTUAL_ENV goto refuse
if exist "%VIRTUAL_ENV%\Scripts\pip.exe" set "_pip=%VIRTUAL_ENV%\Scripts\pip.exe"
if defined _pip goto run
set "_cfg=%UV_CONFIG_FILE%"
if defined _cfg goto uvpip
rem The values uv takes for true, in any case.
for %%v in (1 y yes t true on) do if /i "%UV_NO_CONFIG%"=="%%v" goto uvpip
if defined APPDATA if exist "%APPDATA%\uv\uv.toml" set "_cfg=%APPDATA%\uv\uv.toml"
if defined _cfg goto uvpip
for %%v in (1 y yes t true on) do if /i "%UV_NO_SYSTEM_CONFIG%"=="%%v" goto uvpip
if defined SYSTEMDRIVE if exist "%SYSTEMDRIVE%\ProgramData\uv\uv.toml" set "_cfg=%SYSTEMDRIVE%\ProgramData\uv\uv.toml"
:uvpip
if defined _cfg goto uvpip_cfg
echo pip %* → uv --no-config pip %* (reads no uv.toml or pyproject.toml here or above, which a clone can ship; type uv pip to read those) >&2
"%_uv%" --no-config pip %*
exit /b
:uvpip_cfg
echo pip %* → uv --config-file "%_cfg%" pip %* (reads your uv settings, not a uv.toml or pyproject.toml here or above, which a clone can ship; type uv pip to read those) >&2
"%_uv%" --config-file "%_cfg%" pip %*
exit /b
:refuse
if "%~1"=="" goto refuse_bare
>&2 echo pip: no venv is active; activate a venv you made (its Scripts\activate), or type uv pip %* directly
exit /b 1
:refuse_bare
>&2 echo pip: no venv is active; activate a venv you made (its Scripts\activate), or type uv pip directly
exit /b 1
:plain
for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $_abs:pip.exe 2^>nul') do if not defined _pip set "_pip=%%p"
if defined _pip goto run
>&2 echo pip: pip.exe is not on PATH
exit /b 9009
:run
"%_pip%" %*
exit /b
