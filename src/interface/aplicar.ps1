# [parte] Revisar, executar, concluir e o temporizador da interface
function Invoke-Review([string]$Title, [string]$Subtitle, [string[]]$Ids, [string[]]$Extras = @()) {
    if ($sync.Running) { return }
    $r = Show-Review $Title $Subtitle $Ids $Extras
    if ($r -and $r.Ids) { Start-Run $r.Ids $r.Restore 'tasks' $Title }
}

function Start-Run([string[]]$Ids, [bool]$RestorePoint, [string]$Mode = 'tasks', [string]$Label = 'Otimização', [string]$UndoFile = '') {
    if ($sync.Running) { return }
    $sync.Done = $false; $sync.Running = $true; $sync.Progress = 0; $sync.Freed = 0; $sync.Mode = $Mode
    Set-Busy $true
    $ui.Tabs.SelectedItem = $ui.TabLog
    Start-Worker $worker @($sync, $TaskLibrary.ToString(), [string[]]@($Ids), $RestorePoint, $Global:TLogFile, $Label, $UndoFile)
}

function Complete-Run {
    $sync.Running = $false
    try { [void]$script:job.PS.EndInvoke($script:job.Handle) } catch {}
    try { $script:job.PS.Runspace.Dispose(); $script:job.PS.Dispose() } catch {}
    Set-Busy $false
    $ui.StatusText.Text = 'Concluído.'
    if ($sync.Mode -eq 'restore') {
        Show-Msg 'Pronto. Veja o resultado no Histórico.' | Out-Null
        return
    }
    if ($sync.Mode -eq 'undo') {
        Load-History
        Start-InfoLoad
        $r = Show-Msg "Pronto, as alterações foram desfeitas. Veja os detalhes no Histórico.`n`nReiniciar agora para valer tudo?" 'YesNo' 'Information'
        if ($r -eq 'Yes') { shutdown.exe /r /t 5 /c "Reiniciando após desfazer (TurboPC)" }
        return
    }
    if ($sync.Mode -eq 'apps') {
        Load-Apps
        $icon = if ($sync.AppFail) { 'Warning' } else { 'Information' }
        Show-Msg "Concluído: $($sync.AppOk) com sucesso, $($sync.AppFail) com problema.`n`nOs detalhes estão no Histórico." 'OK' $icon | Out-Null
        return
    }
    Load-History
    $script:SpaceStale = $true
    $script:SessionFreed += [int64]$sync.Freed
    $ui.TxtFreed.Text = "Espaço liberado nesta sessão: $(Format-Size $script:SessionFreed)"
    Start-InfoLoad
    $r = Show-Msg "Otimização concluída!`n`nEspaço liberado: $(Format-Size $sync.Freed)`n`nSe algo ficar diferente do que você queria, dá para desfazer no Histórico.`n`nAlgumas mudanças só valem depois de reiniciar. Reiniciar agora?" 'YesNo' 'Information'
    if ($r -eq 'Yes') { shutdown.exe /r /t 5 /c "Reiniciando após otimização (TurboPC)" }
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$timer.Add_Tick({
    $line = $null
    $sb = New-Object Text.StringBuilder
    while ($sync.Queue.TryDequeue([ref]$line)) { [void]$sb.AppendLine($line) }
    if ($sb.Length -gt 0) { $ui.LogBox.AppendText($sb.ToString()); $ui.LogBox.ScrollToEnd() }
    if ($sync.Running) {
        $ui.Progress.Value = $sync.Progress
        if ($sync.Current) { $ui.StatusText.Text = "Executando: $($sync.Current)" }
        if ($sync.Done) { Complete-Run }
    }
    if ($sync.UpdateBusy -and $sync.UpdateDone) { Complete-UpdateCheck }
    if ($sync.InfoBusy -and $sync.InfoDone) { Complete-InfoLoad }
    if ($sync.FpsBusy) {
        $ui.FpsInfo.Text = $sync.FpsStatus; $ui.StatusText.Text = $sync.FpsStatus
        if ($sync.FpsDone) { Complete-FpsTest }
    }
    if ($sync.DiskBusy) {
        if ($script:DiskMode -eq 'full') { $ui.SpaceStatus.Text = $sync.DiskStatus; $ui.SpaceProgress.Value = $sync.DiskProgress }
        if ($sync.DiskDone) { Complete-DiskScan }
    }
    if ($sync.MonActive -and $sync.MonSeq -ne $script:MonSeq) {
        $script:MonSeq = $sync.MonSeq
        Update-Monitor
    }
})
$timer.Start()

