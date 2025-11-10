@echo off
setlocal enabledelayedexpansion

:: hdrheif2uhdr.cmd - Call PowerShell script hdrheif2uhdr.ps1 from cmd.exe
:: Usage:
::   hdrheif2uhdr.cmd <InputHeic> <OutputJpeg>
:: Example:
::   hdrheif2uhdr.cmd IMG_5763.HEIC output_hdr.jpg

if "%~1"=="" goto :help
if /I "%~1"=="/?" goto :help
if /I "%~1"=="-h" goto :help
if /I "%~1"=="--help" goto :help

set "INPUT=%~1"
set "OUTPUT=%~2"

if "%OUTPUT%"=="" (
  echo [ERROR] Missing output JPEG parameter.
  goto :help
)

:: Compatible with PowerShell 7+ (pwsh) and Windows PowerShell (powershell)
set "PSH=pwsh"
where pwsh >nul 2>&1 || set "PSH=powershell"

:: Resolve current script directory to absolute path, locate ps1 in same dir
set "THIS_DIR=%~dp0"
set "PS1=%THIS_DIR%hdrheif2uhdr.ps1"

if not exist "%PS1%" (
  echo [ERROR] PowerShell script not found: %PS1%
  exit /b 2
)

:: Call PowerShell script, bypass execution policy, pass parameters
"%PSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -InputHeic "%INPUT%" -OutputJpeg "%OUTPUT%"
set "ERR=%ERRORLEVEL%"
if not "%ERR%"=="0" (
  echo [ERROR] Conversion failed with exit code %ERR%.
  exit /b %ERR%
)

echo Completed: %OUTPUT%
exit /b 0

:help
echo.
echo Usage:
echo   %~nx0 ^<InputHeic^> ^<OutputJpeg^>
echo Parameters:
echo   InputHeic    Apple HDR HEIC input file (.heic)
echo   OutputJpeg   UltraHDR JPEG output file (.jpg)
echo.
echo Example:
echo   %~nx0 IMG_5763.HEIC output_hdr.jpg
exit /b 1