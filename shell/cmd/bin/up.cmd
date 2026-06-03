@echo off
rem up — go up N directories (default: 1)
rem Usage: up [N]

setlocal enabledelayedexpansion
set /a "_n=%~1" 2>nul
if !_n! leq 0 set /a "_n=1"

set "_path=.."
set /a "_i=1"
:loop
if !_i! geq !_n! goto :done
set "_path=!_path!\.."
set /a "_i+=1"
goto :loop

:done
endlocal & cd /d "%_path%"
