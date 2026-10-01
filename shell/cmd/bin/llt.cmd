@echo off
rem llt - lsd -l --tree when lsd is on PATH, else tree /f
rem (tree /f also while the wrappers are off: _DEN_WRAPPERS=0, tgl-wr).
rem It branches on whether lsd exists, never on its exit code, so lsd keeps
rem its own exit code and tree /f never runs after it. lsd comes from PATH
rem only, through System32's where.exe, so no where.* or lsd.* in the
rem current directory runs instead.
setlocal
set "_t="
if not "%_DEN_WRAPPERS%"=="0" for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $PATH:lsd.exe 2^>nul') do if not defined _t set "_t=%%p"
if defined _t "%_t%" -l --tree %*
if not defined _t %SystemRoot%\System32\tree.com /f %*
exit /b %errorlevel%
