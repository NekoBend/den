@echo off
rem tgl-wr - short name for toggle-wrapper
rem Usage: tgl-wr [on|off]
rem CALL runs toggle-wrapper.cmd in this same cmd session, and neither file uses
rem setlocal, so its set commands still reach the caller. The path is this
rem shim's own folder, so a toggle-wrapper.cmd in the current directory never runs.
call "%~dp0toggle-wrapper.cmd" %*
