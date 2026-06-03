@echo off
rem mkcd — mkdir + cd in one step
rem Usage: mkcd <dir>

if "%~1"=="" (
    echo usage: mkcd ^<dir^> >&2
    exit /b 1
)
mkdir "%~1" 2>nul
cd /d "%~1"
