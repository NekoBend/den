@echo off
rem cmd_shims.cmd - run den's cmd shims (shell\cmd\bin) for real. The Windows
rem CI job calls it; it exits 1 when any check fails. The tools are stand-ins
rem that cmd_fake_tool.ps1 builds: each prints its arguments as [arg] lines
rem and exits with FAKE_RC. Checked: the wrappers run the tool found on PATH,
rem keep its exit code and run their fallback only without it (find also
rem after a failing fd); no where.* or tool in the current directory runs;
rem touch takes several files; uv passes the arguments after `run` through
rem unchanged; python3 runs a venv's python.exe; path lists PATH; again
rem asks before it re-runs.
rem CRLF line endings: with LF only, cmd can miss a label.
setlocal EnableExtensions DisableDelayedExpansion
for %%b in ("%~dp0..\..\shell\cmd\bin") do set "BIN=%%~fb"
set "T=%RUNNER_TEMP%"
if not defined T set "T=%TEMP%"
set "T=%T%\den-cmd-shims"
if exist "%T%" rmdir /s /q "%T%"
mkdir "%T%\tools" "%T%\notools" "%T%\work" "%T%\cwd" "%T%\venv\Scripts" || exit /b 1
set "FC=%SystemRoot%\System32\fc.exe"
set "FINDSTR=%SystemRoot%\System32\findstr.exe"
set "W=%T%\want.txt"
set "O=%T%\out.txt"
set "N=0"
set "FAILS=0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0cmd_fake_tool.ps1" -Out "%T%\tools\fake.exe" || exit /b 1
for %%t in (lsd bat rg fd uv) do copy /y "%T%\tools\fake.exe" "%T%\tools\%%t.exe" >nul || exit /b 1
copy /y "%T%\tools\fake.exe" "%T%\venv\Scripts\python.exe" >nul || exit /b 1
set "BASEPATH=%SystemRoot%\System32;%SystemRoot%;%SystemRoot%\System32\WindowsPowerShell\v1.0"
set "PATH=%T%\tools;%BASEPATH%"
set "FAKE_RC="
set "_DEN_WRAPPERS="
set "_DEN_UV_OVERRIDE="
set "VIRTUAL_ENV="
set "_DEN_VENV_PYTHON="
set "_DEN_AGAIN="
set "_DEN_AGAIN_ERR="
set "_DEN_AGAIN_RUN="
cd /d "%T%\work" || exit /b 1
>"%T%\work\a.txt" echo zzz

rem --- wrappers: the tool runs, its exit code is the shim's, no fallback after it
set "FAKE_RC=2"
>"%W%" echo [a]
>>"%W%" echo [b c]
call "%BIN%\ls.cmd" a "b c" >"%O%" 2>&1
call :expect %errorlevel% 2 "ls: lsd's exit code, no dir after it"

set "FAKE_RC=1"
>"%W%" echo [zzz]
>>"%W%" echo [a.txt]
call "%BIN%\grep.cmd" zzz a.txt <nul >"%O%" 2>&1
call :expect %errorlevel% 1 "grep: rg finds nothing, exit 1, no findstr after it"

>"%W%" echo [--style=plain]
>>"%W%" echo [--paging=never]
>>"%W%" echo [a.txt]
>>"%W%" echo [missing.txt]
call "%BIN%\cat.cmd" a.txt missing.txt >"%O%" 2>&1
call :expect %errorlevel% 1 "cat: bat fails, no type after it"

rem find is the exception: find.exe still runs after a failing fd, so a
rem DOS-style find typed at the prompt answers as it always has
call "%BIN%\find.cmd" "zzz" a.txt >"%O%" 2>&1
set "RC=%errorlevel%"
set "OK="
"%FINDSTR%" /x /l /c:"[zzz]" "%O%" >nul && "%FINDSTR%" /x /l /c:"zzz" "%O%" >nul && if "%RC%"=="0" set "OK=1"
call :check "find: fd fails, then find.exe answers"

set "FAKE_RC="
>"%W%" echo [--tree]
>>"%W%" echo [x]
call "%BIN%\lt.cmd" x >"%O%" 2>&1
call :expect %errorlevel% 0 "lt: lsd --tree"

>"%W%" echo [-l]
>>"%W%" echo [--tree]
call "%BIN%\llt.cmd" >"%O%" 2>&1
call :expect %errorlevel% 0 "llt: lsd -l --tree"

>"%W%" echo [-a]
call "%BIN%\la.cmd" >"%O%" 2>&1
call :expect %errorlevel% 0 "la: lsd -a"

>"%W%" echo [-l]
call "%BIN%\ll.cmd" >"%O%" 2>&1
call :expect %errorlevel% 0 "ll: lsd -l"

>"%W%" echo [-la]
call "%BIN%\lla.cmd" >"%O%" 2>&1
call :expect %errorlevel% 0 "lla: lsd -la"

rem --- the fallback runs when the tool is missing or the wrappers are off
set "PATH=%T%\notools;%BASEPATH%"
>"%W%" echo zzz
call "%BIN%\grep.cmd" zzz a.txt >"%O%" 2>&1
call :expect %errorlevel% 0 "grep: findstr without rg"
call "%BIN%\ls.cmd" >"%O%" 2>&1
set "RC=%errorlevel%"
set "OK="
"%FINDSTR%" /l /c:"a.txt" "%O%" >nul && if "%RC%"=="0" set "OK=1"
call :check "ls: dir /w without lsd"
set "PATH=%T%\tools;%BASEPATH%"
set "_DEN_WRAPPERS=0"
>"%W%" echo zzz
call "%BIN%\grep.cmd" zzz a.txt >"%O%" 2>&1
call :expect %errorlevel% 0 "grep: findstr with the wrappers off"
set "_DEN_WRAPPERS="

rem --- no where.* or lsd.exe in the current directory runs
cd /d "%T%\cwd" || exit /b 1
>"%T%\cwd\where.bat" echo @echo where.bat ran^>"%T%\where-ran.txt"
copy /y "%SystemRoot%\System32\hostname.exe" "%T%\cwd\lsd.exe" >nul
>"%W%" echo [q]
call "%BIN%\ls.cmd" q >"%O%" 2>&1
call :expect %errorlevel% 0 "ls: lsd from PATH, not the current directory"
>"%W%" echo %T%\tools\fake.exe
call "%BIN%\which.cmd" fake >"%O%" 2>&1
call :expect %errorlevel% 0 "which: where.exe from System32"
set "OK=1"
if exist "%T%\where-ran.txt" set "OK="
call :check "no where.bat from the current directory runs"
cd /d "%T%\work" || exit /b 1

rem --- touch: every operand, a usage error without one
call "%BIN%\touch.cmd" t1.txt "t 2.txt" t3.txt
set "RC=%errorlevel%"
set "OK="
if exist t1.txt if exist "t 2.txt" if exist t3.txt if "%RC%"=="0" set "OK=1"
call :check "touch: three files"
call "%BIN%\touch.cmd" 2>"%O%"
set "RC=%errorlevel%"
set "OK="
"%FINDSTR%" /b /l /c:"usage: touch" "%O%" >nul && if "%RC%"=="1" set "OK=1"
call :check "touch: usage without a file"
call "%BIN%\touch.cmd" t1.txt no-such-dir\x.txt 2>nul
set "RC=%errorlevel%"
set "OK="
if "%RC%"=="1" set "OK=1"
call :check "touch: exit 1 when one fails"

rem --- uv: the arguments after run arrive as typed
set "VIRTUAL_ENV=%T%\venv"
set "_DEN_VENV_PYTHON=3.12"
>"%W%" echo [run]
>>"%W%" echo [--python]
>>"%W%" echo [3.12]
>>"%W%" echo [--]
>>"%W%" echo [python]
>>"%W%" echo [-c]
>>"%W%" echo [import sys; print(sys.argv)]
>>"%W%" echo [a^&b]
>>"%W%" echo [key=value]
>>"%W%" echo [--with]
>>"%W%" echo [requests==2.31]
>>"%W%" echo [x!y]
>>"%W%" echo []
>>"%W%" echo [a ^| b]
call "%BIN%\uv.cmd" run python -c "import sys; print(sys.argv)" "a&b" key=value --with requests==2.31 "x!y" "" "a | b" >"%O%" 2>&1
call :expect %errorlevel% 0 "uv: run arguments unchanged"
>"%W%" echo [run]
>>"%W%" echo [--python]
>>"%W%" echo [3.12]
>>"%W%" echo [--with]
>>"%W%" echo [rich]
>>"%W%" echo [app.py]
call "%BIN%\uv.cmd" run --with rich app.py >"%O%" 2>&1
call :expect %errorlevel% 0 "uv: no -- before an option"
set "_DEN_VENV_PYTHON=3.12 --index-url x"
>"%W%" echo [run]
>>"%W%" echo [app.py]
call "%BIN%\uv.cmd" run app.py >"%O%" 2>&1
call :expect %errorlevel% 0 "uv: no injection of a version that is not digits and dots"
set "_DEN_VENV_PYTHON=3.12"
set "FAKE_RC=3"
>"%W%" echo [pip]
>>"%W%" echo [list]
call "%BIN%\uv.cmd" pip list >"%O%" 2>&1
call :expect %errorlevel% 3 "uv: other commands pass through with their exit code"
set "FAKE_RC="

rem --- python3 in a venv: the venv's python.exe (a Windows venv has no python3.exe)
>"%W%" echo [-V]
call "%BIN%\python3.cmd" -V >"%O%" 2>&1
call :expect %errorlevel% 0 "python3: the venv's python.exe"
set "VIRTUAL_ENV="
set "_DEN_VENV_PYTHON="

rem --- path.cmd lists PATH (typed `path` stays cmd's own command)
call "%BIN%\path.cmd" >"%O%" 2>&1
set "FIRST="
set /p "FIRST=" <"%O%"
set "OK="
if /i "%FIRST%"=="%T%\tools" set "OK=1"
call :check "path: lists PATH"

rem --- again: asks, and leaves the command for the next input line on a yes
>"%T%\yes.txt" echo y
>"%T%\no.txt" echo n
set "_DEN_AGAIN=echo a & echo b (x)"
call "%BIN%\again.cmd" <"%T%\yes.txt" >"%O%" 2>&1
set "RC=%errorlevel%"
set "OK="
"%FINDSTR%" /b /l /c:"+ echo a & echo b (x)" "%O%" >nul && if "%RC%"=="0" if "%_DEN_AGAIN_RUN%"=="1" set "OK=1"
call :check "again: yes"
set "_DEN_AGAIN_RUN="
set "_DEN_AGAIN=echo hi"
call "%BIN%\again.cmd" <"%T%\no.txt" >"%O%" 2>&1
set "RC=%errorlevel%"
set "OK="
if "%RC%"=="0" if not defined _DEN_AGAIN_RUN if not defined _DEN_AGAIN set "OK=1"
call :check "again: no"
set "_DEN_AGAIN_ERR=again: no command at position 3 in history"
>"%W%" echo again: no command at position 3 in history
call "%BIN%\again.cmd" >"%O%" 2>&1
call :expect %errorlevel% 1 "again: the lookup's message"
set "OK=1"
if defined _DEN_AGAIN_ERR set "OK="
call :check "again: the message is cleared"
>"%W%" echo again: type it on a line of its own (needs Clink 1.3.18 or newer)
call "%BIN%\again.cmd" >"%O%" 2>&1
call :expect %errorlevel% 1 "again: run without the lookup"

cd /d "%~dp0"
if not "%FAILS%"=="0" (
    echo ::error::cmd shims: %FAILS% of %N% checks failed
    exit /b 1
)
echo cmd shims: all %N% checks passed
exit /b 0

rem :expect RC WANT LABEL - the run exited RC; it passes when RC is WANT and
rem its output holds the lines in want.txt.
:expect
set /a "N+=1"
if not "%~1"=="%~2" goto expect_fail
"%FC%" "%W%" "%O%" >nul 2>&1
if errorlevel 1 goto expect_fail
echo ok   %~3
exit /b 0
:expect_fail
set /a "FAILS+=1"
echo ::error::cmd shims: %~3: exit %~1, want %~2
echo --- want:
type "%W%"
echo --- got:
type "%O%"
exit /b 0

rem :check LABEL - passes when OK is defined.
:check
set /a "N+=1"
if not defined OK goto check_fail
echo ok   %~1
exit /b 0
:check_fail
set /a "FAILS+=1"
echo ::error::cmd shims: %~1
exit /b 0
