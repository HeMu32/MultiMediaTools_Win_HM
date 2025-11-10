@echo off
setlocal

if /i "%~1" == "/h" goto :help
if /i "%~1" == "/help" goto :help
if "%~1" == "/?" goto :help

if "%~1"=="" (
    echo Error: Input file not specified.
    goto :help
)
if "%~2"=="" (
    echo Error: Output file not specified.
    goto :help
)

set "SCRIPT_PATH=%~dp0hdr2uhdr.ps1"
set "INPUT_FILE=%~1"
set "OUTPUT_FILE=%~2"

echo Calling PowerShell script to convert %INPUT_FILE% to %OUTPUT_FILE%...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" "%INPUT_FILE%" "%OUTPUT_FILE%"

if %ERRORLEVEL% neq 0 (
    echo.
    echo PowerShell script failed with exit code %ERRORLEVEL%.
    exit /b %ERRORLEVEL%
)

echo.
echo Conversion completed successfully.
goto :eof

:help
echo.
echo Converts an HDR image file (e.g., HEIC, AVIF) to an UltraHDR JPEG.
echo.
echo Usage:
echo   %~n0 ^<input_file^> ^<output_jpeg^>
echo.
echo Parameters:
echo   input_file     Path to the source HDR image file.
echo   output_jpeg    Path for the destination UltraHDR JPEG file.
echo.
echo Example:
echo   %~n0 my_photo.heic my_photo.jpg
echo.
exit /b 1

:eof
endlocal
