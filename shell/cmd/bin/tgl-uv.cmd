@echo off
rem tgl-uv - short name for toggle-uv
rem Usage: tgl-uv [on|off]
rem CALL runs toggle-uv.cmd in this same cmd session, and neither file uses
rem setlocal, so its set commands still reach the caller. The path is this
rem shim's own folder, so a toggle-uv.cmd in the current directory never runs.
call "%~dp0toggle-uv.cmd" %*
