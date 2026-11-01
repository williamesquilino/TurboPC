# [parte] Thread de execução das tarefas e bloqueio de botões
# ---------------------------------------------------------------- execução em segundo plano
function Start-Worker([scriptblock]$Script, [object[]]$Arguments) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Script.ToString())
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    $script:job = @{ PS = $ps; Handle = $ps.BeginInvoke() }
}

$worker = {
    param($sync, $libText, $ids, $makeRP, $logFile, $label, $undoFile)
    try {
        $Global:TLogFile = $logFile
        $Global:TQueue   = $sync.Queue
        . ([scriptblock]::Create($libText))
        $progress = { param($p, $n) $sync.Progress = $p; $sync.Current = $n }
        if ($undoFile) { Undo-TRun -File $undoFile -OnProgress $progress }
        else { Invoke-TTasks -Ids $ids -RestorePoint:$makeRP -OnProgress $progress -Label $label }
        $sync.Freed = $Global:TotalFreed
    } catch {
        $sync.Queue.Enqueue("[ERRO] $($_.Exception.Message)")
    } finally {
        $sync.Done = $true
    }
}

function Set-Busy([bool]$Busy) {
    foreach ($b in @($script:ModeButtons) + @($script:UndoButtons)) { if ($b) { $b.IsEnabled = -not $Busy } }
    foreach ($n in 'BtnRun','BtnRec','BtnRecGame','BtnNone','BtnRestore','BtnSaveStartup',
                   'AllLimpeza','AllDesempenho','AllPrivacidade','AllJogos','AllAjustes','AllReparo',
                   'BtnInstall','BtnUninstall','BtnUpgradeAll','BtnInstallChoco') {
        $ui[$n].IsEnabled = -not $Busy
    }
    foreach ($cb in $script:CheckMap.Values) { $cb.IsEnabled = -not $Busy }
}

