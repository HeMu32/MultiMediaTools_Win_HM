<#!
.SYNOPSIS
  处理 iPhone HDR HEIC，生成指定传输函数与位深的 TIFF。

.DESCRIPTION
  工作流程：
    1. 调用 hdrheif2uhdr.ps1 将 HEIC 转换为 UltraHDR JPEG（临时文件）。
    2. 使用 ultrahdr_app.exe 解码 UltraHDR JPEG 为 10bit RGBA1010102 raw。
    3. 通过 ffmpeg 将 raw 封装为 TIFF（支持 HLG/PQ 与 8/16bit）。

.PARAMETER InputPath
  Apple HDR HEIC 输入路径。

.PARAMETER OutputPath
  输出 TIFF 路径。

.PARAMETER Transfer
  输出传输函数：'pq' 或 'hlg'（默认 'pq'）。

.PARAMETER BitDepth
  输出 TIFF 位深：8 或 16（默认 16）。

.REQUIREMENTS
  需存在工具：hdrheif2uhdr.ps1、ultrahdr_app.exe、ffprobe、ffmpeg。
  hdrheif2uhdr.ps1 依赖 heif-dec.exe 与 extract_apple_hdr_metadata.ps1。
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
  [string]$Transfer = 'pq',

  [Parameter(Position = 3)]
  [ValidateSet(8,16)]
  [int]$BitDepth = 16
)

$ErrorActionPreference = 'Stop'

function Test-Tool {
  param([Parameter(Mandatory=$true)][string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Command '$Name' not found, ensure it is installed and in PATH."
  }
}

function Get-ImageSize {
  param([Parameter(Mandatory=$true)][string]$Path)
  $ffprobeArgs = @(
    '-hide_banner',
    '-v','error',
    '-select_streams','v:0',
    '-show_entries','stream=width,height',
    '-of','csv=s=,:p=0',
    $Path
  )
  $out = & ffprobe @ffprobeArgs 2>$null | Select-Object -First 1
  if (-not $out) { throw "Unable to parse resolution from '$Path' (ffprobe no output)." }
  $parts = $out -split ','
  if ($parts.Count -lt 2) { throw "Unable to parse resolution from '$Path' (unexpected output: $out)" }
  $width  = [int]$parts[0]
  $height = [int]$parts[1]
  if ($width -le 0 -or $height -le 0) { throw "Parsed width/height invalid: $width x $height" }
  [pscustomobject]@{ Width = $width; Height = $height }
}

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
$heicToUhdr = Join-Path $scriptDir 'hdrheif2uhdr.ps1'
if (-not (Test-Path $heicToUhdr)) {
  throw "Required script 'hdrheif2uhdr.ps1' not found next to uhdr2tiff-heic.ps1."
}

Test-Tool -Name 'ultrahdr_app.exe'
Test-Tool -Name 'ffprobe'
Test-Tool -Name 'ffmpeg'
Test-Tool -Name 'exiftool'

$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("uhdr2tiff_heic_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir | Out-Null
Write-Host "Using temp dir: $tempDir"

$uhdrJpeg = Join-Path $tempDir 'intermediate_uhdr.jpg'
$rawPath  = Join-Path $tempDir 'decoded_rgba1010102.raw'

try {
  Write-Host "> stage1: heic -> ultrahdr jpeg"
  & $heicToUhdr -InputHeic $resolvedInput.Path -OutputJpeg $uhdrJpeg
  if (-not (Test-Path $uhdrJpeg)) {
    throw "Failed to generate UltraHDR JPEG at '$uhdrJpeg'."
  }

  $size = Get-ImageSize -Path $uhdrJpeg
  $w = $size.Width
  $h = $size.Height
  Write-Host "Detected resolution: $w x $h"

  $tf = if ($Transfer -eq 'hlg') { 1 } else { 2 }
  $uhdrArgs = @(
    '-m','1',
    '-j',$uhdrJpeg,
    '-o',$tf,
    '-O','5',
    '-z',$rawPath
  )
  Write-Host "> stage2: decode UltraHDR -> raw"
  Invoke-External -File 'ultrahdr_app.exe' -Args $uhdrArgs

  $expected = [int64]$w * [int64]$h * 4
  if (-not (Test-Path $rawPath)) { throw "Decoder did not create raw output '$rawPath'." }
  $actual = (Get-Item $rawPath).Length
  if ($actual -ne $expected) {
    Write-Warning "Raw file size mismatch: $actual vs $expected (expected $w x $h x 4)."
  }

  $pixIn = 'x2bgr10le'
  $pixOut = if ($BitDepth -eq 16) { 'rgb48le' } else { 'rgb24' }
  $colorTrc = if ($Transfer -eq 'hlg') { 'arib-std-b67' } else { 'smpte2084' }

  $ffArgs = @(
    '-hide_banner',
    '-f','rawvideo',
    '-pix_fmt',$pixIn,
    '-s',"${w}x${h}",
    '-i',$rawPath,
    '-frames:v','1',
    '-pix_fmt',$pixOut,
    '-color_trc',$colorTrc,
    '-y',$outputFull
  )
  Write-Host "> stage3: raw -> tiff"
  Invoke-External -File 'ffmpeg' -Args $ffArgs

  Write-Host "Completed: $outputFull"

  # Copy EXIF from input HEIC to output TIFF
  Write-Host "> copying EXIF metadata"
  Invoke-External -File 'exiftool' -Args @('-TagsFromFile', $resolvedInput.Path, '-all:all', '-overwrite_original', $outputFull)
}
finally {
  if (Test-Path $tempDir) {
    try { Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
}
