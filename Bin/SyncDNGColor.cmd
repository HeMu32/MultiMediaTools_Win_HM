@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem 使用 UTF-8 控制台以避免中文乱码
chcp 65001 >nul

rem --- 参数与模式判定 ---
set "MODE=DIRS"
set "ARG1=%~1"
set "ARG2=%~2"
if /I "%~1"=="/f" set "MODE=FILES" & set "ARG1=%~2" & set "ARG2=%~3"
if /I "%~1"=="-f" set "MODE=FILES" & set "ARG1=%~2" & set "ARG2=%~3"
if /I "%~1"=="--files" set "MODE=FILES" & set "ARG1=%~2" & set "ARG2=%~3"

if "%ARG2%"=="" (
    echo.
    echo 用法:
    echo   目录模式: %~nx0 [dest_dir] [ref_dir]
    echo   文件模式: %~nx0 /f [dest_file] [ref_file]
    echo 说明:
    echo   目录模式会同步 [dest_dir] 下所有 .dng 的标签，并在 [ref_dir] ^(含子文件夹^) 中寻找同名参考原始文件 ^(dng/arw/raf/cr3/nef/...^)
    echo   文件模式会仅同步一对文件 ^(目标 DNG 和参考原始文件^)
    exit /b 1
)

if /I "%MODE%"=="FILES" (
    set "DEST_FILE=%ARG1%"
    set "REF_PAIR=%ARG2%"
    if not exist "!DEST_FILE!" (
        echo [错误] 目标文件 "%DEST_FILE%" 不存在。
        exit /b 1
    )
    if not exist "!REF_PAIR!" (
        echo [错误] 参考文件 "%REF_PAIR%" 不存在。
        exit /b 1
    )
) else (
    set "DEST_DIR=%ARG1%"
    set "REF_DIR=%ARG2%"
    if not exist "!DEST_DIR!" (
        echo [错误] 目标目录 "%DEST_DIR%" 不存在。
        exit /b 1
    )
    if not exist "!REF_DIR!" (
        echo [错误] 参考目录 "%REF_DIR%" 不存在。
        exit /b 1
    )
)

rem --- 可接受的参考文件扩展名 ---
set "EXT_LIST=dng arw raf cr3 cr2 nef orf rw2 srw pef dcr kdc erf raw"

rem --- 要同步的 DNG 标签 ---
set "TAG_LIST=-ColorMatrix1 -ColorMatrix2 -ForwardMatrix1 -ForwardMatrix2 -CalibrationIlluminant1 -CalibrationIlluminant2 -CameraCalibration1 -CameraCalibration2 -AsShotNeutral -AnalogBalance -UniqueCameraModel"

rem --- 输出基本配置信息 ---
if /I "%MODE%"=="FILES" (
    echo [配置] 目标文件: "!DEST_FILE!"
    echo [配置] 参考文件: "!REF_PAIR!"
) else (
    echo [配置] 目标目录: "%DEST_DIR%"
    echo [配置] 参考目录: "%REF_DIR%"
)

rem --- 操作确认（明确将被修改的目标）---
if /I "%MODE%"=="FILES" (
    echo [将修改] 目标: "!DEST_FILE!" 的 DNG 标签
) else (
    echo [将修改] 目标目录: "%DEST_DIR%" 下所有匹配的 *.dng 的 DNG 标签
)
choice /C YN /M "继续执行吗？"
if errorlevel 2 (
    echo 已取消。
    exit /b 2
)

rem --- 初始化时间与统计 ---
set "START_TS=%date% %time%"
set "TOT=0"
set "FOUND=0"
set "MISSING=0"
set "SUCCESS=0"
set "FAIL=0"
set "MISSING_LIST="

rem --- 文件模式：直接处理一对文件 ---
if /I "%MODE%"=="FILES" (
    set /a TOT=1 >nul
    set /a FOUND=1 >nul
    echo.
    echo [同步] 目标: !DEST_FILE!
    echo         参考: !REF_PAIR!
    call :CopyTags "!DEST_FILE!" "!REF_PAIR!"
    if errorlevel 1 (
        set /a FAIL+=1 >nul
        echo [结果] 失败，错误码=!errorlevel!
    ) else (
        set /a SUCCESS+=1 >nul
        echo [结果] 成功
    )
    goto :summary
)

rem --- 逐一处理目标 DNG ---
for %%F in ("%DEST_DIR%\*.dng") do (
    set /a TOT+=1 >nul
    set "REF_FILE="
    call :FindReference "%%~nF" REF_FILE
    if not defined REF_FILE (
        echo [警告] 未在 "%REF_DIR%" 找到对应原始文件: %%~nF.*
        set /a MISSING+=1 >nul
        set "MISSING_LIST=!MISSING_LIST! %%~nF"
    ) else (
        echo.
        echo [同步] 目标: %%~fF
        echo         参考: !REF_FILE!
        set /a FOUND+=1 >nul
        call :CopyTags "%%~fF" "!REF_FILE!"
        if errorlevel 1 (
            set /a FAIL+=1 >nul
            echo [结果] 失败，错误码=!errorlevel!
        ) else (
            set /a SUCCESS+=1 >nul
            echo [结果] 成功
        )
    )
)

:summary
echo.
echo [汇总] 总 DNG: !TOT!，找到参考: !FOUND!，未找到参考: !MISSING!，成功: !SUCCESS!，失败: !FAIL!
if not "!MISSING_LIST!"=="" echo [未找到清单] !MISSING_LIST!
echo [开始时间] %START_TS%
echo [结束时间] %date% %time%
echo 完成。
exit /b 0

rem ================= 子程序 =================

:FindReference
set "BASE=%~1"
set "RESULT="

for /f "delims=" %%R in ('dir /b /s "%REF_DIR%\%BASE%.*" 2^>nul') do (
    for %%E in (%EXT_LIST%) do (
        if /I "%%~xR"==".%%E" (
            set "RESULT=%%~fR"
            goto found_ref
        )
    )
)
:found_ref
if defined RESULT (
    set "%~2=%RESULT%"
    exit /b 0
) else (
    set "%~2="
    exit /b 1
)

:CopyTags
set "DEST=%~1"
set "REF=%~2"
echo    exiftool -overwrite_original -TagsFromFile "!REF!" !TAG_LIST! "!DEST!"
exiftool -overwrite_original -TagsFromFile "!REF!" !TAG_LIST! "!DEST!"
if errorlevel 1 (
    echo    [警告] exiftool 写入失败 ^(代码 !errorlevel!^)。
)
exit /b %errorlevel%