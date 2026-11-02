# [parte] Tarefas da categoria Jogos (inclui driver NVIDIA/AMD)
        # ======================= JOGOS =======================
        [pscustomobject]@{ Id='gamemode'; Cat='Jogos'; Rec=$false; Warn=''
            Name='Ligar o Modo de Jogo'
            Desc='O Windows prioriza o jogo aberto e segura atualizações e notificações enquanto você joga. Reduz travadinhas.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
                Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
                Write-TLog '  Modo de Jogo ligado' 'OK'
            } }

        [pscustomobject]@{ Id='hags'; Cat='Jogos'; Rec=$false; Warn='Em alguns jogos competitivos (como o Valorant) pode baixar o FPS. Ligue só se for usar o DLSS Frame Generation (RTX 4000 ou mais nova). Vale após reiniciar.'
            Name='Agendamento de GPU acelerado por hardware'
            Desc='A própria placa de vídeo gerencia sua memória. Menos latência e às vezes alguns FPS a mais; necessário para o DLSS Frame Generation.'
            Action={
                Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
                Write-TLog '  agendamento de GPU ativado (reinicie)' 'OK'
            } }

        [pscustomobject]@{ Id='gamepriority'; Cat='Jogos'; Rec=$false; Warn=''
            Name='Prioridade de CPU e GPU para jogos'
            Desc='Ajusta o agendador multimídia do Windows para dar mais prioridade a jogos do que a tarefas de fundo.'
            Action={
                $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
                Set-Reg $mm 'SystemResponsiveness' 10
                Set-Reg "$mm\Tasks\Games" 'GPU Priority' 8
                Set-Reg "$mm\Tasks\Games" 'Priority' 6
                Set-Reg "$mm\Tasks\Games" 'Scheduling Category' 'High' 'String'
                Set-Reg "$mm\Tasks\Games" 'SFIO Priority' 'High' 'String'
                Write-TLog '  prioridades ajustadas' 'OK'
            } }

        [pscustomobject]@{ Id='mouseaccel'; Cat='Jogos'; Rec=$false; Warn='O mouse vai parecer diferente no Windows nos primeiros minutos.'
            Name='Desligar aceleração do mouse'
            Desc='Desliga a "precisão aprimorada do ponteiro": o mesmo movimento da mão sempre gira a mesma distância. Melhora a mira em jogos de tiro.'
            Action={
                Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
                Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
                Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
                Write-TLog '  aceleração do mouse desligada (vale no próximo login)' 'OK'
            } }

        [pscustomobject]@{ Id='deliveryp2p'; Cat='Jogos'; Rec=$false; Warn='Em empresas que usam compartilhamento de atualizações na rede local, deixe desligado.'
            Name='Não enviar atualizações para outros PCs'
            Desc='Impede que o Windows use sua internet para enviar atualizações para outros computadores. Evita picos de ping no meio do jogo.'
            Action={
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
                Write-TLog '  compartilhamento P2P de atualizações desligado' 'OK'
            } }

        [pscustomobject]@{ Id='stickykeys'; Cat='Jogos'; Rec=$false; Warn=''
            Name='Sem a janela de Teclas de Aderência'
            Desc='Apertar Shift 5 vezes (comum em jogos) não abre mais o aviso de Teclas de Aderência e minimiza o jogo. A acessibilidade continua disponível nas Configurações.'
            Action={
                Set-Reg 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'
                Set-Reg 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String'
                Set-Reg 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' 'String'
                Write-TLog '  atalhos de acessibilidade desligados' 'OK'
            } }

        [pscustomobject]@{ Id='ultimate'; Cat='Jogos'; Rec=$false
            Warn='Só para PC de mesa. Consome mais energia mesmo parado; em notebook acaba com a bateria.'
            Name='Plano de energia Desempenho Máximo'
            Desc='Plano escondido do Windows que tira até as micro-economias de energia do processador. Um passo além do Alto Desempenho.'
            Action={
                $guid = $null
                foreach ($line in (powercfg /list)) {
                    if ($line -match '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27}).*(Ultimate|Máximo|Maximo)') { $guid = $Matches[1] }
                }
                if (-not $guid) {
                    $out = (powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null) -join ' '
                    if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})') { $guid = $Matches[1] }
                }
                if ($guid) { Save-PowerPlan; powercfg /setactive $guid | Out-Null; Write-TLog '  plano Desempenho Máximo ativado' 'OK' }
                else { Write-TLog '  este PC não permite o plano Desempenho Máximo' 'WARN' }
            } }

        [pscustomobject]@{ Id='powerthrottle'; Cat='Jogos'; Rec=$false; Warn='Em notebook, gasta mais bateria.'
            Name='Desligar limitação de energia de processos'
            Desc='O Windows 10/11 "freia" programas que ele acha que estão em segundo plano. Às vezes freia o jogo, o Discord ou o OBS junto.'
            Action={
                Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
                Write-TLog '  limitação de energia desligada (reinicie)' 'OK'
            } }

        [pscustomobject]@{ Id='nvidiadrv'; Cat='Jogos'; Rec=$false
            Warn=$(if ($Global:HasNvidia) { 'Para desfazer: Painel de Controle NVIDIA > Gerenciar as configurações 3D > Restaurar. Precisa de internet na primeira vez.' } else { 'Nenhuma placa NVIDIA neste PC: este item não faz nada aqui.' })
            Name='Otimizar driver NVIDIA'
            Desc='Muda as configurações globais do Painel de Controle NVIDIA só no que não tem efeito colateral: placa sempre em velocidade máxima durante o jogo, filtragem de textura em desempenho e o monitor na taxa mais alta. Não mexe em baixa latência nem no cache (use o NVIDIA Reflex dentro do jogo).'
            Action={
                if (-not $Global:HasNvidia) { Write-TLog '  nenhuma placa NVIDIA encontrada' 'WARN'; return }
                $npi = Find-NvInspector
                if (-not $npi) {
                    $wg = Find-Winget
                    if (-not $wg) { Write-TLog '  precisa do winget para baixar o NVIDIA Profile Inspector (veja Programas > Instalar)' 'WARN'; return }
                    Write-TLog '  baixando o NVIDIA Profile Inspector pelo winget...'
                    $base = 'install --id Orbmu2k.nvidiaProfileInspector -e --source winget --silent --accept-package-agreements --accept-source-agreements'
                    $c = Invoke-Exe $wg "$base --scope machine --disable-interactivity"
                    if (-not (Find-NvInspector)) { $c = Invoke-Exe $wg $base }
                    $npi = Find-NvInspector
                    if (-not $npi) { Write-TLog "  não foi possível baixar o NVIDIA Profile Inspector (código $c)" 'ERRO'; return }
                }
                # ID e valor de cada configuração, conforme a lista do próprio Profile Inspector.
                # Só o que nunca baixa FPS. Ficam de fora de propósito: modo de baixa latência (em jogo que depende do processador,
                # como Valorant e CS2, derruba o FPS; o NVIDIA Reflex do jogo faz isso melhor) e tamanho do cache de shaders
                # (mudar pode descartar o cache e fazer os jogos recompilarem tudo).
                $settings = @(
                    @('Power Management - Mode: Prefer maximum performance', 0x1057EB71, 1),
                    @('Texture Filtering - Quality: High performance',        0x00CE2691, 20),
                    @('Prefered Refreshrate: Highest available',              0x0064B541, 1)
                )
                $xmlSettings = foreach ($s in $settings) {
                    "<ProfileSetting><SettingNameInfo>$($s[0])</SettingNameInfo><SettingID>$([uint32]$s[1])</SettingID><SettingValue>$([uint32]$s[2])</SettingValue><ValueType>Dword</ValueType></ProfileSetting>"
                }
                $nip = Join-Path $env:TEMP 'TurboPC_NVIDIA.nip'
                $xml = '<?xml version="1.0" encoding="utf-8"?><ArrayOfProfile xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">' +
                       "<Profile><ProfileName>Base Profile</ProfileName><Executeables /><Settings>$($xmlSettings -join '')</Settings></Profile></ArrayOfProfile>"
                [IO.File]::WriteAllText($nip, $xml, (New-Object Text.UTF8Encoding $true))
                Write-TLog "  aplicando $($settings.Count) configurações no perfil global do driver"
                $p = Start-Process -FilePath $npi -ArgumentList "`"$nip`" -silentImport -mergeImport" -PassThru -WindowStyle Hidden
                if (-not $p.WaitForExit(90000)) { try { $p.Kill() } catch {}; Write-TLog '  o Profile Inspector não respondeu' 'ERRO'; return }
                foreach ($s in $settings) { Write-TLog "    $($s[0])" }
                Add-UndoNote 'Driver NVIDIA: para voltar ao padrão, abra o Painel de Controle NVIDIA > Gerenciar as configurações 3D > Restaurar.'
                Set-Svc 'NvTelemetryContainer' 'Disabled'
                Write-TLog '  driver NVIDIA otimizado' 'OK'
            } }

        [pscustomobject]@{ Id='amddrv'; Cat='Jogos'; Rec=$false
            Warn=$(if ($Global:HasAmd) { 'A AMD não documenta essas chaves. O backup fica em C:\ProgramData\TurboPC\backup (dois cliques no .reg desfaz). Para o resto, ligue o HYPR-RX no AMD Software.' } else { 'Nenhuma placa AMD neste PC: este item não faz nada aqui.' })
            Name='Otimizar driver AMD Radeon'
            Desc='Deixa o cache de shaders do driver sempre ligado, o que reduz as travadinhas quando o jogo carrega efeitos novos. Depois, aperte Alt+R e ligue o HYPR-RX (Anti-Lag + Radeon Boost), o modo de desempenho oficial da AMD.'
            Action={
                if (-not $Global:HasAmd) { Write-TLog '  nenhuma placa AMD encontrada' 'WARN'; return }
                $cls = 'SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
                $bk = "$env:ProgramData\TurboPC\backup"
                New-Item -ItemType Directory -Path $bk -Force | Out-Null
                $n = 0
                foreach ($k in Get-ChildItem "HKLM:\$cls" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' }) {
                    $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
                    if ("$($p.ProviderName) $($p.DriverDesc)" -notmatch 'AMD|ATI|Advanced Micro|Radeon') { continue }
                    if (-not (Test-Path "$($k.PSPath)\UMD")) { continue }
                    $file = "$bk\AMD_UMD_$($k.PSChildName)_$(Get-Date -Format 'yyyy-MM-dd_HH-mm').reg"
                    [void](Invoke-Exe "$env:windir\System32\reg.exe" "export `"HKLM\$cls\$($k.PSChildName)\UMD`" `"$file`" /y")
                    # texto em UTF-16 dentro de um valor binário: "2" = sempre ligado ("1" = otimizado pela AMD)
                    Set-Reg "$($k.PSPath)\UMD" 'ShaderCache' ([byte[]](0x32, 0x00)) 'Binary'
                    Write-TLog "  $($p.DriverDesc): cache de shaders sempre ligado (backup em $file)"
                    $n++
                }
                if ($n) { Write-TLog '  driver AMD ajustado (vale depois de reiniciar)' 'OK' } else { Write-TLog '  não encontrei as configurações do driver AMD' 'WARN' }
            } }

        [pscustomobject]@{ Id='gpupref'; Cat='Jogos'; Rec=$false; Warn=''
            Name='Jogos sempre na placa de vídeo dedicada'
            Desc='Marca os jogos da Steam e da Epic como "Alto desempenho" nas configurações de gráficos do Windows (em notebook, impede o jogo de rodar no vídeo integrado) e liga as otimizações para jogos em janela do Windows 11.'
            Action={
                $k = Resolve-UserPath 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
                $cur = [string](Get-ItemProperty $k -Name DirectXUserGlobalSettings -ErrorAction SilentlyContinue).DirectXUserGlobalSettings
                $opts = [ordered]@{}
                foreach ($kv in ($cur -split ';' | Where-Object { $_ -match '=' })) { $a = $kv -split '=', 2; $opts[$a[0]] = $a[1] }
                $opts['SwapEffectUpgradeEnable'] = '1'
                Set-Reg $k 'DirectXUserGlobalSettings' ((($opts.Keys | ForEach-Object { "$_=$($opts[$_])" }) -join ';') + ';') 'String'
                $games = Get-GameExes
                foreach ($g in $games) { Set-Reg $k $g 'GpuPreference=2;' 'String' }
                Write-TLog "  $($games.Count) executável(is) de jogos marcados como Alto desempenho" 'OK'
            } }

