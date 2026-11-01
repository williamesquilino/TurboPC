# [parte] Monitor ao vivo: medição, medidores e gráficos
# ---------------------------------------------------------------- monitor em tempo real
# Thread separada que lê os contadores de desempenho do Windows uma vez por segundo enquanto a aba Monitor está aberta.
$monitorWorker = {
    param($sync)
    function New-PC([string]$Cat, [string]$Ctr, [string]$Inst = '') {
        try { $c = New-Object Diagnostics.PerformanceCounter $Cat, $Ctr, $Inst, $true; [void]$c.NextValue(); $c } catch { $null }
    }
    function Get-Val($c) { if ($c) { try { return [double]$c.NextValue() } catch {} }; 0.0 }

    $cpu = New-PC 'Processor Information' '% Processor Utility' '_Total'
    if (-not $cpu) { $cpu = New-PC 'Processor' '% Processor Time' '_Total' }
    $idle   = New-PC 'PhysicalDisk' '% Idle Time' '_Total'
    $dRead  = New-PC 'PhysicalDisk' 'Disk Read Bytes/sec' '_Total'
    $dWrite = New-PC 'PhysicalDisk' 'Disk Write Bytes/sec' '_Total'
    $avail  = New-PC 'Memory' 'Available Bytes'
    $ramTotal = [double](Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    $gpuCat = try { New-Object Diagnostics.PerformanceCounterCategory 'GPU Engine' } catch { $null }
    $gpuPrev = $null
    $nets = @(); $netAt = [datetime]::MinValue
    $cpuPrev = @{}; $procAt = $null
    $cores = [Environment]::ProcessorCount
    $tick = 0

    while (-not $sync.Quit) {
        if (-not $sync.MonActive) { Start-Sleep -Milliseconds 300; continue }
        $t0 = [datetime]::Now
        if (($t0 - $netAt).TotalSeconds -ge 30) {
            $nets = @()
            try {
                foreach ($n in (New-Object Diagnostics.PerformanceCounterCategory 'Network Interface').GetInstanceNames()) {
                    $nets += ,@((New-PC 'Network Interface' 'Bytes Received/sec' $n), (New-PC 'Network Interface' 'Bytes Sent/sec' $n))
                }
            } catch {}
            $netAt = $t0
        }
        $m = @{}
        $m.Cpu   = [math]::Min(100.0, (Get-Val $cpu))
        $m.Disk  = if ($idle) { [math]::Max(0.0, [math]::Min(100.0, 100 - (Get-Val $idle))) } else { 0 }
        $m.DiskR = Get-Val $dRead
        $m.DiskW = Get-Val $dWrite
        $m.RamTotal = $ramTotal
        $m.RamUsed  = $ramTotal - (Get-Val $avail)
        $down = 0.0; $up = 0.0
        foreach ($n in $nets) { $down += Get-Val $n[0]; $up += Get-Val $n[1] }
        $m.Down = $down; $m.Up = $up

        # GPU: soma o uso de cada motor (3D, vídeo, cópia) entre os processos e mostra o motor mais ocupado, como o Gerenciador de Tarefas
        $m.Gpu = -1
        if ($gpuCat) {
            try {
                $all = $gpuCat.ReadCategory()
                $key = @($all.Keys) | Where-Object { $_ -match 'tiliz' } | Select-Object -First 1
                $cur = $all[$key]
                if ($gpuPrev) {
                    $grp = @{}
                    foreach ($s in $cur.Values) {
                        $p = $gpuPrev[$s.InstanceName]
                        if (-not $p) { continue }
                        $grp[($s.InstanceName -replace '^.*?_luid_', '')] += [Diagnostics.CounterSample]::Calculate($p.Sample, $s.Sample)
                    }
                    $m.Gpu = [math]::Min(100.0, [double](($grp.Values | Measure-Object -Maximum).Maximum))
                }
                $gpuPrev = $cur
            } catch { $gpuCat = $null }
        }

        # processos agrupados por nome (Chrome com 30 abas vira uma linha só)
        if ($tick % 2 -eq 0) {
            $now  = [datetime]::Now
            $span = if ($procAt) { ($now - $procAt).TotalMilliseconds } else { 0 }
            $procAt = $now
            $agg = @{}; $seen = @{}; $count = 0
            foreach ($p in [Diagnostics.Process]::GetProcesses()) {
                $count++
                if ($p.Id -le 4) { $p.Dispose(); continue }
                $ms = 0.0
                try { $ms = $p.TotalProcessorTime.TotalMilliseconds } catch {}
                $seen[$p.Id] = $ms
                $d = if ($span -gt 0 -and $cpuPrev.ContainsKey($p.Id)) { [math]::Max(0.0, $ms - $cpuPrev[$p.Id]) } else { 0 }
                $name = $p.ProcessName
                if (-not $agg.ContainsKey($name)) { $agg[$name] = @{ Name = $name; Cpu = 0.0; Ram = [int64]0; Count = 0 } }
                $a = $agg[$name]
                $a.Cpu += $d; $a.Ram += $p.WorkingSet64; $a.Count++
                $p.Dispose()
            }
            $cpuPrev = $seen
            foreach ($a in $agg.Values) { $a.Cpu = if ($span -gt 0) { [math]::Min(100.0, 100 * $a.Cpu / ($span * $cores)) } else { 0 } }
            $sortKey = if ($sync.ProcSort -eq 'ram') { 'Ram' } else { 'Cpu' }
            $sync.Procs = @($agg.Values | Sort-Object { $_[$sortKey] }, { $_.Ram } -Descending | Select-Object -First 14)
            $sync.ProcCount = $count
        }
        $sync.Mon = $m
        $sync.MonSeq++
        $tick++
        $wait = 1000 - ([datetime]::Now - $t0).TotalMilliseconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
    }
}

$HistLen = 60
$script:Hist = @{}
foreach ($k in 'Cpu','Ram','Gpu','Disk','Down','Up') { $script:Hist[$k] = New-Object 'System.Collections.Generic.List[double]' }
$script:MonSeq = -1
$script:LastProcs = $null
$ProtectedProcs = 'system','idle','registry','smss','csrss','wininit','winlogon','services','lsass','lsaiso','svchost','dwm',
                  'fontdrvhost','memory compression','msmpeng','nissrv','securityhealthservice','sihost','ctfmon','explorer','audiodg',
                  [Diagnostics.Process]::GetCurrentProcess().ProcessName.ToLower()

function Format-Rate([double]$b) {
    if ($b -ge 1MB) { '{0:N1} MB/s' -f ($b / 1MB) } elseif ($b -ge 1KB) { '{0:N0} KB/s' -f ($b / 1KB) } else { '{0:N0} B/s' -f $b }
}

function Push-Hist([string]$Key, [double]$Value) {
    $l = $script:Hist[$Key]
    $l.Add($Value)
    if ($l.Count -gt $HistLen) { $l.RemoveAt(0) }
}

# Cor com transparência a partir de "#RRGGBB"
function Get-Color([string]$Hex, [byte]$Alpha = 255) {
    $c = [Windows.Media.ColorConverter]::ConvertFromString($Hex)
    [Windows.Media.Color]::FromArgb($Alpha, $c.R, $c.G, $c.B)
}

# Curva suave (Catmull-Rom convertida em Bézier) passando pelos pontos; com -Area fecha até a base para preencher
function New-SmoothFigure([Windows.Point[]]$P, [double]$Height, [switch]$Area) {
    $fig = New-Object Windows.Media.PathFigure
    $n = $P.Count
    if ($Area) {
        $fig.StartPoint = [Windows.Point]::new($P[0].X, $Height)
        $fig.Segments.Add([Windows.Media.LineSegment]::new($P[0], $false))
    } else {
        $fig.StartPoint = $P[0]
    }
    for ($i = 0; $i -lt $n - 1; $i++) {
        $p0 = $P[[math]::Max(0, $i - 1)]; $p1 = $P[$i]; $p2 = $P[$i + 1]; $p3 = $P[[math]::Min($n - 1, $i + 2)]
        $c1 = [Windows.Point]::new($p1.X + ($p2.X - $p0.X) / 6, [math]::Min($Height, [math]::Max(0.0, $p1.Y + ($p2.Y - $p0.Y) / 6)))
        $c2 = [Windows.Point]::new($p2.X - ($p3.X - $p1.X) / 6, [math]::Min($Height, [math]::Max(0.0, $p2.Y - ($p3.Y - $p1.Y) / 6)))
        $fig.Segments.Add([Windows.Media.BezierSegment]::new($c1, $c2, $p2, $true))
    }
    if ($Area) {
        $fig.Segments.Add([Windows.Media.LineSegment]::new([Windows.Point]::new($P[$n - 1].X, $Height), $false))
        $fig.IsClosed = $true
    }
    $g = New-Object Windows.Media.PathGeometry
    $g.Figures.Add($fig)
    $g
}

# Gráfico de área com curva suave, degradê embaixo e um ponto no valor atual. -Grid desenha linhas-guia.
function Draw-Chart($Canvas, [object[]]$Series, [double]$Max, [switch]$Grid) {
    $w = $Canvas.ActualWidth; $h = $Canvas.ActualHeight
    if ($w -le 0 -or $h -le 0) { return }
    $Canvas.Children.Clear()
    if ($Grid) {
        foreach ($k in 1..3) {
            $ln = New-Object Windows.Shapes.Line
            $ln.X1 = 0; $ln.X2 = $w; $ln.Y1 = [math]::Round($h * $k / 4) + 0.5; $ln.Y2 = $ln.Y1
            $ln.Stroke = '#222736'; $ln.StrokeThickness = 1; $ln.StrokeDashArray = New-Object Windows.Media.DoubleCollection (,[double[]]@(3, 4))
            [void]$Canvas.Children.Add($ln)
        }
    }
    $step = $w / ($HistLen - 1)
    $top = 5.0
    foreach ($s in $Series) {
        $vals = $s.Values; $n = $vals.Count
        if ($n -lt 2) { continue }
        $x0 = $w - ($n - 1) * $step
        $pts = [Windows.Point[]]@(for ($i = 0; $i -lt $n; $i++) {
            [Windows.Point]::new($x0 + $i * $step, $h - 1.5 - [math]::Min(1.0, $vals[$i] / $Max) * ($h - 1.5 - $top))
        })
        $area = New-Object Windows.Shapes.Path
        $area.Data = New-SmoothFigure $pts $h -Area
        $area.Fill = New-Object Windows.Media.LinearGradientBrush ((Get-Color $s.Color 105), (Get-Color $s.Color 0), 90.0)
        [void]$Canvas.Children.Add($area)
        $line = New-Object Windows.Shapes.Path
        $line.Data = New-SmoothFigure $pts $h
        $line.Stroke = New-Object Windows.Media.SolidColorBrush (Get-Color $s.Color)
        $line.StrokeThickness = 2; $line.StrokeLineJoin = 'Round'
        [void]$Canvas.Children.Add($line)
        $last = $pts[$n - 1]
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width = 9; $dot.Height = 9; $dot.Fill = $line.Stroke; $dot.Stroke = '#171B24'; $dot.StrokeThickness = 2
        [Windows.Controls.Canvas]::SetLeft($dot, $last.X - 7); [Windows.Controls.Canvas]::SetTop($dot, $last.Y - 4.5)
        [void]$Canvas.Children.Add($dot)
    }
}

# Arco de velocímetro (270°, abrindo embaixo) para os medidores 150x124
function New-GaugeArc([double]$Pct) {
    $cx = 75.0; $cy = 66.0; $r = 54.0
    $sweep = [math]::Max(0.6, 270.0 * [math]::Max(0.0, [math]::Min(100.0, $Pct)) / 100)
    $at = { param($deg) $rad = $deg * [math]::PI / 180; [Windows.Point]::new($cx + $r * [math]::Cos($rad), $cy + $r * [math]::Sin($rad)) }
    $fig = New-Object Windows.Media.PathFigure
    $fig.StartPoint = & $at 135.0
    $fig.Segments.Add([Windows.Media.ArcSegment]::new((& $at (135.0 + $sweep)), [Windows.Size]::new($r, $r), 0.0, ($sweep -gt 180), [Windows.Media.SweepDirection]::Clockwise, $true))
    $g = New-Object Windows.Media.PathGeometry
    $g.Figures.Add($fig)
    $g
}

# Palavra simples para quem não entende porcentagem
function Get-LoadState([double]$Pct) {
    if ($Pct -lt 50) { 'Tranquilo', '#4ADE80' } elseif ($Pct -lt 80) { 'Moderado', '#F5A524' } else { 'Pesado', '#F87171' }
}

function Set-Gauge([string]$Key, [double]$Pct, [string]$Text) {
    $ui["Gauge$($Key)Arc"].Data = New-GaugeArc $Pct
    $state, $color = Get-LoadState $Pct
    $ui["Gauge$($Key)Arc"].Stroke = New-Object Windows.Media.LinearGradientBrush ((Get-Color $color 150), (Get-Color $color), 0.0)
    $ui["Mon$Key"].Text = $Text
    $ui["Mon$($Key)State"].Text = $state
    $ui["Mon$($Key)State"].Foreground = $color
}

foreach ($g in $GaugeDefs) { $ui["Gauge$($g.Key)Track"].Data = New-GaugeArc 100 }

function Update-ProcList {
    $script:LastProcs = $sync.Procs
    $selName = if ($ui.ProcList.SelectedItem) { $ui.ProcList.SelectedItem.Tag } else { $null }
    $ui.ProcList.Items.Clear()
    foreach ($p in $script:LastProcs) {
        $g = New-Object Windows.Controls.Grid
        foreach ($wd in 0, 90, 110, 80) {
            $cd = New-Object Windows.Controls.ColumnDefinition
            $cd.Width = if ($wd) { New-Object Windows.GridLength $wd } else { New-Object Windows.GridLength 1, 'Star' }
            $g.ColumnDefinitions.Add($cd)
        }
        $cpuColor = if ($p.Cpu -ge 50) { '#F87171' } elseif ($p.Cpu -ge 15) { '#F5A524' } else { '#D5D9E3' }
        $cells = @(
            @($p.Name, '#F1F3F8', 'Left'),
            @(('{0:N1}%' -f $p.Cpu), $cpuColor, 'Right'),
            @((Format-Size $p.Ram), '#D5D9E3', 'Right'),
            @("$($p.Count)", '#8A91A3', 'Right')
        )
        for ($i = 0; $i -lt 4; $i++) {
            $tb = New-Object Windows.Controls.TextBlock
            $tb.Text = $cells[$i][0]; $tb.Foreground = $cells[$i][1]; $tb.HorizontalAlignment = $cells[$i][2]
            $tb.FontSize = 13; $tb.TextTrimming = 'CharacterEllipsis'
            [Windows.Controls.Grid]::SetColumn($tb, $i)
            [void]$g.Children.Add($tb)
        }
        $item = New-Object Windows.Controls.ListBoxItem
        $item.Content = $g; $item.Tag = $p.Name
        [void]$ui.ProcList.Items.Add($item)
        if ($p.Name -eq $selName) { $item.IsSelected = $true }
    }
}

function Update-Monitor {
    $m = $sync.Mon
    if (-not $m) { return }
    $ramPct = 100 * $m.RamUsed / $m.RamTotal
    Push-Hist Cpu $m.Cpu; Push-Hist Ram $ramPct; Push-Hist Disk $m.Disk
    Push-Hist Gpu ([math]::Max(0, $m.Gpu)); Push-Hist Down $m.Down; Push-Hist Up $m.Up

    Set-Gauge Cpu $m.Cpu ('{0:N0}%' -f $m.Cpu)
    $ui.MonCpuSub.Text = "$($sync.ProcCount) processos abertos"
    Set-Gauge Ram $ramPct ('{0:N0}%' -f $ramPct)
    $ui.MonRamSub.Text = "$(Format-Size $m.RamUsed) de $(Format-Size $m.RamTotal)"
    if ($m.Gpu -ge 0) {
        Set-Gauge Gpu $m.Gpu ('{0:N0}%' -f $m.Gpu)
    } else {
        Set-Gauge Gpu 0 'n/d'; $ui.MonGpuState.Text = 'sem leitura'; $ui.MonGpuState.Foreground = '#8A91A3'
    }
    $ui.MonGpuSub.Text = $ui.InfoGPU.Text
    Set-Gauge Disk $m.Disk ('{0:N0}%' -f $m.Disk)
    $ui.MonDiskSub.Text = "Lê $(Format-Rate $m.DiskR)  ·  grava $(Format-Rate $m.DiskW)"

    $ui.MonNet.Text = Format-Rate $m.Down
    $ui.MonNetSub.Text = Format-Rate $m.Up
    $peakDown = [double]($script:Hist.Down | Measure-Object -Maximum).Maximum
    $peakUp   = [double]($script:Hist.Up | Measure-Object -Maximum).Maximum
    $ui.MonNetPeak.Text = "Pico no último minuto: $(Format-Rate $peakDown) recebendo  ·  $(Format-Rate $peakUp) enviando"
    $netMax = [math]::Max([double]128KB, [math]::Max($peakDown, $peakUp)) * 1.15

    foreach ($g in $GaugeDefs) { Draw-Chart $ui["Chart$($g.Key)"] @(@{ Values = $script:Hist[$g.Key]; Color = $g.Color }) 100 }
    Draw-Chart $ui.ChartNet @(@{ Values = $script:Hist.Down; Color = '#4ADE80' }, @{ Values = $script:Hist.Up; Color = '#60A5FA' }) $netMax -Grid

    if ($sync.Procs -and -not [object]::ReferenceEquals($sync.Procs, $script:LastProcs)) { Update-ProcList }
}

function Update-Drives {
    $ui.PanelDrives.Children.Clear()
    foreach ($d in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue) {
        if (-not $d.Size) { continue }
        $pct = [int](100 * ($d.Size - $d.FreeSpace) / $d.Size)
        $color = if ($pct -ge 90) { '#F87171' } elseif ($pct -ge 80) { '#F5A524' } else { '#7C5CFF' }
        if ($d.DeviceID -eq $env:SystemDrive) {
            # anel grande: unidade do Windows. Circunferência em unidades de espessura do traço: pi * (118 - 12) / 12
            $ui.DiskRing.StrokeDashArray = New-Object Windows.Media.DoubleCollection (,[double[]]@((([math]::PI * 106 / 12) * $pct / 100), 1000))
            $ui.DiskRing.Stroke = $color
            $ui.DiskPct.Text = "$pct%"
        }
        $label = if ($d.VolumeName) { "$($d.DeviceID) $($d.VolumeName)" } else { $d.DeviceID }
        $x = @"
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Margin="0,0,0,10">
  <DockPanel>
    <TextBlock DockPanel.Dock="Right" Text="$(Esc "$(Format-Size $d.FreeSpace) livres")" Foreground="#8A91A3" FontSize="12"/>
    <TextBlock Text="$(Esc $label)" Foreground="#F1F3F8" FontSize="13" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
  </DockPanel>
  <ProgressBar Height="6" Margin="0,6,0,0" Maximum="100" Value="$pct" Foreground="$color" Background="#262B37" BorderThickness="0"/>
</StackPanel>
"@
        [void]$ui.PanelDrives.Children.Add([Windows.Markup.XamlReader]::Parse($x))
    }
}

