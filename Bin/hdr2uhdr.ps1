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

  $exifOutput = & exiftool -s -G1 -ImageWidth -ImageHeight -TransferCharacteristics $Path
  
  $width = ($exifOutput | Where-Object { $_ -match 'Image\s*Width\s*:\s*(\d+)' } | Select-Object -First 1 | ForEach-Object { ($_ -split ':\s*')[-1] }) -as [int]
  $height = ($exifOutput | Where-Object { $_ -match 'Image\s*Height\s*:\s*(\d+)' } | Select-Object -First 1 | ForEach-Object { ($_ -split ':\s*')[-1] }) -as [int]
  $transfer = ($exifOutput | Where-Object { $_ -match 'Transfer\s*Characteristics\s*:\s*(.*)' } | Select-Object -First 1 | ForEach-Object { ($_ -split ':\s*', 2)[-1] })

  if ($width -le 0 -or $height -le 0) {
    throw "Could not determine image dimensions from exiftool output."
  }

  $hdrFormat = 'hlg' # Default
  if ($transfer -match 'hlg' -or $transfer -match 'arib-std-b67') {
    $hdrFormat = 'hlg'
  }
  elseif ($transfer -match 'pq' -or $transfer -match 'smpte2084') {
    $hdrFormat = 'pq'
  }
  else {
    Write-Warning "Could not determine HDR transfer function. Defaulting to HLG. Found: '$transfer'"
  }

  return [pscustomobject]@{
    Width = $width
    Height = $height
    HdrFormat = $hdrFormat
  }
}

$tmpRaw = $null
try {
  # 1) 工具自检
  Test-Tool -Name 'exiftool'
  Test-Tool -Name 'ffmpeg'
  Test-Tool -Name 'ultrahdr_app.exe'

  # 2) 读取HDR格式和帧宽高
  $hdrInfo = Get-HdrInfo -Path $InputPath
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
  $tmpName = "hdr2uhdr_" + [IO.Path]::GetFileNameWithoutExtension($OutputPath) + "_" + ([Guid]::NewGuid().ToString('N')) + ".raw"
  $tmpRaw  = Join-Path $env:TEMP $tmpName
  Write-Host "Temporary raw file: $tmpRaw"

  $ffArgs = @(
    '-hide_banner', '-y',
    '-i', $InputPath,
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
    '-a', '5', # rgba1010102 for x2bgr10le
    '-z', $OutputPath
  )
  Invoke-External -File 'ultrahdr_app.exe' -Args $uhdrArgs

  Write-Host "Successfully created UltraHDR file: $OutputPath"
  
  # 6) (Optional) Copy EXIF
  Write-Host "> Copying EXIF metadata..."
  # Copy only EXIF and XMP to avoid overwriting UltraHDR-specific metadata or color profiles
  Invoke-External -File 'exiftool' -Args @('-TagsFromFile', $InputPath, '-exif:all', '-xmp:all', '-overwrite_original', $OutputPath)

}
finally {
  if ($tmpRaw -and (Test-Path $tmpRaw)) {
    try {
      Remove-Item $tmpRaw -ErrorAction SilentlyContinue
      Write-Host "Cleaned up temporary file."
    } catch {}
  }
}
