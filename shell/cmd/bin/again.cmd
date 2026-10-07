@echo off
rem again - re-run a command from Clink's history after a confirm
rem Usage: again [N]   (the Nth previous command, default 1)
rem cmd's own history (doskey /history) stays empty under Clink, so
rem starship.lua does the lookup: it catches a line that is just `again [N]`
rem and runs this shim with the command in _DEN_AGAIN, or a message in
rem _DEN_AGAIN_ERR. A yes here sets _DEN_AGAIN_RUN=1, and starship.lua hands
rem the command to cmd as the next input line, so it runs as if typed. No
rem setlocal around those sets: they must reach this cmd session.
if not defined _DEN_AGAIN if not defined _DEN_AGAIN_ERR (
    >&2 echo again: type it on a line of its own ^(needs Clink 1.3.18 or newer^)
    exit /b 1
)
if defined _DEN_AGAIN_ERR (
    setlocal EnableDelayedExpansion
    >&2 echo(!_DEN_AGAIN_ERR!
    endlocal
    set "_DEN_AGAIN_ERR="
    set "_DEN_AGAIN="
    exit /b 1
)
setlocal EnableDelayedExpansion
echo(+ !_DEN_AGAIN!
set "_ans="
set /p "_ans=Re-run? [Y/n] "
set "_run=1"
if /i "!_ans!"=="n" set "_run="
endlocal & set "_DEN_AGAIN_RUN=%_run%"
if not defined _DEN_AGAIN_RUN set "_DEN_AGAIN="
exit /b 0
