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
  输出传输函数：'pq' 或 'hlg'（默认 'pq'）。

.PARAMETER BitDepth
  输出 TIFF 位深：8 或 16（默认 16）。

.REQUIREMENTS
  需在 PATH 中可找到：ultrahdr_app.exe、ffprobe、ffmpeg。

.EXAMPLE
  # 转换为 PQ 16bit TIFF
  pwsh .\uhdr2tiff.ps1 -InputPath .\hdr.jpg -OutputPath .\out_pq_16b.tiff -Transfer pq -BitDepth 16

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

try {
  # 1) 工具自检
  Test-Tool -Name 'ultrahdr_app.exe'
  Test-Tool -Name 'ffprobe'
  Test-Tool -Name 'ffmpeg'
  Test-Tool -Name 'exiftool'

  # 2) 解析分辨率
  $sz = Get-ImageSize -Path $InputPath
  $w = $sz.Width
  $h = $sz.Height
  Write-Host "Detected resolution: $w x $h"

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

  $ffArgs = @(
    '-hide_banner',
    '-f','rawvideo',
    '-pix_fmt', $pixIn,
    '-s', "${w}x${h}",
    '-i', $tmpRaw,
    '-frames:v','1',
    '-pix_fmt', $pixOut,
    '-color_trc', $colorTrc,
    '-y', $OutputPath
  )

  Invoke-External -File 'ffmpeg' -Args $ffArgs

  Write-Host "Completed: $OutputPath"

  # Copy EXIF from input JPEG to output TIFF
  Write-Host "> copying EXIF metadata"
  Invoke-External -File 'exiftool' -Args @('-TagsFromFile', $InputPath, '-all:all', '-overwrite_original', $OutputPath)
}
finally {
  if (Test-Path $tmpRaw) {
    try { Remove-Item $tmpRaw -ErrorAction SilentlyContinue } catch {}
  }
}
