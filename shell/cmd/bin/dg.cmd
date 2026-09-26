@echo off
rem dg - file hashes with certutil: print them, check a file against an
rem expected hash, compare two files, or verify checksum files.
rem Usage: dg [algo] <file...>        hash; one file prints the bare hash
rem        dg [algo] <file> <hash>    check a file against an expected hash
rem        dg -e [algo] <a> <b>       do a and b have the same content?
rem        dg -c <sumsfile...>        verify checksum files (GNU or BSD lines)
rem algo: md5|sha256|sha512 or 5|256|512 (default sha256). digest.cmd runs this.
rem
rem This file keeps CRLF line endings: with bare LF, cmd can miss a :label
rem that a goto or call searches for when it straddles a 512-byte block.
rem
rem Delayed expansion stays OFF in the main flow, so a "!" in an argument
rem survives. The helpers at the bottom that touch a file name or a line of a
rem checksum file turn it ON and only ever expand those as !var!: a value
rem expanded that way is never parsed again, so "&", "|", "^" or a quote in
rem it cannot turn into syntax. certutil is started directly (never inside a
rem for /f command, which would hand the name to a second cmd to parse) and
rem writes into a temporary directory of its own that for /f then reads.

setlocal DisableDelayedExpansion
set "_mode=hash"
set "_alg="
set "_nd="
rem :hash appends a random number to this and makes that directory.
set "_tmp=%TEMP%\dg-"

:opts
if "%~1"=="-e" goto :opt_e
if "%~1"=="-c" goto :opt_c
if "%~1"=="-h" goto :help
if "%~1"=="--help" goto :help
if "%~1"=="/?" goto :help
if not "%~1"=="--" goto :algo
rem -- ends the options and the algo token too: `dg -- 256` hashes "256".
set "_nd=1"
shift
goto :dispatch

:opt_e
if "%_mode%"=="check" goto :conflict
set "_mode=equal"
shift
goto :opts

:opt_c
if "%_mode%"=="equal" goto :conflict
set "_mode=check"
shift
goto :opts

:algo
set "_t="
if /i "%~1"=="md5" set "_t=MD5"
if "%~1"=="5" set "_t=MD5"
if /i "%~1"=="sha256" set "_t=SHA256"
if "%~1"=="256" set "_t=SHA256"
if /i "%~1"=="sha512" set "_t=SHA512"
if "%~1"=="512" set "_t=SHA512"
if not defined _t goto :dispatch
set "_alg=%_t%"
shift
if "%~1"=="--" shift

:dispatch
if "%_mode%"=="check" goto :check
if "%_mode%"=="equal" goto :equal
if "%~1"=="" goto :usage
rem Two operands where the second is no path but reads as a hash: check
rem the first against it.
if "%~2"=="" goto :hash_mode
if not "%~3"=="" goto :hash_mode
if exist "%~2" goto :hash_mode
set "_x=%~2"
call :expected
if not defined _xa goto :hash_mode
goto :compare

rem ===== dg [algo] <file...> =====
:hash_mode
if not defined _alg set "_alg=SHA256"
rem One file prints the bare hash; several print hash and name per line.
set "_many="
if not "%~2"=="" set "_many=1"
set "_rc=0"
:hash_next
if "%~1"=="" exit /b %_rc%
set "_f=%~1"
shift
call :isfile _f
if errorlevel 1 (
    call :err _f " is not a file"
    set "_rc=1"
    goto :hash_next
)
call :hash _f
if not defined _h (
    call :err _f " could not be read"
    set "_rc=1"
    goto :hash_next
)
if not defined _many (
    echo %_h%
    goto :hash_next
)
call :say "%_h%  " _f ""
goto :hash_next

rem ===== dg [algo] <file> <hash> =====
:compare
rem _x is the expected hash, _xa the algorithm its length implies, and _xp
rem the one its "<algo>:" prefix names; an algo token or prefix that
rem disagrees with the length is refused.
if defined _alg if /i not "%_alg%"=="%_xa%" goto :compare_algo
if defined _xp if /i not "%_xp%"=="%_xa%" goto :compare_algo
set "_alg=%_xa%"
set "_f=%~1"
call :isfile _f
if errorlevel 1 (
    call :err _f " is not a file"
    exit /b 2
)
call :hash _f
if not defined _h (
    call :err _f " could not be read"
    exit /b 2
)
if /i "%_h%"=="%_x%" (
    call :say "OK  " _f ""
    exit /b 0
)
call :say "MISMATCH  " _f ""
echo(  expected %_x%
echo(  actual   %_h%
exit /b 1

:compare_algo
set "_named=%_alg%"
if defined _xp if /i not "%_xp%"=="%_xa%" set "_named=%_xp%"
set "_len=32"
if "%_xa%"=="SHA256" set "_len=64"
if "%_xa%"=="SHA512" set "_len=128"
>&2 echo(dg: the expected hash is %_len% hex digits (%_xa%), not %_named%
exit /b 2

rem ===== dg -e [algo] <a> <b> =====
:equal
if "%~2"=="" goto :usage_e
if not "%~3"=="" goto :usage_e
if not defined _alg set "_alg=SHA256"
set "_f=%~1"
set "_g=%~2"
set "_rc=0"
call :isfile _f
if errorlevel 1 (
    call :err _f " is not a file"
    set "_rc=2"
)
call :isfile _g
if errorlevel 1 (
    call :err _g " is not a file"
    set "_rc=2"
)
if not "%_rc%"=="0" exit /b 2
call :hash _f
set "_h1=%_h%"
call :hash _g
set "_h2=%_h%"
if not defined _h1 (
    call :err _f " could not be read"
    exit /b 2
)
if not defined _h2 (
    call :err _g " could not be read"
    exit /b 2
)
if /i "%_h1%"=="%_h2%" (
    call :say2 "SAME  "
    exit /b 0
)
call :say2 "DIFFERENT  "
call :say "  %_h1%  " _f ""
call :say "  %_h2%  " _g ""
exit /b 1

:usage_e
>&2 echo usage: dg -e [algo] ^<a^> ^<b^>
exit /b 2

rem ===== dg -c <sumsfile...> =====
:check
if defined _alg goto :check_algo
if "%~1"=="" goto :usage
set /a "_ok=0, _bad=0, _miss=0, _unread=0"
:check_next
if "%~1"=="" goto :check_done
set "_s=%~1"
shift
call :isfile _s
if errorlevel 1 (
    call :err _s " is not a readable file"
    set /a "_unread+=1"
    goto :check_next
)
set /a "_mal=0"
rem for /f skips blank lines, and eol=# skips the # comment lines. Names
rem are relative to the current directory, as with sha256sum -c.
for /f "usebackq eol=# delims=" %%L in ("%_s%") do (
    set "_ln=%%L"
    call :check_line
)
if not "%_mal%"=="0" call :err _s ": %_mal% malformed line(s) ignored"
goto :check_next

:check_done
set /a "_n=_ok+_bad+_miss"
if "%_n%"=="0" (
    >&2 echo dg: no checksum lines found
    exit /b 1
)
set /a "_fail=_bad+_miss+_unread"
if "%_fail%"=="0" exit /b 0
set "_msg=%_bad% FAILED, %_miss% MISSING of %_n% checked"
if not "%_unread%"=="0" set "_msg=%_msg%, %_unread% sums file(s) unreadable"
>&2 echo(dg: %_msg%
exit /b 1

:check_algo
>&2 echo dg: -c takes no algo (each line names its own)
exit /b 1

rem ===== help and refusals =====
:help
call :usage_text
exit /b 0

:usage
call :usage_text 1>&2
exit /b 1

:conflict
>&2 echo dg: -e and -c cannot be combined
exit /b 1

:usage_text
echo usage: dg [algo] ^<file...^>        hash; one file prints the bare hash
echo        dg [algo] ^<file^> ^<hash^>    check a file against an expected hash
echo        dg -e [algo] ^<a^> ^<b^>       do a and b have the same content?
echo        dg -c ^<sumsfile...^>        verify checksum files (GNU or BSD lines)
echo algo: md5^|sha256^|sha512 or 5^|256^|512; default sha256, or the one the
echo ^<hash^>'s length implies. -- ends option and algo parsing. digest = dg.
exit /b 0

rem ===== helpers =====

rem :isfile VAR - errorlevel 0 when the path in VAR is an existing file
rem (not a directory).
:isfile
setlocal EnableDelayedExpansion
if not exist "!%~1!" exit /b 1
if exist "!%~1!\*" exit /b 1
exit /b 0

rem :hash VAR - hash the file named in VAR with _alg; sets _h to the hex
rem digest, or clears it when certutil could not read the file. certutil
rem prints a header line, the hash (in old versions with a space between
rem bytes) and a status line; the second line is taken, so a translated
rem header does not matter, and a failure's text is refused as not hex.
:hash
setlocal EnableDelayedExpansion
set "_h="
set "_p=!%~1!"
rem A leading-dash name would read as a certutil option.
if "!_p:~0,1!"=="-" set "_p=.\!_p!"
rem The output goes into a directory made for this one hash: md fails when
rem the name is taken, so two dg runs that draw the same random number (cmd
rem seeds it from the clock) cannot read each other's output. Where no
rem directory can be made, it gives up after 20 draws, as for an unreadable
rem file.
rem certutil refuses a 0-byte file (the Windows CI run shows it), but
rem the digest of empty input is a constant per algorithm.
for %%F in ("!_p!") do if "%%~zF"=="0" goto :hash_empty
set /a "_try=0"
:hash_dir
set /a "_try+=1"
if !_try! gtr 20 goto :hash_done
set "_d=!_tmp!!RANDOM!!RANDOM!"
md "!_d!" >nul 2>&1 || goto :hash_dir
certutil -hashfile "!_p!" !_alg! >"!_d!\out.txt" 2>&1
for /f "usebackq skip=1 delims=" %%H in ("!_d!\out.txt") do if not defined _h set "_h=%%H"
rd /s /q "!_d!" >nul 2>&1
if defined _h set "_h=!_h: =!"
if defined _h call :ishex _h || set "_h="
rem Lowercase: cmd's replace ignores case, so a=a turns every A into a.
if defined _h for %%C in (a b c d e f) do set "_h=!_h:%%C=%%C!"
goto :hash_done
:hash_empty
if /i "!_alg!"=="MD5" set "_h=d41d8cd98f00b204e9800998ecf8427e"
if /i "!_alg!"=="SHA256" set "_h=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
if /i "!_alg!"=="SHA512" set "_h=cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"
:hash_done
endlocal & set "_h=%_h%"
exit /b 0

rem :expected - can _x be an expected hash? Trimmed and with an optional
rem "md5:" / "sha256:" / "sha512:" prefix taken off (blanks after it too, as
rem in "SHA256: <hex>"), it must be 32, 64 or 128 hex digits. Then _x is that
rem hex, _xa the algorithm its length implies and _xp the prefix's (or
rem empty); otherwise _xa is empty.
:expected
setlocal EnableDelayedExpansion
set "_xa="
set "_xp="
set "_x2="
rem Leading blanks go first, so a prefix starts the value; the blanks after
rem the prefix and at the end go below, where a second word is refused.
for /f "tokens=*" %%A in ("!_x!") do set "_x=%%A"
for /f "tokens=1,* delims=:" %%A in ("!_x!") do if not "%%B"=="" (
    set "_xp=%%A"
    set "_x=%%B"
)
set "_t="
if /i "!_xp!"=="md5" set "_t=MD5"
if /i "!_xp!"=="sha256" set "_t=SHA256"
if /i "!_xp!"=="sha512" set "_t=SHA512"
if defined _xp if not defined _t goto :expected_no
set "_xp=!_t!"
for /f "tokens=1,2" %%A in ("!_x!") do (
    set "_x=%%A"
    set "_x2=%%B"
)
if defined _x2 goto :expected_no
call :ishex _x || goto :expected_no
if not "!_x:~31,1!"=="" if "!_x:~32,1!"=="" set "_xa=MD5"
if not "!_x:~63,1!"=="" if "!_x:~64,1!"=="" set "_xa=SHA256"
if not "!_x:~127,1!"=="" if "!_x:~128,1!"=="" set "_xa=SHA512"
if not defined _xa goto :expected_no
for %%C in (a b c d e f) do set "_x=!_x:%%C=%%C!"
endlocal & set "_x=%_x%" & set "_xa=%_xa%" & set "_xp=%_xp%"
exit /b 0
:expected_no
endlocal & set "_xa="
exit /b 0

rem :check_line - verify the checksum-file line in _ln: GNU "<hash>  <name>"
rem or "<hash> *<name>", or BSD "SHA256 (<name>) = <hash>" (MD5, SHA512
rem alike), with the algorithm taken from the tag or the hash's length.
rem Prints "<name>: OK|FAILED|MISSING" and counts it; a malformed line only
rem counts in _mal.
:check_line
setlocal EnableDelayedExpansion
set "_st=BAD"
set "_alg="
set "_nm="
set "_x="
rem A line of blanks is a blank line.
set "_t=!_ln: =!"
if not defined _t (
    set "_st=SKIP"
    goto :check_line_end
)
rem GNU starts a line with a backslash when it escaped the name in it.
set "_esc="
if "!_ln:~0,1!"=="\" (
    set "_esc=1"
    set "_ln=!_ln:~1!"
)
rem BSD: the tag fixes the hash's length, so the name is what lies between
rem "TAG (" and ") = <hash>" at the end.
if "!_ln:~0,5!"=="MD5 (" (
    set "_alg=MD5"
    set "_x=!_ln:~-32!"
    set "_sep=!_ln:~-36,4!"
    set "_nm=!_ln:~5,-36!"
)
if "!_ln:~0,8!"=="SHA256 (" (
    set "_alg=SHA256"
    set "_x=!_ln:~-64!"
    set "_sep=!_ln:~-68,4!"
    set "_nm=!_ln:~8,-68!"
)
if "!_ln:~0,8!"=="SHA512 (" (
    set "_alg=SHA512"
    set "_x=!_ln:~-128!"
    set "_sep=!_ln:~-132,4!"
    set "_nm=!_ln:~8,-132!"
)
if defined _alg (
    if not "!_sep!"==") = " goto :check_line_end
    goto :check_line_hex
)
rem GNU: the hash is 32, 64 or 128 hex digits, then " " and " " or "*".
if "!_ln:~32,2!"=="  " goto :check_line_md5
if "!_ln:~32,2!"==" *" goto :check_line_md5
if "!_ln:~64,2!"=="  " goto :check_line_sha256
if "!_ln:~64,2!"==" *" goto :check_line_sha256
if "!_ln:~128,2!"=="  " goto :check_line_sha512
if "!_ln:~128,2!"==" *" goto :check_line_sha512
goto :check_line_end
:check_line_md5
set "_alg=MD5"
set "_x=!_ln:~0,32!"
set "_nm=!_ln:~34!"
goto :check_line_hex
:check_line_sha256
set "_alg=SHA256"
set "_x=!_ln:~0,64!"
set "_nm=!_ln:~66!"
goto :check_line_hex
:check_line_sha512
set "_alg=SHA512"
set "_x=!_ln:~0,128!"
set "_nm=!_ln:~130!"
:check_line_hex
if not defined _nm goto :check_line_end
call :ishex _x || goto :check_line_end
rem A Windows name cannot hold a newline, so only \\ needs undoing.
if defined _esc set "_nm=!_nm:\\=\!"
set "_st=MISSING"
if not exist "!_nm!" goto :check_line_print
call :hash _nm
set "_st=FAILED"
if /i "!_h!"=="!_x!" set "_st=OK"
:check_line_print
echo(!_nm!: !_st!
:check_line_end
endlocal & set "_st=%_st%"
if "%_st%"=="OK" set /a "_ok+=1"
if "%_st%"=="FAILED" set /a "_bad+=1"
if "%_st%"=="MISSING" set /a "_miss+=1"
if "%_st%"=="BAD" set /a "_mal+=1"
exit /b 0

rem :say PRE VAR POST - print PRE, the name in VAR, then POST, without cmd
rem parsing the name.
:say
setlocal EnableDelayedExpansion
echo(%~1!%~2!%~3
exit /b 0

rem :say2 PRE - print "PRE<_f>  <_g>" (dg -e's verdict line).
:say2
setlocal EnableDelayedExpansion
echo(%~1!_f!  !_g!
exit /b 0

rem :ishex VAR - errorlevel 0 when VAR holds at least one character and only
rem hex digits. cmd's replace ignores case, so taking out 0-9 and a-f also
rem takes out A-F, and anything left is not hex. (findstr /r /x over `set VAR`
rem output did this first, but on Windows it matched no line, valid hex
rem included, so every hash and every expected hash was refused.)
:ishex
setlocal EnableDelayedExpansion
set "_r=!%~1!"
if not defined _r exit /b 1
for %%C in (0 1 2 3 4 5 6 7 8 9 a b c d e f) do if defined _r set "_r=!_r:%%C=!"
if defined _r exit /b 1
exit /b 0

rem :err VAR MSG - print "dg: '<name in VAR>'MSG" to stderr.
:err
setlocal EnableDelayedExpansion
>&2 echo(dg: '!%~1!'%~2
exit /b 0
