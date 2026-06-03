@echo off
rem install.cmd - Deploy cmd/Clink configs to %LOCALAPPDATA%\clink\.
rem Usage: install.cmd
setlocal

for %%I in ("%~dp0..") do set "REPO=%%~fI\"
set "CLINK_DIR=%LOCALAPPDATA%\clink"
set "BIN_DIR=%LOCALAPPDATA%\clink\bin"
set "CONFIG_DIR=%USERPROFILE%\.config"

echo Installing dotfiles → %CLINK_DIR%

rem --- Create target directories ---
if not exist "%CLINK_DIR%\" mkdir "%CLINK_DIR%"
if not exist "%BIN_DIR%\"   mkdir "%BIN_DIR%"
if not exist "%CONFIG_DIR%\" mkdir "%CONFIG_DIR%"

rem --- starship.lua ---
if exist "%REPO%shell\cmd\starship.lua" (
    copy /Y "%REPO%shell\cmd\starship.lua" "%CLINK_DIR%\starship.lua" >nul
    echo   [OK] starship.lua
) else (
    echo   [SKIP] starship.lua ^(not found^)
)

rem --- bin\*.cmd ---
for %%F in ("%REPO%shell\cmd\bin\*.cmd") do (
    copy /Y "%%F" "%BIN_DIR%\%%~nxF" >nul
    echo   [OK] bin\%%~nxF
)

rem --- starship.toml ---
if exist "%REPO%shell\starship\starship.toml" (
    copy /Y "%REPO%shell\starship\starship.toml" "%CONFIG_DIR%\starship.toml" >nul
    echo   [OK] starship.toml
) else (
    echo   [SKIP] starship.toml ^(not found^)
)

echo.
echo Done. Restart cmd to apply changes.
endlocal
