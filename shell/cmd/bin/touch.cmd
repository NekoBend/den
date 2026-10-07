@echo off
rem touch - create each file, or update its timestamp when it exists
rem Usage: touch <file>...   (exit 1 when any of them failed)
setlocal
if "%~1"=="" (
    >&2 echo usage: touch ^<file^>...
    exit /b 1
)
set "_rc=0"
:next
if "%~1"=="" exit /b %_rc%
if exist "%~1" (
    copy /b "%~1"+,, "%~1" >nul || set "_rc=1"
) else (
    type nul >"%~1" || set "_rc=1"
)
shift
goto next
