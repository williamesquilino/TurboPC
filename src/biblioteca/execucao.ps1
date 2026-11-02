# [parte] Executar tarefas, gravar e aplicar o desfazer; fim da biblioteca
    $Global:UndoDir = Join-Path $env:ProgramData 'TurboPC\desfazer'

    function Invoke-TTasks {
        param([string[]]$Ids, [switch]$RestorePoint, [scriptblock]$OnProgress, [string]$Label = 'Otimização')
        $sel   = @($TTasks | Where-Object { $Ids -contains $_.Id })
        $total = [math]::Max(1, $sel.Count + [int][bool]$RestorePoint)
        $i = 0
        $Global:TotalFreed = [int64]0
        $Global:UndoItems = New-Object Collections.ArrayList
        $Global:UndoNotes = New-Object Collections.ArrayList
        $Global:UndoSeen  = @{}
        Write-TLog "==== $Label | $env:COMPUTERNAME | $($sel.Count) tarefa(s) | executado por $Global:RunAs ====" 'STEP'
        if ($Global:UserHive) { Write-TLog "  ajustes de usuário vão para quem está logado: $Global:TargetUser" }
        elseif (-not $Global:SessionUser) { Write-TLog '  ninguém logado na tela: ajustes de usuário vão para a conta que executou' 'WARN' }

        if ($RestorePoint) {
            if ($OnProgress) { & $OnProgress 0 'Criando ponto de restauração...' }
            New-TRestorePoint
            $i++
        }
        foreach ($t in $sel) {
            if ($OnProgress) { & $OnProgress ([int](100 * $i / $total)) $t.Name }
            Write-TLog "> $($t.Name)" 'STEP'
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try {
                & $t.Action | Out-Null
                Write-TLog ('  concluído em {0:N1}s' -f $sw.Elapsed.TotalSeconds)
            } catch {
                Write-TLog "  falhou: $($_.Exception.Message)" 'ERRO'
            }
            $i++
        }
        if (@($sel | Where-Object Cat -eq 'Limpeza').Count) { Add-UndoNote 'Arquivos apagados na limpeza não voltam (eram temporários e cache, o Windows recria o que precisar).' }
        if ($Global:UndoItems.Count -or $Global:UndoNotes.Count) {
            try {
                New-Item -ItemType Directory -Path $Global:UndoDir -Force | Out-Null
                $file = Join-Path $Global:UndoDir ('{0}.json' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
                [ordered]@{
                    Date = (Get-Date).ToString('s'); Label = $Label; User = $Global:RunAs; Target = $Global:TargetUser; Version = 1
                    Tasks = @($sel | ForEach-Object Name); Items = @($Global:UndoItems); Notes = @($Global:UndoNotes); Undone = $null
                } | ConvertTo-Json -Depth 6 | Set-Content -Path $file -Encoding UTF8
                Write-TLog "  $($Global:UndoItems.Count) alteração(ões) guardada(s): dá para desfazer em Histórico" 'OK'
            } catch { Write-TLog "  não foi possível salvar o desfazer: $($_.Exception.Message)" 'WARN' }
        }
        $Global:UndoItems = $null
        if ($OnProgress) { & $OnProgress 100 'Concluído' }
        Write-TLog "==== Fim. Espaço liberado: $(Format-Size $Global:TotalFreed). Reinicie o PC para aplicar tudo. ====" 'STEP'
    }

    function Get-UndoRuns {
        Get-ChildItem -Path $Global:UndoDir -Filter *.json -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object {
            try { $r = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json; $r | Add-Member -NotePropertyName File -NotePropertyValue $_.FullName -Force; $r } catch {}
        }
    }

    # Volta cada valor guardado, do último para o primeiro
    function Undo-TRun {
        param([string]$File, [scriptblock]$OnProgress)
        $rec = Get-Content $File -Raw -Encoding UTF8 | ConvertFrom-Json
        $items = @($rec.Items)
        [array]::Reverse($items)
        # ajustes de usuário de outra pessoa só voltam com ela logada (o registro dela precisa estar carregado)
        $away = @($items | Where-Object { $_.T -eq 'reg' -and $_.P -match '^Registry::HKEY_USERS\\(S-[\d-]+)' -and -not (Test-Path "Registry::HKEY_USERS\$($Matches[1])") })
        if ($away) { Write-TLog "  $($away.Count) ajuste(s) de usuário são de $($rec.Target), que não está logado agora: entre com esse usuário e desfaça de novo para voltar esses também" 'WARN' }
        Write-TLog "==== Desfazendo: $($rec.Label) de $(([datetime]$rec.Date).ToString('dd/MM/yyyy HH:mm')) ($($items.Count) alterações) ====" 'STEP'
        $ok = 0; $fail = 0; $i = 0
        foreach ($it in $items) {
            $i++
            if ($OnProgress) { & $OnProgress ([int](100 * $i / [math]::Max(1, $items.Count))) "Desfazendo $i de $($items.Count)" }
            try {
                # política (GPO) que mudou depois do TurboPC: a empresa mexeu nela, então fica como a empresa deixou
                if ($it.T -eq 'reg' -and $it.P -match '\\Policies\\' -and $it.PSObject.Properties.Name -contains 'S') {
                    $cur = (Get-ItemProperty -LiteralPath $it.P -Name $it.N -ErrorAction SilentlyContinue).($it.N)
                    if ($null -eq $cur -or (@($cur) -join ',') -ne (@($it.S) -join ',')) {
                        Write-TLog "  $($it.N) em $($it.P -replace '^Registry::', '') foi mudado depois (provavelmente pela GPO): mantido como está"
                        $ok++; continue
                    }
                }
                switch ($it.T) {
                    'reg' {
                        if ($it.E) {
                            $val = switch ($it.K) {
                                'Binary'      { [byte[]]@($it.V) }
                                'DWord'       { [int]$it.V }
                                'QWord'       { [long]$it.V }
                                'MultiString' { [string[]]@($it.V) }
                                default       { [string]$it.V }
                            }
                            if (-not (Test-Path -LiteralPath $it.P)) { New-Item -Path $it.P -Force | Out-Null }
                            New-ItemProperty -LiteralPath $it.P -Name $it.N -Value $val -PropertyType $it.K -Force -ErrorAction Stop | Out-Null
                        } elseif (Test-Path -LiteralPath $it.P) {
                            $k = Get-Item -LiteralPath $it.P
                            if ($it.PSObject.Properties.Name -contains 'KX' -and -not $it.KX -and $k.SubKeyCount -eq 0 -and $k.ValueCount -le 1) {
                                # chave criada pelo TurboPC e sem mais nada dentro: sai inteira (ex.: menu de clique direito clássico)
                                Remove-Item -LiteralPath $it.P -Force -ErrorAction Stop
                            } else {
                                # pelo .NET porque o Remove-ItemProperty não apaga o valor "(padrão)" de uma chave
                                $hives = @{ HKEY_LOCAL_MACHINE = [Microsoft.Win32.Registry]::LocalMachine; HKEY_USERS = [Microsoft.Win32.Registry]::Users; HKEY_CURRENT_USER = [Microsoft.Win32.Registry]::CurrentUser }
                                $full = $k.Name   # ex.: HKEY_USERS\S-1-5-...\Software\...
                                $root, $sub = $full -split '\\', 2
                                $w = $hives[$root].OpenSubKey($sub, $true)
                                if ($w) { $w.DeleteValue($(if ($it.N -eq '(default)') { '' } else { $it.N }), $false); $w.Close() }
                            }
                        }
                    }
                    'svc' {
                        if ('Automatic', 'Manual', 'Disabled' -contains $it.S) { Set-Service -Name $it.N -StartupType $it.S -ErrorAction Stop }
                        if ($it.R) { Start-Service -Name $it.N -ErrorAction SilentlyContinue }
                        Write-TLog "  serviço $($it.N) -> $($it.S)"
                    }
                    'task'  { Enable-ScheduledTask -TaskPath $it.P -TaskName $it.N -ErrorAction Stop | Out-Null; Write-TLog "  tarefa $($it.N) religada" }
                    'power' { powercfg /setactive $it.G | Out-Null; Write-TLog '  plano de energia anterior restaurado' }
                    'hib'   { powercfg /hibernate on | Out-Null; Write-TLog '  hibernação religada' }
                }
                $ok++
            } catch {
                $fail++
                Write-TLog "  não deu para desfazer $($it.T) $($it.P) $($it.N): $($_.Exception.Message)" 'WARN'
            }
        }
        foreach ($n in @($rec.Notes)) { if ($n) { Write-TLog "  atenção: $n" 'WARN' } }
        $rec.Undone = (Get-Date).ToString('s')
        $rec.PSObject.Properties.Remove('File')
        $rec | ConvertTo-Json -Depth 6 | Set-Content -Path $File -Encoding UTF8
        Write-TLog "==== Desfeito: $ok alteração(ões) revertida(s), $fail com problema. Reinicie o PC. ====" 'STEP'
    }
}

. $TaskLibrary

