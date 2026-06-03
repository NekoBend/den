@echo off
rem back — return to the previous directory
rem Usage: back
rem Requires _OLDPWD to be tracked (set by cd override in starship.lua)

if not defined _OLDPWD (
    echo back: no previous directory >&2
    exit /b 1
)
cd /d "%_OLDPWD%"
