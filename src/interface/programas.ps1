# [parte] Instalar programas (winget/Chocolatey)
# ---------------------------------------------------------------- instalar programas (winget / Chocolatey)
# Categoria ; Nome ; ID no winget ; pacote no Chocolatey ; como aparece em Programas instalados (regex) ; descrição
$AppCatalog = @'
Navegadores;Google Chrome;Google.Chrome;googlechrome;^Google Chrome$;O navegador mais usado.
Navegadores;Mozilla Firefox;Mozilla.Firefox;firefox;^Mozilla Firefox;Leve e focado em privacidade.
Navegadores;Brave;Brave.Brave;brave;^Brave;Chrome com bloqueador de anúncios embutido.
Navegadores;Opera GX;Opera.OperaGX;opera-gx;^Opera GX;Navegador "gamer" com limite de RAM e CPU.
Escritório;LibreOffice;TheDocumentFoundation.LibreOffice;libreoffice-fresh;^LibreOffice;Pacote Office gratuito: Writer, Calc e Impress.
Escritório;ONLYOFFICE;ONLYOFFICE.DesktopEditors;onlyoffice;^ONLYOFFICE;Office gratuito com visual parecido com o da Microsoft.
Escritório;Adobe Acrobat Reader;Adobe.Acrobat.Reader.64-bit;adobereader;^Adobe Acrobat;Leitor de PDF oficial, com assinatura digital.
Escritório;SumatraPDF;SumatraPDF.SumatraPDF;sumatrapdf;^SumatraPDF;Leitor de PDF levíssimo, ideal para PC fraco.
Escritório;PDF24 Creator;geeksoftwareGmbH.PDF24Creator;pdf24;^PDF24;Juntar, dividir, comprimir e converter PDFs.
Escritório;Notepad++;Notepad++.Notepad++;notepadplusplus;^Notepad\+\+;Bloco de notas avançado.
Comunicação;Zoom;Zoom.Zoom;zoom;^Zoom;Reuniões por vídeo.
Comunicação;Microsoft Teams;Microsoft.Teams;;^Microsoft Teams;Chat e reuniões da Microsoft.
Comunicação;WhatsApp;9NKSQGP7F2NH;;^WhatsApp;App oficial para PC (pela Microsoft Store).
Comunicação;Telegram;Telegram.TelegramDesktop;telegram;^Telegram Desktop;Mensagens e grupos.
Comunicação;Discord;Discord.Discord;discord;^Discord$;Voz e chat para grupos e jogos.
Comunicação;Slack;SlackTechnologies.Slack;slack;^Slack;Chat para equipes.
Acesso remoto;AnyDesk;AnyDesk.AnyDesk;anydesk;^AnyDesk;Suporte remoto rápido.
Acesso remoto;TeamViewer;TeamViewer.TeamViewer;teamviewer;^TeamViewer;Suporte remoto mais conhecido.
Utilitários;7-Zip;7zip.7zip;7zip;^7-Zip;Abre .zip, .rar e .7z. Gratuito.
Utilitários;WinRAR;RARLab.WinRAR;winrar;^WinRAR;Compactador clássico.
Utilitários;PowerToys;Microsoft.PowerToys;powertoys;^PowerToys;Ferramentas extras da Microsoft: redimensionar imagens, texto de prints e mais.
Utilitários;Everything;voidtools.Everything;everything;^Everything;Acha qualquer arquivo do PC na hora.
Utilitários;ShareX;ShareX.ShareX;sharex;^ShareX;Prints e gravação de tela.
Utilitários;Greenshot;Greenshot.Greenshot;greenshot;^Greenshot;Prints com setas e marcações, bem simples.
Mídia;VLC;VideoLAN.VLC;vlc;^VLC media player;Toca qualquer vídeo ou música.
Mídia;K-Lite Codec Pack;CodecGuide.K-LiteCodecPack.Standard;k-litecodecpack-standard;^K-Lite;Codecs e o Media Player Classic.
Mídia;OBS Studio;OBSProject.OBSStudio;obs-studio;^OBS Studio;Gravar a tela e fazer lives.
Mídia;Audacity;Audacity.Audacity;audacity;^Audacity;Editor de áudio.
Mídia;Paint.NET;dotPDN.PaintDotNet;paint.net;^paint\.net;Editor de imagens simples e leve.
Jogos;Steam;Valve.Steam;steam;^Steam$;Loja e biblioteca de jogos da Valve.
Jogos;Epic Games Launcher;EpicGames.EpicGamesLauncher;epicgameslauncher;^Epic Games Launcher;Loja da Epic (Fortnite e jogos grátis toda semana).
Jogos;EA app;ElectronicArts.EADesktop;ea-app;^EA app;Jogos da EA (EA FC, Battlefield, The Sims).
Jogos;Ubisoft Connect;Ubisoft.Connect;ubisoft-connect;^Ubisoft Connect;Jogos da Ubisoft.
Jogos;GOG Galaxy;GOG.Galaxy;goggalaxy;^GOG GALAXY;Jogos sem DRM da GOG.
Jogos;Battle.net;Blizzard.BattleNet;;^Battle\.net;Jogos da Blizzard e Call of Duty.
Jogos;MSI Afterburner;Guru3D.Afterburner;msiafterburner;^MSI Afterburner;Mostra FPS e temperatura dentro do jogo.
Componentes;Visual C++ 2015-2022 (64 bits);Microsoft.VCRedist.2015+.x64;vcredist140;Visual C\+\+ (v14 Redistributable|20(15|17|19|22)).*x64;Quase todo jogo e programa precisa. Resolve erros de "MSVCP140.dll".
Componentes;Visual C++ 2015-2022 (32 bits);Microsoft.VCRedist.2015+.x86;vcredist140;Visual C\+\+ (v14 Redistributable|20(15|17|19|22)).*x86;Versão 32 bits, necessária para jogos e programas antigos.
Componentes;DirectX (pacote completo);Microsoft.DirectX;directx;;Bibliotecas antigas do DirectX 9/10/11. Resolve erros de "d3dx9_43.dll".
Componentes;.NET Desktop Runtime 8;Microsoft.DotNet.DesktopRuntime.8;dotnet-8.0-desktopruntime;Windows Desktop Runtime - 8\.;Necessário para vários programas novos.
Componentes;Java (Temurin 21);EclipseAdoptium.Temurin.21.JRE;temurin21jre;Temurin.*21;Para sistemas e programas que pedem Java.
Diagnóstico;CPU-Z;CPUID.CPU-Z;cpu-z;CPU-Z;Mostra o processador, a placa-mãe e a memória do PC.
Diagnóstico;HWiNFO;REALiX.HWiNFO;hwinfo;^HWiNFO;Temperaturas e sensores de tudo.
Diagnóstico;CrystalDiskInfo;CrystalDewWorld.CrystalDiskInfo;crystaldiskinfo;^CrystalDiskInfo;Saúde do HD/SSD.
Diagnóstico;CrystalDiskMark;CrystalDewWorld.CrystalDiskMark;crystaldiskmark;^CrystalDiskMark;Testa a velocidade do disco.
Diagnóstico;WizTree;AntibodySoftware.WizTree;wiztree;^WizTree;Mostra o que está ocupando espaço no disco.
Diagnóstico;Malwarebytes;Malwarebytes.Malwarebytes;malwarebytes;^Malwarebytes;Segunda opinião contra vírus e adware.
Diagnóstico;BCUninstaller;Klocman.BulkCrapUninstaller;bulk-crap-uninstaller;^BCUninstaller;Desinstala vários programas de uma vez, com restos.
Desenvolvimento;Visual Studio Code;Microsoft.VisualStudioCode;vscode;^Microsoft Visual Studio Code;Editor de código.
Desenvolvimento;Git;Git.Git;git;^Git$;Controle de versão.
Desenvolvimento;Python 3.12;Python.Python.3.12;python312;^Python 3\.12;Linguagem Python.
Desenvolvimento;Node.js LTS;OpenJS.NodeJS.LTS;nodejs-lts;^Node\.js;JavaScript fora do navegador.
'@ -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object -Begin { $i = 0 } -Process {
    $f = $_ -split ';'
    $i++
    [pscustomobject]@{
        Id = "app$i"; Cat = $f[0]; Name = $f[1]; Winget = $f[2]; Choco = $f[3]; Match = $f[4]; Desc = $f[5]
        Source = if ($f[2] -match '^9[A-Z0-9]{11}$') { 'msstore' } else { 'winget' }
    }
}
$script:AppBoxes = @{}
$script:AppCards = @()
$script:AppsLoaded = $false

function Find-Choco {
    $c = Get-Command choco.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    if (Test-Path "$env:ProgramData\chocolatey\bin\choco.exe") { return "$env:ProgramData\chocolatey\bin\choco.exe" }
    $null
}

function Get-InstalledNames {
    $u = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    @(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
                       "Registry::HKEY_USERS\*\$u" -ErrorAction SilentlyContinue | Where-Object DisplayName | ForEach-Object DisplayName)
}

function Update-PkgStatus {
    $ui.TxtWinget.Text = if ($script:Winget) { '✔  winget disponível' } else { '✖  winget não encontrado. Clique em "Instalar winget" (Instalador de Aplicativo da Microsoft Store).' }
    $ui.TxtWinget.Foreground = if ($script:Winget) { '#4ADE80' } else { '#F87171' }
    $ui.TxtChoco.Text = if ($script:Choco) { '✔  Chocolatey disponível' } else { '•  Chocolatey não instalado (opcional: serve de reserva quando o winget falha)' }
    $ui.TxtChoco.Foreground = if ($script:Choco) { '#4ADE80' } else { '#8A91A3' }
    $ui.BtnInstallChoco.Visibility = if ($script:Choco -or -not $script:Winget) { 'Collapsed' } else { 'Visible' }
    $ui.BtnGetWinget.Visibility = if ($script:Winget) { 'Collapsed' } else { 'Visible' }
}

function Update-AppSel {
    $n = @($script:AppBoxes.Values | Where-Object { $_.IsChecked }).Count
    $ui.TxtAppSel.Text = if ($n) { "$n programa(s) marcado(s)." } else { 'Nenhum programa marcado.' }
}

function Load-Apps {
    $script:AppsLoaded = $true
    $script:Winget = Find-Winget
    $script:Choco  = Find-Choco
    Update-PkgStatus
    $installed = Get-InstalledNames
    $ui.PanelApps.Children.Clear()
    $script:AppBoxes = @{}
    $script:AppCards = @()
    foreach ($grp in ($AppCatalog | Group-Object Cat)) {
        $hdr = New-Object Windows.Controls.TextBlock
        $hdr.Text = $grp.Name.ToUpper(); $hdr.FontSize = 11.5; $hdr.FontWeight = 'SemiBold'; $hdr.Foreground = '#7C849A'; $hdr.Margin = '2,6,0,10'
        [void]$ui.PanelApps.Children.Add($hdr)
        $grid = New-Object Windows.Controls.Primitives.UniformGrid
        $grid.Columns = 3; $grid.Margin = '0,0,-10,10'
        [void]$ui.PanelApps.Children.Add($grid)
        foreach ($a in $grp.Group) {
            $isIn = $a.Match -and ($installed -match $a.Match)
            # embaixo da descrição: na linha do título não cabe com 3 colunas
            $pill = if ($isIn) { '<TextBlock Text="&#x2714;  Instalado" FontSize="11.5" Foreground="#4ADE80" FontWeight="SemiBold" Margin="0,5,0,0"/>' } else { '' }
            $glyph = if ($AppIcons[$a.Cat]) { $AppIcons[$a.Cat] } else { 'E71D' }
            $card = [Windows.Markup.XamlReader]::Parse((New-IconCardXaml $glyph '#8B7CFF' (Esc $a.Name) '' (Esc $a.Desc) $pill '0,0,10,10'))
            $cb = $card.Child
            $cb.Style = $window.FindResource('ToggleRight')
            $cb.Tag = $a
            $cb.Add_Checked({ Update-AppSel })
            $cb.Add_Unchecked({ Update-AppSel })
            $script:AppBoxes[$a.Id] = $cb
            $script:AppCards += [pscustomobject]@{ Card = $card; App = $a; Header = $hdr; Grid = $grid }
            [void]$grid.Children.Add($card)
        }
    }
    Update-AppSel
    Filter-Apps
}

function Filter-Apps {
    $q = $ui.TxtAppSearch.Text.Trim()
    $ui.TxtAppHint.Visibility = if ($q) { 'Collapsed' } else { 'Visible' }
    foreach ($c in $script:AppCards) {
        $show = (-not $q) -or ("$($c.App.Name) $($c.App.Desc) $($c.App.Cat)" -like "*$q*")
        $c.Card.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }
    }
    foreach ($g in ($script:AppCards | Group-Object { $_.Header.GetHashCode() })) {
        $any = @($g.Group | Where-Object { $_.Card.Visibility -eq 'Visible' }).Count -gt 0
        $g.Group[0].Header.Visibility = if ($any) { 'Visible' } else { 'Collapsed' }
        $g.Group[0].Grid.Visibility   = if ($any) { 'Visible' } else { 'Collapsed' }
    }
}

$appWorker = {
    param($sync, $apps, $action, $useChoco, $winget, $choco, $logFile)
    function Log([string]$Message, [string]$Level = 'INFO') {
        $line = '[{0}] {1,-4} {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
        try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch {}
        $sync.Queue.Enqueue($line)
    }
    # roda sem abrir janela e joga a saída no log, sem as barras de progresso
    function Run([string]$Exe, [string]$Arguments) {
        $psi = New-Object Diagnostics.ProcessStartInfo $Exe, $Arguments
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $p = [Diagnostics.Process]::Start($psi)
        $err = $p.StandardError.ReadToEndAsync()
        while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
            $t = $line.Trim()
            if ($t.Length -lt 3 -or $t -match '[█▒]|^[-\\|/]+$|\d+(\.\d+)?\s*[KMG]B\s*/\s*\d') { continue }
            Log "    $t"
        }
        $p.WaitForExit()
        if ($err.Result.Trim()) { Log "    $($err.Result.Trim())" 'WARN' }
        return $p.ExitCode
    }
    function Run-Winget([string]$Arguments) {
        $c = Run $winget "$Arguments --accept-source-agreements --disable-interactivity"
        # winget antigo não conhece --disable-interactivity
        if ($c -eq -1978335230) { $c = Run $winget "$Arguments --accept-source-agreements" }
        return $c
    }
    $okCodes = 0, 3010, 1641, -1978335189, -1978335135   # sucesso, pedir reinício, já instalado/atualizado
    $ok = 0; $fail = 0
    try {
        if ($action -eq 'upgrade') {
            if ($winget) {
                $sync.Current = 'Atualizando programas pelo winget...'
                Log '> Atualizando todos os programas (winget)' 'STEP'
                $c = Run-Winget 'upgrade --all --silent --accept-package-agreements'
                if ($okCodes -contains $c) { $ok++; Log '  winget: atualização concluída' 'OK' } else { $fail++; Log "  winget terminou com código $c" 'WARN' }
            }
            if ($useChoco -and $choco) {
                $sync.Progress = 50
                $sync.Current = 'Atualizando programas pelo Chocolatey...'
                Log '> Atualizando todos os programas (Chocolatey)' 'STEP'
                $c = Run $choco 'upgrade all -y --no-progress'
                if ($okCodes -contains $c) { $ok++; Log '  Chocolatey: atualização concluída' 'OK' } else { $fail++; Log "  Chocolatey terminou com código $c" 'WARN' }
            }
        } else {
            $verb = if ($action -eq 'uninstall') { 'Desinstalando' } else { 'Instalando' }
            for ($i = 0; $i -lt $apps.Count; $i++) {
                $a = $apps[$i]
                $sync.Progress = [int](100 * $i / $apps.Count)
                $sync.Current = "$verb $($a.Name) ($($i + 1) de $($apps.Count))"
                Log "> $verb $($a.Name)" 'STEP'
                $done = $false
                if ($winget -and $a.Winget) {
                    $c = if ($action -eq 'uninstall') { Run-Winget "uninstall --id $($a.Winget) -e --silent" }
                         else { Run-Winget "install --id $($a.Winget) -e --source $($a.Source) --silent --accept-package-agreements" }
                    if ($okCodes -contains $c) { $done = $true } else { Log "  winget não conseguiu (código $c)" 'WARN' }
                }
                if (-not $done -and $useChoco -and $a.Choco) {
                    if (-not $choco -and (Test-Path "$env:ProgramData\chocolatey\bin\choco.exe")) { $choco = "$env:ProgramData\chocolatey\bin\choco.exe" }
                    if ($choco) {
                        Log '  tentando pelo Chocolatey...'
                        $c = Run $choco "$(if ($action -eq 'uninstall') { 'uninstall' } else { 'install' }) $($a.Choco) -y --no-progress"
                        if ($okCodes -contains $c) { $done = $true } else { Log "  Chocolatey não conseguiu (código $c)" 'WARN' }
                    }
                }
                if ($done) { $ok++; Log "  $($a.Name): pronto" 'OK' } else { $fail++; Log "  $($a.Name): não foi possível" 'ERRO' }
            }
        }
    } catch {
        Log "Erro: $($_.Exception.Message)" 'ERRO'
    } finally {
        $sync.AppOk = $ok; $sync.AppFail = $fail
        $sync.Progress = 100
        $sync.Done = $true
    }
}

function Start-AppJob([string]$Action, [object[]]$Apps) {
    if ($sync.Running) { return }
    $useChoco = [bool]$ui.ChkChoco.IsChecked
    if (-not $script:Winget -and -not ($useChoco -and $script:Choco)) {
        Show-Msg 'O winget não foi encontrado neste PC. Clique em "Instalar winget" para instalar o Instalador de Aplicativo pela Microsoft Store e tente de novo.' 'OK' 'Warning' | Out-Null
        return
    }
    if ($Action -ne 'upgrade') {
        if (-not $Apps) { Show-Msg 'Marque pelo menos um programa.' 'OK' 'Warning' | Out-Null; return }
        $verb = if ($Action -eq 'uninstall') { 'desinstalados' } else { 'instalados' }
        $names = ($Apps | ForEach-Object { "  •  $($_.Name)" }) -join "`n"
        $r = Show-Msg "Serão $verb $(@($Apps).Count) programa(s):`n`n$names`n`nPode demorar alguns minutos, dependendo da internet. Continuar?" 'YesNo' 'Question'
    } else {
        $r = Show-Msg "Atualizar todos os programas do PC que tenham versão nova?`n`nFeche os programas abertos antes. Pode demorar bastante." 'YesNo' 'Question'
    }
    if ($r -ne 'Yes') { return }
    $sync.Done = $false; $sync.Running = $true; $sync.Progress = 0; $sync.Mode = 'apps'; $sync.Current = ''
    Set-Busy $true
    $ui.Tabs.SelectedItem = $ui.TabLog
    Start-Worker $appWorker @($sync, [object[]]@($Apps), $Action, $useChoco, $script:Winget, $script:Choco, $Global:TLogFile)
}

