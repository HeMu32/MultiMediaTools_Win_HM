<#!
.SYNOPSIS
  处理 iPhone HDR HEIC，生成指定传输函数与位深的 TIFF。

.DESCRIPTION
  工作流程：
    1. 调用 aaplheic2uhdr.ps1 将 HEIC 转换为 UltraHDR JPEG（临时文件）。
    2. 调用 uhdr2tiff.ps1 完成 UltraHDR JPEG -> TIFF 的全部工作
       （包括 ultrahdr_app 解码、ICC 色域检测、zscale 色域转换、ffmpeg 封装）。
    3. 用原始 HEIC 的 EXIF 覆盖 TIFF 中由 uhdr2tiff.ps1 写入的中间 JPEG EXIF。

.PARAMETER InputPath
  Apple HDR HEIC 输入路径。

.PARAMETER OutputPath
  输出 TIFF 路径。

.PARAMETER Transfer
  输出传输函数：'hlg' 或 'pq'（默认 'hlg'）。

.PARAMETER BitDepth
  输出 TIFF 位深：8 或 16（默认 16）。

.REQUIREMENTS
  需存在脚本：aaplheic2uhdr.ps1、uhdr2tiff.ps1（同目录）。
  aaplheic2uhdr.ps1 依赖 heif-dec.exe 与 extract_apple_hdr_metadata.ps1。
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateNotNullOrEmpty()]
  [string]$InputPath,

  [Parameter(Mandatory = $true, Position = 1)]
  [ValidateNotNullOrEmpty()]
  [string]$OutputPath,

  [Parameter(Position = 2)]
  [ValidateSet('pq','hlg')]
  [string]$Transfer = 'hlg',

  [Parameter(Position = 3)]
  [ValidateSet(8,16)]
  [int]$BitDepth = 16
)

$ErrorActionPreference = 'Stop'

function Invoke-External {
  param(
    [Parameter(Mandatory=$true)][string]$File,
    [string[]]$Args
  )
  Write-Host "> $File $($Args -join ' ')"
  & $File @Args
  $code = $LASTEXITCODE
  if ($code -ne 0) { throw "Command failed ($File), exit code: $code" }
}

$resolvedInput = Resolve-Path -LiteralPath $InputPath -ErrorAction Stop
$outputFull = [IO.Path]::GetFullPath($OutputPath)
$outDir = Split-Path -Parent $outputFull
if ($outDir -and -not (Test-Path $outDir)) {
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent

$heicToUhdr = Join-Path $scriptDir 'aaplheic2uhdr.ps1'
if (-not (Test-Path $heicToUhdr)) {
  throw "Required script 'aaplheic2uhdr.ps1' not found next to uhdr2tiff-aaplheic.ps1."
}
$uhdrToTiff = Join-Path $scriptDir 'uhdr2tiff.ps1'
if (-not (Test-Path $uhdrToTiff)) {
  throw "Required script 'uhdr2tiff.ps1' not found next to uhdr2tiff-aaplheic.ps1."
}

if (-not (Get-Command 'exiftool' -ErrorAction SilentlyContinue)) {
  throw "Command 'exiftool' not found, ensure it is installed and in PATH."
}

$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("uhdr2tiff_heic_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir | Out-Null
Write-Host "Using temp dir: $tempDir"

$uhdrJpeg = Join-Path $tempDir 'intermediate_uhdr.jpg'

try {
  # stage 1: HEIC -> UltraHDR JPEG
  Write-Host "> stage1: heic -> ultrahdr jpeg"
  & $heicToUhdr -InputHeic $resolvedInput.Path -OutputJpeg $uhdrJpeg
  if (-not (Test-Path $uhdrJpeg)) {
    throw "Failed to generate UltraHDR JPEG at '$uhdrJpeg'."
  }

  # stage 2+3: UltraHDR JPEG -> TIFF（委托给 uhdr2tiff.ps1，含解码、ICC 检测、色域转换、ffmpeg 封装）
  Write-Host "> stage2+3: ultrahdr jpeg -> tiff (delegating to uhdr2tiff.ps1)"
  & $uhdrToTiff -InputPath $uhdrJpeg -OutputPath $outputFull -Transfer $Transfer -BitDepth $BitDepth
  if ($LASTEXITCODE -ne 0) { throw "uhdr2tiff.ps1 failed with exit code $LASTEXITCODE." }

  # stage 4: 用原始 HEIC 的 EXIF 覆盖（uhdr2tiff.ps1 已写入中间 JPEG 的 EXIF，此处以源文件覆盖）
  # --ICC_Profile: 排除 ICC Profile — 输出 TIFF 像素已由 uhdr2tiff.ps1 转换为 BT.2020，
  #               不应被 HEIC 的 P3 ICC 覆盖
  Write-Host "> stage4: overwrite EXIF/XMP from original HEIC (excluding ICC_Profile)"
  Invoke-External -File 'exiftool' -Args @(
      '-TagsFromFile', $resolvedInput.Path,
      '-exif:all',
      '-xmp:all',
      '--ICC_Profile',
      '-overwrite_original',
      $outputFull
  )

  Write-Host "Completed: $outputFull"
}
finally {
  if (Test-Path $tempDir) {
    try { Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
}