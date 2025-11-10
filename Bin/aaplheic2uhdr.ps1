<#!
.SYNOPSIS
  将 Apple HDR HEIC 转换为 UltraHDR JPEG。

.DESCRIPTION
  该脚本自动完成以下步骤：
    1. 使用 heif-dec.exe 解码 HEIC，并导出主图与 HDR 增益图（aux）。
    2. 调用 extract_apple_hdr_metadata.ps1 生成符合 ultrahdr_app 的 metadata.cfg。
    3. 借助 ffmpeg 将 heif-dec 导出的 TIFF 主图和增益图压缩为 JPEG（最高质量）。
    4. 使用 ultrahdr_app.exe 以最高 JPEG 质量重新编码为 UltraHDR JPEG。

.PARAMETER InputHeic
  Apple HDR HEIC 输入路径。

.PARAMETER OutputJpeg
  UltraHDR JPEG 输出路径。

.REQUIREMENTS
  需在 PATH 中可找到：heif-dec.exe、ffmpeg、ultrahdr_app.exe。
  同目录需存在 extract_apple_hdr_metadata.ps1。
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateNotNullOrEmpty()]
  [string]$InputHeic,

  [Parameter(Mandatory = $true, Position = 1)]
  [ValidateNotNullOrEmpty()]
  [string]$OutputJpeg
)

$ErrorActionPreference = 'Stop'

function Test-Tool {
  param([Parameter(Mandatory=$true)][string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Command '$Name' not found, ensure it is installed and in PATH."
  }
}

function Invoke-External {
  param(
    [Parameter(Mandatory=$true)][string]$File,
    [string[]]$Args
  )
  Write-Host "> $File $($Args -join ' ')"
  & $File @Args
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    throw "Command failed ($File), exit code: $code"
  }
}

$resolvedInput = Resolve-Path -LiteralPath $InputHeic -ErrorAction Stop
$outputFull = [IO.Path]::GetFullPath($OutputJpeg)
$outDir = Split-Path -Parent $outputFull
if ($outDir -and -not (Test-Path $outDir)) {
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$metadataScript = Join-Path $scriptDir 'extract_apple_hdr_metadata.ps1'
if (-not (Test-Path $metadataScript)) {
  throw "Required script 'extract_apple_hdr_metadata.ps1' not found next to aaplheic2uhdr.ps1."
}

Test-Tool -Name 'heif-dec.exe'
Test-Tool -Name 'ffmpeg'
Test-Tool -Name 'ultrahdr_app.exe'
Test-Tool -Name 'exiftool'

$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("hdrheif_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir | Out-Null
Write-Host "Using temp dir: $tempDir"

$baseTif = Join-Path $tempDir 'base.tif'
$heifArgs = @('--with-aux','--no-colons',$resolvedInput.Path,$baseTif)

try {
  Invoke-External -File 'heif-dec.exe' -Args $heifArgs
  if (-not (Test-Path $baseTif)) {
    throw "Expected decoded file '$baseTif' not found."
  }

  $baseStem = [IO.Path]::GetFileNameWithoutExtension($baseTif)
  $gainmapDefault = Join-Path $tempDir ("{0}-urn_com_apple_photo_2020_aux_hdrgainmap.tif" -f $baseStem)
  if (Test-Path $gainmapDefault) {
    $gainmapTif = $gainmapDefault
  } else {
    $candidate = Get-ChildItem -Path $tempDir -Filter '*aux_hdrgainmap*.tif' | Select-Object -First 1
    if (-not $candidate) {
      throw "Unable to locate HDR gain map TIFF (expected suffix 'urn_com_apple_photo_2020_aux_hdrgainmap')."
    }
    $gainmapTif = $candidate.FullName
  }
  Write-Host "Base TIFF: $baseTif"
  Write-Host "Gain map TIFF: $gainmapTif"

  $metadataCfg = Join-Path $tempDir 'metadata.cfg'
  Write-Host "> extracting gain map metadata"
  & $metadataScript -InputFile $resolvedInput.Path -OutputFile $metadataCfg
  if (-not (Test-Path $metadataCfg)) {
    throw "Metadata extraction failed: '$metadataCfg' not created."
  }

  $baseJpeg = Join-Path $tempDir 'base.jpg'
  $gainmapJpeg = Join-Path $tempDir 'gainmap.jpg'

  Write-Host "> converting base TIFF -> JPEG"
  Invoke-External -File 'ffmpeg' -Args @('-hide_banner','-y','-i',$baseTif,'-q:v','1','-pix_fmt','yuv444p',$baseJpeg)

  Write-Host "> converting gain map TIFF -> JPEG"
  Invoke-External -File 'ffmpeg' -Args @('-hide_banner','-y','-i',$gainmapTif,'-q:v','1','-pix_fmt','gray',$gainmapJpeg)

  Write-Host "> encoding UltraHDR JPEG"
  $ultraArgs = @(
    '-m','0',
    '-i',$baseJpeg,
    '-g',$gainmapJpeg,
    '-f',$metadataCfg,
    '-q','100',
    '-Q','100',
    '-z',$outputFull
  )
  Invoke-External -File 'ultrahdr_app.exe' -Args $ultraArgs
  Write-Host "Success: $outputFull"

  # Copy EXIF from input HEIC to output JPEG
  Write-Host "> copying EXIF metadata"
  Invoke-External -File 'exiftool' -Args @('-TagsFromFile', $resolvedInput.Path, '-all:all', '-overwrite_original', $outputFull)
}
finally {
  if (Test-Path $tempDir) {
    try { Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
}
