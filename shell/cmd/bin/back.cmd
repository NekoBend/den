@echo off
rem back - go back N entries in the directory history (default 1)
rem Usage: back [N] | back -l
rem The history is kept by the directory-history promptfilter in starship.lua:
rem _DEN_DIRBACK and _DEN_DIRFWD hold directories joined by '|', in `back -l`
rem order (back list farthest entry first, forward list nearest first). This
rem shim only reads them: it changes directory and leaves a note in
rem _DEN_DIRNAV that the filter applies at the next prompt. fwd.cmd runs this
rem file with --fwd, and `back -l` runs it with --show for each line it prints.
rem No goto labels: cmd can miss a label in a file checked out with LF line
rem endings. Delayed expansion is on only around !var! reads, so a '!' in a
rem path survives, and no line expands both lists (cmd caps a line at 8191
rem characters).

rem --show <label> <variable>: print one `back -l` line, %USERPROFILE% as ~
if "%~1"=="--show" (
    setlocal EnableDelayedExpansion
    set "_p=!%~3!"
    if defined USERPROFILE (
        set "_r=!_p:*%USERPROFILE%=!"
        if /i "!_p!"=="!USERPROFILE!" set "_p=~"
        if /i "!USERPROFILE!!_r!"=="!_p!" if "!_r:~0,1!"=="\" set "_p=~!_r!"
    )
    set "_l=   %~2"
    echo(!_l:~-3!  !_p!
    exit /b 0
)

setlocal DisableDelayedExpansion
set "_cmd=back"
if "%~1"=="--fwd" set "_cmd=fwd"
if "%_cmd%"=="fwd" shift
set "_word=back"
if "%_cmd%"=="fwd" set "_word=forward"
set "_list=%_DEN_DIRBACK%"
if "%_cmd%"=="fwd" set "_list=%_DEN_DIRFWD%"
set "_s=|%_list%|"
set "_count=0"
for %%a in ("%_s:|=" "%") do if not "%%~a"=="" set /a "_count+=1"

rem back -l: back entries numbered down to 1, * for the current directory,
rem then forward entries as +1, +2 ...
set "_mode=go"
if /i "%~1"=="-l" if "%_cmd%"=="back" set "_mode=list"
if "%_mode%"=="list" (
    set "_i=%_count%"
    for %%a in ("%_s:|=" "%") do if not "%%~a"=="" (
        set "_e=%%~a"
        call "%~f0" --show %%_i%% _e
        set /a "_i-=1"
    )
    set "_e=%CD%"
    call "%~f0" --show * _e
)
if "%_mode%"=="list" set "_s=|%_DEN_DIRFWD%|"
if "%_mode%"=="list" (
    set "_i=0"
    for %%a in ("%_s:|=" "%") do if not "%%~a"=="" (
        set /a "_i+=1"
        set "_e=%%~a"
        call "%~f0" --show +%%_i%% _e
    )
    exit /b 0
)

rem N: a positive integer without a leading zero, as on the other shells.
set "_n=%~1"
if not defined _n set "_n=1"
set "_bad="
for /f "eol=0 delims=0123456789" %%c in ("%_n%") do set "_bad=1"
if "%_n:~0,1%"=="0" set "_bad=1"
if defined _bad if "%_cmd%"=="back" >&2 echo usage: back [N ^| -l]  ^(N=positive integer, default 1^)
if defined _bad if "%_cmd%"=="fwd" >&2 echo usage: fwd [N]  ^(N=positive integer, default 1^)
if defined _bad exit /b 1

rem The entry to go to, as a token of the list: back N counts from the end of
rem _DEN_DIRBACK, fwd N from the start of _DEN_DIRFWD. 0 means out of range
rem (more than 4 digits is always out of range: a list holds 25).
set "_idx=0"
if "%_n:~4%"=="" if "%_cmd%"=="back" set /a "_idx=_count - _n + 1"
if "%_n:~4%"=="" if "%_cmd%"=="fwd" set /a "_idx=_n"
if %_idx% gtr %_count% set "_idx=0"
if %_idx% lss 1 set "_idx=0"
set "_ent=entries"
if "%_count%"=="1" set "_ent=entry"
if "%_idx%"=="0" >&2 echo %_cmd%: history has %_count% %_word% %_ent%, cannot go %_word% %_n%
if "%_idx%"=="0" exit /b 1

set "_t="
for /f "tokens=%_idx% delims=|" %%a in ("%_list%") do set "_t=%%a"
if not exist "%_t%\" (
    setlocal EnableDelayedExpansion
    >&2 echo(%_cmd%: !_t! no longer exists, dropped from history
    endlocal
    endlocal & set "_DEN_DIRNAV=drop%_cmd%:%_n%"
    exit /b 1
)
endlocal & set "_DEN_DIRNAV=%_cmd%:%_n%" & cd /d "%_t%"
