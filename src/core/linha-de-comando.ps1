# [parte] Modos -List e -Auto (sem interface)
# ---------------------------------------------------------------- modo linha de comando
if ($List) {
    $modeCol = @{ n = 'Modos'; e = { $id = $_.Id; ($Global:Modes.Keys | Where-Object { $Global:Modes[$_].Ids -contains $id }) -join ',' } }
    $TTasks | Format-Table @{n='ID';e={$_.Id}}, @{n='Categoria';e={$_.Cat}}, $modeCol, Name -AutoSize
    exit
}

if ($Auto) {
    $ids = if ($Tasks) { $Tasks | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } }
           else { Write-Host "Perfil: $Perfil" -ForegroundColor Cyan; Get-ProfileIds $Perfil }
    Invoke-TTasks -Ids $ids -RestorePoint:(-not $NoRestorePoint) -Label $(if ($Tasks) { 'Automático (tarefas escolhidas)' } else { "Automático: $Perfil" })
    Write-Host "Log salvo em $Global:TLogFile"
    if ($IsCompiled -and -not $NoPause) { Read-Host 'Pressione Enter para fechar' | Out-Null }
    exit
}

