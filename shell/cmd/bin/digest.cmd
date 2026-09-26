@echo off
rem digest - dg under its older name; every form works the same (see dg.cmd).
rem Started without call, which would double any caret in the arguments;
rem dg.cmd then ends this script with its own exit code.
"%~dp0dg.cmd" %*
