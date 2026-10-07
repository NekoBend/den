@echo off
rem cat - bat --style=plain --paging=never when bat is on PATH, else type
rem (type also while the wrappers are off: _DEN_WRAPPERS=0, tgl-wr).
rem It branches on whether bat exists, never on its exit code, so bat keeps
rem its own exit code and type never runs after it. bat comes from PATH
rem only, through System32's where.exe, so no where.* or bat.* in the
rem current directory runs instead.
setlocal
set "_t="
if not "%_DEN_WRAPPERS%"=="0" for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $PATH:bat.exe 2^>nul') do if not defined _t set "_t=%%p"
if defined _t "%_t%" --style=plain --paging=never %*
if not defined _t type %*
exit /b %errorlevel%
