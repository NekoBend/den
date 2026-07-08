@echo off
rem toggle-uv — flip the uv python/pip override on/off
rem Usage: toggle-uv [on|off]
rem The python/pip/python3 shims read _DEN_UV_OVERRIDE (0 = off). No setlocal, so
rem the set below mutates the caller's cmd environment (like toggle-wrapper.cmd).

if /i "%~1"=="on"  goto :enable
if /i "%~1"=="off" goto :disable

rem No argument: toggle current state (default/unset is ON)
if "%_DEN_UV_OVERRIDE%"=="0" (goto :enable) else (goto :disable)

:enable
set "_DEN_UV_OVERRIDE=1"
echo uv override: ON (python/pip -^> uv)
exit /b

:disable
set "_DEN_UV_OVERRIDE=0"
echo uv override: OFF (using system python/pip)
exit /b
