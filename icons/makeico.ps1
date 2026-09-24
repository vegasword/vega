Add-Type -AssemblyName System.Drawing

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $here "logo.png"
$target = Join-Path $here "vega.ico"
$sizes = @(16, 24, 32, 48, 64, 128, 256)

if ((Test-Path $target) -and ((Get-Item $target).LastWriteTime -gt (Get-Item $source).LastWriteTime)) {
    exit 0
}

$logo = [System.Drawing.Image]::FromFile($source)
$payloads = @()

foreach ($size in $sizes) {
    $canvas = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($canvas)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    $pad = [Math]::Max(0, [int]($size * 0.02))
    $room = $size - 2 * $pad
    $scale = [Math]::Min($room / $logo.Width, $room / $logo.Height)
    $w = $logo.Width * $scale
    $h = $logo.Height * $scale
    $g.DrawImage($logo, (New-Object System.Drawing.RectangleF (($size - $w) / 2), (($size - $h) / 2), $w, $h))
    $g.Dispose()

    $stream = New-Object System.IO.MemoryStream
    $canvas.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $canvas.Dispose()
    $payloads += , $stream.ToArray()
    $stream.Dispose()
}
$logo.Dispose()

$out = New-Object System.IO.MemoryStream
$writer = New-Object System.IO.BinaryWriter $out
$writer.Write([uint16]0)
$writer.Write([uint16]1)
$writer.Write([uint16]$sizes.Count)

$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $side = $(if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] })
    $writer.Write([byte]$side)
    $writer.Write([byte]$side)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]32)
    $writer.Write([uint32]$payloads[$i].Length)
    $writer.Write([uint32]$offset)
    $offset += $payloads[$i].Length
}
foreach ($payload in $payloads) { $writer.Write($payload) }
$writer.Flush()
[System.IO.File]::WriteAllBytes($target, $out.ToArray())
$writer.Dispose(); $out.Dispose()
