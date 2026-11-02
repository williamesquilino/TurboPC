# [parte] Eventos dos botões, abertura e fechamento da janela
# ---------------------------------------------------------------- eventos
$ui.BtnRun.Add_Click({
    Invoke-Review 'Executar selecionados' 'Estas são as otimizações que você marcou. Feche os programas abertos antes de aplicar.' @(Get-SelectedIds)
})
$ui.BtnRec.Add_Click({ Set-Profile 'Escritorio' })
$ui.BtnRecGame.Add_Click({ Set-Profile 'Jogos' })
$ui.BtnNone.Add_Click({ foreach ($cb in $script:CheckMap.Values) { $cb.IsChecked = $false } })
foreach ($b in $script:ModeButtons) { $b.Add_Click({ param($s) Invoke-Mode $s.Tag }) }
$ui.BtnDriver.Add_Click({ if ($script:DriverUrl) { Start-Process $script:DriverUrl } })
$ui.BtnRestore.Add_Click({ Start-Run @() $true 'restore' })
$ui.BtnRefresh.Add_Click({ Start-InfoLoad })
$ui.BtnReport.Add_Click({
    try { Export-Report } catch { Show-Msg "Não foi possível gerar o relatório: $($_.Exception.Message)" 'OK' 'Error' | Out-Null }
})
$ui.BtnOpenLogs.Add_Click({ Start-Process explorer.exe $LogDir })
$ui.BtnUndo.Add_Click({ $ui.Tabs.SelectedItem = $ui.TabLog })
$ui.BtnUsage.Add_Click({ Initialize-Usage -Ask })
$ui.BtnFps.Add_Click({ Start-FpsTest })
# espaço em disco
$ui.BtnSpaceScan.Add_Click({ Start-DiskScan $script:SpaceDrive $null })
$ui.BtnFreeSafe.Add_Click({ if ($script:SafeJunkIds) { Start-Run @($script:SafeJunkIds) ([bool]$ui.ChkRestore.IsChecked) 'tasks' 'Liberar espaço'; $script:SpaceStale = $true } })
$ui.BtnFolderUp.Add_Click({
    if ($script:FolderStack.Count) { $script:FolderStack.RemoveAt($script:FolderStack.Count - 1) }
    $p = if ($script:FolderStack.Count) { $script:FolderStack[$script:FolderStack.Count - 1] } else { "$($script:SpaceDrive)\" }
    Render-Folders $p $script:FolderCache[$p]
})
$ui.BtnSysRestore.Add_Click({ Start-Process "$env:windir\System32\rstrui.exe" })

# monitor
$ui.BtnSortCpu.Add_Click({ $sync.ProcSort = 'cpu' })
$ui.BtnSortRam.Add_Click({ $sync.ProcSort = 'ram' })
$ui.BtnKill.Add_Click({
    $item = $ui.ProcList.SelectedItem
    if (-not $item) { Show-Msg 'Clique primeiro num programa da lista.' | Out-Null; return }
    $name = [string]$item.Tag
    if ($ProtectedProcs -contains $name.ToLower()) {
        Show-Msg "'$name' faz parte do Windows (ou é o próprio TurboPC) e não deve ser encerrado." 'OK' 'Warning' | Out-Null
        return
    }
    if ((Show-Msg "Encerrar '$name'? O que não foi salvo nesse programa será perdido." 'YesNo' 'Warning') -ne 'Yes') { return }
    Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object Id -ne $PID | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-TLog "Monitor: programa encerrado: $name" 'OK'
})

# programas
$ui.TxtAppSearch.Add_TextChanged({ Filter-Apps })
$ui.BtnInstall.Add_Click({ Start-AppJob 'install' @($AppCatalog | Where-Object { $script:AppBoxes[$_.Id].IsChecked }) })
$ui.BtnUninstall.Add_Click({ Start-AppJob 'uninstall' @($AppCatalog | Where-Object { $script:AppBoxes[$_.Id].IsChecked }) })
$ui.BtnUpgradeAll.Add_Click({ Start-AppJob 'upgrade' @() })
$ui.BtnInstallChoco.Add_Click({
    Start-AppJob 'install' @([pscustomobject]@{ Name = 'Chocolatey'; Winget = 'Chocolatey.Chocolatey'; Choco = ''; Source = 'winget' })
})
$ui.BtnGetWinget.Add_Click({ Start-Process 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1' })
$ui.BtnAppsNone.Add_Click({ foreach ($cb in $script:AppBoxes.Values) { $cb.IsChecked = $false } })

$ui.Tabs.Add_SelectionChanged({
    param($s, $e)
    if ($e.OriginalSource -ne $ui.Tabs) { return }
    $sel = $ui.Tabs.SelectedItem
    $sync.MonActive = ($sel -eq $ui.TabHome)
    $ui.FooterTasks.Visibility = if ($sel -eq $ui.TabOpt) { 'Visible' } else { 'Collapsed' }
    if ($sel -eq $ui.TabHome) { Update-Drives }
    if ($sel -eq $ui.TabSpace -and $script:SpaceStale -and -not $sync.DiskBusy) { Start-DiskScan $script:SpaceDrive $null }
    if ($sel -eq $ui.TabProg -and -not $script:AppsLoaded) {
        $ui.StatusText.Text = 'Verificando programas instalados...'
        Load-Apps
        $ui.StatusText.Text = 'Pronto.'
    }
})

foreach ($n in 'AllLimpeza','AllDesempenho','AllPrivacidade','AllJogos','AllAjustes','AllReparo') {
    $ui[$n].Add_Click({
        param($s)
        foreach ($t in ($TTasks | Where-Object Cat -eq $s.Tag)) { $script:CheckMap[$t.Id].IsChecked = $true }
    })
}

$ui.BtnReloadStartup.Add_Click({ [void](Load-Startup) })
$ui.BtnSaveStartup.Add_Click({
    $changed = 0
    foreach ($cb in $script:StartupBoxes) {
        $e = $cb.Tag
        if ([bool]$cb.IsChecked -ne $e.Enabled) {
            try {
                Set-StartupEntry $e ([bool]$cb.IsChecked)
                $e.Enabled = [bool]$cb.IsChecked
                Write-TLog ("Inicialização: {0} -> {1}" -f $e.Name, $(if ($e.Enabled) { 'ativado' } else { 'desativado' })) 'OK'
                $changed++
            } catch {
                Write-TLog "Inicialização: falha em $($e.Name): $($_.Exception.Message)" 'ERRO'
            }
        }
    }
    Show-Msg "$changed alteração(ões) salva(s). Vale a partir do próximo login." | Out-Null
})

$window.Add_ContentRendered({
    $mrs = [runspacefactory]::CreateRunspace()
    $mrs.Open()
    $script:monPS = [powershell]::Create()
    $script:monPS.Runspace = $mrs
    [void]$script:monPS.AddScript($monitorWorker.ToString()).AddArgument($sync)
    [void]$script:monPS.BeginInvoke()
    $ui.StatusText.Text = 'Lendo informações do computador...'
    $ui.FooterTasks.Visibility = 'Collapsed'
    # o Painel e a detecção de uso são lidos em segundo plano: a janela já fica usável (Complete-InfoLoad termina o resto)
    Start-InfoLoad
    [void](Load-Startup)
    Load-History
    Update-Drives
    $sync.MonActive = $true
    # barra lateral fica no modelo visual das abas: os elementos dela são achados por lá
    $tpl = $ui.Tabs.Template
    $script:BtnUpdate = $tpl.FindName('BtnUpdate', $ui.Tabs)
    $script:TxtUpdate = $tpl.FindName('TxtUpdate', $ui.Tabs)
    $script:BtnUpdate.Add_Click({ if ($script:PendingUpdate) { Install-Update $script:PendingUpdate } else { Start-UpdateCheck -Manual } })
    if ($IsCompiled) { Remove-Item -Path (Join-Path (Split-Path $ExePath) 'TurboPC*.exe.old') -Force -ErrorAction SilentlyContinue }
    Start-UpdateCheck
    $lastFps = @(Get-FpsHistory) | Select-Object -Last 1
    if ($lastFps) { Render-FpsResult $lastFps @(Get-FpsHistory | Select-Object -SkipLast 1) }
})

$window.Add_Closing({
    param($s, $e)
    if ($sync.Running) {
        Show-Msg 'Aguarde a otimização terminar antes de fechar.' 'OK' 'Warning' | Out-Null
        $e.Cancel = $true
        return
    }
    $sync.Quit = $true
})

Write-TLog "TurboPC $AppVersion (por $AppAuthor) iniciado em $env:COMPUTERNAME"
[void]$window.ShowDialog()
$timer.Stop()
$sync.Quit = $true
if ($script:monPS) { try { $script:monPS.Stop(); $script:monPS.Runspace.Dispose(); $script:monPS.Dispose() } catch {} }
