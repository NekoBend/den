@echo off
rem again — re-run the last command with confirmation
rem Usage: again
rem Note: cmd limitations restrict this to N=1 (last command only)

setlocal enabledelayedexpansion
set "_prev="
set "_last="
for /f "tokens=*" %%a in ('doskey /history') do (
    set "_prev=!_last!"
    set "_last=%%a"
)

rem If last entry is "again", use the one before it
if "!_last!"=="again" set "_last=!_prev!"
if "!_last!"=="again" set "_last="

if not defined _last (
    echo again: no command in history >&2
    exit /b 1
)

echo + !_last!
set /p "_ans=Re-run? [Y/n] "
if /i "!_ans!"=="n" exit /b 0
endlocal & %_last%
