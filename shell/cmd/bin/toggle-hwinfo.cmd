@echo off
rem toggle-hwinfo — flip hardware info display in starship prompt on/off

if "%_DEN_HWINFO_HIDDEN%"=="1" goto :restore

rem --- Hide: save current values, clear STARSHIP_* vars ---
set "_DEN_SAVED_CPU_INTEL=%STARSHIP_CPU_INTEL%"
set "_DEN_SAVED_CPU_AMD=%STARSHIP_CPU_AMD%"
set "_DEN_SAVED_GPU_NVIDIA=%STARSHIP_GPU_NVIDIA%"
set "_DEN_SAVED_GPU_AMD=%STARSHIP_GPU_AMD%"
set "_DEN_SAVED_GPU_INTEL=%STARSHIP_GPU_INTEL%"
set "STARSHIP_CPU_INTEL="
set "STARSHIP_CPU_AMD="
set "STARSHIP_GPU_NVIDIA="
set "STARSHIP_GPU_AMD="
set "STARSHIP_GPU_INTEL="
set "_DEN_HWINFO_HIDDEN=1"
echo hwinfo: OFF (hidden from prompt)
goto :eof

:restore
rem --- Show: restore saved values, clear saved vars ---
set "STARSHIP_CPU_INTEL=%_DEN_SAVED_CPU_INTEL%"
set "STARSHIP_CPU_AMD=%_DEN_SAVED_CPU_AMD%"
set "STARSHIP_GPU_NVIDIA=%_DEN_SAVED_GPU_NVIDIA%"
set "STARSHIP_GPU_AMD=%_DEN_SAVED_GPU_AMD%"
set "STARSHIP_GPU_INTEL=%_DEN_SAVED_GPU_INTEL%"
set "_DEN_SAVED_CPU_INTEL="
set "_DEN_SAVED_CPU_AMD="
set "_DEN_SAVED_GPU_NVIDIA="
set "_DEN_SAVED_GPU_AMD="
set "_DEN_SAVED_GPU_INTEL="
set "_DEN_HWINFO_HIDDEN=0"
echo hwinfo: ON (visible in prompt)
