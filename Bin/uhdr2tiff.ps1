<#
.SYNOPSIS
  将 UltraHDR 兼容的 JPEG（含 gain map）解码并转换为 HLG 或 PQ 的 TIFF。

.DESCRIPTION
  该脚本调用 ultrahdr_app.exe 将 UltraHDR 输入解码为 10bit 打包的 RGBA1010102 原始数据，
  再用 ffmpeg 按指定位深封装为 TIFF。

  色彩空间行为说明：
  - ultrahdr_app.exe 在解码时保持原始 UltraHDR 文件的色彩空间不变（cg 字段从解码器获取）。
  - 传输函数根据 -Transfer 参数转换为 PQ 或 HLG，但色彩空间本身不改变。
  - 在 uhdr->tiff 过程中，色彩空间信息在 UltraHDR->raw 阶段是"传透"的，但在 raw->TIFF 阶段
    没有完整传透（FFmpeg 默认不嵌入色彩空间元数据，除非明确指定 primaries/colorspace）。

.PARAMETER InputPath
  UltraHDR 兼容输入文件路径（通常是 .jpg）。

.PARAMETER OutputPath
  输出 TIFF 路径（.tiff 或 .tif）。

.PARAMETER Transfer
  输出传输函数：'hlg' 或 'pq'（默认 'hlg'）。

.PARAMETER BitDepth
  输出 TIFF 位深：8 或 16（默认 16）。

.REQUIREMENTS
  需在 PATH 中可找到：ultrahdr_app.exe、ffprobe、ffmpeg。

.EXAMPLE
  # 转换为 HLG 16bit TIFF（BT.2020）
  pwsh .\uhdr2tiff.ps1 -InputPath .\hdr.jpg -OutputPath .\out_hlg_16b.tiff -Transfer hlg -BitDepth 16

.EXAMPLE
  # 转换为 HLG 8bit TIFF
  pwsh .\uhdr2tiff.ps1 -InputPath .\hdr.jpg -OutputPath .\out_hlg_8b.tiff -Transfer hlg -BitDepth 8
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

function Test-Tool {
  param([Parameter(Mandatory=$true)][string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Command '$Name' not found, ensure it is installed and in PATH."
  }
}

function Get-ImageSize {
  param([Parameter(Mandatory=$true)][string]$Path)
  # 使用 exiftool JSON 输出；ImageWidth/Height 来自文件实际像素而非 EXIF 字段
  $exifJson = & exiftool -j -ImageWidth -ImageHeight $Path 2>$null | ConvertFrom-Json
  if (-not $exifJson -or $exifJson.Count -eq 0) {
    throw "exiftool returned no data for '$Path'."
  }
  $width  = $exifJson[0].ImageWidth  -as [int]
  $height = $exifJson[0].ImageHeight -as [int]
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

try {
  # 1) 工具自检
  Test-Tool -Name 'ultrahdr_app.exe'
  Test-Tool -Name 'ffmpeg'
  Test-Tool -Name 'exiftool'

  # 2) 解析分辨率
  $sz = Get-ImageSize -Path $InputPath
  $w = $sz.Width
  $h = $sz.Height
  Write-Host "Detected resolution: $w x $h"

  # 2a) 通过 exiftool 读取 SDR 底图嵌入的 ICC Profile 描述，判断源色彩原色
  #      ultrahdr_app 解码时不改变色域（cg 字段传透自编码时的 -C 值），
  #      ICC Profile 描述是目前最可靠的来源；未检测到时 fallback 到 sRGB/BT.709
  function Get-SdrColorPrimaries {
    param([string]$Path)
    $exifJson = & exiftool -j '-ICC_Profile:ProfileDescription' $Path 2>$null | ConvertFrom-Json
    $desc = if ($exifJson -and $exifJson.Count -gt 0) { $exifJson[0].ProfileDescription } else { $null }
    Write-Host "Detected ICC ProfileDescription: $(if ($desc) { $desc } else { '(none – fallback to sRGB/BT.709)' })"
    # 注意区分两种 P3：Display P3 (也称 P3‑D65，苹果和大多数现代设备使用) 与 DCI-P3 (P3‑DCI，用于数字影院)
    if ($desc -match 'Display P3' -or $desc -match 'P3 D65') {
      # P3‑D65 -> smpte432
      return @{ FfmpegIn = 'smpte432'; ZscaleIn = 'smpte432'; NeedConvert = $true  }
    } elseif ($desc -match 'DCI.P3') {
      # P3‑DCI -> smpte431
      return @{ FfmpegIn = 'smpte431'; ZscaleIn = 'smpte431'; NeedConvert = $true  }
    } elseif ($desc -match 'BT\.?2020' -or $desc -match 'BT\.?2100' -or $desc -match 'Rec\.?\s*2020') {
      return @{ FfmpegIn = 'bt2020';   ZscaleIn = '2020'; NeedConvert = $false }
    } else {
      # fallback: sRGB / BT.709
      return @{ FfmpegIn = 'bt709';    ZscaleIn = '709';  NeedConvert = $true  }
    }
  }
  $srcColor = Get-SdrColorPrimaries -Path $InputPath
  Write-Host "Mapped source primaries: ffmpeg='$($srcColor.FfmpegIn)', zscale='$($srcColor.ZscaleIn)'"

  # 3) 生成临时 raw 路径
  $tmpName = "uhdr_" + [IO.Path]::GetFileNameWithoutExtension($OutputPath) + "_" + ([Guid]::NewGuid().ToString('N')) + ".raw"
  $tmpRaw  = Join-Path $env:TEMP $tmpName
  Write-Host "Temporary raw: $tmpRaw"

  # 4) Transfer -> ultrahdr_app -o 映射（pq=2, hlg=1）
  $tf = if ($Transfer -eq 'hlg') { 1 } else { 2 }

  # 5) 解码 UltraHDR 为 10bit 打包 raw（RGBA1010102）
  $uhdrArgs = @(
    '-m','1',
    '-j', $InputPath,
    '-o', $tf,
    '-O','5',    # 32bpp RGBA1010102
    '-z', $tmpRaw
  )
  Invoke-External -File 'ultrahdr_app.exe' -Args $uhdrArgs

  # 粗检尺寸：应为 w*h*4 字节
  $expected = [int64]$w * [int64]$h * 4
  $actual = (Get-Item $tmpRaw).Length
  if ($actual -ne $expected) {
    Write-Warning "Raw file size mismatch: $actual vs $expected (expected $w x $h x 4). Continuing anyway."
  }

  # 6) 用 ffmpeg 封装为 TIFF
  $pixIn = 'x2bgr10le'   # R:bits0-9, G:10-19, B:20-29, A:30-31 (BGR order)
  $pixOut = if ($BitDepth -eq 16) { 'rgb48le' } else { 'rgb24' }

  # 可选：为输出加上传输函数元数据标签（某些查看器可能忽略）
  $colorTrc = if ($Transfer -eq 'hlg') { 'arib-std-b67' } else { 'smpte2084' }

  # Route B: 若源色域不是 BT.2020，用 zscale 做像素级色域转换；
  #           需同时在 zscale 中声明 pin/tin，以便滤镜使用正确的变换矩阵
  $vfFilter = ''
  if ($srcColor.NeedConvert) {
    Write-Host "Source primaries '$($srcColor.FfmpegIn)': applying zscale primaries conversion to BT.2020."
    # pin/p  = 输入/输出原色；tin/t = 传输函数（告知 zscale 如何线性化再映射）
    $vfFilter = "zscale=pin=$($srcColor.ZscaleIn):p=bt2020:tin=arib-std-b67:t=arib-std-b67:m=bt2020nc"
  } else {
    Write-Host "Source primaries already BT.2020; no zscale needed."
  }

  # 在 rawvideo 输入端声明源原色与传输函数，确保 ffmpeg 内部管线元数据一致
  $ffArgs = @(
    '-hide_banner',
    '-f', 'rawvideo',
    '-pix_fmt', $pixIn,
    '-s', "${w}x${h}",
    '-color_primaries', $srcColor.FfmpegIn,
    '-color_trc', $colorTrc,
    '-i', $tmpRaw
  )
  if ($vfFilter) { $ffArgs += @('-vf', $vfFilter) }
  $ffArgs += @(
    '-frames:v', '1',
    '-pix_fmt', $pixOut,
    '-color_primaries', 'bt2020',
    '-colorspace', 'bt2020nc',
    '-color_trc', $colorTrc,
    '-y', $OutputPath
  )

  Invoke-External -File 'ffmpeg' -Args $ffArgs

  Write-Host "Completed: $OutputPath"

  # Copy EXIF from input JPEG to output TIFF
  # --ICC_Profile: 排除 ICC Profile — 输出 TIFF 像素已转换为 BT.2020，源 ICC（如 P3）不再适用
  Write-Host "> copying EXIF/XMP metadata to TIFF (excluding ICC_Profile)"
  # Only transfer the EXIF and XMP groups, since the TIFF already has its own
  # BT.2020 color tags; any other metadata (MakerNotes, etc.) is unnecessary.
  Invoke-External -File 'exiftool' -Args @(
      '-TagsFromFile', $InputPath,
      '-exif:all',
      '-xmp:all',
      '--ICC_Profile',
      '-overwrite_original',
      $OutputPath
  )
}
finally {
  if ($tmpRaw -and (Test-Path $tmpRaw)) {
    try { Remove-Item $tmpRaw -Force -ErrorAction SilentlyContinue } catch {}
  }
}
