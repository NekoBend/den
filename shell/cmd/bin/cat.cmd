@echo off
rem cat - bat --style=plain --paging=never when bat is on PATH, else type
rem (type also while the wrappers are off: _DEN_WRAPPERS=0, tgl-wr).
rem It branches on whether bat exists, never on its exit code, so bat keeps
rem its own exit code and type never runs after it. bat comes from PATH
rem only, through System32's where.exe, so no where.* or bat.* in the
rem current directory runs instead.
rem bat expands the wildcards in its arguments itself (cmd does not) and
rem reads a name that starts with - as an option: `cat *` beside files named
rem --pager=cmd and --paging=always ran cmd as bat's pager, which ran the
rem files' lines. bat takes the last --paging it reads, so a second
rem --paging=never goes after the arguments. After a typed -- bat would
rem read that word as a file name, and the options before the -- would
rem still count, so cat refuses a -- and runs nothing.
setlocal
set "_t="
if not "%_DEN_WRAPPERS%"=="0" for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $PATH:bat.exe 2^>nul') do if not defined _t set "_t=%%p"
if not defined _t goto run
:scan
if "%~1"=="" goto run
if "%~1"=="--" (
    >&2 echo cat: -- would make bat read den's last --paging=never as a file name.
    >&2 echo cat: write a file whose name starts with - as .\-name instead.
    exit /b 2
)
shift
goto scan
:run
if defined _t "%_t%" --style=plain --paging=never %* --paging=never
if not defined _t type %*
exit /b %errorlevel%
