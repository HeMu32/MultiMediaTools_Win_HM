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

  # 读取源 HEIC 的 ICC Profile 描述，确定向 ultrahdr_app 传递的 SDR 色域参数 (-c)
  # 使用源 HEIC 是因为 heif-dec 的部分输出 TIFF 会使得 exiftool 难以正确解析 ICC 字符串标识
  # 使目标 UltraHDR JPEG 的 XMP 色域字段与嵌入的 ICC Profile 保持一致
  $exifBase = & exiftool -j '-ICC_Profile:ProfileDescription' $resolvedInput.Path 2>$null | ConvertFrom-Json
  $baseIccDesc = if ($exifBase -and $exifBase.Count -gt 0) { $exifBase[0].ProfileDescription } else { $null }
  Write-Host "Source HEIC ICC ProfileDescription: $(if ($baseIccDesc) { $baseIccDesc } else { '(none – fallback BT.709)' })"
  # P3-D65 (Display P3) 与 P3-DCI 区分；苹果图片总是 P3-D65
  if ($baseIccDesc -match 'Display P3' -or $baseIccDesc -match 'P3 D65') {
    $sdrCgArg = '1'   # UHDR_CG_DISPLAY_P3 (P3‑D65)
  } elseif ($baseIccDesc -match 'DCI.P3') {
    $sdrCgArg = '1'   # 罕见的 P3‑DCI 也当做 P3 处理，但仍使用同一个编码值
  } elseif ($baseIccDesc -match 'BT\.?2020' -or $baseIccDesc -match 'Rec\.?\s*2020') {
    $sdrCgArg = '2'   # UHDR_CG_BT_2100
  } else {
    $sdrCgArg = '0'   # UHDR_CG_BT_709 (sRGB fallback)
  }
  Write-Host "Passing -c $sdrCgArg to ultrahdr_app SDR gamut."

  Write-Host "> encoding UltraHDR JPEG"
  $ultraArgs = @(
    '-m','0',
    '-i',$baseJpeg,
    '-g',$gainmapJpeg,
    '-f',$metadataCfg,
    '-q','100',
    '-Q','100',
    '-c',$sdrCgArg,
    '-z',$outputFull
  )
  Invoke-External -File 'ultrahdr_app.exe' -Args $ultraArgs
  Write-Host "Success: $outputFull"

  # Copy full EXIF metadata from the HEIC into the UltraHDR JPEG.  
  # Exiftool's "-all:all" already includes the ICC_Profile tag, so the
  # separate explicit copy previously here was redundant and has been
  # removed.  The important part is that the original P3 ICC travels
  # along with the JPEG so legacy SDR viewers render correctly.
  Write-Host "> copying EXIF/XMP metadata and ICC_Profile"
  # Only copy the standard EXIF and XMP groups plus ICC profile.  Apple devices
  # can be sensitive to extraneous maker notes or proprietary tags, so we avoid
  # pulling over unrelated fields.
    # Copy EXIF (all) and a curated set of common XMP groups to avoid
    # bringing Apple-private XMP namespaces (e.g. XMP-HDRGainMap / XMP-apdi).
    # Whitelist copy: select common EXIF, GPS, IPTC and safe XMP groups so
    # we preserve useful photographic metadata (exposure, ISO, focal length,
    # lens, creation dates, GPS, IPTC captions/keywords, XMP-dc/xmpMM provenance)
    # while avoiding Apple-private XMP namespaces (e.g. XMP-apdi / XMP-HDRGainMap).
    Invoke-External -File 'exiftool' -Args @(
        '-TagsFromFile', $resolvedInput.Path,
        # Core timestamps & camera identification
        '-EXIF:DateTimeOriginal',
        '-EXIF:CreateDate',
        '-EXIF:ModifyDate',
        '-EXIF:SubSecTimeOriginal',
        '-EXIF:SubSecTimeDigitized',
        '-EXIF:Make',
        '-EXIF:Model',
        '-EXIF:Orientation',
        # Exposure / capture parameters (comprehensive set)
        '-EXIF:ExposureTime',
        '-EXIF:FNumber',
        '-EXIF:ExposureProgram',
        '-EXIF:ExposureCompensation',
        '-EXIF:ExposureBiasValue',
        '-EXIF:ShutterSpeedValue',
        '-EXIF:ApertureValue',
        '-EXIF:MaxApertureValue',
        '-EXIF:ISOSpeedRatings',
        '-EXIF:PhotographicSensitivity',
        '-EXIF:ExposureIndex',
        '-EXIF:MeteringMode',
        '-EXIF:Flash',
        '-EXIF:WhiteBalance',
        '-EXIF:ExposureMode',
        '-EXIF:CustomRendered',
        '-EXIF:GainControl',
        '-EXIF:Contrast',
        '-EXIF:Saturation',
        '-EXIF:Sharpness',
        # Focal length / lens (including 35mm equiv and lens details)
        '-EXIF:FocalLength',
        '-EXIF:FocalLengthIn35mmFormat',
        '-EXIF:LensModel',
        '-EXIF:LensMake',
        '-EXIF:LensInfo',
        '-EXIF:LensSpecification',
        '-EXIF:SubjectArea',
        '-EXIF:SceneType',
        '-EXIF:ColorSpace',
        # GPS, IPTC (preserve common location and editorial metadata)
        '-GPS:All',
        '-IPTC:All',
        # XMP groups: keep common, non-proprietary groups (dc, xmpMM, photoshop, exif)
        '-XMP-dc:All',
        '-XMP-xmpMM:All',
        '-XMP-photoshop:All',
        '-XMP-iptcCore:All',
        '-XMP-exif:All',
        '-XMP-xmp:All',
        '-XMP-aux:All',
        # Preserve ICC profile if present (remove this entry if you don't want ICC copied)
        '-ICC_Profile:All',
        # finalize
        '-overwrite_original',
        $outputFull
    )


  # append Google-style hdrgm/GContainer XMP metadata (padding=0)
  Write-Host "> appending Google hdrgm/GContainer XMP metadata"
  $mpLen = (& exiftool -s -s -s -MPImage2:MPImageLength $outputFull)
  if ($mpLen) {
      Invoke-External -File 'exiftool' -Args @(
          '-overwrite_original',
          '-XMP-hdrgm:Version=1.0',
          '-XMP-GContainer:DirectoryItemMime+=image/jpeg',
          '-XMP-GContainer:DirectoryItemSemantic+=Primary',
          '-XMP-GContainer:DirectoryItemSemantic+=GainMap',
          '-XMP-GContainer:DirectoryItemLength+=0',
          "-XMP-GContainer:DirectoryItemLength+=$mpLen",
          '-XMP-GContainer:DirectoryItemPadding+=0',
          $outputFull
      )
  } else {
      Write-Warning "MPImage2 length not found; skipping Google XMP."
  }

}
finally {
  if (Test-Path $tempDir) {
    try { Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
}
