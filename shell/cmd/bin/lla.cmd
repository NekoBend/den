@echo off
rem lla - lsd -la when lsd is on PATH, else dir /a
rem (dir /a also while the wrappers are off: _DEN_WRAPPERS=0, tgl-wr).
rem It branches on whether lsd exists, never on its exit code, so lsd keeps
rem its own exit code and dir /a never runs after it. lsd comes from PATH
rem only, through System32's where.exe, so no where.* or lsd.* in the
rem current directory runs instead.
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
set "_t="
if not "%_DEN_WRAPPERS%"=="0" for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $_abs:lsd.exe 2^>nul') do if not defined _t set "_t=%%p"
if defined _t "%_t%" -la %*
if not defined _t dir /a %*
exit /b %errorlevel%
