# Junta as partes de src\ no TurboPC.ps1 e gera TurboPC.exe (interface) e TurboPC-Auto-Recomendado/Escritorio/Jogos.exe
# (sem janela), todos exigindo administrador.
# Uso: powershell -ExecutionPolicy Bypass -File build.ps1            (gera o .ps1 e compila os .exe)
#      powershell -ExecutionPolicy Bypass -File build.ps1 -SoGerar   (só gera o TurboPC.ps1)
param([switch]$SoGerar)
$ErrorActionPreference = 'Stop'
$root   = $PSScriptRoot
$srcDir = Join-Path $root 'src'
$src    = Join-Path $root 'TurboPC.ps1'
$out    = Join-Path $root 'dist'
$ico    = Join-Path $root 'TurboPC.ico'

# "#include caminho" puxa outra parte; a linha "# [parte] ..." do topo de cada arquivo é só descrição e fica de fora
function Expand-Part([string]$Path) {
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        if ($line -match '^\s*#include\s+(\S+)\s*$') { Expand-Part (Join-Path $srcDir $Matches[1]) }
        elseif ($line -notmatch '^# \[parte\] ') { $line }
    }
}
$banner = '# ARQUIVO GERADO pelo build.ps1 a partir da pasta src\. Não edite aqui: edite os arquivos em src\ e rode o build.'
$lines  = @($banner) + @(Expand-Part (Join-Path $srcDir 'TurboPC.main.ps1'))
$text   = ($lines -join "`r`n") + "`r`n"
$errs   = $null
[void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errs)
if ($errs) { throw "O TurboPC.ps1 gerado tem erro de sintaxe na linha $($errs[0].Extent.StartLineNumber): $($errs[0].Message)" }
# o PowerShell 5.1 precisa de UTF-8 com BOM para os acentos
[IO.File]::WriteAllText($src, $text, (New-Object Text.UTF8Encoding $true))
"TurboPC.ps1 gerado: $($lines.Count) linhas"
if ($SoGerar) { return }
New-Item -ItemType Directory -Path $out -Force | Out-Null

if (-not (Test-Path $ico)) {
    Add-Type -AssemblyName System.Drawing
    $frames = foreach ($size in 256, 48, 32, 16) {
        $bmp = New-Object Drawing.Bitmap $size, $size
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([Drawing.Color]::Transparent)
        $s = $size / 256.0
        $r = 56 * $s
        $path = New-Object Drawing.Drawing2D.GraphicsPath
        $path.AddArc(0, 0, $r, $r, 180, 90)
        $path.AddArc($size - $r - 1, 0, $r, $r, 270, 90)
        $path.AddArc($size - $r - 1, $size - $r - 1, $r, $r, 0, 90)
        $path.AddArc(0, $size - $r - 1, $r, $r, 90, 90)
        $path.CloseFigure()
        $grad = New-Object Drawing.Drawing2D.LinearGradientBrush (New-Object Drawing.Point 0, 0), (New-Object Drawing.Point $size, $size),
            ([Drawing.Color]::FromArgb(124, 92, 255)), ([Drawing.Color]::FromArgb(34, 211, 238))
        $g.FillPath($grad, $path)
        $bolt = [Drawing.PointF[]]@(
            (New-Object Drawing.PointF (146*$s), (34*$s)),
            (New-Object Drawing.PointF (70*$s),  (142*$s)),
            (New-Object Drawing.PointF (124*$s), (142*$s)),
            (New-Object Drawing.PointF (106*$s), (222*$s)),
            (New-Object Drawing.PointF (188*$s), (108*$s)),
            (New-Object Drawing.PointF (134*$s), (108*$s))
        )
        $g.FillPolygon([Drawing.Brushes]::White, $bolt)
        $g.Dispose()
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        [pscustomobject]@{ Size = $size; Bytes = $ms.ToArray() }
    }
    $fs = [IO.File]::Create($ico)
    $bw = New-Object IO.BinaryWriter $fs
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$frames.Count)
    $offset = 6 + 16 * $frames.Count
    foreach ($f in $frames) {
        $dim = if ($f.Size -ge 256) { 0 } else { $f.Size }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$f.Bytes.Length); $bw.Write([uint32]$offset)
        $offset += $f.Bytes.Length
    }
    foreach ($f in $frames) { $bw.Write($f.Bytes) }
    $bw.Close()
}

Import-Module ps2exe
# versão vem do próprio TurboPC.ps1 ($AppVersion), para não ter dois lugares para trocar
$appVersion = [regex]::Match($text, "\`$AppVersion\s*=\s*'(\d+\.\d+\.\d+)'").Groups[1].Value
if (-not $appVersion) { throw 'Não achei $AppVersion no TurboPC.ps1' }
$common = @{
    inputFile   = $src
    iconFile    = $ico
    requireAdmin = $true
    STA         = $true
    x64         = $true
    title       = 'TurboPC'
    description = 'Otimizador para Windows 10/11'
    product     = 'TurboPC'
    version     = "$appVersion.0"
    copyright   = "(c) $(Get-Date -Format yyyy) William Silva Esquilino"
    company     = 'William Silva Esquilino'
}
Invoke-ps2exe @common -outputFile (Join-Path $out 'TurboPC.exe') -noConsole -noOutput -noError
# o nome do arquivo define o perfil do modo automático (ver início do TurboPC.ps1)
Remove-Item (Join-Path $out 'TurboPC-Auto.exe') -ErrorAction SilentlyContinue
Invoke-ps2exe @common -outputFile (Join-Path $out 'TurboPC-Auto-Recomendado.exe')
Invoke-ps2exe @common -outputFile (Join-Path $out 'TurboPC-Auto-Escritorio.exe')
Invoke-ps2exe @common -outputFile (Join-Path $out 'TurboPC-Auto-Jogos.exe')
Get-ChildItem $out -Filter *.exe | Format-Table Name, @{n='KB';e={[int]($_.Length/1KB)}} -AutoSize
