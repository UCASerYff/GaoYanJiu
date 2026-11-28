param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function New-RoundedTile([Drawing.Image]$Image) {
    $tile = [Drawing.Bitmap]::new($Image.Width, $Image.Height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($tile)
    $outline = [Drawing.Drawing2D.GraphicsPath]::new()
    $brush = [Drawing.TextureBrush]::new($Image, [Drawing.Drawing2D.WrapMode]::TileFlipXY)
    try {
        [single]$diameter = 0.40 * [Math]::Min($Image.Width, $Image.Height)
        [single]$right = $Image.Width - $diameter
        [single]$bottom = $Image.Height - $diameter
        $outline.AddArc(0, 0, $diameter, $diameter, 180, 90)
        $outline.AddArc($right, 0, $diameter, $diameter, 270, 90)
        $outline.AddArc($right, $bottom, $diameter, $diameter, 0, 90)
        $outline.AddArc(0, $bottom, $diameter, $diameter, 90, 90)
        $outline.CloseFigure()
        $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::Half
        $graphics.FillPath($brush, $outline)
        return $tile
    } catch {
        $tile.Dispose()
        throw
    } finally {
        $brush.Dispose()
        $outline.Dispose()
        $graphics.Dispose()
    }
}

$sizes = @(16, 20, 24, 28, 32, 35, 36, 40, 42, 44, 48, 50, 56, 60, 64, 70, 72, 80, 84, 96, 112, 128, 160, 192, 256)
$image = [Drawing.Image]::FromFile($Source)
try {
    $roundedTile = New-RoundedTile $image
} finally {
    $image.Dispose()
}
$frames = [Collections.Generic.List[object]]::new()
$sampling = [Drawing.Imaging.ImageAttributes]::new()
try {
    # Keep the art at full size and reflect edge samples while resizing the masked original.
    $sampling.SetWrapMode([Drawing.Drawing2D.WrapMode]::TileFlipXY)
    foreach ($size in $sizes) {
        $bitmap = [Drawing.Bitmap]::new($size, $size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $stream = [IO.MemoryStream]::new()
        try {
            $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
            $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::Half
            $destination = [Drawing.Rectangle]::new(0, 0, $size, $size)
            $graphics.DrawImage($roundedTile, $destination, 0, 0, $roundedTile.Width, $roundedTile.Height,
                [Drawing.GraphicsUnit]::Pixel, $sampling)
            $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
            $frames.Add(@{ Size = $size; Bytes = $stream.ToArray() })
        } finally {
            $stream.Dispose()
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }
} finally {
    $sampling.Dispose()
    $roundedTile.Dispose()
}

$writer = [IO.BinaryWriter]::new([IO.File]::Create($OutputPath))
try {
    $writer.Write([UInt16]0)
    $writer.Write([UInt16]1)
    $writer.Write([UInt16]$frames.Count)
    $offset = 6 + 16 * $frames.Count
    foreach ($entry in $frames) {
        $width = [Byte]($entry.Size % 256)
        $writer.Write($width)
        $writer.Write($width)
        $writer.Write([UInt16]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]32)
        $writer.Write([UInt32]$entry.Bytes.Length)
        $writer.Write([UInt32]$offset)
        $offset += $entry.Bytes.Length
    }
    foreach ($entry in $frames) { $writer.Write([Byte[]]$entry.Bytes) }
} finally {
    $writer.Dispose()
}
