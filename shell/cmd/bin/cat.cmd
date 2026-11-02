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
rem wild crate) leaves alone. bat reads a run of backslashes before a quote
rem as half as many, and an odd one as escaping the quote, so a word that
rem ends in \ gets that run doubled before its closing quote: label\ would
rem otherwise run on into the words after it. A word that matches nothing
rem goes on as it is, and bat says there is no such file. cmd splits a word
rem at = , and ; as for its own commands: such a name goes in quotes.
rem bat takes the last --paging it reads, so a second --paging=never goes
rem after the names. After a typed -- bat would read that word as a file
rem name, so cat refuses a --.
rem cat's for would make file names of an option or an option's value too:
rem `cat -l * a.txt` would give bat a file name as the language. So cat
rem refuses (exit 2) a word that starts with - and holds * or ?, and the
rem value of an option that takes it from the next word (bat 0.26.1's
rem --help: --file-name, --language or -l, --map-syntax or -m, ...) when
rem that holds one. cmd splits an unquoted --file-name=*.py into --file-name
rem and *.py, so the value case arises from the = form too. [ and ] are no
rem wildcard to cmd's for, and a quoted word none to bat's expansion.
rem
rem This file keeps CRLF line endings: with bare LF, cmd can miss a :label
rem that a goto or call searches for when it straddles a 512-byte block.
rem Delayed expansion stays OFF where a name is read, so a "!" in it
rem survives; where it is ON, a name is only ever expanded as !var!, which
rem is never parsed again, so "&", "^" or a percent sign in it cannot turn
rem into syntax.
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
if not "%_DEN_WRAPPERS%"=="0" for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $_abs:bat.exe 2^>nul') do if not defined _t set "_t=%%p"
if not defined _t goto :type
set "_n=0"
set "_bad="
set "_val="

:scan
if not "%~1"=="" goto :word
if "%1"=="" goto :run
rem An empty argument (""): bat says it cannot read it.
set /a "_n+=1"
set "_w%_n%="
set "_val="
shift
goto :scan

:word
if "%~1"=="--" goto :dashdash
rem _p: the word holds * or ?. cmd's for then gives the names it matches,
rem none of which holds either, and never the word itself; for any other
rem word it gives just that word.
set "_f="
for %%f in ("%~1") do set "_f=%%~f"
set "_m=%~1"
set "_p=1"
setlocal EnableDelayedExpansion
if "!_f!"=="!_m!" (endlocal & set "_p=") else endlocal
call :option
if defined _bad exit /b 2
if defined _val set "_vo=%~1"
if defined _lit goto :literal
set "_k=%_n%"
for %%f in ("%~1") do (
    set "_m=%%~f"
    call :add
)
if defined _bad exit /b 2
if not "%_n%"=="%_k%" goto :next
rem No file matched the wildcard.
set "_m=%~1"
:literal
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
for /l %%i in (1,1,%_n%) do call :quote %%i
"!_t!" --style=plain --paging=never!_a! --paging=never
exit /b %errorlevel%

:type
type %*
exit /b %errorlevel%

rem :quote <i> - add _w<i> to _a in quotes, with the run of backslashes it
rem ends in doubled. bat parses its command line by CommandLineToArgvW's
rem rules (wild 2.2.1, src/parser.rs:102-121): 2n backslashes before a quote
rem are n and the quote ends the word, 2n+1 are n and a quote in the word.
rem So "label\" would swallow its closing quote and run on into the words
rem after it, den's last --paging=never included, where "label\\" is label\.
rem Called from :run, where delayed expansion is on: a name is read only as
rem !var!.
:quote
set "_s=!_w%1!"
set "_x="
:quote_bs
if not defined _s goto :quote_end
if not "!_s:~-1!"=="\" goto :quote_end
set "_s=!_s:~0,-1!"
set "_x=!_x!\"
goto :quote_bs
:quote_end
set "_a=!_a! "!_w%1!!_x!""
exit /b 0

rem :option - the word in _m, which holds * or ? when _p is set: set _lit
rem when it is an option or an option's value, which bat gets as it is, and
rem _val when bat takes this option's value from the next word; refuse (say
rem why, set _bad) such a word that holds * or ?. A cluster of short options
rem gives -l, -m, -r or -H the rest of the word, or the next word when it
rem ends the word (-pl).
:option
set "_lit="
if defined _val goto :option_value
setlocal EnableDelayedExpansion
if not "!_m:~0,1!"=="-" goto :option_no
if "!_m!"=="-" goto :option_no
if defined _p goto :option_wild
set "_v="
for %%o in (--binary --color --completion --decorations --diff-context --file-name --highlight-line --ignored-suffix --italic-text --language --line-range --map-syntax --nonprintable-notation --pager --paging --squeeze-limit --strip-ansi --style --tabs --terminal-width --theme --theme-dark --theme-light --wrap --source --target) do if "!_m!"=="%%o" set "_v=1"
if "!_m:~1,1!"=="-" goto :option_yes
set "_i=0"
:option_short
set /a "_i+=1"
set "_c=!_m:~%_i%,1!"
if not defined _c goto :option_yes
for %%c in (l m r H) do if "!_c!"=="%%c" goto :option_short_value
goto :option_short
:option_short_value
set /a "_i+=1"
set "_c=!_m:~%_i%,1!"
if not defined _c set "_v=1"
:option_yes
endlocal & set "_lit=1" & set "_val=%_v%"
exit /b 0
:option_no
endlocal
exit /b 0
:option_wild
>&2 echo(cat: '!_m!' is an option that holds * or ?, which cat would expand as a wildcard: bat did not run.
>&2 echo(cat: run bat by name for it.
endlocal
set "_bad=1"
exit /b 0
:option_value
set "_val="
set "_lit=1"
if not defined _p exit /b 0
setlocal EnableDelayedExpansion
>&2 echo(cat: '!_m!', the value of !_vo!, holds * or ?, which cat would expand as a wildcard: bat did not run.
>&2 echo(cat: run bat by name for it.
endlocal
set "_bad=1"
exit /b 0

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
