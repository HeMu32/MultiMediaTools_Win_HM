<#
.SYNOPSIS
  Converts an HDR image file (like HEIC/HIF) into an UltraHDR compatible JPEG.

.DESCRIPTION
  This script uses exiftool to determine the HDR format (HLG or PQ) and resolution of the input file.
  It then uses ffmpeg to convert the input image to a 10-bit raw format.
  Finally, it calls ultrahdr_app.exe to encode the raw data into an UltraHDR JPEG.
  If the input image's longest dimension exceeds 8192px, it is scaled down.

.PARAMETER InputPath
  Path to the input HDR file (e.g., .hif, .heic).

.PARAMETER OutputPath
  Path for the output UltraHDR JPEG file (.jpg).

.REQUIREMENTS
  Requires exiftool, ffmpeg, and ultrahdr_app.exe to be available in the system's PATH.

.EXAMPLE
  # Convert an HDR file to UltraHDR JPEG
  .\hdr2uhdr.ps1 -InputPath 'DSC02617.hif' -OutputPath 'output.jpg'
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateNotNullOrEmpty()]
  [string]$InputPath,

  [Parameter(Mandatory = $true, Position = 1)]
  [ValidateNotNullOrEmpty()]
  [string]$OutputPath
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
  if ($code -ne 0) { throw "Command failed ($File), exit code: $code" }
}

function Get-HdrInfo {
  param([Parameter(Mandatory=$true)][string]$Path)
  # JSON 输出解析比文本正则更可靠；ImageWidth/Height 取自文件实际像素，非 EXIF 字段
  $exifJson = & exiftool -j -ImageWidth -ImageHeight -TransferCharacteristics $Path 2>$null | ConvertFrom-Json
  if (-not $exifJson -or $exifJson.Count -eq 0) {
    throw "exiftool returned no data for '$Path'."
  }
  $info     = $exifJson[0]
  $width    = $info.ImageWidth            -as [int]
  $height   = $info.ImageHeight           -as [int]
  $transfer = [string]$info.TransferCharacteristics

  if ($width -le 0 -or $height -le 0) {
    throw "Could not determine image dimensions from exiftool output."
  }

  $hdrFormat = 'hlg' # Default HLG
  if ($transfer -match 'hlg' -or $transfer -match 'arib-std-b67') {
    $hdrFormat = 'hlg'
  } elseif ($transfer -match 'pq' -or $transfer -match 'smpte2084') {
    $hdrFormat = 'pq'
  } else {
    Write-Warning "Could not determine HDR transfer function. Defaulting to HLG. Found: '$transfer'"
  }

  return [pscustomobject]@{
    Width     = $width
    Height    = $height
    HdrFormat = $hdrFormat
  }
}

$resolvedInput = Resolve-Path -LiteralPath $InputPath -ErrorAction Stop
$outputFull    = [IO.Path]::GetFullPath($OutputPath)
$outDir = Split-Path -Parent $outputFull
if ($outDir -and -not (Test-Path $outDir)) {
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

$tempDir = $null
try {
  # 1) 工具自检
  Test-Tool -Name 'exiftool'
  Test-Tool -Name 'ffmpeg'
  Test-Tool -Name 'ultrahdr_app.exe'

  # 2) 读取HDR格式和帧宽高
  $hdrInfo = Get-HdrInfo -Path $resolvedInput.Path
  $w = $hdrInfo.Width
  $h = $hdrInfo.Height
  $hdrFormat = $hdrInfo.HdrFormat
  Write-Host "Detected properties: ${w}x${h}, Format: $hdrFormat"

  # 3) 如果帧大小大于8192px, 计算缩放尺寸
  $scaleArgs = @()
  $maxDim = 8192
  if ($w -gt $maxDim -or $h -gt $maxDim) {
    Write-Host "Image dimensions ($w x $h) exceed $maxDim px, scaling down."
    if ($w -ge $h) {
      $newW = $maxDim
      $newH = [int]([Math]::Round($h / ($w / $newW)))
      # 确保为偶数
      if ($newH % 2 -ne 0) { $newH++ }
    }
    else {
      $newH = $maxDim
      $newW = [int]([Math]::Round($w / ($h / $newH)))
      if ($newW % 2 -ne 0) { $newW++ }
    }
    $w = $newW
    $h = $newH
    $scaleArgs = @('-s', "${w}x${h}")
    Write-Host "New dimensions: ${w}x${h}"
  }

  # 4) 用ffmpeg转换输入文件为临时文件
  $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("hdr2uhdr_" + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tempDir | Out-Null
  $tmpRaw = Join-Path $tempDir 'hdr.raw'
  Write-Host "Temporary dir: $tempDir"

  $ffArgs = @(
    '-hide_banner', '-y',
    '-i', $resolvedInput.Path,
    '-f', 'rawvideo',
    '-pix_fmt', 'x2bgr10le'
  ) + $scaleArgs + @(
    $tmpRaw
  )
  Invoke-External -File 'ffmpeg' -Args $ffArgs

  # 5) 用ultrahdr_app生成输出文件
  $tf = if ($hdrFormat -eq 'hlg') { 1 } else { 2 }
  $uhdrArgs = @(
    '-m', '0',
    '-p', $tmpRaw,
    '-w', $w,
    '-h', $h,
    '-t', $tf,
    '-C', '2', # BT.2100 intent color gamut
    '-a', '5', # rgba1010102 for x2bgr10le
    '-z', $outputFull
  )
  Invoke-External -File 'ultrahdr_app.exe' -Args $uhdrArgs

  Write-Host "Successfully created UltraHDR file: $outputFull"

  # 6) Copy EXIF/XMP；不复制 ICC Profile（UltraHDR SDR 色彩空间由 ultrahdr_app 的 -C 参数定义，
  #    源文件 ICC 与输出容器不对应）
  Write-Host "> Copying EXIF/XMP metadata (excluding ICC_Profile)..."
  Invoke-External -File 'exiftool' -Args @(
      '-TagsFromFile', $resolvedInput.Path,
      '-exif:all',
      '-xmp:all',
      '--ICC_Profile',
      '-overwrite_original',
      $outputFull
  )

}
finally {
  if ($tempDir -and (Test-Path $tempDir)) {
    try { Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
}
