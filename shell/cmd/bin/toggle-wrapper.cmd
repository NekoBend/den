@echo off
rem toggle-wrapper — toggle modern CLI wrappers on/off
rem Usage: toggle-wrapper [on|off]

if /i "%~1"=="on"  goto :enable
if /i "%~1"=="off" goto :disable

rem No argument: toggle current state
if "%_DEN_WRAPPERS%"=="0" (goto :enable) else (goto :disable)

:enable
set "_DEN_WRAPPERS=1"
set "STARSHIP_WRAPPER_STATE="
echo wrappers: ON
exit /b

:disable
set "_DEN_WRAPPERS=0"
set "STARSHIP_WRAPPER_STATE=OFF"
echo wrappers: OFF
exit /b
