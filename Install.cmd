
@echo off
setlocal
title Software Installer

echo Downloading installation script...

set "SCRIPT_URL=https://raw.githubusercontent.com/floringalea/cl-dependency-installer/main/Install.ps1"
set "SCRIPT_FILE=%TEMP%\CompanyInstall-%RANDOM%.ps1"

powershell.exe -NoProfile -Command "Invoke-WebRequest -Uri '%SCRIPT_URL%' -OutFile '%SCRIPT_FILE%' -ErrorAction Stop"

if errorlevel 1 (
    echo Download failed.
    pause
    exit /b 1
)

echo Starting installation...

powershell.exe -NoProfile -File "%SCRIPT_FILE%"
set "RESULT=%ERRORLEVEL%"

del "%SCRIPT_FILE%" 2>nul

if not "%RESULT%"=="0" (
    echo Installation failed with exit code %RESULT%.
) else (
    echo Installation completed successfully.
)

pause
exit /b %RESULT%
