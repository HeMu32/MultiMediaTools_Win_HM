<#
.SYNOPSIS
  Converts an HDR image file (like HEIC/HIF) into an UltraHDR compatible JPEG.

.DESCRIPTION
  This script uses exiftool to determine the HDR format (HLG or PQ) and resolution of the input file.
  It then uses ffmpeg to convert the input image to a 10-bit raw format.
  Finally, it calls ultrahdr_app.exe to encode the raw data into an UltraHDR JPEG.
  If the input image's longest dimension exceeds 8192px, it is scaled down.
  
  Color / gamut handling:
    - If the input file lacks explicit color-space tags, the script will assume BT.2020/HLG by default.
    - If transfer is present but color gamut is missing, the script fallbacks: HLG->BT.2100, PQ->P3.

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

  # 使用 exiftool 的 JSON 输出（-j），然后用 ConvertFrom-Json 解析——更稳健，避免地域化/输出格式差异
  $json = & exiftool -j -ImageWidth -ImageHeight -TransferCharacteristics -ColorSpace -ColorPrimaries -PrimaryChromaticities -ProfileDescription -ICC_ProfileName $Path 2>&1
  if (-not $json) {
    throw "exiftool returned no metadata for: $Path"
  }

  $meta = $null
  try {
    $meta = $json | ConvertFrom-Json
  } catch {
    throw "Failed to parse exiftool JSON output: $_"
  }

  # exiftool -j 返回数组（即使单文件也会是数组），取第一个记录
  $rec = if ($meta -is [System.Array]) { $meta[0] } else { $meta }

  # 宽高
  $width = ($rec.ImageWidth) -as [int]
  $height = ($rec.ImageHeight) -as [int]
  if ($width -le 0 -or $height -le 0) {
    throw "Could not determine image dimensions from exiftool JSON output."
  }

  # 辅助：规范化 tag 值（处理数组 / 占位词）
  function Normalize-TagValue($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [System.Array]) { $v = ($v -join ' ') }
    $s = $v.ToString().Trim()
    if ($s -eq '') { return $null }
    if ($s -match '^(uncalibrat|unknown|n/?a|none|not ?set|undefined)$') { return $null }
    return $s
  }

  $transfer = Normalize-TagValue $rec.TransferCharacteristics
  $colorSpace = Normalize-TagValue $rec.ColorSpace
  $colorPrimaries = Normalize-TagValue $rec.ColorPrimaries
  $primaryChromaticities = Normalize-TagValue $rec.PrimaryChromaticities
  $profileDesc = Normalize-TagValue $rec.ProfileDescription
  $iccName = Normalize-TagValue $rec.ICC_ProfileName

  # 组合有意义的 color 字段文本用于检测
  $availableColorStrings = @($colorSpace, $colorPrimaries, $primaryChromaticities, $profileDesc, $iccName) | Where-Object { $_ -ne $null }
  $colorInfoText = ($availableColorStrings -join ' ')
  $hasColorInfo = ($availableColorStrings.Count -gt 0)

  # 解析 transfer（默认 HLG）
  $hdrFormat = 'hlg'
  if ($transfer -and ($transfer -match 'hlg' -or $transfer -match 'arib' -or $transfer -match 'b67')) {
    $hdrFormat = 'hlg'
  } elseif ($transfer -and ($transfer -match 'pq' -or $transfer -match 'smpte' -or $transfer -match '2084')) {
    $hdrFormat = 'pq'
  } else {
    Write-Warning "Could not determine HDR transfer function from JSON; defaulting to HLG. Raw transfer: '$transfer'"
    $hdrFormat = 'hlg'
  }

  # 解析色域（优先使用显式标签）
  $gamut = 'unknown'
  $gamutFlag = 2 # 默认 BT.2100
  $searchText = $colorInfoText
  if (-not $searchText) { $searchText = ($transfer -as [string]) }

  if ($searchText -match '2020|bt\.?2020|rec\.?2020') {
    $gamut = 'bt2020'; $gamutFlag = 2
  } elseif ($searchText -match 'p3|display\s?p3|dci\-p3') {
    $gamut = 'p3'; $gamutFlag = 1
  } elseif ($searchText -match '709|bt\.?709|rec\.?709|srgb') {
    $gamut = 'bt709'; $gamutFlag = 0
  }

  # Fallback 规则（与需求一致）
  if ($gamut -eq 'unknown') {
    if (-not $hasColorInfo) {
      if ($hdrFormat -eq 'hlg') {
        $gamut = 'bt2020'; $gamutFlag = 2
        Write-Host "No color-space tags found; assuming BT.2020 for HLG content."
      } elseif ($hdrFormat -eq 'pq') {
        $gamut = 'p3'; $gamutFlag = 1
        Write-Host "No color-space tags found; assuming P3 for PQ content."
      } else {
        $gamut = 'bt2020'; $gamutFlag = 2; $hdrFormat = 'hlg'
        Write-Host "Input missing transfer & color info; defaulting to BT.2020/HLG."
      }
    } else {
      # 存在标签但无法识别 -> 安全默认 BT.2020
      $gamut = 'bt2020'; $gamutFlag = 2
      Write-Host "Color tags present but unrecognized; falling back to BT.2020 for safety. Detected: $colorInfoText"
    }
  }

  return [pscustomobject]@{
    Width = $width
    Height = $height
    HdrFormat = $hdrFormat
    HdrGamut = $gamut
    HdrGamutFlag = $gamutFlag
    HasColorInfo = $hasColorInfo
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
  $hdrGamut = $hdrInfo.HdrGamut
  $hdrGamutFlag = $hdrInfo.HdrGamutFlag
  $hasColorInfo = $hdrInfo.HasColorInfo
  Write-Host "Detected properties: ${w}x${h}, Format: $hdrFormat, Gamut: $hdrGamut (hasColorInfo: $hasColorInfo)"

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
    # 指定 HDR intent 色域 (-C): 0=bt709, 1=p3, 2=bt2100
    '-C', $hdrGamutFlag,
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
