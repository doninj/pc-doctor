# Génère le logo de PC Doctor : PCDoctor.ico (16 à 256 px) et PCDoctor.png (256 px)
param([string]$OutDir = $PSScriptRoot)
Add-Type -AssemblyName System.Drawing

function New-LogoBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)

    # Carré arrondi avec dégradé bleu -> violet
    $pad = [math]::Max(0.5, $size * 0.03)
    $r = $size * 0.23
    $w = $size - 2 * $pad
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $path.AddArc($pad, $pad, $d, $d, 180, 90)
    $path.AddArc($pad + $w - $d, $pad, $d, $d, 270, 90)
    $path.AddArc($pad + $w - $d, $pad + $w - $d, $d, $d, 0, 90)
    $path.AddArc($pad, $pad + $w - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $rect = New-Object System.Drawing.RectangleF(0, 0, $size, $size)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, [System.Drawing.Color]::FromArgb(255, 0x4F, 0x86, 0xFF), [System.Drawing.Color]::FromArgb(255, 0x8B, 0x5C, 0xF6), 45)
    $g.FillPath($brush, $path)

    # Léger reflet en haut
    if ($size -ge 48) {
        $hlRect = New-Object System.Drawing.RectangleF(0, 0, $size, ($size * 0.5 + 1))
        $hl = New-Object System.Drawing.Drawing2D.LinearGradientBrush($hlRect, [System.Drawing.Color]::FromArgb(40, 255, 255, 255), [System.Drawing.Color]::FromArgb(0, 255, 255, 255), 90)
        $g.SetClip($path)
        $g.FillRectangle($hl, 0, 0, $size, $size * 0.5)
        $g.ResetClip()
    }

    # Ligne de pouls (électrocardiogramme) blanche
    $pts = @(@(0.15, 0.55), @(0.35, 0.55), @(0.43, 0.33), @(0.53, 0.75), @(0.61, 0.28), @(0.69, 0.55), @(0.85, 0.55))
    $pf = foreach ($p in $pts) { New-Object System.Drawing.PointF(($p[0] * $size), ($p[1] * $size)) }
    $thick = [math]::Max(1.6, $size * 0.078)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, $thick)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $g.DrawLines($pen, [System.Drawing.PointF[]]$pf)

    $g.Dispose()
    return $bmp
}

$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = foreach ($s in $sizes) {
    $b = New-LogoBitmap $s
    $ms = New-Object System.IO.MemoryStream
    $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    if ($s -eq 256) { $b.Save((Join-Path $OutDir 'PCDoctor.png'), [System.Drawing.Imaging.ImageFormat]::Png) }
    $b.Dispose()
    , $ms.ToArray()
}

# Fichier .ico (entrées PNG, format Windows Vista et suivants)
$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($out)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $data = $pngs[$i]
    $bw.Write([byte]$(if ($s -ge 256) { 0 } else { $s })); $bw.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$data.Length); $bw.Write([uint32]$offset)
    $offset += $data.Length
}
foreach ($data in $pngs) { $bw.Write([byte[]]$data) }
$bw.Flush()
[IO.File]::WriteAllBytes((Join-Path $OutDir 'PCDoctor.ico'), $out.ToArray())
"Logo généré : $(Join-Path $OutDir 'PCDoctor.ico')"
