@echo off
rem cmd_shims.cmd - run den's cmd shims (shell\cmd\bin) for real. The Windows
rem CI job calls it; it exits 1 when any check fails. The tools are stand-ins
rem that cmd_fake_tool.ps1 builds: each prints its arguments as [arg] lines
rem and exits with FAKE_RC. Checked: the wrappers run the tool found on PATH,
rem keep its exit code and run their fallback only without it; findw runs fd
rem whatever the toggle, and says so without it; there is no find shim, so
rem typed find is find.exe; no where.* or tool in the current directory runs;
rem touch takes several files; uv passes the arguments after `run` through
rem unchanged; python3 runs a venv's python.exe; python and python3 run a
rem python directly, not uv run, under a pyproject.toml, beside a .venv,
rem below a pyvenv.cfg, a uv.toml or a .python-version that names a path,
rem and for --version / -V; pip runs nothing outside a venv; path lists
rem PATH; again asks before it re-runs.
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

rem findw is fd, the toggle notwithstanding, and find.exe never runs after
rem it. There is no find.cmd: typed find is find.exe, which reads a pipe
rem (netstat -ano | find "8080") where fd reads none.
>"%W%" echo [zzz]
>>"%W%" echo [a.txt]
call "%BIN%\findw.cmd" "zzz" a.txt >"%O%" 2>&1
call :expect %errorlevel% 1 "findw: fd's exit code, no find.exe after it"
set "_DEN_WRAPPERS=0"
call "%BIN%\findw.cmd" "zzz" a.txt >"%O%" 2>&1
call :expect %errorlevel% 1 "findw: fd with the wrappers off"
set "_DEN_WRAPPERS="
set "OK=1"
if exist "%BIN%\find.cmd" set "OK="
call :check "find: no shim, typed find stays find.exe"

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
>"%W%" echo findw: fd is not installed.
call "%BIN%\findw.cmd" zzz a.txt >"%O%" 2>&1
call :expect %errorlevel% 1 "findw: says so without fd, and runs no find.exe"
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

rem --- python and pip where uv would build or run a clone's code. FAKE_SELF
rem makes each copy of the stand-in name its folder first; as uv it answers
rem `uv python find --system --no-config` with FAKE_FIND_SYSTEM or
rem FAKE_FIND_MANAGED. The line on stderr comes before python's output.
mkdir "%T%\sys" "%T%\managed" "%T%\proj\sub" "%T%\vproj\.venv" "%T%\cfgvenv\Scripts" "%T%\cfgvenv\sub" || exit /b 1
copy /y "%T%\tools\fake.exe" "%T%\sys\python.exe" >nul || exit /b 1
copy /y "%T%\tools\fake.exe" "%T%\managed\python.exe" >nul || exit /b 1
copy /y "%T%\tools\fake.exe" "%T%\cfgvenv\Scripts\python.exe" >nul || exit /b 1
>"%T%\proj\pyproject.toml" echo [project]
rem uv takes a directory that holds a pyvenv.cfg for a venv, whatever its name.
>"%T%\cfgvenv\pyvenv.cfg" echo home = %T%\sys
set "FAKE_SELF=1"
set "FAKE_FIND_SYSTEM=%T%\sys\python.exe"
set "FAKE_FIND_MANAGED=%T%\managed\python.exe"
cd /d "%T%\proj\sub" || exit /b 1
>"%W%" echo python: running %T%\sys\python.exe, not uv run: uv run would build or run code from %T%\proj\pyproject.toml
>>"%W%" echo [@sys]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python.cmd" -c x >"%O%" 2>&1
call :expect %errorlevel% 0 "python: under a pyproject.toml, the system python and a line, not uv run"
cd /d "%T%\vproj" || exit /b 1
>"%W%" echo python3: running %T%\sys\python.exe, not uv run: uv run would build or run code from %T%\vproj\.venv
>>"%W%" echo [@sys]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python3.cmd" -c x >"%O%" 2>&1
call :expect %errorlevel% 0 "python3: beside a .venv, the system python and a line, not uv run"
cd /d "%T%\cfgvenv\sub" || exit /b 1
>"%W%" echo python: running %T%\sys\python.exe, not uv run: uv run would build or run code from %T%\cfgvenv\pyvenv.cfg
>>"%W%" echo [@sys]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python.cmd" -c x >"%O%" 2>&1
call :expect %errorlevel% 0 "python: below a pyvenv.cfg, the system python and a line, not uv run"
rem A uv.toml counts whatever it holds, and a .python-version when a line
rem names a path (here with \ and after a comment and a blank line); one of
rem version requests alone, with a path only in a comment line, does not.
mkdir "%T%\uvtoml\sub" "%T%\pyver\sub" "%T%\pyveronly" || exit /b 1
>"%T%\uvtoml\uv.toml" echo python-preference = "only-managed"
>"%T%\pyver\.python-version" echo # pinned to the one in tools\
>>"%T%\pyver\.python-version" echo(
>>"%T%\pyver\.python-version" echo   .\tools\py
>"%T%\pyveronly\.python-version" echo 3.13
>>"%T%\pyveronly\.python-version" echo cpython@3.13
>>"%T%\pyveronly\.python-version" echo   # not .\tools\py
cd /d "%T%\uvtoml\sub" || exit /b 1
>"%W%" echo python: running %T%\sys\python.exe, not uv run: uv run would build or run code from %T%\uvtoml\uv.toml
>>"%W%" echo [@sys]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python.cmd" -c x >"%O%" 2>&1
call :expect %errorlevel% 0 "python: below a uv.toml, the system python and a line, not uv run"
cd /d "%T%\pyver\sub" || exit /b 1
>"%W%" echo python3: running %T%\sys\python.exe, not uv run: uv run would build or run code from %T%\pyver\.python-version
>>"%W%" echo [@sys]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python3.cmd" -c x >"%O%" 2>&1
call :expect %errorlevel% 0 "python3: below a .python-version that names a path, the system python and a line, not uv run"
cd /d "%T%\pyveronly" || exit /b 1
>"%W%" echo [@tools]
>>"%W%" echo [run]
>>"%W%" echo [--]
>>"%W%" echo [python]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python.cmd" -c x >"%O%" 2>nul
call :expect %errorlevel% 0 "python: beside a .python-version of version requests alone, uv run as before"
cd /d "%T%\work" || exit /b 1
>"%W%" echo [@sys]
>>"%W%" echo [--version]
call "%BIN%\python.cmd" --version >"%O%" 2>&1
call :expect %errorlevel% 0 "python --version: the system python, no line"
>"%W%" echo [@sys]
>>"%W%" echo [-V]
call "%BIN%\python3.cmd" -V >"%O%" 2>&1
call :expect %errorlevel% 0 "python3 -V: the system python, no line"
rem stdout only: the line on stderr holds a non-ASCII arrow
>"%W%" echo [@tools]
>>"%W%" echo [run]
>>"%W%" echo [--]
>>"%W%" echo [python]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python.cmd" -c x >"%O%" 2>nul
call :expect %errorlevel% 0 "python: outside a project, uv run as before"
cd /d "%T%\proj" || exit /b 1
set "FAKE_FIND_SYSTEM="
>"%W%" echo python: running %T%\managed\python.exe, not uv run: uv run would build or run code from %T%\proj\pyproject.toml
>>"%W%" echo [@managed]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python.cmd" -c x >"%O%" 2>&1
call :expect %errorlevel% 0 "python: no system python, one uv installed"
set "FAKE_FIND_MANAGED="
>"%W%" echo python: no Python found to run in place of uv run; uv python install installs one
call "%BIN%\python.cmd" -c x >"%O%" 2>&1
call :expect %errorlevel% 1 "python: no python to run, an error and nothing runs"
set "FAKE_FIND_SYSTEM=%T%\sys\python.exe"
set "FAKE_FIND_MANAGED=%T%\managed\python.exe"
>"%W%" echo pip: no venv is active; activate a venv you made (its Scripts\activate), or type uv pip install foo directly
call "%BIN%\pip.cmd" install foo >"%O%" 2>&1
call :expect %errorlevel% 1 "pip: no venv, nothing runs"
set "VIRTUAL_ENV=%T%\venv"
>"%W%" echo [@tools]
>>"%W%" echo [pip]
>>"%W%" echo [list]
call "%BIN%\pip.cmd" list >"%O%" 2>nul
call :expect %errorlevel% 0 "pip: a venv without pip.exe, uv pip"
copy /y "%T%\tools\fake.exe" "%T%\venv\Scripts\pip.exe" >nul || exit /b 1
>"%W%" echo [@Scripts]
>>"%W%" echo [list]
call "%BIN%\pip.cmd" list >"%O%" 2>&1
call :expect %errorlevel% 0 "pip: the venv's own pip.exe"
del "%T%\venv\Scripts\pip.exe"
set "VIRTUAL_ENV="

rem --- no python.exe, pip.exe or uv.exe in the current directory runs
cd /d "%T%\cwd" || exit /b 1
for %%e in (python pip uv) do copy /y "%SystemRoot%\System32\hostname.exe" "%T%\cwd\%%e.exe" >nul
copy /y "%T%\tools\fake.exe" "%T%\tools\python.exe" >nul || exit /b 1
copy /y "%T%\tools\fake.exe" "%T%\tools\pip.exe" >nul || exit /b 1
set "_DEN_UV_OVERRIDE=0"
>"%W%" echo [@tools]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python.cmd" -c x >"%O%" 2>&1
call :expect %errorlevel% 0 "python: python.exe from PATH, not the current directory"
>"%W%" echo [@tools]
>>"%W%" echo [list]
call "%BIN%\pip.cmd" list >"%O%" 2>&1
call :expect %errorlevel% 0 "pip: pip.exe from PATH, not the current directory"
set "_DEN_UV_OVERRIDE="
>"%W%" echo [@tools]
>>"%W%" echo [--version]
call "%BIN%\uv.cmd" --version >"%O%" 2>&1
call :expect %errorlevel% 0 "uv: uv.exe from PATH, not the current directory"
del "%T%\tools\python.exe" "%T%\tools\pip.exe"
set "FAKE_SELF="
set "FAKE_FIND_SYSTEM="
set "FAKE_FIND_MANAGED="
cd /d "%T%\work" || exit /b 1

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
