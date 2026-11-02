@echo off
rem cmd_shims.cmd - run den's cmd shims (shell\cmd\bin) for real. The Windows
rem CI job calls it; it exits 1 when any check fails. The tools are stand-ins
rem that cmd_fake_tool.ps1 builds: each prints its arguments as [arg] lines
rem and exits with FAKE_RC. Checked: the wrappers run the tool found on PATH,
rem keep its exit code and run their fallback only without it; findw runs fd
rem whatever the toggle, and says so without it; there is no find shim, so
rem typed find is find.exe; cat expands each wildcard itself, refuses a name
rem that starts with - and names a file, a typed --, and an option or an
rem option's value that holds * or ?, and hands bat every name in quotes,
rem the run of backslashes it ends in doubled, then a last --paging=never;
rem no where.* or tool in the current directory runs;
rem touch takes several files; uv passes the arguments after `run` through
rem unchanged; python3 runs a venv's python.exe; python and python3 run a
rem python directly, not uv run, under a pyproject.toml, beside a .venv,
rem below a pyvenv.cfg, a uv.toml or a .python-version(s) that names a path
rem or something in the current directory, for --version / -V too, and
rem elsewhere uv run for those as well; pip runs nothing outside a venv,
rem and in a venv without pip.exe runs uv pip with --config-file and your
rem own uv.toml, or with --no-config without one;
rem path lists PATH; again asks before it re-runs, and only Enter or y
rem runs it.
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
>>"%W%" echo [--paging=never]
call "%BIN%\cat.cmd" a.txt missing.txt >"%O%" 2>&1
call :expect %errorlevel% 1 "cat: bat fails, no type after it"

rem bat expands a wildcard itself, one word at a time (cmd does not), and
rem reads a name that starts with - as an option. So cat expands each word
rem with cmd's for and hands bat every name in quotes, which bat's expansion
rem leaves alone, then a last --paging=never: bat takes the last --paging.
rem With FAKE_RAW set the stand-in prints its command line in braces, which
rem shows the quotes. A word that matches nothing goes on as it is, "" stays
rem an argument, and cat alone or cat - leaves bat to read standard input.
set "FAKE_RC="
set "FAKE_RAW=1"
>"%W%" echo {--style=plain --paging=never "a.txt" --paging=never}
>>"%W%" echo [--style=plain]
>>"%W%" echo [--paging=never]
>>"%W%" echo [a.txt]
>>"%W%" echo [--paging=never]
call "%BIN%\cat.cmd" * >"%O%" 2>&1
call :expect %errorlevel% 0 "cat: cmd expands the wildcard, and bat gets each name in quotes"
>"%W%" echo {--style=plain --paging=never "a.txt" "-" "" "zz*" --paging=never}
>>"%W%" echo [--style=plain]
>>"%W%" echo [--paging=never]
>>"%W%" echo [a.txt]
>>"%W%" echo [-]
>>"%W%" echo []
>>"%W%" echo [zz*]
>>"%W%" echo [--paging=never]
call "%BIN%\cat.cmd" a.txt - "" zz* >"%O%" 2>&1
call :expect %errorlevel% 0 "cat: -, an empty argument and a wildcard that matches nothing reach bat"
>"%W%" echo {--style=plain --paging=never --paging=never}
>>"%W%" echo [--style=plain]
>>"%W%" echo [--paging=never]
>>"%W%" echo [--paging=never]
call "%BIN%\cat.cmd" <nul >"%O%" 2>&1
call :expect %errorlevel% 0 "cat: no argument, bat reads standard input"
>"%W%" echo {--style=plain --paging=never "-n" "a.txt" --paging=never}
>>"%W%" echo [--style=plain]
>>"%W%" echo [--paging=never]
>>"%W%" echo [-n]
>>"%W%" echo [a.txt]
>>"%W%" echo [--paging=never]
call "%BIN%\cat.cmd" -n a.txt >"%O%" 2>&1
call :expect %errorlevel% 0 "cat: an option that names no file reaches bat"

rem cat's for would make file names of an option or an option's value that
rem holds * or ?: -l * would give bat a.txt as the language. So cat refuses
rem such a word, and the value of an option that takes it from the next word
rem (cmd splits an unquoted --file-name=*.py at the =), and bat does not run.
rem An option or a value without them goes on as it is, and a wildcard after
rem an option's value, or after -lrust, which holds its value, is a file.
>"%W%" echo cat: '*.py', the value of --file-name, holds * or ?, which cat would expand as a wildcard: bat did not run.
>>"%W%" echo cat: run bat by name for it.
call "%BIN%\cat.cmd" --file-name=*.py - >"%O%" 2>&1
call :expect %errorlevel% 2 "cat: refuses --file-name=*.py, split at the =, and bat does not run"
>"%W%" echo cat: '--file-name=*.py' is an option that holds * or ?, which cat would expand as a wildcard: bat did not run.
>>"%W%" echo cat: run bat by name for it.
call "%BIN%\cat.cmd" "--file-name=*.py" - >"%O%" 2>&1
call :expect %errorlevel% 2 "cat: refuses a quoted --file-name=*.py, and bat does not run"
>"%W%" echo cat: '*', the value of -l, holds * or ?, which cat would expand as a wildcard: bat did not run.
>>"%W%" echo cat: run bat by name for it.
call "%BIN%\cat.cmd" -l * a.txt >"%O%" 2>&1
call :expect %errorlevel% 2 "cat: refuses -l *, and bat does not run"
>"%W%" echo cat: 'a?txt', the value of -pl, holds * or ?, which cat would expand as a wildcard: bat did not run.
>>"%W%" echo cat: run bat by name for it.
call "%BIN%\cat.cmd" -pl a?txt a.txt >"%O%" 2>&1
call :expect %errorlevel% 2 "cat: refuses -pl a?txt, and bat does not run"
>"%W%" echo {--style=plain --paging=never "--file-name" "x.py" "-l" "rust" "-lrust" "a.txt" --paging=never}
>>"%W%" echo [--style=plain]
>>"%W%" echo [--paging=never]
>>"%W%" echo [--file-name]
>>"%W%" echo [x.py]
>>"%W%" echo [-l]
>>"%W%" echo [rust]
>>"%W%" echo [-lrust]
>>"%W%" echo [a.txt]
>>"%W%" echo [--paging=never]
call "%BIN%\cat.cmd" --file-name=x.py -l rust -lrust * >"%O%" 2>&1
call :expect %errorlevel% 0 "cat: options and values without * or ? reach bat, and * after them is a file"

rem Beside files named --, --pager=cmd and --paging=always, bat once
rem expanded ???* to the pager options and then * to a -- that turned the
rem last --paging=never into a file name. cat refuses a match that starts
rem with - and names a file, for either word and for * alone, and bat does
rem not run.
mkdir "%T%\opt" || exit /b 1
cd /d "%T%\opt" || exit /b 1
type nul >"--"
type nul >"--pager=cmd"
type nul >"--paging=always"
>"notes.txt" echo type nul
call "%BIN%\cat.cmd" ???* * >"%O%" 2>&1
call :refused %errorlevel% "cat: ???* * beside --, --pager=cmd and --paging=always, bat does not run"
call "%BIN%\cat.cmd" * >"%O%" 2>&1
call :refused %errorlevel% "cat: * beside them, bat does not run"

rem The message names the file and the ways that work: .\ before the name
rem or the wildcard, which bat reads as a file, or type.
mkdir "%T%\opt2" || exit /b 1
cd /d "%T%\opt2" || exit /b 1
type nul >"-x.txt"
>"a.txt" echo zzz
>"%W%" echo cat: '-x.txt' names a file, and bat would read it as an option: bat did not run.
>>"%W%" echo cat: write it as .\-x.txt (a wildcard as .\*), or run type instead.
call "%BIN%\cat.cmd" * >"%O%" 2>&1
call :expect %errorlevel% 2 "cat: refuses a match named -x.txt and says why"
call "%BIN%\cat.cmd" -x.txt >"%O%" 2>&1
call :expect %errorlevel% 2 "cat: refuses a typed -x.txt that names a file"
>"%W%" echo {--style=plain --paging=never ".\-x.txt" ".\a.txt" --paging=never}
>>"%W%" echo [--style=plain]
>>"%W%" echo [--paging=never]
>>"%W%" echo [.\-x.txt]
>>"%W%" echo [.\a.txt]
>>"%W%" echo [--paging=never]
call "%BIN%\cat.cmd" .\* >"%O%" 2>&1
call :expect %errorlevel% 0 "cat: .\* hands bat .\-x.txt as a file"

rem A name with characters cmd would parse reaches bat whole.
mkdir "%T%\spec" || exit /b 1
cd /d "%T%\spec" || exit /b 1
type nul >"a&b!c%%d^e (1).txt"
>"%W%" echo {--style=plain --paging=never "a&b!c%%d^e (1).txt" --paging=never}
>>"%W%" echo [--style=plain]
>>"%W%" echo [--paging=never]
>>"%W%" echo [a^&b!c%%d^^e (1).txt]
>>"%W%" echo [--paging=never]
call "%BIN%\cat.cmd" * >"%O%" 2>&1
call :expect %errorlevel% 0 "cat: a name with special characters and a blank reaches bat whole"
cd /d "%T%\work" || exit /b 1

rem bat reads a run of backslashes before a quote as half as many, and an
rem odd one as escaping the quote: "label\" would swallow its closing quote
rem and run on into the words after it, den's last --paging=never included.
rem So cat doubles the run of backslashes a word ends in.
>"%W%" echo {--style=plain --paging=never "--file-name" "label\\" "a.txt" --paging=never}
>>"%W%" echo [--style=plain]
>>"%W%" echo [--paging=never]
>>"%W%" echo [--file-name]
>>"%W%" echo [label\]
>>"%W%" echo [a.txt]
>>"%W%" echo [--paging=never]
call "%BIN%\cat.cmd" --file-name label\ a.txt >"%O%" 2>&1
call :expect %errorlevel% 0 "cat: a value that ends in \ reaches bat whole, and so do the words after it"
>"%W%" echo {--style=plain --paging=never ".\sub\\" "sub\\\\" "a.txt" --paging=never}
>>"%W%" echo [--style=plain]
>>"%W%" echo [--paging=never]
>>"%W%" echo [.\sub\]
>>"%W%" echo [sub\\]
>>"%W%" echo [a.txt]
>>"%W%" echo [--paging=never]
call "%BIN%\cat.cmd" .\sub\ sub\\ a.txt >"%O%" 2>&1
call :expect %errorlevel% 0 "cat: a typed path that ends in \ or \\ reaches bat whole, and so do the words after it"
set "FAKE_RAW="

rem A typed -- would make bat read the last --paging=never as a file name,
rem so cat refuses one and bat does not run.
>"%W%" echo cat: -- would make bat read den's last --paging=never as a file name.
>>"%W%" echo cat: write a file whose name starts with - as .\-name instead.
call "%BIN%\cat.cmd" a.txt -- -x.txt >"%O%" 2>&1
call :expect %errorlevel% 2 "cat: refuses a typed --, and bat does not run"
call "%BIN%\cat.cmd" a.txt "--" >"%O%" 2>&1
call :expect %errorlevel% 2 "cat: refuses a quoted --, and bat does not run"
set "FAKE_RC=1"

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
rem uv reads a .python-versions the same way.
mkdir "%T%\pyvers\sub" || exit /b 1
>"%T%\pyvers\.python-versions" echo ./tools/py
cd /d "%T%\pyvers\sub" || exit /b 1
>"%W%" echo python: running %T%\sys\python.exe, not uv run: uv run would build or run code from %T%\pyvers\.python-versions
>>"%W%" echo [@sys]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python.cmd" -c x >"%O%" 2>&1
call :expect %errorlevel% 0 "python: below a .python-versions that names a path, the system python and a line, not uv run"
rem uv trims white space alone and keeps a byte order mark: a line that
rem starts with U+200B, or the mark, and then # names a path to it.
rem PowerShell writes the bytes, so this file holds no character beyond
rem ASCII.
mkdir "%T%\pyverzw" "%T%\pyverbom" || exit /b 1
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "$u = New-Object Text.UTF8Encoding $false; [IO.File]::WriteAllBytes($env:T + '\pyverzw\.python-version', $u.GetBytes([string][char]0x200B + '#x/tools/py' + [char]10)); [IO.File]::WriteAllBytes($env:T + '\pyverbom\.python-version', [byte[]](@(0xEF, 0xBB, 0xBF) + $u.GetBytes('#x/tools/py' + [char]10)))" || exit /b 1
cd /d "%T%\pyverzw" || exit /b 1
>"%W%" echo python: running %T%\sys\python.exe, not uv run: uv run would build or run code from %T%\pyverzw\.python-version
>>"%W%" echo [@sys]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python.cmd" -c x >"%O%" 2>&1
call :expect %errorlevel% 0 "python: beside a .python-version with U+200B before #, the system python and a line, not uv run"
cd /d "%T%\pyverbom" || exit /b 1
>"%W%" echo python: running %T%\sys\python.exe, not uv run: uv run would build or run code from %T%\pyverbom\.python-version
>>"%W%" echo [@sys]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python.cmd" -c x >"%O%" 2>&1
call :expect %errorlevel% 0 "python: beside a .python-version with a byte order mark before #, the system python and a line, not uv run"
rem A line that names something in the current directory counts as well,
rem without the spaces and tabs around it (pyvpad), and a version request
rem too (pyv313): uv looks a bare name up there, not beside the file, and
rem takes a directory for a venv. Below the file it counts where the
rem current directory holds the name (pyvdir\sub2), and not elsewhere
rem (pyvdir\sub).
mkdir "%T%\pyvdir\tools" "%T%\pyvdir\sub" "%T%\pyvdir\sub2\tools" "%T%\pyvpad\tools" "%T%\pyv313\3.13" || exit /b 1
>"%T%\pyvdir\.python-version" echo tools
>"%T%\pyv313\.python-version" echo 3.13
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "[IO.File]::WriteAllText($env:T + '\pyvpad\.python-version', [string][char]9 + '  tools ' + [char]9 + [char]13 + [char]10)" || exit /b 1
cd /d "%T%\pyvdir" || exit /b 1
>"%W%" echo python: running %T%\sys\python.exe, not uv run: uv run would build or run code from %T%\pyvdir\.python-version
>>"%W%" echo [@sys]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python.cmd" -c x >"%O%" 2>&1
call :expect %errorlevel% 0 "python: beside a .python-version that names a directory here, the system python and a line, not uv run"
cd /d "%T%\pyvdir\sub2" || exit /b 1
>"%W%" echo python3: running %T%\sys\python.exe, not uv run: uv run would build or run code from %T%\pyvdir\.python-version
>>"%W%" echo [@sys]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python3.cmd" -c x >"%O%" 2>&1
call :expect %errorlevel% 0 "python3: below it, in a directory that holds the name too, the system python and a line, not uv run"
cd /d "%T%\pyvdir\sub" || exit /b 1
>"%W%" echo [@tools]
>>"%W%" echo [run]
>>"%W%" echo [--]
>>"%W%" echo [python]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python3.cmd" -c x >"%O%" 2>nul
call :expect %errorlevel% 0 "python3: below it, in a directory that does not hold the name, uv run"
cd /d "%T%\pyvpad" || exit /b 1
>"%W%" echo python: running %T%\sys\python.exe, not uv run: uv run would build or run code from %T%\pyvpad\.python-version
>>"%W%" echo [@sys]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python.cmd" -c x >"%O%" 2>&1
call :expect %errorlevel% 0 "python: beside a .python-version that names a directory here between spaces and tabs, the system python and a line, not uv run"
cd /d "%T%\pyv313" || exit /b 1
>"%W%" echo python: running %T%\sys\python.exe, not uv run: uv run would build or run code from %T%\pyv313\.python-version
>>"%W%" echo [@sys]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python.cmd" -c x >"%O%" 2>&1
call :expect %errorlevel% 0 "python: beside a .python-version whose version request names a directory here, the system python and a line, not uv run"
cd /d "%T%\pyveronly" || exit /b 1
>"%W%" echo [@tools]
>>"%W%" echo [run]
>>"%W%" echo [--]
>>"%W%" echo [python]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python.cmd" -c x >"%O%" 2>nul
call :expect %errorlevel% 0 "python: beside a .python-version of version requests alone, uv run as before"
cd /d "%T%\proj\sub" || exit /b 1
>"%W%" echo python: running %T%\sys\python.exe, not uv run: uv run would build or run code from %T%\proj\pyproject.toml
>>"%W%" echo [@sys]
>>"%W%" echo [--version]
call "%BIN%\python.cmd" --version >"%O%" 2>&1
call :expect %errorlevel% 0 "python --version: in a project, the system python and a line"
rem In a venv, its python.exe and no line, in a project too (bash, zsh and
rem pwsh do the same).
set "VIRTUAL_ENV=%T%\venv"
>"%W%" echo [@Scripts]
>>"%W%" echo [-c]
>>"%W%" echo [x]
call "%BIN%\python.cmd" -c x >"%O%" 2>&1
call :expect %errorlevel% 0 "python: in a venv in a project, the venv's python.exe and no line"
set "VIRTUAL_ENV="
cd /d "%T%\work" || exit /b 1
rem stdout only: the line on stderr holds a non-ASCII arrow
>"%W%" echo [@tools]
>>"%W%" echo [run]
>>"%W%" echo [--]
>>"%W%" echo [python]
>>"%W%" echo [--version]
call "%BIN%\python.cmd" --version >"%O%" 2>nul
call :expect %errorlevel% 0 "python --version: outside a project, uv run as any other call"
>"%W%" echo [@tools]
>>"%W%" echo [run]
>>"%W%" echo [--]
>>"%W%" echo [python]
>>"%W%" echo [-V]
call "%BIN%\python3.cmd" -V >"%O%" 2>nul
call :expect %errorlevel% 0 "python3 -V: outside a project, uv run as any other call"
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
rem uv reads no uv.toml or pyproject.toml of a clone here, which can have it
rem run a python the clone ships or install from the clone's files: pip has
rem it read your own uv.toml alone (--config-file), or none (--no-config).
rem Yours is the one UV_CONFIG_FILE names, even under UV_NO_CONFIG, else,
rem unless UV_NO_CONFIG is true, %APPDATA%\uv\uv.toml, else, unless
rem UV_NO_SYSTEM_CONFIG is true, %SYSTEMDRIVE%\ProgramData\uv\uv.toml.
set "_APPDATA=%APPDATA%"
set "_SYSTEMDRIVE=%SYSTEMDRIVE%"
set "APPDATA=%T%\appdata"
set "SYSTEMDRIVE=%T%\sysdrive"
set "UV_CONFIG_FILE="
set "UV_NO_CONFIG="
set "UV_NO_SYSTEM_CONFIG="
mkdir "%T%\appdata\uv" "%T%\sysdrive\ProgramData\uv" || exit /b 1
>"%W%" echo [@tools]
>>"%W%" echo [--no-config]
>>"%W%" echo [pip]
>>"%W%" echo [list]
call "%BIN%\pip.cmd" list >"%O%" 2>nul
call :expect %errorlevel% 0 "pip: a venv without pip.exe and no uv.toml of yours, uv --no-config pip"
type nul >"%T%\sysdrive\ProgramData\uv\uv.toml"
>"%W%" echo [@tools]
>>"%W%" echo [--config-file]
>>"%W%" echo [%T%\sysdrive\ProgramData\uv\uv.toml]
>>"%W%" echo [pip]
>>"%W%" echo [list]
call "%BIN%\pip.cmd" list >"%O%" 2>nul
call :expect %errorlevel% 0 "pip: a venv without pip.exe, uv --config-file pip with the system uv.toml"
set "UV_NO_SYSTEM_CONFIG=On"
>"%W%" echo [@tools]
>>"%W%" echo [--no-config]
>>"%W%" echo [pip]
>>"%W%" echo [list]
call "%BIN%\pip.cmd" list >"%O%" 2>nul
call :expect %errorlevel% 0 "pip: UV_NO_SYSTEM_CONFIG true, uv --no-config pip"
type nul >"%T%\appdata\uv\uv.toml"
>"%W%" echo [@tools]
>>"%W%" echo [--config-file]
>>"%W%" echo [%T%\appdata\uv\uv.toml]
>>"%W%" echo [pip]
>>"%W%" echo [list]
call "%BIN%\pip.cmd" list >"%O%" 2>nul
call :expect %errorlevel% 0 "pip: a venv without pip.exe, uv --config-file pip with your uv.toml"
set "UV_NO_CONFIG=TRUE"
>"%W%" echo [@tools]
>>"%W%" echo [--no-config]
>>"%W%" echo [pip]
>>"%W%" echo [list]
call "%BIN%\pip.cmd" list >"%O%" 2>nul
call :expect %errorlevel% 0 "pip: UV_NO_CONFIG true, uv --no-config pip"
set "UV_CONFIG_FILE=%T%\mine.toml"
>"%W%" echo [@tools]
>>"%W%" echo [--config-file]
>>"%W%" echo [%T%\mine.toml]
>>"%W%" echo [pip]
>>"%W%" echo [list]
call "%BIN%\pip.cmd" list >"%O%" 2>nul
call :expect %errorlevel% 0 "pip: UV_CONFIG_FILE, under UV_NO_CONFIG too, uv --config-file pip with that file"
set "UV_CONFIG_FILE="
set "UV_NO_CONFIG="
set "UV_NO_SYSTEM_CONFIG="
set "APPDATA=%_APPDATA%"
set "SYSTEMDRIVE=%_SYSTEMDRIVE%"
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
rem Any answer other than Enter or y cancels; only n used to.
>"%T%\other.txt" echo x
>"%T%\enter.txt" echo(
set "_DEN_AGAIN=echo hi"
call "%BIN%\again.cmd" <"%T%\other.txt" >"%O%" 2>&1
set "RC=%errorlevel%"
set "OK="
if "%RC%"=="0" if not defined _DEN_AGAIN_RUN if not defined _DEN_AGAIN set "OK=1"
call :check "again: any other answer cancels"
set "_DEN_AGAIN=echo hi"
call "%BIN%\again.cmd" <"%T%\enter.txt" >"%O%" 2>&1
set "RC=%errorlevel%"
set "OK="
if "%RC%"=="0" if "%_DEN_AGAIN_RUN%"=="1" if "%_DEN_AGAIN%"=="echo hi" set "OK=1"
call :check "again: Enter runs it"
set "_DEN_AGAIN_RUN="
set "_DEN_AGAIN="
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

rem :refused RC LABEL - cat ran nothing: RC is 2, the output says why, and
rem the stand-in printed nothing (its lines start with { or [).
:refused
set "OK="
"%FINDSTR%" /b /l /c:"cat: '-" "%O%" >nul && if "%~1"=="2" set "OK=1"
"%FINDSTR%" /b /l /c:"{" /c:"[" "%O%" >nul && set "OK="
call :check "%~2"
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
