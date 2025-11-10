param(
    [Parameter(Mandatory=$true)]
    [string]$InputFile,

    [Parameter(Mandatory=$true)]
    [string]$OutputFile
)

# 检查 exiftool 是否可用
if (-not (Get-Command exiftool -ErrorAction SilentlyContinue)) {
    Write-Error "exiftool is not installed or not in PATH. Please install exiftool first."
    exit 1
}

# 检查输入文件是否存在
if (-not (Test-Path $InputFile)) {
    Write-Error "Input file '$InputFile' does not exist."
    exit 1
}

# 使用 exiftool 提取 HDRHeadroom 和 HDRGain
try {
    $exifData = & exiftool -s -HDRHeadroom -HDRGain $InputFile
} catch {
    Write-Error "Failed to run exiftool on '$InputFile'."
    exit 1
}

# 解析输出
$hdrHeadroom = $null
$hdrGain = $null

foreach ($line in $exifData) {
    if ($line -match "^HDRHeadroom\s*:\s*(.+)") {
        $hdrHeadroom = [double]$matches[1]
    } elseif ($line -match "^HDRGain\s*:\s*(.+)") {
        $hdrGain = [double]$matches[1]
    }
}

if ($hdrHeadroom -eq $null -or $hdrGain -eq $null) {
    Write-Error "Failed to extract HDRHeadroom or HDRGain from '$InputFile'. Ensure it's an Apple HDR HEIC file."
    exit 1
}

# 计算 headroom (基于 apple-hdr-heic 的逻辑)
$stops = 0.0
if ($hdrHeadroom -lt 1.0) {
    if ($hdrGain -le 0.01) {
        $stops = -20.0 * $hdrGain + 1.8
    } else {
        $stops = -0.101 * $hdrGain + 1.601
    }
} else {
    if ($hdrGain -le 0.01) {
        $stops = -70.0 * $hdrGain + 3.0
    } else {
        $stops = -0.303 * $hdrGain + 2.303
    }
}

$headroom = [Math]::Pow(2.0, [Math]::Max($stops, 0.0))

# 生成 ultrahdr_app 兼容的 metadata.cfg
$metadataContent = @"
--maxContentBoost $headroom $headroom $headroom
--minContentBoost 1.0 1.0 1.0
--gamma 1.0 1.0 1.0
--offsetSdr 0.0 0.0 0.0
--offsetHdr 0.0 0.0 0.0
--hdrCapacityMin 1.0
--hdrCapacityMax $headroom
--useBaseColorSpace 1
"@

# 写入输出文件
try {
    $metadataContent | Out-File -FilePath $OutputFile -Encoding ASCII
    Write-Host "Metadata extracted and saved to '$OutputFile'."
} catch {
    Write-Error "Failed to write to '$OutputFile'."
    exit 1
}