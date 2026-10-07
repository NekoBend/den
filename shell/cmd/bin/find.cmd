@echo off
rem find - fd when fd is on PATH, else find.exe
rem (find.exe also while the wrappers are off: _DEN_WRAPPERS=0, tgl-wr).
rem Unlike the other wrappers, find.exe still runs after fd exits non-zero,
rem as it always has: that is how a DOS-style `find "text" file.txt` or
rem `find /c /v "" file.txt` typed at the prompt reaches find.exe. fd comes
rem from PATH only, through System32's where.exe, so no where.* or fd.* in
rem the current directory runs instead.
setlocal
set "_t="
if not "%_DEN_WRAPPERS%"=="0" for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $PATH:fd.exe 2^>nul') do if not defined _t set "_t=%%p"
if defined _t "%_t%" %* || %SystemRoot%\System32\find.exe %*
if not defined _t %SystemRoot%\System32\find.exe %*
exit /b %errorlevel%
