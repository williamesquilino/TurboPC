# [parte] Tarefas da categoria Desempenho
        # ======================= DESEMPENHO =======================
        [pscustomobject]@{ Id='powerplan'; Cat='Desempenho'; Rec=(-not $Global:IsLaptop)
            Warn=$(if ($Global:IsLaptop) { 'Notebook detectado: gasta mais bateria. Indicado só para notebooks que ficam na tomada.' } else { '' })
            Name='Plano de energia Alto Desempenho'
            Desc='Impede que o processador fique "economizando" e travando o sistema. Faz bastante diferença em PCs fracos.'
            Action={
                Save-PowerPlan
                powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { Write-TLog '  plano Alto Desempenho ativado' 'OK'; return }
                $out = (powercfg /duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null) -join ' '
                if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})') {
                    powercfg /setactive $Matches[1] | Out-Null
                    Write-TLog '  plano Alto Desempenho criado e ativado' 'OK'
                } else {
                    Write-TLog '  este PC não permite trocar o plano de energia (Modern Standby)' 'WARN'
                }
            } }

        [pscustomobject]@{ Id='visualfx'; Cat='Desempenho'; Rec=$true; Warn=''
            Name='Efeitos visuais para desempenho'
            Desc='Desliga animações, sombras e transições, mas mantém as fontes suaves para não ficar feio. Vale após sair e entrar de novo.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3
                Set-Reg 'HKCU:\Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) 'Binary'
                Set-Reg 'HKCU:\Control Panel\Desktop' 'FontSmoothing' '2' 'String'
                Set-Reg 'HKCU:\Control Panel\Desktop' 'DragFullWindows' '0' 'String'
                Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewShadow' 0
                Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
                Write-TLog '  efeitos visuais ajustados' 'OK'
            } }

        [pscustomobject]@{ Id='transparency'; Cat='Desempenho'; Rec=$true; Warn=''
            Name='Desligar transparência'
            Desc='Remove o efeito de vidro da barra de tarefas e do menu Iniciar, que pesa em placas de vídeo integradas antigas.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
                Write-TLog '  transparência desligada' 'OK'
            } }

        [pscustomobject]@{ Id='startupdelay'; Cat='Desempenho'; Rec=$true; Warn=''
            Name='Inicialização e menus mais rápidos'
            Desc='Tira o atraso artificial que o Windows coloca nos programas de inicialização e deixa os menus abrirem mais rápido.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'WaitForIdleState' 0
                Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '100' 'String'
                Write-TLog '  atrasos removidos' 'OK'
            } }

        [pscustomobject]@{ Id='gamedvr'; Cat='Desempenho'; Rec=$true; Warn=''
            Name='Desativar Xbox Game Bar / gravação de jogos'
            Desc='Desliga a gravação em segundo plano do Game DVR, que consome CPU e disco à toa em PC de escritório.'
            Action={
                Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
                Write-TLog '  Game DVR desativado' 'OK'
            } }

        [pscustomobject]@{ Id='services'; Cat='Desempenho'; Rec=$true; Warn='Não use em PC de jogos: quebra o Game Pass, o app Xbox e o login Xbox de vários jogos.'
            Name='Desativar serviços inúteis no escritório'
            Desc='Serviços do Xbox, modo demonstração de loja, mapas offline e compartilhamento do Windows Media Player.'
            Action={
                foreach ($s in 'XblAuthManager','XblGameSave','XboxNetApiSvc','XboxGipSvc','RetailDemo','MapsBroker','WMPNetworkSvc') {
                    Set-Svc $s 'Disabled'
                }
                Write-TLog '  serviços ajustados' 'OK'
            } }

        [pscustomobject]@{ Id='suggestions'; Cat='Desempenho'; Rec=$true; Warn=''
            Name='Desligar dicas, sugestões e apps instalados sozinhos'
            Desc='Impede o Windows de instalar Candy Crush & cia., mostrar propaganda no menu Iniciar e ficar dando "dicas".'
            Action={
                $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
                foreach ($v in 'SilentInstalledAppsEnabled','SystemPaneSuggestionsEnabled','SoftLandingEnabled','PreInstalledAppsEnabled',
                               'OemPreInstalledAppsEnabled','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled',
                               'SubscribedContent-353694Enabled','SubscribedContent-353696Enabled','SubscribedContent-310093Enabled',
                               'SubscribedContent-338387Enabled','RotatingLockScreenOverlayEnabled') {
                    Set-Reg $k $v 0
                }
                # "Vamos concluir a configuração do seu dispositivo" depois de atualizações
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
                Write-TLog '  sugestões desligadas' 'OK'
            } }

        [pscustomobject]@{ Id='bloat'; Cat='Desempenho'; Rec=$false
            Warn='Remove de todos os usuários. Não mexe em Calculadora, Fotos, Loja, Office, Teams nem Outlook. Não use em PC de jogos (remove o app Xbox).'
            Name='Remover apps inúteis pré-instalados'
            Desc='Xbox, Solitaire, Clipchamp, Notícias, Dicas, Hub de Comentários, Mixed Reality, Spotify, Disney+, jogos da King etc.'
            Action={
                $apps = 'Microsoft.BingNews','Microsoft.GamingApp','Microsoft.XboxApp','Microsoft.Xbox.TCUI','Microsoft.XboxGamingOverlay',
                        'Microsoft.XboxGameOverlay','Microsoft.XboxSpeechToTextOverlay','Microsoft.XboxIdentityProvider',
                        'Microsoft.MicrosoftSolitaireCollection','Microsoft.ZuneMusic','Microsoft.ZuneVideo','Microsoft.People',
                        'Microsoft.MixedReality.Portal','Microsoft.SkypeApp','Microsoft.GetHelp','Microsoft.Getstarted',
                        'Microsoft.WindowsFeedbackHub','Microsoft.549981C3F5F10','Clipchamp.Clipchamp','Microsoft.MicrosoftOfficeHub',
                        'MicrosoftCorporationII.MicrosoftFamily','Microsoft.3DBuilder','Microsoft.Microsoft3DViewer',
                        'king.com.*','SpotifyAB.SpotifyMusic','Disney.*','*.TikTok','*.Instagram','*.Facebook'
                $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
                foreach ($a in $apps) {
                    foreach ($p in @(Get-AppxPackage -AllUsers -Name $a -ErrorAction SilentlyContinue)) {
                        try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop; Write-TLog "  removido: $($p.Name)" }
                        catch { Write-TLog "  não removido: $($p.Name)" 'WARN' }
                    }
                    foreach ($p in ($prov | Where-Object { $_.DisplayName -like $a })) {
                        try { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null } catch {}
                    }
                }
                Add-UndoNote 'Apps removidos não voltam sozinhos: se precisar de algum, instale de novo pela Microsoft Store.'
                Write-TLog '  remoção concluída' 'OK'
            } }

        [pscustomobject]@{ Id='backgroundapps'; Cat='Desempenho'; Rec=$false
            Warn='Pode atrasar notificações de apps da Loja (inclusive o novo Teams).'
            Name='Bloquear apps da Loja em segundo plano'
            Desc='Impede que apps da Microsoft Store fiquem rodando escondidos depois de fechados.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0
                Write-TLog '  apps em segundo plano bloqueados' 'OK'
            } }

        [pscustomobject]@{ Id='indexing'; Cat='Desempenho'; Rec=$false
            Warn='A pesquisa do Outlook e do Explorador fica bem mais lenta. Use só em PC com HDD que vive com disco a 100%.'
            Name='Desativar indexação da pesquisa'
            Desc='Desliga o serviço Windows Search, que fica lendo o disco o tempo todo.'
            Action={ Set-Svc 'WSearch' 'Disabled'; Write-TLog '  indexação desativada' 'OK' } }

        [pscustomobject]@{ Id='hibernate'; Cat='Desempenho'; Rec=$false
            Warn='Desliga a hibernação e a Inicialização Rápida. Em notebook, perde a opção Hibernar.'
            Name='Desativar hibernação'
            Desc='Apaga o hiberfil.sys e libera alguns GB no C: (o tamanho depende da RAM).'
            Action={
                if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue).HibernateEnabled -eq 1) { Add-UndoItem ([ordered]@{ T = 'hib' }) 'hib' }
                powercfg /hibernate off | Out-Null
                Write-TLog '  hibernação desativada' 'OK'
            } }

        [pscustomobject]@{ Id='browserbg'; Cat='Desempenho'; Rec=$true; Warn='O Edge e o Chrome vão mostrar "Gerenciado pela sua organização". É normal, é assim que a configuração é aplicada.'
            Name='Navegadores não ficam abertos escondidos'
            Desc='Impede o Edge e o Chrome de continuarem rodando depois de fechados e de abrirem junto com o Windows (Inicialização Turbo). Economiza bastante RAM.'
            Action={
                # navegador que já tem política da empresa (bloqueio de sites, extensões...) fica como está: quem manda nele é a GPO
                $mine = 'StartupBoostEnabled', 'BackgroundModeEnabled'
                foreach ($br in @(@{ N = 'Edge'; P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; V = $mine },
                                  @{ N = 'Chrome'; P = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; V = @('BackgroundModeEnabled') })) {
                    $k = Get-Item -LiteralPath $br.P -ErrorAction SilentlyContinue
                    $other = @(if ($k) { @($k.GetValueNames() | Where-Object { $mine -notcontains $_ }) + @($k.GetSubKeyNames()) })
                    if ($other.Count) { Write-TLog "  $($br.N) já tem políticas da empresa: não foi alterado" 'WARN'; continue }
                    foreach ($v in $br.V) { Set-Reg $br.P $v 0 }
                    Write-TLog "  $($br.N) sem segundo plano" 'OK'
                }
            } }

