# [parte] Tarefas da categoria Reparo (e o fim da lista de tarefas)
        # ======================= REPARO =======================
        [pscustomobject]@{ Id='optimizedisk'; Cat='Reparo'; Rec=$false
            Warn='Em HD antigo a desfragmentação pode levar mais de uma hora.'
            Name='Otimizar disco (TRIM / desfragmentar)'
            Desc='Detecta sozinho: faz TRIM se for SSD e desfragmenta se for HD mecânico.'
            Action={
                $letter = $env:SystemDrive.TrimEnd(':')
                Optimize-Volume -DriveLetter $letter -ErrorAction Stop
                Write-TLog "  unidade $letter`: otimizada" 'OK'
            } }

        [pscustomobject]@{ Id='sfc'; Cat='Reparo'; Rec=$false; Warn='Leva de 10 a 30 minutos.'
            Name='Verificar arquivos do sistema (SFC)'
            Desc='Procura e corrige arquivos do Windows corrompidos. Bom para PC com erros estranhos ou tela azul.'
            Action={
                $c = Invoke-Exe "$env:windir\System32\sfc.exe" '/scannow'
                Write-TLog "  SFC terminou (código $c). Detalhes em C:\Windows\Logs\CBS\CBS.log" 'OK'
            } }

        [pscustomobject]@{ Id='dism'; Cat='Reparo'; Rec=$false; Warn='Precisa de internet e pode levar de 15 a 40 minutos.'
            Name='Reparar imagem do Windows (DISM)'
            Desc='Conserta a base que o SFC usa. Rode antes do SFC quando o SFC não conseguir corrigir.'
            Action={
                $c = Invoke-Exe "$env:windir\System32\dism.exe" '/Online /Cleanup-Image /RestoreHealth'
                if ($c -eq 0) { Write-TLog '  DISM concluído sem erros' 'OK' } else { Write-TLog "  DISM terminou com código $c" 'WARN' }
            } }

        [pscustomobject]@{ Id='componentcleanup'; Cat='Reparo'; Rec=$false; Warn='Pode levar de 5 a 20 minutos.'
            Name='Limpar componentes antigos do Windows (WinSxS)'
            Desc='Remove versões antigas de atualizações já instaladas. Costuma liberar alguns GB.'
            Action={
                $c = Invoke-Exe "$env:windir\System32\dism.exe" '/Online /Cleanup-Image /StartComponentCleanup'
                if ($c -eq 0) { Write-TLog '  limpeza de componentes concluída' 'OK' } else { Write-TLog "  DISM terminou com código $c" 'WARN' }
            } }

        [pscustomobject]@{ Id='chkdsk'; Cat='Reparo'; Rec=$false; Warn=''
            Name='Verificar erros no disco'
            Desc='Analisa o sistema de arquivos do C: sem precisar reiniciar (chkdsk /scan).'
            Action={
                $c = Invoke-Exe "$env:windir\System32\chkdsk.exe" "$env:SystemDrive /scan"
                if ($c -eq 0) { Write-TLog '  nenhum erro encontrado no disco' 'OK' } else { Write-TLog "  chkdsk encontrou problemas (código $c). Rode 'chkdsk C: /f' e reinicie." 'WARN' }
            } }

        [pscustomobject]@{ Id='netreset'; Cat='Reparo'; Rec=$false
            Warn='Precisa reiniciar. Configurações de IP fixo e VPN podem precisar ser refeitas.'
            Name='Resetar rede (Winsock / TCP-IP)'
            Desc='Para quando a internet "está conectada" mas nada abre.'
            Action={
                Add-UndoNote 'Reset de rede não tem como desfazer (IP fixo e VPN podem precisar ser configurados de novo).'
                netsh winsock reset | Out-Null
                netsh int ip reset | Out-Null
                ipconfig /flushdns | Out-Null
                Write-TLog '  pilha de rede resetada (reinicie o PC)' 'OK'
            } }

        [pscustomobject]@{ Id='wureset'; Cat='Reparo'; Rec=$false; Warn='O próximo Windows Update demora mais, porque ele reconstrói o histórico.'
            Name='Consertar o Windows Update'
            Desc='Para quando as atualizações ficam travadas em 0% ou falham sempre. Recria as pastas SoftwareDistribution e catroot2 (as antigas ficam com ".old").'
            Action={
                $svcs = 'wuauserv', 'bits', 'cryptsvc', 'msiserver'
                foreach ($s in $svcs) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
                foreach ($d in "$env:windir\SoftwareDistribution", "$env:windir\System32\catroot2") {
                    try {
                        if (Test-Path "$d.old") { Remove-Item "$d.old" -Recurse -Force -ErrorAction SilentlyContinue }
                        if (Test-Path $d) { Rename-Item -Path $d -NewName "$(Split-Path $d -Leaf).old" -ErrorAction Stop }
                        Write-TLog "  $d recriada"
                    } catch { Write-TLog "  não foi possível renomear $d ($($_.Exception.Message))" 'WARN' }
                }
                foreach ($s in $svcs) { Start-Service -Name $s -ErrorAction SilentlyContinue }
                Write-TLog '  Windows Update resetado' 'OK'
            } }

        [pscustomobject]@{ Id='printqueue'; Cat='Reparo'; Rec=$false; Warn='Cancela todas as impressões que estão na fila.'
            Name='Destravar fila de impressão'
            Desc='Para quando um documento trava a fila e nada mais imprime. Reinicia o Spooler e limpa os trabalhos presos.'
            Action={
                Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
                [void](Clear-PathContents @("$env:windir\System32\spool\PRINTERS"))
                Start-Service -Name Spooler -ErrorAction SilentlyContinue
                Write-TLog '  fila de impressão limpa' 'OK'
            } }

        [pscustomobject]@{ Id='timesync'; Cat='Reparo'; Rec=$false; Warn=''
            Name='Acertar o relógio'
            Desc='Sincroniza a hora com a internet ou com o servidor da empresa. Hora errada causa erro de certificado em sites e sistemas.'
            Action={
                if ((Get-Service w32time -ErrorAction SilentlyContinue).StartType -eq 'Disabled') { Set-Svc 'w32time' 'Manual' }
                Start-Service -Name w32time -ErrorAction SilentlyContinue
                $c = Invoke-Exe "$env:windir\System32\w32tm.exe" '/resync /force'
                if ($c -eq 0) { Write-TLog '  relógio sincronizado' 'OK' } else { Write-TLog "  w32tm terminou com código $c" 'WARN' }
            } }

        [pscustomobject]@{ Id='iconcache'; Cat='Reparo'; Rec=$false; Warn='Vale depois de reiniciar.'
            Name='Reconstruir cache de ícones'
            Desc='Corrige ícones em branco, trocados ou que não atualizam na área de trabalho e no Explorador.'
            Action={
                $paths = @()
                foreach ($p in Get-ProfilePaths) { $paths += "$p\AppData\Local\IconCache.db", "$p\AppData\Local\Microsoft\Windows\Explorer\iconcache_*.db" }
                [void](Clear-PathContents $paths)
                [void](Invoke-Exe "$env:windir\System32\ie4uinit.exe" '-show')
                Write-TLog '  cache de ícones marcado para reconstrução' 'OK'
            } }
    )

