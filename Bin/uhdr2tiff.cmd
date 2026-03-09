@echo off
setlocal enabledelayedexpansion

:: uhdr2tiff.cmd - Wrapper for uhdr2tiff.ps1
:: Decodes an UltraHDR JPEG to a BT.2020 TIFF using ultrahdr_app + ffmpeg.
:: Underlying PS1 handles output directory creation, color-space detection,
:: and metadata transfer (EXIF/XMP only).

:: uhdr2tiff.cmd - Call PowerShell script uhdr2tiff.ps1 from cmd.exe
:: Usage:
::   uhdr2tiff.cmd <InputPath> <OutputPath> [pq|hlg] [8|16]
:: Example:
::   uhdr2tiff.cmd 7078a2ba2a64976.jpg out_hlg_16b.tiff hlg 16

if "%~1"=="" goto :help
if /I "%~1"=="/?" goto :help
if /I "%~1"=="-h" goto :help
if /I "%~1"=="--help" goto :help

set "INPUT=%~1"
set "OUTPUT=%~2"
set "TRANSFER=%~3"
set "BITDEPTH=%~4"

if "%OUTPUT%"=="" (
  echo [ERROR] Missing output file parameter.
  goto :help
)

:: Compatible with PowerShell 7+ (pwsh) and Windows PowerShell (powershell)
set "PSH=pwsh"
where pwsh >nul 2>&1 || set "PSH=powershell"

:: Resolve current script directory to absolute path, locate ps1 in same dir
set "THIS_DIR=%~dp0"
set "PS1=%THIS_DIR%uhdr2tiff.ps1"

if not exist "%PS1%" (
  echo [ERROR] PowerShell script not found: %PS1%
  exit /b 2
)

:: Default values: Transfer defaults to hlg, BitDepth to 16
if "%TRANSFER%"=="" set "TRANSFER=hlg"
if "%BITDEPTH%"=="" set "BITDEPTH=16"

:: Call PowerShell script, bypass execution policy, pass parameters
"%PSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -InputPath "%INPUT%" -OutputPath "%OUTPUT%" -Transfer "%TRANSFER%" -BitDepth %BITDEPTH%
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
echo   %~nx0 ^<InputPath^> ^<OutputPath^> [pq^|hlg] [8^|16]
echo Parameters:
echo   InputPath   UltraHDR compatible input file (.jpg)
echo   OutputPath  Output TIFF file path
echo   hlg^|pq     Target transfer function (default hlg)
echo   8^|16       TIFF bit depth (default 16)
echo.
echo Example:
echo   %~nx0 7078a2ba2a64976.jpg out_hlg_16b.tiff hlg 16
exit /b 1
