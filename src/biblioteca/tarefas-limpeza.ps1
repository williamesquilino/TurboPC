# [parte] Tarefas da categoria Limpeza
        # ======================= LIMPEZA =======================
        [pscustomobject]@{ Id='temp'; Cat='Limpeza'; Rec=$true; Warn=''
            Name='Arquivos temporários'
            Desc='Limpa a pasta Temp do Windows e de todos os usuários do PC. Arquivos em uso são ignorados.'
            Action={
                $paths = @("$env:windir\Temp")
                foreach ($p in Get-ProfilePaths) { $paths += "$p\AppData\Local\Temp" }
                $f = Clear-PathContents $paths
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        [pscustomobject]@{ Id='wucache'; Cat='Limpeza'; Rec=$true; Warn=''
            Name='Cache do Windows Update'
            Desc='Apaga instaladores de atualizações já baixados e o cache de Otimização de Entrega. O Windows baixa de novo se precisar.'
            Action={
                foreach ($s in 'wuauserv','bits') { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
                $f = Clear-PathContents @("$env:windir\SoftwareDistribution\Download")
                foreach ($s in 'bits','wuauserv') { Start-Service -Name $s -ErrorAction SilentlyContinue }
                try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop | Out-Null } catch {}
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        [pscustomobject]@{ Id='browsercache'; Cat='Limpeza'; Rec=$true; Warn=''
            Name='Cache dos navegadores'
            Desc='Chrome, Edge, Brave e Firefox (todos os usuários). Apaga só o cache: senhas, favoritos, histórico e logins continuam.'
            Action={
                $paths = @()
                foreach ($p in Get-ProfilePaths) {
                    foreach ($b in 'Google\Chrome','Microsoft\Edge','BraveSoftware\Brave-Browser') {
                        $ud = "$p\AppData\Local\$b\User Data"
                        $paths += "$ud\*\Cache", "$ud\*\Code Cache", "$ud\*\GPUCache", "$ud\ShaderCache"
                    }
                    $paths += "$p\AppData\Local\Mozilla\Firefox\Profiles\*\cache2"
                }
                $f = Clear-PathContents $paths
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        [pscustomobject]@{ Id='dumps'; Cat='Limpeza'; Rec=$true; Warn=''
            Name='Relatórios de erro e despejos de memória'
            Desc='Remove relatórios do Windows Error Reporting, minidumps e MEMORY.DMP de travamentos antigos.'
            Action={
                $paths = @("$env:windir\Minidump", "$env:windir\MEMORY.DMP", "$env:windir\LiveKernelReports\*.dmp",
                           "$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue")
                foreach ($p in Get-ProfilePaths) {
                    $paths += "$p\AppData\Local\CrashDumps", "$p\AppData\Local\Microsoft\Windows\WER\ReportArchive"
                }
                $f = Clear-PathContents $paths
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        [pscustomobject]@{ Id='dns'; Cat='Limpeza'; Rec=$true; Warn=''
            Name='Limpar cache de DNS'
            Desc='Resolve sites que não abrem ou abrem o endereço antigo depois de mudanças na rede.'
            Action={
                Clear-DnsClientCache -ErrorAction SilentlyContinue
                ipconfig /flushdns | Out-Null
                Write-TLog '  cache de DNS limpo' 'OK'
            } }

        [pscustomobject]@{ Id='recycle'; Cat='Limpeza'; Rec=$false; Warn='Apaga de vez o que está na Lixeira de TODOS os usuários.'
            Name='Esvaziar Lixeira'
            Desc='Esvazia a Lixeira da unidade do sistema.'
            Action={
                $f = Clear-PathContents @("$env:SystemDrive\`$Recycle.Bin\*")
                Clear-RecycleBin -Force -ErrorAction SilentlyContinue
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        [pscustomobject]@{ Id='thumbcache'; Cat='Limpeza'; Rec=$true; Warn=''
            Name='Cache de miniaturas'
            Desc='Apaga as miniaturas de fotos e vídeos guardadas pelo Explorador. Ele recria só as que forem abertas de novo.'
            Action={
                $paths = @()
                foreach ($p in Get-ProfilePaths) { $paths += "$p\AppData\Local\Microsoft\Windows\Explorer\thumbcache_*.db" }
                $f = Clear-PathContents $paths
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        [pscustomobject]@{ Id='appcache'; Cat='Limpeza'; Rec=$true; Warn=''
            Name='Cache de Teams, Discord, Slack, Spotify e Steam'
            Desc='Esses apps guardam GBs de cache que só crescem. Conversas, contas e configurações não são apagadas. Feche os apps antes.'
            Action={
                $paths = @()
                foreach ($p in Get-ProfilePaths) {
                    $r = "$p\AppData\Roaming"; $l = "$p\AppData\Local"
                    foreach ($app in "$r\Microsoft\Teams", "$r\discord", "$r\Slack", "$l\Steam\htmlcache",
                                     "$l\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\*") {
                        $paths += "$app\Cache", "$app\Code Cache", "$app\GPUCache"
                    }
                    $paths += "$r\Microsoft\Teams\Service Worker\CacheStorage", "$l\Spotify\Data"
                }
                $f = Clear-PathContents $paths
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        [pscustomobject]@{ Id='shadercache'; Cat='Limpeza'; Rec=$false
            Warn='Os jogos ficam com travadinhas nos primeiros minutos enquanto recriam o cache. Use depois de atualizar o driver de vídeo.'
            Name='Cache de shaders (DirectX, NVIDIA, AMD, Intel)'
            Desc='Resolve travadinhas e gráficos bugados que aparecem depois de trocar ou atualizar o driver de vídeo.'
            Action={
                $paths = @("$env:ProgramData\NVIDIA Corporation\NV_Cache")
                foreach ($p in Get-ProfilePaths) {
                    $l = "$p\AppData\Local"
                    $paths += "$l\D3DSCache", "$l\NVIDIA\DXCache", "$l\NVIDIA\GLCache", "$l\AMD\DxCache", "$l\AMD\DxcCache", "$l\AMD\GLCache", "$l\Intel\ShaderCache"
                }
                $f = Clear-PathContents $paths
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        [pscustomobject]@{ Id='driverinstallers'; Cat='Limpeza'; Rec=$false; Warn=''
            Name='Instaladores de driver antigos'
            Desc='Esvazia as pastas C:\NVIDIA e C:\AMD, onde ficam os arquivos extraídos na instalação do driver de vídeo. O driver instalado não é afetado.'
            Action={
                $f = Clear-PathContents @("$env:SystemDrive\NVIDIA", "$env:SystemDrive\AMD")
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        [pscustomobject]@{ Id='cleanmgr'; Cat='Limpeza'; Rec=$false
            Warn='Pode levar de 5 a 30 minutos. Apaga o Windows.old: depois não dá para voltar para a versão anterior do Windows.'
            Name='Limpeza de Disco completa do Windows'
            Desc='Roda a Limpeza de Disco do próprio Windows com todas as opções de sistema: instalações antigas do Windows, atualizações substituídas, logs de instalação e mais.'
            Action={
                $vc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
                $skip = 'DownloadsFolder', 'Recycle Bin', 'BranchCache', 'Windows Defender'
                foreach ($k in Get-ChildItem $vc -ErrorAction SilentlyContinue) {
                    if ($skip -notcontains $k.PSChildName) { Set-Reg $k.PSPath 'StateFlags0777' 2 }
                }
                $free = { (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace }
                $before = & $free
                [void](Invoke-Exe "$env:windir\System32\cleanmgr.exe" '/sagerun:777')
                $f = [math]::Max([int64]0, [int64](& $free) - [int64]$before)
                $Global:TotalFreed += $f
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

