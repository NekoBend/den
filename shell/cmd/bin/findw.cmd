@echo off
rem findw - fd, also while the wrappers are off (_DEN_WRAPPERS=0, tgl-wr), as
rem on bash/zsh and pwsh; without fd it says so and exits 1. There is no find
rem shim: typed find stays Windows' find.exe, which reads piped text
rem (netstat -ano | find "8080") where fd reads none. fd comes from PATH only,
rem through System32's where.exe, so no where.* or fd.* in the current
rem directory runs instead.
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
for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $_abs:fd.exe 2^>nul') do if not defined _t set "_t=%%p"
if not defined _t (
    >&2 echo findw: fd is not installed.
    exit /b 1
)
"%_t%" %*
exit /b %errorlevel%
