# [parte] Painel: informações, diagnóstico, nota de saúde e faixa do PC
# ---------------------------------------------------------------- painel
function Add-Diag([string]$Text, [string]$Color) {
    $x = @"
<DockPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Margin="0,0,0,8">
  <Ellipse Width="9" Height="9" Fill="$Color" VerticalAlignment="Top" Margin="0,5,12,0"/>
  <TextBlock Text="$(Esc $Text)" Foreground="#D5D9E3" FontSize="13" TextWrapping="Wrap"/>
</DockPanel>
"@
    [void]$ui.PanelDiag.Children.Add([Windows.Markup.XamlReader]::Parse($x))
    $script:Penalty += switch ($Color) { '#F87171' { 22 } '#F5A524' { 8 } default { 0 } }
}

function Set-Score {
    $score = [math]::Max(5, 100 - $script:Penalty)
    $label, $color = if ($score -ge 85) { 'Ótimo', '#4ADE80' } elseif ($score -ge 65) { 'Bom', '#A3E635' }
                     elseif ($score -ge 45) { 'Regular', '#F5A524' } else { 'Precisa de atenção', '#F87171' }
    $ui.ScoreText.Text = "$score"
    $ui.ScoreLabel.Text = $label
    $ui.ScoreLabel.Foreground = $color
    $ui.ScoreRing.Stroke = $color
    # circunferência em unidades de espessura do traço: pi * (132 - 11) / 11
    $ui.ScoreRing.StrokeDashArray = New-Object Windows.Media.DoubleCollection (,[double[]]@((([math]::PI * 121 / 11) * $score / 100), 1000))
}

function Update-Info {
    $ui.PanelDiag.Children.Clear()
    $script:Penalty = 0
    $red = '#F87171'; $yellow = '#F5A524'; $green = '#4ADE80'; $blue = '#60A5FA'
    $issues = 0
    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cs  = Get-CimInstance Win32_ComputerSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $cv  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue

        $ui.TxtHost.Text = "$($cs.Manufacturer) $($cs.Model)  •  $env:COMPUTERNAME  •  executando como $env:USERDOMAIN\$env:USERNAME"

        $ui.InfoOS.Text = ($os.Caption -replace '^Microsoft\s+', '')
        $ui.InfoOSSub.Text = "Versão $($cv.DisplayVersion)  •  build $($os.BuildNumber).$($cv.UBR)"

        $ui.InfoCPU.Text = ($cpu.Name -replace '\(R\)|\(TM\)|CPU|Processor', '' -replace '\s+', ' ').Trim()
        $ui.InfoCPUSub.Text = "$($cpu.NumberOfCores) núcleos / $($cpu.NumberOfLogicalProcessors) threads  •  uso atual $($cpu.LoadPercentage)%"

        $ramTotal = $os.TotalVisibleMemorySize * 1KB
        $ramFree  = $os.FreePhysicalMemory * 1KB
        $ramPct   = [int](100 * ($ramTotal - $ramFree) / $ramTotal)
        $ramGB    = [math]::Round($ramTotal / 1GB)
        $ui.InfoRAM.Text = "$ramGB GB"
        $ui.InfoRAMSub.Text = "$ramPct% em uso  •  $(Format-Size $ramFree) livres"
        $ui.BarRAM.Value = $ramPct

        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
        $freePct = [int](100 * $disk.FreeSpace / $disk.Size)
        $ui.InfoDisk.Text = "$(Format-Size $disk.FreeSpace) livres"
        $ui.InfoDiskSub.Text = "de $(Format-Size $disk.Size)  •  $freePct% livre"
        $ui.BarDisk.Value = 100 - $freePct

        $media = 'Não identificado'; $model = ''; $wear = $null; $sick = @()
        try {
            $dn = (Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop).DiskNumber
            $allPd = @(Get-PhysicalDisk -ErrorAction Stop)
            $pd = $allPd | Where-Object { $_.DeviceId -eq "$dn" } | Select-Object -First 1
            $model = $pd.FriendlyName
            $media = switch ("$($pd.MediaType)") { 'SSD' { if ("$($pd.BusType)" -eq 'NVMe') { 'SSD NVMe' } else { 'SSD' } } 'HDD' { 'HD mecânico' } default { 'Não identificado' } }
            $sick = @($allPd | Where-Object { $_.HealthStatus -and "$($_.HealthStatus)" -ne 'Healthy' })
            $rel = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            $parts = @($model)
            if ("$($pd.HealthStatus)" -eq 'Healthy') { $parts += 'saúde boa' }
            if ($null -ne $rel.Wear -and $media -like 'SSD*') { $wear = [int]$rel.Wear; $parts += "desgaste $wear%" }
            if ($rel.Temperature) { $parts += "$($rel.Temperature) °C" }
            $model = $parts -join '  •  '
        } catch {}
        $ui.InfoMedia.Text = $media
        $ui.InfoMediaSub.Text = $model

        $up = (Get-Date) - $os.LastBootUpTime
        $ui.InfoUptime.Text = '{0}d {1}h {2}min' -f $up.Days, $up.Hours, $up.Minutes
        $ui.InfoUptimeSub.Text = "desde $($os.LastBootUpTime.ToString('dd/MM/yyyy HH:mm'))"

        # vídeo: prefere a placa dedicada quando há mais de uma
        $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -notmatch 'Remote|Virtual|Parsec|Mirage|DisplayLink|Meta ' })
        $gpu = $gpus | Sort-Object { if ($_.Name -match 'NVIDIA|Radeon|Arc') { 0 } else { 1 } } | Select-Object -First 1
        $script:DriverUrl = $null
        $drvAge = 0
        if ($gpu) {
            $ui.InfoGPU.Text = ($gpu.Name -replace '\(R\)|\(TM\)', '').Trim()
            $ui.InfoGPUSub.Text = if ($gpus.Count -gt 1) { 'Também: ' + (($gpus | Where-Object Name -ne $gpu.Name | ForEach-Object Name) -join ', ') } else { $gpu.VideoProcessor }
            $script:DriverUrl = switch -Regex ($gpu.Name) {
                'NVIDIA'            { 'https://www.nvidia.com/pt-br/drivers/' }
                'AMD|Radeon'        { 'https://www.amd.com/pt/support/download/drivers.html' }
                'Intel'             { 'https://www.intel.com.br/content/www/br/pt/support/detect.html' }
            }
            $ui.InfoDrv.Text = "$($gpu.DriverVersion)"
            if ($gpu.DriverDate) {
                $drvAge = [int]((Get-Date) - $gpu.DriverDate).TotalDays
                $ui.InfoDrvSub.Text = "de $($gpu.DriverDate.ToString('dd/MM/yyyy'))  •  há $([math]::Round($drvAge / 30)) meses"
            }
        } else {
            $ui.InfoGPU.Text = 'Não identificada'
        }
        $ui.BtnDriver.Visibility = if ($script:DriverUrl) { 'Visible' } else { 'Collapsed' }

        # [largura, altura, Hz atual, Hz máximo na resolução atual], lido dos modos que o driver de vídeo oferece
        $mon = $null
        $active = $gpus | Where-Object CurrentRefreshRate | Select-Object -First 1
        if ($active) {
            $w = $active.CurrentHorizontalResolution; $h = $active.CurrentVerticalResolution
            $maxHz = (Get-CimInstance CIM_VideoControllerResolution -ErrorAction SilentlyContinue |
                      Where-Object { $_.HorizontalResolution -eq $w -and $_.VerticalResolution -eq $h } |
                      Measure-Object RefreshRate -Maximum).Maximum
            $maxHz = [math]::Max([int]$maxHz, [int]$active.CurrentRefreshRate)
            $mon = @($w, $h, [int]$active.CurrentRefreshRate, $maxHz)
        }
        $script:MonitorHz = if ($mon) { $mon[2] } else { $null }
        if ($mon) {
            $ui.InfoMon.Text = "$($mon[2]) Hz"
            $ui.InfoMonSub.Text = "$($mon[0]) x $($mon[1])  •  máximo nesta resolução: $($mon[3]) Hz"
        }

        # diagnóstico
        foreach ($d in $sick) { Add-Diag "O disco '$($d.FriendlyName)' está avisando que vai falhar ($($d.HealthStatus)). Faça backup dos arquivos e troque o disco o quanto antes." $red; $issues++ }
        if ($wear -ge 80) { Add-Diag "O SSD já gastou $wear% da vida útil. Planeje a troca." $yellow; $issues++ }
        if ([int]$os.BuildNumber -lt 22000) { Add-Diag 'Windows 10: o suporte gratuito acabou em outubro de 2025. Sem o programa ESU, o PC não recebe mais correções de segurança. Se o hardware for compatível, migre para o Windows 11.' $yellow; $issues++ }
        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            if (-not $mp.AMRunningMode -or $mp.AMRunningMode -eq 'Normal') {
                if (-not $mp.RealTimeProtectionEnabled) { Add-Diag 'A proteção em tempo real do Microsoft Defender está DESLIGADA. Ligue em Segurança do Windows > Proteção contra vírus e ameaças.' $red; $issues++ }
                elseif ($mp.AntivirusSignatureAge -gt 7) { Add-Diag "O antivírus está com as definições de $($mp.AntivirusSignatureAge) dias atrás. Rode o Windows Update." $yellow; $issues++ }
            }
        } catch {}
        if ((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
            (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')) {
            Add-Diag 'Há atualizações do Windows esperando o PC reiniciar para terminar de instalar.' $yellow; $issues++
        }
        if ($Global:IsLaptop) {
            try {
                $full   = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
                $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
                if ($full -and $design) {
                    $bh = [math]::Min(100, [int](100 * $full / $design))
                    if ($bh -lt 60) { Add-Diag "A bateria segura só $bh% da carga original. Está na hora de trocar." $yellow; $issues++ }
                    else { Add-Diag "Bateria com $bh% da capacidade original." $blue }
                }
            } catch {}
        }
        if ($gpu -and $gpu.Name -match 'Microsoft Basic|Básico') { Add-Diag 'A placa de vídeo está sem driver (usando o driver básico da Microsoft). Instale o driver: muda tudo em jogos e até no uso normal.' $red; $issues++ }
        elseif ($drvAge -gt 365 -and $gpu.Name -match 'NVIDIA|Radeon|Arc') { Add-Diag "Driver de vídeo com mais de $([math]::Floor($drvAge / 365)) ano(s). Para jogos, atualizar o driver é o que mais dá FPS. Use o botão 'Baixar driver de vídeo'." $yellow; $issues++ }
        if ($mon -and $mon[3] -gt $mon[2]) { Add-Diag "O monitor está em $($mon[2]) Hz, mas aceita até $($mon[3]) Hz. Mude em Configurações > Sistema > Vídeo > Vídeo avançado: fica muito mais fluido em jogos." $yellow; $issues++ }
        if ($media -eq 'HD mecânico') { Add-Diag 'O Windows está num HD mecânico. Trocar por um SSD é, de longe, o upgrade que mais deixa um PC antigo rápido (custa pouco).' $red; $issues++ }
        if ($ramGB -lt 4)     { Add-Diag "Só $ramGB GB de RAM. Windows 10/11 com navegador e Office precisa de pelo menos 8 GB." $red; $issues++ }
        elseif ($ramGB -lt 8) { Add-Diag "$ramGB GB de RAM é o limite. Se der, coloque mais um pente para chegar em 8 GB." $yellow; $issues++ }
        if ($freePct -lt 10)     { Add-Diag "Só $freePct% livre no $env:SystemDrive. Com pouco espaço o Windows fica lento e as atualizações falham." $red; $issues++ }
        elseif ($freePct -lt 20) { Add-Diag "$freePct% livre no $env:SystemDrive. Rode a Limpeza para ganhar espaço." $yellow; $issues++ }
        if ($up.TotalDays -ge 7) { Add-Diag "PC ligado há $($up.Days) dias sem reiniciar. Reiniciar de vez em quando libera memória e conclui atualizações." $yellow; $issues++ }
        $hw = @($media, "$ramGB GB de RAM", $(if ($gpu) { ($gpu.Name -replace '\(R\)|\(TM\)|NVIDIA |AMD |GeForce ', '').Trim() })) | Where-Object { $_ -and $_ -ne 'Não identificado' }
        $powerWarn = Update-PcBanner ($hw -join '  ·  ')
        if ($powerWarn) { Add-Diag $powerWarn $yellow; $issues++ }

        $enabledStartup = @($script:StartupBoxes | Where-Object { $_.IsChecked }).Count
        if ($enabledStartup -gt 8) { Add-Diag "$enabledStartup programas abrem junto com o Windows. Veja Programas > Inicialização." $yellow; $issues++ }

        $exp = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($exp) {
            $own = Invoke-CimMethod -InputObject $exp -MethodName GetOwner -ErrorAction SilentlyContinue
            if ($own -and $own.User -and $own.User -ne $env:USERNAME) {
                Add-Diag "O app está rodando como '$env:USERNAME', mas quem está logado é '$($own.User)'. Os ajustes visuais e de usuário vão para '$env:USERNAME'. Para aplicar no usuário, rode logado com uma conta que seja admin local." $yellow
                $issues++
            }
        }
        if ($issues -eq 0) { Add-Diag 'Nada crítico encontrado. Use o modo Recomendado de vez em quando para manter tudo em dia.' $green }
    } catch {
        Add-Diag "Não foi possível ler todas as informações: $($_.Exception.Message)" $yellow
    }
    Set-Score
}

