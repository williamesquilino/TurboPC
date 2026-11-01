# [parte] Tarefas da categoria Privacidade
        # ======================= PRIVACIDADE =======================
        [pscustomobject]@{ Id='telemetry'; Cat='Privacidade'; Rec=$true; Warn=''
            Name='Reduzir telemetria'
            Desc='Desliga o serviço de coleta de dados (DiagTrack) e tarefas agendadas que pesam no PC, como o Compatibility Appraiser.'
            Action={
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
                Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
                Set-Svc 'DiagTrack' 'Disabled'
                Set-Svc 'dmwappushservice' 'Disabled'
                $sched = @(
                    @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
                    @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
                    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
                    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
                    @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticDataCollector')
                )
                foreach ($t in $sched) { Disable-TTask $t[0] $t[1] }
                Write-TLog '  telemetria reduzida' 'OK'
            } }

        [pscustomobject]@{ Id='adsid'; Cat='Privacidade'; Rec=$true; Warn=''
            Name='Desativar ID de anúncios'
            Desc='Impede que apps usem um identificador para mostrar propaganda personalizada.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
                Write-TLog '  ID de anúncios desativado' 'OK'
            } }

        [pscustomobject]@{ Id='activity'; Cat='Privacidade'; Rec=$true; Warn=''
            Name='Desativar histórico de atividades'
            Desc='Para de registrar e enviar tudo o que é aberto no PC (linha do tempo).'
            Action={
                $k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
                Set-Reg $k 'EnableActivityFeed' 0
                Set-Reg $k 'PublishUserActivities' 0
                Set-Reg $k 'UploadUserActivities' 0
                Write-TLog '  histórico de atividades desativado' 'OK'
            } }

        [pscustomobject]@{ Id='websearch'; Cat='Privacidade'; Rec=$true; Warn=''
            Name='Tirar pesquisa do Bing do menu Iniciar'
            Desc='A pesquisa do Iniciar passa a procurar só no PC. Fica mais rápida e não manda o que é digitado para a internet.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0
                Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
                Write-TLog '  pesquisa web removida do Iniciar' 'OK'
            } }

        [pscustomobject]@{ Id='widgets'; Cat='Privacidade'; Rec=$true; Warn=''
            Name='Desativar Widgets / Notícias e Interesses'
            Desc='Remove o painel de notícias e clima da barra de tarefas, que fica carregando conteúdo da internet.'
            Action={
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0
                Write-TLog '  widgets desativados' 'OK'
            } }

        [pscustomobject]@{ Id='copilot'; Cat='Privacidade'; Rec=$false; Warn=''
            Name='Desativar Copilot do Windows'
            Desc='Esconde o Copilot da barra de tarefas via política.'
            Action={
                Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
                Write-TLog '  Copilot desativado' 'OK'
            } }

        [pscustomobject]@{ Id='recall'; Cat='Privacidade'; Rec=$true; Warn=''
            Name='Desativar Recall'
            Desc='Impede o Windows 11 de tirar "fotos" da tela o tempo todo para a busca com IA. Só existe em PCs Copilot+, nos outros não muda nada.'
            Action={
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
                Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
                Write-TLog '  Recall desativado' 'OK'
            } }

        [pscustomobject]@{ Id='cortana'; Cat='Privacidade'; Rec=$true; Warn=''
            Name='Desativar Cortana'
            Desc='Desliga a assistente no Windows 10, que fica carregada na memória sem ninguém usar.'
            Action={
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
                Write-TLog '  Cortana desativada' 'OK'
            } }

        [pscustomobject]@{ Id='feedback'; Cat='Privacidade'; Rec=$true; Warn=''
            Name='Sem pedidos de feedback e "experiências personalizadas"'
            Desc='Para os pop-ups pedindo avaliação do Windows e o uso dos dados de diagnóstico para mostrar dicas e propaganda.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
                Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' 'DisableTailoredExperiencesWithDiagnosticData' 1
                Write-TLog '  feedback e experiências personalizadas desligados' 'OK'
            } }

