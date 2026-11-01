@echo off
rem cat - bat --style=plain --paging=never when bat is on PATH, else type
rem (type also while the wrappers are off: _DEN_WRAPPERS=0, tgl-wr).
rem It branches on whether bat exists, never on its exit code, so bat keeps
rem its own exit code and type never runs after it. bat comes from PATH
rem only, through System32's where.exe, so no where.* or bat.* in the
rem current directory runs instead.
rem
rem bat reads a word that starts with - as an option, also when it is the
rem name of a file, and some of its options run a program: beside files
rem named --pager=cmd and --paging=always, `cat *` ran cmd as bat's pager,
rem which ran the files' lines. bat expands a wildcard itself (cmd does
rem not), one word at a time, out of this script's sight: `cat ???* *`
rem beside a file named -- too gave it the pager options from the first word
rem and a -- from the second. So cat expands each word here with cmd's own
rem for, runs nothing (exit 2) when a match or a word starts with - and names
rem a file, and hands bat every name in quotes, which bat's expansion (the
rem wild crate) leaves alone. A word that matches nothing goes on as it is,
rem and bat says there is no such file. cmd splits a word at = , and ; as
rem for its own commands: such a name goes in quotes.
rem bat takes the last --paging it reads, so a second --paging=never goes
rem after the names. After a typed -- bat would read that word as a file
rem name, so cat refuses a --.
rem
rem This file keeps CRLF line endings: with bare LF, cmd can miss a :label
rem that a goto or call searches for when it straddles a 512-byte block.
rem Delayed expansion stays OFF where a name is read, so a "!" in it
rem survives; where it is ON, a name is only ever expanded as !var!, which
rem is never parsed again, so "&", "^" or a percent sign in it cannot turn
rem into syntax.
setlocal EnableExtensions DisableDelayedExpansion
set "_t="
if not "%_DEN_WRAPPERS%"=="0" for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $PATH:bat.exe 2^>nul') do if not defined _t set "_t=%%p"
if not defined _t goto :type
set "_n=0"
set "_bad="

:scan
if not "%~1"=="" goto :word
if "%1"=="" goto :run
rem An empty argument (""): bat says it cannot read it.
set /a "_n+=1"
set "_w%_n%="
shift
goto :scan

:word
if "%~1"=="--" goto :dashdash
set "_k=%_n%"
for %%f in ("%~1") do (
    set "_m=%%~f"
    call :add
)
if defined _bad exit /b 2
if not "%_n%"=="%_k%" goto :next
rem No file matched the wildcard.
set "_m=%~1"
call :add
if defined _bad exit /b 2
:next
shift
goto :scan

:dashdash
>&2 echo cat: -- would make bat read den's last --paging=never as a file name.
>&2 echo cat: write a file whose name starts with - as .\-name instead.
exit /b 2

:run
setlocal EnableDelayedExpansion
set "_a="
for /l %%i in (1,1,%_n%) do set "_a=!_a! "!_w%%i!""
"!_t!" --style=plain --paging=never!_a! --paging=never
exit /b %errorlevel%

:type
type %*
exit /b %errorlevel%

rem :add - the name in _m: refuse it (say why, set _bad) when it starts with
rem - and names a file, else keep it as _w<n>.
:add
if defined _bad exit /b 0
setlocal EnableDelayedExpansion
if not "!_m:~0,1!"=="-" goto :add_keep
if "!_m!"=="-" goto :add_keep
if not exist "!_m!" goto :add_keep
>&2 echo(cat: '!_m!' names a file, and bat would read it as an option: bat did not run.
>&2 echo(cat: write it as .\!_m! (a wildcard as .\*), or run type instead.
endlocal
set "_bad=1"
exit /b 0
:add_keep
endlocal
set /a "_n+=1"
set "_w%_n%=%_m%"
exit /b 0
