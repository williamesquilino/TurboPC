# [parte] Detecção do uso do PC, pergunta "Para que você usa este PC?" e preferências
# ---------------------------------------------------------------- modos
# ---------------------------------------------------------------- uso do PC (detecção + preferências)
# Tudo é lido no próprio PC e fica em C:\ProgramData\TurboPC\preferencias.json. Nada vai para a internet.
$Global:PrefFile = Join-Path $env:ProgramData 'TurboPC\preferencias.json'
$script:SavedAnswers = @{}
$script:UsageKind = $null

# Jogos em que o FPS depende do processador (FPS altíssimo): neles nada que possa segurar quadros é aplicado
$CompetitiveGames = 'VALORANT', 'Counter-Strike', 'Fortnite', 'League of Legends', 'Rocket League', 'Apex Legends', 'Overwatch',
                    'Dota 2', 'Rainbow Six', 'PUBG', 'Call of Duty', 'Marvel Rivals', 'THE FINALS', 'Deadlock', 'Rust', 'Escape from Tarkov'
$NotGames = 'Wallpaper Engine|Steamworks|Redistributable|SteamVR|Soundtrack|Dedicated Server|Proton|Steam Linux|SDK|Benchmark|Tool'

$UsageKinds = [ordered]@{
    Trabalho    = [pscustomobject]@{ Label = 'Trabalho';          Mode = 'Escritorio';  Glyph = 'E821'; Color = '#A78BFA'; Desc = 'Office, navegador, sistemas da empresa e reuniões.' }
    Competitivo = [pscustomobject]@{ Label = 'Jogos competitivos'; Mode = 'Jogos';       Glyph = 'E7FC'; Color = '#38BDF8'; Desc = 'Valorant, CS2, Fortnite, LoL: FPS alto e resposta rápida.' }
    Pesado      = [pscustomobject]@{ Label = 'Jogos pesados';      Mode = 'Jogos';       Glyph = 'E7F4'; Color = '#F472B6'; Desc = 'Jogos com gráfico bonito: GTA, Cyberpunk, Forza, Call of Duty campanha.' }
    Misto       = [pscustomobject]@{ Label = 'Um pouco de tudo';   Mode = 'Recomendado'; Glyph = 'E80F'; Color = '#4ADE80'; Desc = 'Trabalho, estudo, internet e um jogo de vez em quando.' }
}

function ConvertFrom-Rot13([string]$s) {
    -join ($s.ToCharArray() | ForEach-Object {
        $c = [int]$_
        if ($c -ge 65 -and $c -le 90) { [char](65 + ($c - 52) % 26) } elseif ($c -ge 97 -and $c -le 122) { [char](97 + ($c - 84) % 26) } else { $_ }
    })
}

# Nomes dos jogos instalados (Steam, Epic, Riot e lista de programas instalados)
function Get-InstalledGames {
    $names = @()
    $steam = (Get-ItemProperty (Resolve-UserPath 'HKCU:\Software\Valve\Steam') -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { $steam = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath }
    if ($steam -and (Test-Path "$steam\steamapps")) {
        $libs = @($steam) + @(Select-String -Path "$steam\steamapps\libraryfolders.vdf" -Pattern '"path"\s+"(.+)"' -ErrorAction SilentlyContinue |
                               ForEach-Object { $_.Matches[0].Groups[1].Value -replace '\\\\', '\' })
        foreach ($l in ($libs | Sort-Object -Unique)) {
            foreach ($m in Get-ChildItem "$l\steamapps\appmanifest_*.acf" -ErrorAction SilentlyContinue) {
                $hit = Select-String -Path $m.FullName -Pattern '"name"\s+"(.+)"' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($hit) { $names += $hit.Matches[0].Groups[1].Value }
            }
        }
    }
    foreach ($m in Get-ChildItem "$env:ProgramData\Epic\EpicGamesLauncher\Data\Manifests\*.item" -ErrorAction SilentlyContinue) {
        try { $names += (Get-Content $m.FullName -Raw | ConvertFrom-Json).DisplayName } catch {}
    }
    foreach ($d in 'C:\Riot Games\VALORANT', 'C:\Riot Games\League of Legends') { if (Test-Path $d) { $names += Split-Path $d -Leaf } }
    $installed = Get-InstalledNames
    foreach ($g in $CompetitiveGames) { $names += @($installed | Where-Object { $_ -like "$g*" }) }
    @($names | Where-Object { $_ -and $_ -notmatch $NotGames } | Sort-Object -Unique)
}

# "microsoft.office.winword.exe.15" -> "Word"
function Get-FriendlyApp([string]$Name) {
    $map = [ordered]@{ winword = 'Word'; excel = 'Excel'; powerpnt = 'PowerPoint'; outlook = 'Outlook'; onenote = 'OneNote'; teams = 'Teams'
                       acro = 'Acrobat'; zoom = 'Zoom'; slack = 'Slack'; mstsc = 'Área de Trabalho Remota'; anydesk = 'AnyDesk'; sapgui = 'SAP'
                       'libreoffice|soffice' = 'LibreOffice'; steam = 'Steam'; riot = 'Riot Client'; valorant = 'VALORANT'; leagueclient = 'League of Legends'
                       epicgames = 'Epic Games'; 'battle\.net' = 'Battle.net'; eadesktop = 'EA app'; 'upc\.exe|ubisoft' = 'Ubisoft Connect'
                       discord = 'Discord'; obs64 = 'OBS'; cs2 = 'Counter-Strike 2'; fortnite = 'Fortnite'; gog = 'GOG Galaxy' }
    foreach ($k in $map.Keys) { if ($Name -match $k) { return $map[$k] } }
    $Name -replace '\.exe$', ''
}

# Quantas vezes cada tipo de programa foi aberto (contador do próprio Windows, da conta atual)
function Get-AppUsage {
    $work = 'winword|excel|powerpnt|outlook|onenote|teams|acrord32|acrobat|zoom|slack|mstsc|sapgui|anydesk|libreoffice|soffice'
    $game = 'steam|riotclient|valorant|leagueclient|epicgames|battle\.net|eadesktop|upc\.exe|ubisoft|discord|obs64|cs2|fortnite|gog'
    $r = [pscustomobject]@{ Work = 0; Game = 0; WorkApps = @(); GameApps = @() }
    # o contador de quem está logado na tela (não o do técnico que digitou a senha de admin)
    $key = Get-Item (Resolve-UserPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist\{CEBFF5CD-ACE2-4F4F-9178-9926F41749EA}\Count') -ErrorAction SilentlyContinue
    if (-not $key) { return $r }
    foreach ($n in $key.GetValueNames()) {
        $d = $key.GetValue($n)
        if ($d -isnot [byte[]] -or $d.Length -lt 16) { continue }
        $name = [IO.Path]::GetFileName((ConvertFrom-Rot13 $n)).ToLower()
        $count = [BitConverter]::ToInt32($d, 4)
        if ($count -le 0) { continue }
        if ($name -match $work)     { $r.Work += $count; $r.WorkApps += Get-FriendlyApp $name }
        elseif ($name -match $game) { $r.Game += $count; $r.GameApps += Get-FriendlyApp $name }
    }
    $r.WorkApps = @($r.WorkApps | Sort-Object -Unique); $r.GameApps = @($r.GameApps | Sort-Object -Unique)
    $r
}

# Junta tudo e dá um palpite: Trabalho, Competitivo, Pesado ou Misto
function Get-UsageGuess {
    $games = @(Get-InstalledGames)
    $comp  = @($games | Where-Object { $n = $_; @($CompetitiveGames | Where-Object { $n -like "$_*" }).Count })
    $heavy = @($games | Where-Object { $comp -notcontains $_ })
    $apps  = Get-AppUsage
    $office = @(Get-InstalledNames | Where-Object { $_ -match '^Microsoft (Office|365)|^LibreOffice' }).Count -gt 0
    $kind = if ($comp.Count -or $heavy.Count) {
                if ($apps.Work -ge 30 -and $apps.Work -gt 2 * $apps.Game) { 'Misto' } elseif ($comp.Count) { 'Competitivo' } else { 'Pesado' }
            } elseif ($apps.Work -ge 10 -or $office) { 'Trabalho' } else { 'Misto' }
    $why = @()
    if ($comp.Count)  { $why += "jogos competitivos: $(($comp | Select-Object -First 3) -join ', ')" }
    if ($heavy.Count) { $why += "outros jogos: $(($heavy | Select-Object -First 3) -join ', ')" }
    if ($apps.WorkApps.Count) { $why += "programas de trabalho: $(($apps.WorkApps | Select-Object -First 3) -join ', ')" }
    if (-not $why) { $why += 'nenhum jogo nem programa de trabalho em destaque' }
    [pscustomobject]@{ Kind = $kind; Competitive = $comp; Heavy = $heavy; Apps = $apps; Why = ($why -join '  ·  ') }
}

function Get-Prefs {
    try { if (Test-Path $Global:PrefFile) { return Get-Content $Global:PrefFile -Raw -Encoding UTF8 | ConvertFrom-Json } } catch {}
    $null
}

function Save-Prefs {
    try {
        New-Item -ItemType Directory -Path (Split-Path $Global:PrefFile) -Force | Out-Null
        [ordered]@{ Kind = $script:UsageKind; Date = (Get-Date).ToString('s'); Answers = $script:SavedAnswers } |
            ConvertTo-Json -Depth 5 | Set-Content -Path $Global:PrefFile -Encoding UTF8
    } catch {}
}

# Respostas salvas da tela de cada modo: @{ Jogos = @{ gpu = $true; ... } }
function Get-SavedAnswers($Prefs) {
    $h = @{}
    if ($Prefs -and $Prefs.Answers) {
        foreach ($p in $Prefs.Answers.PSObject.Properties) {
            $inner = @{}; foreach ($q in $p.Value.PSObject.Properties) { $inner[$q.Name] = [bool]$q.Value }
            $h[$p.Name] = $inner
        }
    }
    $h
}

# "Para que você usa este PC?" com o palpite já destacado. Devolve a chave escolhida ou $null.
function Show-UsageQuestion {
    $g = $script:UsageGuess
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Para que você usa este PC? - TurboPC" Width="760" SizeToContent="Height" WindowStartupLocation="CenterOwner"
        Background="#0E1117" FontFamily="Segoe UI" Foreground="#E6E8EE" ShowInTaskbar="False" ResizeMode="NoResize">
  <StackPanel Margin="30,26,30,26">
    <TextBlock Text="Para que você usa este PC?" FontSize="24" FontWeight="SemiBold" Foreground="#F4F5F9"/>
    <TextBlock Text="Assim o TurboPC indica o modo certo e nunca aplica algo que atrapalhe o seu uso. Dá para mudar depois no Painel." FontSize="13" Foreground="#8A91A3" TextWrapping="Wrap" Margin="0,5,0,14"/>
    <Border Background="#141821" BorderBrush="#232836" BorderThickness="1" CornerRadius="10" Padding="12,9" Margin="0,0,0,16">
      <DockPanel>
        <TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="#A99BFF" Margin="0,2,10,0"/>
        <TextBlock FontSize="12.5" Foreground="#C9CFDB" TextWrapping="Wrap"><Run Text="O que encontramos: " FontWeight="SemiBold"/><Run Text="$(Esc $g.Why)"/></TextBlock>
      </DockPanel>
    </Border>
    <UniformGrid x:Name="UqGrid" Columns="2" Margin="0,0,-12,0"/>
  </StackPanel>
</Window>
"@
    $w = [Windows.Markup.XamlReader]::Parse($x)
    $w.Owner = $window
    $w.Resources = $window.Resources
    $grid = $w.FindName('UqGrid')
    $script:UqResult = $null
    $script:UqWin = $w
    foreach ($k in $UsageKinds.Keys) {
        $u = $UsageKinds[$k]
        $tint = '#26' + $u.Color.TrimStart('#')
        $badge = if ($k -eq $g.Kind) { '<Border DockPanel.Dock="Right" Background="#163326" CornerRadius="7" Padding="8,2" VerticalAlignment="Top"><TextBlock Text="Achamos que é este" FontSize="10.5" FontWeight="SemiBold" Foreground="#4ADE80"/></Border>' } else { '' }
        $c = @"
<DockPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
  <DockPanel DockPanel.Dock="Top">
    $badge
    <Border Width="42" Height="42" CornerRadius="11" Background="$tint" HorizontalAlignment="Left">
      <TextBlock Text="&#x$($u.Glyph);" FontFamily="Segoe MDL2 Assets" FontSize="19" Foreground="$($u.Color)" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
  </DockPanel>
  <StackPanel Margin="0,12,0,0">
    <TextBlock Text="$(Esc $u.Label)" FontSize="16" FontWeight="SemiBold" Foreground="#F4F5F9"/>
    <TextBlock Text="$(Esc $u.Desc)" FontSize="12.5" Foreground="#8A91A3" TextWrapping="Wrap" Margin="0,4,0,0"/>
  </StackPanel>
</DockPanel>
"@
        $b = New-Object Windows.Controls.Button
        $b.Style = $window.FindResource('ModeCard')
        $b.Content = [Windows.Markup.XamlReader]::Parse($c)
        $b.HorizontalContentAlignment = 'Stretch'
        $b.Tag = $k
        if ($k -eq $g.Kind) { $b.BorderBrush = '#2F6B4C' }
        $b.Add_Click({ param($s) $script:UqResult = $s.Tag; $script:UqWin.Close() })
        [void]$grid.Children.Add($b)
    }
    [void]$w.ShowDialog()
    $script:UqResult
}

# Lê preferências, detecta o uso e, se ainda não perguntou, pergunta
# $Guess vem pronto da leitura em segundo plano; se não vier, calcula aqui
function Initialize-Usage([switch]$Ask, $Guess) {
    if ($Guess) { $script:UsageGuess = $Guess } elseif (-not $script:UsageGuess) { $script:UsageGuess = Get-UsageGuess }
    $prefs = Get-Prefs
    $script:SavedAnswers = Get-SavedAnswers $prefs
    $script:UsageKind = if ($prefs -and $prefs.Kind -and $UsageKinds.Contains([string]$prefs.Kind)) { [string]$prefs.Kind } else { $null }
    if (-not $script:UsageKind -or $Ask) {
        $pick = Show-UsageQuestion
        if ($pick) { $script:UsageKind = $pick; Save-Prefs }
        elseif (-not $script:UsageKind) { $script:UsageKind = $script:UsageGuess.Kind }
    }
    Update-UsageUi
}

function Update-UsageUi {
    $u = $UsageKinds[$script:UsageKind]
    $found = @($script:UsageGuess.Competitive) + @($script:UsageGuess.Heavy) | Select-Object -First 3
    $ui.PcUsage.Text = "Uso: $($u.Label)" + $(if ($found) { "  ·  jogos encontrados: $($found -join ', ')" } else { '' })
    Build-ModeCards
    foreach ($b in $script:ModeButtons) { $b.Add_Click({ param($s) Invoke-Mode $s.Tag }) }
}

