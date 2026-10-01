@echo off
rem find - fd when fd is on PATH, else find.exe
rem (find.exe also while the wrappers are off: _DEN_WRAPPERS=0, tgl-wr).
rem It branches on whether fd exists, never on its exit code, so fd keeps
rem its own exit code and find.exe never runs after it. fd comes from PATH
rem only, through System32's where.exe, so no where.* or fd.* in the
rem current directory runs instead.
setlocal
set "_t="
if not "%_DEN_WRAPPERS%"=="0" for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $PATH:fd.exe 2^>nul') do if not defined _t set "_t=%%p"
if defined _t "%_t%" %*
if not defined _t %SystemRoot%\System32\find.exe %*
exit /b %errorlevel%
