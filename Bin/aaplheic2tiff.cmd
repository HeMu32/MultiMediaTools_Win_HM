@echo off
setlocal enabledelayedexpansion

:: aaplheic2tiff.cmd - Call PowerShell script aaplheic2tiff.ps1 from cmd.exe
:: Usage:
::   aaplheic2tiff.cmd <InputPath> <OutputPath> [pq|hlg] [8|16]
::
:: This wrapper invokes a two-stage pipeline:
::   1) convert HEIC ➜ UltraHDR JPEG with aaplheic2uhdr.ps1
::   2) decode that JPEG ➜ BT.2020 TIFF via uhdr2tiff.ps1
:: The PS1 code handles output directory creation and metadata copying.
::
:: Example:
::   aaplheic2tiff.cmd IMG_5763.HEIC out_hlg_16b.tiff hlg 16

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
set "PS1=%THIS_DIR%aaplheic2tiff.ps1"

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
echo   InputPath   Apple HDR HEIC input file (.heic)
echo   OutputPath  Output TIFF file path
echo   hlg^|pq     Target transfer function (default hlg)
echo   8^|16       TIFF bit depth (default 16)
echo.
echo Example:
echo   %~nx0 IMG_5763.HEIC out_hlg_16b.tiff hlg 16
exit /b 1