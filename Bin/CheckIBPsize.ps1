param(
    [string]$InputFile = "input.mp4"
)

# Check if ffprobe is available
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    Write-Error "ffprobe not found, please install FFmpeg and add it to the environment variables."
    exit 1
}

# Check if input file exists
if (-not (Test-Path $InputFile)) {
    Write-Error "Input file $InputFile not found"
    exit 1
}

# Generate frames.csv
$csvPath = "frames.csv"
ffprobe -show_frames -select_streams v:0 -print_format csv $InputFile > $csvPath

# Define header
$header = @(
    "frame",
    "media_type",
    "stream_index",
    "key_frame",
    "pkt_pts",
    "pkt_pts_time",
    "pkt_dts",
    "pkt_dts_time",
    "best_effort_timestamp",
    "best_effort_timestamp_time",
    "pkt_duration",
    "pkt_duration_time",
    "pkt_pos",
    "pkt_size",
    "width",
    "height",
    "unknown1",
    "unknown2",
    "unknown3",
    "unknown4",
    "pix_fmt",
    "sample_aspect_ratio",
    "pict_type"
)

# Count I/P/B frame numbers and total bytes
Import-Csv -Path $csvPath -Header $header |
    Where-Object { $_.pict_type -in @('I','P','B') } |
    Group-Object pict_type |
    ForEach-Object {
        $type = $_.Name
        $count = $_.Count
        $total = ($_.Group | Measure-Object -Property pkt_size -Sum).Sum
        [PSCustomObject]@{
            FrameType = $type
            FrameCount = $count
            TotalBytes = $total
        }
    } | Format-Table -AutoSize

pause
