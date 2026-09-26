@echo off
rem tgl-hw - short name for toggle-hwinfo
rem Usage: tgl-hw
rem CALL runs toggle-hwinfo.cmd in this same cmd session, and neither file uses
rem setlocal, so its set commands still reach the caller. The path is this
rem shim's own folder, so a toggle-hwinfo.cmd in the current directory never runs.
call "%~dp0toggle-hwinfo.cmd" %*
