@echo off
if "%_DEN_WRAPPERS%"=="0" goto :fallback
where lsd >nul 2>&1 && (lsd %*) || (dir /w %*)
exit /b
:fallback
dir /w %*
