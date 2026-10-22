@echo off
rem findw - fd, also while the wrappers are off (_DEN_WRAPPERS=0, tgl-wr), as
rem on bash/zsh and pwsh; without fd it says so and exits 1. There is no find
rem shim: typed find stays Windows' find.exe, which reads piped text
rem (netstat -ano | find "8080") where fd reads none. fd comes from PATH only,
rem through System32's where.exe, so no where.* or fd.* in the current
rem directory runs instead.
setlocal
set "_t="
for /f "delims=" %%p in ('%SystemRoot%\System32\where.exe $PATH:fd.exe 2^>nul') do if not defined _t set "_t=%%p"
if not defined _t (
    >&2 echo findw: fd is not installed.
    exit /b 1
)
"%_t%" %*
exit /b %errorlevel%
