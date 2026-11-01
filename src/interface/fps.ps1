# [parte] Teste de FPS (PresentMon)
# ---------------------------------------------------------------- teste de FPS (PresentMon, da Intel)
# O PresentMon lê os quadros pelo próprio Windows (ETW): não toca no jogo, então não mexe com anti-cheat.
$Global:FpsFile = Join-Path $env:ProgramData 'TurboPC\fps.json'

# Analisa o CSV do PresentMon (colunas 1.x): pega o programa com mais quadros e calcula FPS médio e 1% baixo
function Get-FpsFromCsv([string]$Path) {
    $rows = @(Import-Csv -LiteralPath $Path)
    if (-not $rows) { return $null }
    $col = @('MsBetweenPresents', 'FrameTime') | Where-Object { $rows[0].PSObject.Properties.Name -contains $_ } | Select-Object -First 1
    if (-not $col) { return $null }
    $skip = '^(dwm|explorer|TurboPC.*|PresentMon.*|powershell|chrome|msedge|firefox|opera|brave|Discord|Spotify|steamwebhelper|EpicWebHelper|ShellExperienceHost|SearchHost|StartMenuExperienceHost|TextInputHost)\.exe$'
    $g = $rows | Where-Object { $_.Application -and $_.Application -notmatch $skip } | Group-Object Application | Sort-Object Count -Descending | Select-Object -First 1
    if (-not $g) { return $null }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $ms = @($g.Group | ForEach-Object { $v = 0.0; if ([double]::TryParse($_.$col, [Globalization.NumberStyles]::Float, $inv, [ref]$v)) { $v } } | Where-Object { $_ -gt 0 -and $_ -lt 1000 } | Sort-Object)
    if ($ms.Count -lt 30) { return $null }
    $sum = [double](($ms | Measure-Object -Sum).Sum)
    $p99 = $ms[[int][math]::Floor(0.99 * ($ms.Count - 1))]
    [pscustomobject]@{
        Game = ($g.Name -replace '\.exe$', '' -replace '(-Win64)?-Shipping$', '' -replace '_x64$', '')
        Exe = $g.Name; Avg = [math]::Round(1000.0 * $ms.Count / $sum, 1); Low1 = [math]::Round(1000.0 / $p99, 1)
        Frames = $ms.Count; Seconds = [math]::Round($sum / 1000, 1); Date = (Get-Date).ToString('s')
    }
}

$fpsWorker = {
    param($sync, $Delay, $Seconds, $OutFile, $Winget, $Parser)
    function Find-PresentMon {
        foreach ($root in "$env:ProgramFiles\WinGet\Packages", "$env:LOCALAPPDATA\Microsoft\WinGet\Packages") {
            $f = Get-ChildItem -Path $root -Filter 'PresentMon*.exe' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'Service' } | Select-Object -First 1
            if ($f) { return $f.FullName }
        }
        $null
    }
    function Run-Hidden([string]$Exe, [string]$Arguments) {
        $psi = New-Object Diagnostics.ProcessStartInfo $Exe, $Arguments
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $p = [Diagnostics.Process]::Start($psi)
        [pscustomobject]@{ Proc = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
    }
    try {
        . ([scriptblock]::Create($Parser))
        $exe = Find-PresentMon
        if (-not $exe) {
            if (-not $Winget) { $sync.FpsError = 'O medidor precisa do winget para ser baixado. Veja a aba Programas > Instalar programas.'; return }
            $sync.FpsStatus = 'Baixando o medidor de FPS da Intel (só na primeira vez)...'
            $base = 'install --id Intel.PresentMon.Console -e --source winget --silent --accept-package-agreements --accept-source-agreements'
            $j = Run-Hidden $Winget "$base --scope machine --disable-interactivity"; $j.Proc.WaitForExit()
            $exe = Find-PresentMon
            if (-not $exe) { $j = Run-Hidden $Winget $base; $j.Proc.WaitForExit(); $exe = Find-PresentMon }
            if (-not $exe) { $sync.FpsError = 'Não foi possível baixar o medidor (PresentMon). Confira a internet e tente de novo.'; return }
        }
        for ($i = [int]$Delay; $i -gt 0; $i--) { $sync.FpsStatus = "Volte para o jogo: a medição começa em $i s"; Start-Sleep -Seconds 1 }
        [System.Media.SystemSounds]::Exclamation.Play()
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        $args2 = "--output_file `"$OutFile`" --timed $Seconds --terminate_after_timed --stop_existing_session --no_console_stats --v1_metrics --session_name TurboPC_FPS"
        $j = Run-Hidden $exe $args2
        $t0 = [datetime]::Now
        while (-not $j.Proc.HasExited) {
            $left = [int]($Seconds - ([datetime]::Now - $t0).TotalSeconds)
            $sync.FpsStatus = if ($left -gt 0) { "Medindo o FPS... faltam $left s (continue jogando)" } else { 'Terminando a medição...' }
            if (([datetime]::Now - $t0).TotalSeconds -gt $Seconds + 40) { try { $j.Proc.Kill() } catch {}; break }
            Start-Sleep -Milliseconds 500
        }
        [System.Media.SystemSounds]::Asterisk.Play()
        if (-not (Test-Path -LiteralPath $OutFile)) {
            $err = "$($j.Err.Result) $($j.Out.Result)".Trim()
            $sync.FpsError = "O medidor não gerou resultado. $(if ($err) { $err.Substring(0, [math]::Min(300, $err.Length)) })"
            return
        }
        $r = Get-FpsFromCsv $OutFile
        if (-not $r) { $sync.FpsError = 'Nenhum jogo foi detectado durante a medição. Deixe o jogo aberto e na tela (não minimizado) enquanto mede.'; return }
        $sync.FpsResult = $r
    } catch {
        $sync.FpsError = $_.Exception.Message
    } finally {
        $sync.FpsDone = $true
    }
}

function Get-FpsHistory {
    # no PowerShell 5 o ConvertFrom-Json devolve a lista inteira como um item só: o ForEach-Object desmonta
    try { if (Test-Path $Global:FpsFile) { return @(Get-Content $Global:FpsFile -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) } } catch {}
    @()
}

function Start-FpsTest {
    if ($sync.UpdateBusy -and $sync.UpdateDone) { Complete-UpdateCheck }
    if ($sync.FpsBusy) { return }
    $msg = "Como funciona:`n`n1. Abra o jogo e vá para um lugar que dê para repetir depois (no Valorant, o The Range).`n2. Clique em OK e volte para o jogo.`n3. Em 10 segundos começa a medição, que dura 30 segundos. Você ouve um aviso sonoro no começo e no fim.`n4. Continue jogando normalmente nesse tempo.`n`nMeça antes e depois de otimizar, no mesmo lugar, para comparar. Na primeira vez o TurboPC baixa o medidor da Intel (PresentMon)."
    if ((Show-Msg $msg 'OKCancel' 'Information') -ne 'OK') { return }
    $sync.FpsBusy = $true; $sync.FpsDone = $false; $sync.FpsResult = $null; $sync.FpsError = $null; $sync.FpsStatus = 'Preparando...'
    $ui.BtnFps.IsEnabled = $false
    $parser = (Get-Item function:Get-FpsFromCsv).ScriptBlock.Ast.Extent.Text
    $out = Join-Path $env:ProgramData 'TurboPC\fps_ultima_medicao.csv'
    New-Item -ItemType Directory -Path (Split-Path $out) -Force | Out-Null
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($fpsWorker.ToString()).AddArgument($sync).AddArgument(10).AddArgument(30).AddArgument($out).AddArgument((Find-Winget)).AddArgument($parser)
    $script:fpsJob = @{ PS = $ps; H = $ps.BeginInvoke() }
}

function Complete-FpsTest {
    $sync.FpsBusy = $false
    try { [void]$script:fpsJob.PS.EndInvoke($script:fpsJob.H); $script:fpsJob.PS.Runspace.Dispose(); $script:fpsJob.PS.Dispose() } catch {}
    $ui.BtnFps.IsEnabled = $true
    if ($sync.FpsError -or -not $sync.FpsResult) {
        $ui.FpsInfo.Text = "Não deu para medir: $($sync.FpsError)"
        $ui.StatusText.Text = 'Teste de FPS não concluído.'
        return
    }
    $r = $sync.FpsResult
    $hist = @(Get-FpsHistory)
    try {
        New-Item -ItemType Directory -Path (Split-Path $Global:FpsFile) -Force | Out-Null
        ConvertTo-Json -InputObject @(@($hist) + @($r) | Select-Object -Last 100) -Depth 3 | Set-Content -Path $Global:FpsFile -Encoding UTF8
    } catch {}
    Write-TLog ("Teste de FPS: {0} | média {1} | 1% baixo {2} | {3} quadros em {4} s" -f $r.Game, $r.Avg, $r.Low1, $r.Frames, $r.Seconds) 'OK'
    $ui.StatusText.Text = "Teste de FPS concluído: $($r.Game), $([int]$r.Avg) FPS."
    Render-FpsResult $r $hist
}

# Mostra o resultado e compara com a medição anterior do mesmo jogo; se caiu depois de uma otimização, oferece desfazer
function Render-FpsResult($r, $hist) {
    $ui.FpsResult.Children.Clear()
    $prev = @($hist | Where-Object { $_.Game -eq $r.Game -and [datetime]$_.Date -lt [datetime]$r.Date }) | Select-Object -Last 1
    $line = "<StackPanel xmlns=""http://schemas.microsoft.com/winfx/2006/xaml/presentation"" Orientation=""Horizontal"" Margin=""0,2,0,0""><TextBlock Text=""$(Esc $r.Game)"" FontSize=""13"" Foreground=""#8A91A3"" VerticalAlignment=""Bottom"" Margin=""0,0,14,3""/><TextBlock Text=""$([int]$r.Avg)"" FontSize=""30"" FontWeight=""Bold"" Foreground=""White""/><TextBlock Text="" FPS médio"" FontSize=""13"" Foreground=""#C9CFDB"" VerticalAlignment=""Bottom"" Margin=""4,0,18,5""/><TextBlock Text=""$([int]$r.Low1)"" FontSize=""20"" FontWeight=""SemiBold"" Foreground=""#E6E8EE"" VerticalAlignment=""Bottom"" Margin=""0,0,0,2""/><TextBlock Text="" no 1% mais baixo"" FontSize=""13"" Foreground=""#8A91A3"" VerticalAlignment=""Bottom"" Margin=""4,0,0,5""/></StackPanel>"
    [void]$ui.FpsResult.Children.Add([Windows.Markup.XamlReader]::Parse($line))

    $text = ''; $color = '#8A91A3'; $undoRun = $null
    if (-not $prev) {
        $text = 'Primeira medição deste jogo. Depois de otimizar, meça de novo no mesmo lugar para comparar.'
    } else {
        $diff = 100.0 * ($r.Avg - $prev.Avg) / [math]::Max(1.0, $prev.Avg)
        $run = @(Get-UndoRuns | Where-Object { -not $_.Undone -and [datetime]$_.Date -gt [datetime]$prev.Date -and [datetime]$_.Date -lt [datetime]$r.Date }) | Select-Object -First 1
        $what = if ($run) { "depois da otimização '$($run.Label)' de $(([datetime]$run.Date).ToString('dd/MM HH:mm'))" } else { "comparado com a medição de $(([datetime]$prev.Date).ToString('dd/MM HH:mm'))" }
        $nums = "$([int]$prev.Avg) → $([int]$r.Avg) FPS ($('{0:+0.0;-0.0}' -f $diff)%)"
        if ($diff -ge 3) { $text = "Melhorou: $nums $what."; $color = '#4ADE80' }
        elseif ($diff -gt -3) { $text = "Ficou igual: $nums $what. Até 3% para cima ou para baixo é variação normal entre medições."; $color = '#C9CFDB' }
        elseif ($diff -gt -6) { $text = "Caiu um pouco: $nums $what. Pode ser variação; meça de novo no mesmo lugar para confirmar."; $color = '#F5A524' }
        else { $text = "O FPS caiu: $nums $what."; $color = '#F87171'; $undoRun = $run }
    }
    # jogo travado no limite de FPS (V-Sync ou limite do próprio jogo): a comparação perde o sentido
    $caps = @(30, 60, 75, 120, 144, 165, 240, 360) + @($script:MonitorHz | Where-Object { $_ })
    $cap = $caps | Where-Object { [math]::Abs($r.Avg - $_) -le ($_ * 0.02) } | Select-Object -First 1
    if ($cap) { $text += " Parece que o jogo está limitado em $cap FPS (V-Sync ou limite do jogo): para comparar o desempenho, tire o limite antes de medir." }
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $text; $tb.Foreground = $color; $tb.FontSize = 12.8; $tb.TextWrapping = 'Wrap'; $tb.Margin = '0,6,0,0'
    [void]$ui.FpsResult.Children.Add($tb)
    if ($undoRun) {
        $b = New-Object Windows.Controls.Button
        $b.Style = $window.FindResource('Btn'); $b.Background = '#B4374A'; $b.HorizontalAlignment = 'Left'; $b.Margin = '0,10,0,0'; $b.Padding = '14,8'
        $b.Content = "Desfazer a otimização '$($undoRun.Label)'"
        $b.Tag = $undoRun
        $b.Add_Click({ param($s) Invoke-Undo $s.Tag })
        [void]$ui.FpsResult.Children.Add($b)
    }
    $ui.FpsInfo.Text = "Medido em $(([datetime]$r.Date).ToString("dd/MM 'às' HH:mm")): $($r.Frames) quadros em $($r.Seconds) s."
}

