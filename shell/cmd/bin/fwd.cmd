@echo off
rem fwd - go forward N entries in the directory history (default 1), undoing back
rem Usage: fwd [N]
rem Shares back.cmd's code, which reads the forward list when given --fwd.
call "%~dp0back.cmd" --fwd %*
