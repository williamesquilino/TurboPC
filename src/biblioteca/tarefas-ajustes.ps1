# [parte] Tarefas da categoria Ajustes
        # ======================= AJUSTES =======================
        [pscustomobject]@{ Id='fileext'; Cat='Ajustes'; Rec=$true; Warn=''
            Name='Mostrar extensões dos arquivos'
            Desc='Mostra o ".pdf", ".exe" no nome. Ajuda a não cair em vírus do tipo "nota_fiscal.pdf.exe" que chega por e-mail.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0
                Write-TLog '  extensões visíveis' 'OK'
            } }

        [pscustomobject]@{ Id='numlock'; Cat='Ajustes'; Rec=$true; Warn=''
            Name='Num Lock ligado ao iniciar'
            Desc='O teclado numérico já vem ligado na tela de senha e depois do login. Acaba com o "minha senha não entra".'
            Action={
                Set-Reg 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' 'String'
                Set-Reg 'HKCU:\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' 'String'
                Write-TLog '  Num Lock ligado na inicialização' 'OK'
            } }

        [pscustomobject]@{ Id='thispc'; Cat='Ajustes'; Rec=$false; Warn=''
            Name='Explorador abre em "Este Computador"'
            Desc='Abre mostrando os discos e pastas em vez de "Acesso rápido" / "Início".'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 1
                Write-TLog '  Explorador abre em Este Computador' 'OK'
            } }

        [pscustomobject]@{ Id='classicmenu'; Cat='Ajustes'; Rec=$false; Warn='Só Windows 11. Vale depois de reiniciar ou sair e entrar.'
            Name='Menu de clique direito completo (Windows 11)'
            Desc='Volta o menu do botão direito do Windows 10, sem precisar clicar em "Mostrar mais opções".'
            Action={
                Set-Reg 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '(default)' '' 'String'
                Write-TLog '  menu clássico ativado' 'OK'
            } }

        [pscustomobject]@{ Id='taskbarleft'; Cat='Ajustes'; Rec=$false; Warn='Só Windows 11.'
            Name='Botão Iniciar à esquerda (Windows 11)'
            Desc='Alinha a barra de tarefas à esquerda, como no Windows 10. Usuários acostumados agradecem.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAl' 0
                Write-TLog '  barra de tarefas à esquerda' 'OK'
            } }

        [pscustomobject]@{ Id='endtask'; Cat='Ajustes'; Rec=$false; Warn='Só Windows 11 (23H2 ou mais novo).'
            Name='"Finalizar tarefa" na barra de tarefas'
            Desc='Clique direito num programa travado na barra de tarefas > Finalizar tarefa, sem abrir o Gerenciador de Tarefas.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' 'TaskbarEndTask' 1
                Write-TLog '  Finalizar tarefa habilitado' 'OK'
            } }

