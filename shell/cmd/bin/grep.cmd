@echo off
rem grep - rg when rg is on PATH, else findstr
rem (findstr also while the wrappers are off: _DEN_WRAPPERS=0, tgl-wr).
rem It branches on whether rg exists, never on its exit code, so rg keeps
rem its own exit code and findstr never runs after it. rg comes from PATH
rem only, through System32's where.exe, so no where.* or rg.* in the
rem current directory runs instead.
setlocal
set "_t="
if not "%_DEN_WRAPPERS%"=="0" for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $PATH:rg.exe 2^>nul') do if not defined _t set "_t=%%p"
if defined _t "%_t%" %*
if not defined _t %SystemRoot%\System32\findstr.exe %*
exit /b %errorlevel%
