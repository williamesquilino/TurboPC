# [parte] Espaço em disco: tela, apagar com segurança, desinstalar
# ---------------------------------------------------------------- espaço em disco: tela
$SpaceColors = @{ 'Windows' = '#60A5FA'; 'Programas' = '#A78BFA'; 'Jogos' = '#38BDF8'; 'Seus arquivos' = '#4ADE80'; 'Seus arquivos e pastas' = '#4ADE80'
                  'Dados de programas' = '#F5A524'; 'Arquivos do sistema' = '#F472B6'; 'Outros' = '#5F6679' }
$script:SpaceDrive = $env:SystemDrive
$script:SpaceStale = $true
$script:FolderStack = New-Object Collections.ArrayList
$script:FolderCache = @{}

function Format-Age($Date) {
    if (-not $Date) { return '' }
    $d = ((Get-Date) - $Date).TotalDays
    if ($d -lt 7) { 'esta semana' } elseif ($d -lt 31) { "há $([int]($d / 7)) semana(s)" } elseif ($d -lt 365) { "há $([int]($d / 30)) mes(es)" } else { "há $([math]::Round($d / 365, 1)) ano(s)" }
}

# Só deixa apagar onde não quebra nada: pastas da pessoa (fora do AppData) e outras unidades (fora da raiz e das bibliotecas de jogos)
function Test-CanDelete([string]$Path) {
    try { $p = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
    if ($p.Length -le 3) { return $false }
    if ($p.StartsWith($env:SystemDrive, 'OrdinalIgnoreCase')) {
        foreach ($prof in (Get-ProfilePaths)) {
            if ($p.StartsWith("$prof\", 'OrdinalIgnoreCase')) {
                # só dentro de pastas comuns: nada de AppData, pastas/arquivos de configuração (".algo") ou arquivo solto na raiz do perfil
                $rest = $p.Substring($prof.Length + 1)
                $top = $rest.Split('\')[0]
                if ($top -match '^(AppData|NTUSER|ntuser|Application Data|Local Settings|Cookies|\.)') { return $false }
                # as pastas padrão do Windows ficam; o que está dentro delas pode ir
                if (-not $rest.Contains('\') -and $top -match '^(Desktop|Downloads|Documents|Pictures|Videos|Music|OneDrive.*|Favorites|Contacts|Links|Saved Games|Searches|3D Objects)$') { return $false }
                return ($rest.Contains('\') -or (Test-Path -LiteralPath $p -PathType Container))
            }
        }
        return $false
    }
    -not ($p -match '^[A-Za-z]:\\(System Volume Information|\$Recycle\.Bin)|\\steamapps\\|\\SteamLibrary$|\\Epic Games\\|\\Riot Games\\|\\XboxGames\\')
}

# Quanto cabe na Lixeira desta unidade (0 = Lixeira desligada). Sem configuração própria, o Windows usa uns 5% do disco.
function Get-RecycleCapacity([string]$Path) {
    $drive = [IO.Path]::GetPathRoot($Path).TrimEnd('\')
    $vol = Get-CimInstance Win32_Volume -Filter "DriveLetter='$drive'" -ErrorAction SilentlyContinue | Select-Object -First 1
    $guid = if ($vol) { [regex]::Match($vol.DeviceID, '\{[0-9a-fA-F-]+\}').Value }
    $cfg = if ($guid) { Get-ItemProperty (Resolve-UserPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\$guid") -ErrorAction SilentlyContinue }
    if ($cfg.NukeOnDelete -eq 1) { return [int64]0 }
    if ($cfg.MaxCapacity) { return [int64]$cfg.MaxCapacity * 1MB }
    if ($vol) { [int64]($vol.Capacity * 0.05) } else { [int64]0 }
}

function Remove-ToRecycle([string]$Path) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    # AllDialogs: se o Windows não conseguir usar a Lixeira (caminho longo demais, por exemplo), ele mesmo pergunta antes de apagar de vez.
    # Com OnlyErrorDialogs ele apagaria de vez sem avisar. Em uso normal não aparece janela extra.
    if (Test-Path -LiteralPath $Path -PathType Container) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, 'AllDialogs', 'SendToRecycleBin') }
    else { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'AllDialogs', 'SendToRecycleBin') }
}

function Invoke-DeleteItem([string]$Path, [int64]$Size) {
    if (-not (Test-CanDelete $Path)) { Show-Msg 'Essa pasta é do Windows ou de um programa. Para liberar esse espaço, desinstale o programa.' 'OK' 'Warning' | Out-Null; return $false }
    $cloud = if ($Path -match '\\OneDrive') { "`n`nAtenção: está no OneDrive. Apagar aqui apaga também na nuvem e nos outros computadores. Para só liberar espaço no PC, use 'Deixar só na nuvem'." } else { '' }
    $fits = $Size -lt (Get-RecycleCapacity $Path)
    $where = if ($fits) { 'Vai para a Lixeira: dá para recuperar até você esvaziar a Lixeira.' }
             else { 'ATENÇÃO: é grande demais para a Lixeira deste disco. Vai ser apagado DE VEZ, sem como recuperar.' }
    $msg = "Apagar '$([IO.Path]::GetFileName($Path))' ($(Format-Size $Size))?`n`n$Path`n`n$where$cloud"
    if ((Show-Msg $msg 'YesNo' 'Warning') -ne 'Yes') { return $false }
    try {
        if ($fits) { Remove-ToRecycle $Path } else { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
        Write-TLog "Espaço: enviado para a Lixeira: $Path ($(Format-Size $Size))" 'OK'
        $script:SpaceStale = $true
        return $true
    } catch {
        if ($_.Exception -isnot [OperationCanceledException] -and $_.Exception.InnerException -isnot [OperationCanceledException]) { Show-Msg "Não foi possível apagar: $($_.Exception.Message)" 'OK' 'Error' | Out-Null }
        return $false
    }
}

# Igual ao "Liberar espaço" do OneDrive: o arquivo continua na nuvem e baixa de novo quando for aberto
function Invoke-CloudOnly([string]$Path, [int64]$Size) {
    $msg = "Deixar '$([IO.Path]::GetFileName($Path))' só na nuvem?`n`nLibera $(Format-Size $Size) no PC. O arquivo NÃO é apagado: continua no OneDrive e baixa de novo sozinho quando você abrir (precisa de internet)."
    if ((Show-Msg $msg 'YesNo' 'Question') -ne 'Yes') { return $false }
    $p = Start-Process -FilePath "$env:windir\System32\attrib.exe" -ArgumentList "-P +U `"$Path`"" -WindowStyle Hidden -Wait -PassThru
    if ($p.ExitCode -eq 0) { Write-TLog "Espaço: deixado só na nuvem: $Path ($(Format-Size $Size))" 'OK'; $script:SpaceStale = $true; return $true }
    Show-Msg 'Não deu certo. Confira se o OneDrive está aberto e conectado.' 'OK' 'Warning' | Out-Null
    $false
}

# Entrada de desinstalação de um programa pelo nome (para os botões da aba Espaço)
function Get-UninstallEntry([string]$Pattern) {
    $u = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $e = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*", "Registry::HKEY_USERS\*\$u" -ErrorAction SilentlyContinue |
         Where-Object { $_.DisplayName -match $Pattern -and $_.UninstallString } | Select-Object -First 1
    if ($e) { [pscustomobject]@{ Name = $e.DisplayName; Size = [int64]$e.EstimatedSize * 1KB; Kind = 'Programa'; AppId = ''; Path = $e.InstallLocation; Uninstall = $e.UninstallString } }
}

# Cache de programação: apaga de vez (não vale ocupar a Lixeira com algo que baixa de novo)
function Invoke-ClearCache($Item) {
    $msg = "Limpar '$($Item.Title)' ($(Format-Size $Item.Size))?`n`n$($Item.Path)`n`nÉ só cache: é apagado de vez (sem Lixeira) e baixado de novo quando algum projeto precisar."
    if ((Show-Msg $msg 'YesNo' 'Question') -ne 'Yes') { return $false }
    Get-ChildItem -LiteralPath $Item.Path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-TLog "Espaço: cache limpo: $($Item.Path) ($(Format-Size $Item.Size))" 'OK'
    $script:SpaceStale = $true
    $true
}

# Log gigante: apaga de vez; se estiver em uso, pede para fechar o programa
function Invoke-DeleteLog($Item) {
    $msg = "Apagar '$([IO.Path]::GetFileName($Item.Path))' ($(Format-Size $Item.Size))?`n`n$($Item.Path)`n`nÉ só um registro de erros: é apagado de vez e o programa cria outro."
    if ((Show-Msg $msg 'YesNo' 'Question') -ne 'Yes') { return $false }
    try {
        Remove-Item -LiteralPath $Item.Path -Force -ErrorAction Stop
        Write-TLog "Espaço: log apagado: $($Item.Path) ($(Format-Size $Item.Size))" 'OK'
        $script:SpaceStale = $true
        $true
    } catch {
        Show-Msg "O arquivo está em uso. Feche o programa dele e tente de novo.`n`n$($_.Exception.Message)" 'OK' 'Warning' | Out-Null
        $false
    }
}

# Copia "wsl --unregister <nome>" com o nome certo da distribuição
function Copy-WslCommand([string]$Hint) {
    $names = @(wsl.exe -l -q 2>$null | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
    $name = $names | Where-Object { $_ -like "*$Hint*" } | Select-Object -First 1
    if (-not $name) { $name = '<nome>' }
    Set-Clipboard -Value "wsl --unregister $name"
    Show-Msg "Comando copiado: wsl --unregister $name`n`nAbra o Terminal, cole e aperte Enter. ATENÇÃO: apaga tudo que está dentro desse Linux.$(if ($names) { "`n`nDistribuições neste PC: $($names -join ', ')" })" | Out-Null
}

function Invoke-UninstallApp($App) {
    if ($App.Kind -eq 'Steam' -and $App.AppId) { Start-Process "steam://uninstall/$($App.AppId)"; return }
    if ($App.Kind -eq 'Epic') { Show-Msg "Para desinstalar '$($App.Name)', abra a Epic Games, vá em Biblioteca, clique nos três pontinhos do jogo e em Desinstalar." | Out-Null; Start-Process 'com.epicgames.launcher://store' -ErrorAction SilentlyContinue; return }
    if ((Show-Msg "Desinstalar '$($App.Name)' ($(Format-Size $App.Size))?`n`nVai abrir o desinstalador do próprio programa. Siga as telas dele." 'YesNo' 'Question') -ne 'Yes') { return }
    $s = "$($App.Uninstall)".Trim()
    if ($s -match '^(?i)msiexec(\.exe)?\s+/[IX]\s*(\{[^}]+\})') { $exe = 'msiexec.exe'; $arg = "/x $($Matches[2])" }
    elseif ($s -match '^"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $arg = $Matches[2] }
    elseif ($s -match '^(.+?\.exe)\s*(.*)$') { $exe = $Matches[1]; $arg = $Matches[2] }
    else { $exe = $s; $arg = '' }
    try {
        if ($arg) { Start-Process -FilePath $exe -ArgumentList $arg } else { Start-Process -FilePath $exe }
        Write-TLog "Espaço: desinstalador aberto para $($App.Name)" 'OK'
        $script:SpaceStale = $true
    } catch { Show-Msg "Não foi possível abrir o desinstalador: $($_.Exception.Message)" 'OK' 'Error' | Out-Null }
}

function Start-DiskScan([string]$Drive, [string]$Folder) {
    if ($sync.UpdateBusy -and $sync.UpdateDone) { Complete-UpdateCheck }
    if ($sync.FpsBusy) {
        $ui.FpsInfo.Text = $sync.FpsStatus; $ui.StatusText.Text = $sync.FpsStatus
        if ($sync.FpsDone) { Complete-FpsTest }
    }
    if ($sync.DiskBusy) { return }
    $sync.DiskBusy = $true; $sync.DiskDone = $false; $sync.DiskStatus = 'Começando...'; $sync.DiskProgress = 0
    $script:DiskMode = if ($Folder) { 'folder' } else { 'full' }
    if ($Folder) { $ui.TxtFolderPath.Text = "Medindo $Folder..." }
    else {
        $script:SpaceDrive = $Drive; $script:SpaceStale = $false
        $script:FolderStack.Clear(); $script:FolderCache = @{}
        $ui.SpaceTitle.Text = "Analisando a unidade $Drive..."
        $ui.SpaceProgress.Visibility = 'Visible'
        Build-DriveButtons
    }
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($diskWorker.ToString()).AddArgument($sync).AddArgument($Drive).AddArgument($Folder)
    $script:diskJob = @{ PS = $ps; H = $ps.BeginInvoke() }
}

function Complete-DiskScan {
    $sync.DiskBusy = $false
    try { [void]$script:diskJob.PS.EndInvoke($script:diskJob.H); $script:diskJob.PS.Runspace.Dispose(); $script:diskJob.PS.Dispose() } catch {}
    if ($script:DiskMode -eq 'folder') {
        $r = $sync.FolderResult
        if ($r) { $script:FolderCache[$r.Path] = $r.Items; Render-Folders $r.Path $r.Items }
    } else {
        $ui.SpaceProgress.Visibility = 'Collapsed'
        if ($sync.DiskResult) { Render-Space $sync.DiskResult } else { $ui.SpaceTitle.Text = 'Não deu para analisar'; $ui.SpaceStatus.Text = $sync.DiskStatus }
    }
}

function Build-DriveButtons {
    $ui.PanelDriveBtns.Children.Clear()
    foreach ($d in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue) {
        $b = New-Object Windows.Controls.Button
        $b.Style = $window.FindResource($(if ($d.DeviceID -eq $script:SpaceDrive) { 'Btn' } else { 'BtnGhost' }))
        $b.Content = "$($d.DeviceID)  ·  $(Format-Size $d.FreeSpace) livres"
        $b.Padding = '12,8'; $b.Margin = '0,0,6,0'; $b.Tag = $d.DeviceID
        $b.Add_Click({ param($s) Start-DiskScan $s.Tag $null })
        [void]$ui.PanelDriveBtns.Children.Add($b)
    }
}

# linha genérica: ícone, título, texto menor, valor à direita e botões
function New-SpaceRow([string]$Glyph, [string]$Color, [string]$Title, [string]$Sub, [string]$Right, [double]$Fill = -1, [switch]$Wrap) {
    $tint = '#26' + $Color.TrimStart('#')
    $bar = if ($Fill -ge 0) {
        "<Border Height=""4"" CornerRadius=""2"" Background=""#232838"" Margin=""0,7,0,0""><Border HorizontalAlignment=""Left"" CornerRadius=""2"" Background=""$Color"" Width=""$([int](300 * [math]::Max(0.01, [math]::Min(1.0, $Fill))))""/></Border>"
    } else { '' }
    $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Background="#171B24" BorderBrush="#232836" BorderThickness="1" CornerRadius="12" Padding="14,10" Margin="0,0,0,8">
  <DockPanel>
    <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center"/>
    <TextBlock DockPanel.Dock="Right" Text="$(Esc $Right)" FontSize="14" FontWeight="SemiBold" Foreground="#F1F3F8" VerticalAlignment="Center" Margin="12,0,16,0"/>
    <Border Width="36" Height="36" CornerRadius="10" Background="$tint" VerticalAlignment="Center" Margin="0,0,14,0">
      <TextBlock Text="&#x$Glyph;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="$Color" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <StackPanel VerticalAlignment="Center">
      <TextBlock Text="$(Esc $Title)" FontSize="13.5" FontWeight="SemiBold" Foreground="#F1F3F8" TextTrimming="CharacterEllipsis"/>
      <TextBlock Text="$(Esc $Sub)" FontSize="12" Foreground="#8A91A3" $(if ($Wrap) { 'TextWrapping="Wrap"' } else { 'TextTrimming="CharacterEllipsis"' }) Margin="0,2,0,0"/>$bar
    </StackPanel>
  </DockPanel>
</Border>
"@
    [Windows.Markup.XamlReader]::Parse($x)
}

function Add-RowButton($Row, [string]$Glyph, [string]$Text, [scriptblock]$OnClick, $Tag, [string]$Style = 'BtnGhost') {
    $b = New-Object Windows.Controls.Button
    $b.Style = $window.FindResource($Style)
    $b.Padding = '12,7'; $b.Margin = '6,0,0,0'; $b.Tag = $Tag
    $b.Content = [Windows.Markup.XamlReader]::Parse("<StackPanel xmlns=""http://schemas.microsoft.com/winfx/2006/xaml/presentation"" Orientation=""Horizontal""><TextBlock Text=""&#x$Glyph;"" FontFamily=""Segoe MDL2 Assets"" Margin=""0,2,7,0""/><TextBlock Text=""$(Esc $Text)""/></StackPanel>")
    $b.Add_Click($OnClick)
    [void]$Row.Child.Children[0].Children.Add($b)
    $b
}

function Get-FileGlyph([string]$Name) {
    switch -Regex ($Name) {
        '\.(mp4|mkv|avi|mov|wmv|m4v|ts)$' { 'E714'; break }
        '\.(jpe?g|png|gif|bmp|heic|raw|psd)$' { 'E91B'; break }
        '\.(iso|img|vhdx?|vmdk|ova)$' { 'EDA2'; break }
        '\.(zip|rar|7z|tar|gz|bak|pst|ost)$' { 'E8F1'; break }
        '\.(exe|msi)$' { 'E896'; break }
        default { 'E8A5' }
    }
}

function Render-BigFiles {
    $ui.PanelBigFiles.Children.Clear()
    if (-not $script:BigAll) { [void]$ui.PanelBigFiles.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = 'Nenhum arquivo de 500 MB ou mais nas suas pastas.'; Foreground = '#8A91A3'; Margin = '2,0,0,10' })) }
    foreach ($f in ($script:BigAll | Select-Object -First $script:BigShown)) {
        $age = Format-Age $f.Date
        $row = New-SpaceRow (Get-FileGlyph $f.Name) '#38BDF8' $f.Name "$(if ($age) { "Modificado $age  ·  " })$($f.Folder)" (Format-Size $f.Size)
        [void](Add-RowButton $row 'E8DA' 'Abrir pasta' { param($s) Start-Process explorer.exe "/select,`"$($s.Tag.Path)`"" } $f)
        if ($f.Cloud) {
            [void](Add-RowButton $row 'E753' 'Deixar só na nuvem' { param($s) if (Invoke-CloudOnly $s.Tag.Path $s.Tag.Size) { $ui.PanelBigFiles.Children.Remove($s.Parent.Parent.Parent) } } $f)
        }
        if (Test-CanDelete $f.Path) {
            [void](Add-RowButton $row 'E74D' 'Apagar' { param($s) if (Invoke-DeleteItem $s.Tag.Path $s.Tag.Size) { $ui.PanelBigFiles.Children.Remove($s.Parent.Parent.Parent) } } $f)
        }
        [void]$ui.PanelBigFiles.Children.Add($row)
    }
    $rest = $script:BigAll.Count - $script:BigShown
    if ($rest -gt 0) {
        $more = New-Object Windows.Controls.Button
        $more.Style = $window.FindResource('BtnGhost'); $more.HorizontalAlignment = 'Left'; $more.Margin = '0,2,0,8'
        $more.Content = "Mostrar mais $([math]::Min(10, $rest)) (de $rest)"
        $more.Add_Click({ $script:BigShown += 10; Render-BigFiles })
        [void]$ui.PanelBigFiles.Children.Add($more)
    }
}

function Render-Space($r) {
    $usedPct = 100.0 * $r.Used / $r.Total
    $ui.SpaceRing.StrokeDashArray = New-Object Windows.Media.DoubleCollection (,[double[]]@((([math]::PI * 123 / 13) * $usedPct / 100), 1000))
    $ui.SpaceRing.Stroke = if ($usedPct -ge 90) { '#F87171' } elseif ($usedPct -ge 80) { '#F5A524' } else { '#7C5CFF' }
    $ui.SpaceFree.Text = Format-Size $r.Free
    $ui.SpaceTitle.Text = "$(Format-Size $r.Used) usados de $(Format-Size $r.Total)  ·  unidade $($r.Drive)"
    $ui.SpaceStatus.Text = if ($usedPct -ge 90) { "O disco está quase cheio ($([int]$usedPct)%). Com menos de 10% livre o Windows fica lento e as atualizações falham." }
                           else { "$([int]$usedPct)% ocupado. Análise feita em $($r.Seconds) segundos." }

    # barra empilhada e legenda
    $ui.SpaceBar.Children.Clear(); $ui.SpaceBar.ColumnDefinitions.Clear(); $ui.SpaceLegend.Children.Clear()
    $col = 0
    foreach ($k in $r.Buckets.Keys) {
        $v = [double]$r.Buckets[$k]
        if ($v -lt 100MB) { continue }
        $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = New-Object Windows.GridLength $v, 'Star'
        $ui.SpaceBar.ColumnDefinitions.Add($cd)
        $seg = New-Object Windows.Controls.Border; $seg.Background = $SpaceColors[$k]; $seg.Margin = '0,0,2,0'; $seg.ToolTip = "$k  ·  $(Format-Size ([int64]$v))"
        [Windows.Controls.Grid]::SetColumn($seg, $col); [void]$ui.SpaceBar.Children.Add($seg); $col++
        $leg = [Windows.Markup.XamlReader]::Parse("<StackPanel xmlns=""http://schemas.microsoft.com/winfx/2006/xaml/presentation"" Orientation=""Horizontal"" Margin=""0,0,18,6""><Ellipse Width=""9"" Height=""9"" Fill=""$($SpaceColors[$k])"" VerticalAlignment=""Center"" Margin=""0,0,7,0""/><TextBlock Text=""$(Esc $k)"" FontSize=""12.5"" Foreground=""#C9CFDB""/><TextBlock Text=""  $(Format-Size ([int64]$v))"" FontSize=""12.5"" FontWeight=""SemiBold"" Foreground=""#F1F3F8""/></StackPanel>")
        [void]$ui.SpaceLegend.Children.Add($leg)
    }
    $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = New-Object Windows.GridLength ([double]$r.Free), 'Star'; $ui.SpaceBar.ColumnDefinitions.Add($cd)
    [void]$ui.SpaceLegend.Children.Add([Windows.Markup.XamlReader]::Parse("<StackPanel xmlns=""http://schemas.microsoft.com/winfx/2006/xaml/presentation"" Orientation=""Horizontal"" Margin=""0,0,18,6""><Ellipse Width=""9"" Height=""9"" Fill=""#232838"" Stroke=""#5F6679"" VerticalAlignment=""Center"" Margin=""0,0,7,0""/><TextBlock Text=""Livre"" FontSize=""12.5"" Foreground=""#C9CFDB""/><TextBlock Text=""  $(Format-Size $r.Free)"" FontSize=""12.5"" FontWeight=""SemiBold"" Foreground=""#F1F3F8""/></StackPanel>"))

    # dá para liberar
    $ui.PanelJunk.Children.Clear()
    $safe = @($r.Junk | Where-Object Safe)
    $safeSize = [int64](@($safe | ForEach-Object Size) | Measure-Object -Sum).Sum
    $script:SafeJunkIds = @($safe | ForEach-Object { $_.Ids })
    $ui.BtnFreeSafe.Visibility = if ($safeSize -ge 50MB) { 'Visible' } else { 'Collapsed' }
    $ui.TxtFreeSafe.Text = "Liberar o que é seguro ($(Format-Size $safeSize))"
    if (-not $r.Junk) { [void]$ui.PanelJunk.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = 'Quase nada para limpar. O disco já está em ordem.'; Foreground = '#8A91A3'; Margin = '2,0,0,10' })) }
    foreach ($j in $r.Junk) {
        $color = if ($j.Safe) { '#4ADE80' } else { '#F5A524' }
        $tint = '#26' + $color.TrimStart('#')
        $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Background="#171B24" BorderBrush="#232836" BorderThickness="1" CornerRadius="12" Padding="14,12" Margin="0,0,12,12">
  <DockPanel>
    <DockPanel DockPanel.Dock="Top">
      <TextBlock DockPanel.Dock="Right" Text="$(Format-Size $j.Size)" FontSize="18" FontWeight="Bold" Foreground="#F4F5F9"/>
      <Border Width="34" Height="34" CornerRadius="9" Background="$tint" HorizontalAlignment="Left">
        <TextBlock Text="&#x$($j.Glyph);" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="$color" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
    </DockPanel>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,10,0,0"/>
    <StackPanel Margin="0,10,0,0">
      <TextBlock Text="$(Esc $j.Title)" FontSize="13.5" FontWeight="SemiBold" Foreground="#F1F3F8"/>
      <TextBlock Text="$(Esc $j.Desc)" FontSize="12" Foreground="#8A91A3" TextWrapping="Wrap" Margin="0,3,0,0"/>
    </StackPanel>
  </DockPanel>
</Border>
"@
        $card = [Windows.Markup.XamlReader]::Parse($x)
        $b = New-Object Windows.Controls.Button
        $b.Style = $window.FindResource($(if ($j.Safe) { 'Btn' } else { 'BtnGhost' }))
        $b.Padding = '14,7'; $b.Content = 'Limpar'; $b.Tag = $j
        $b.Add_Click({ param($s) Start-Run @($s.Tag.Ids) ([bool]$ui.ChkRestore.IsChecked) 'tasks' "Liberar espaço: $($s.Tag.Title)"; $script:SpaceStale = $true })
        [void]$card.Child.Children[1].Children.Add($b)
        [void]$ui.PanelJunk.Children.Add($card)
    }

    # coisas escondidas
    $ui.PanelHidden.Children.Clear()
    $ui.SecHidden.Visibility = if ($r.Hidden) { 'Visible' } else { 'Collapsed' }
    $colors = @{ docker = '#38BDF8'; wsl = '#F5A524'; vm = '#A78BFA'; mc = '#4ADE80'; cache = '#F472B6'; log = '#F87171'; isoext = '#60A5FA'; restore = '#22D3EE' }
    foreach ($h in $r.Hidden) {
        $age = Format-Age $h.Date
        $sub = $h.Desc + $(if ($age) { "  ·  Mexido pela última vez $age." } else { '' })
        $row = New-SpaceRow $h.Glyph $colors[$h.Kind] $h.Title $sub (Format-Size $h.Size) -Wrap
        switch ($h.Kind) {
            'docker'  { $d = Get-UninstallEntry 'Docker Desktop'
                        if ($d) { [void](Add-RowButton $row 'E74D' 'Desinstalar Docker' { param($s) Invoke-UninstallApp $s.Tag } $d) } }
            'wsl'     { [void](Add-RowButton $row 'E8C8' 'Copiar comando' { param($s) Copy-WslCommand $s.Tag.Extra } $h) }
            'cache'   { [void](Add-RowButton $row 'E74D' 'Limpar' { param($s) if (Invoke-ClearCache $s.Tag) { $ui.PanelHidden.Children.Remove($s.Parent.Parent.Parent) } } $h 'Btn') }
            'log'     { [void](Add-RowButton $row 'E74D' 'Apagar' { param($s) if (Invoke-DeleteLog $s.Tag) { $ui.PanelHidden.Children.Remove($s.Parent.Parent.Parent) } } $h 'Btn') }
            'restore' { [void](Add-RowButton $row 'E713' 'Configurar' { param($s) Start-Process "$env:windir\System32\SystemPropertiesProtection.exe" } $h) }
            { 'vm', 'isoext' -contains $_ } {
                if (Test-CanDelete $h.Path) { [void](Add-RowButton $row 'E74D' 'Apagar' { param($s) if (Invoke-DeleteItem $s.Tag.Path $s.Tag.Size) { $ui.PanelHidden.Children.Remove($s.Parent.Parent.Parent) } } $h) }
            }
        }
        if ($h.Kind -ne 'restore') {
            [void](Add-RowButton $row 'E8DA' 'Abrir pasta' { param($s) if (Test-Path -LiteralPath $s.Tag.Path -PathType Leaf) { Start-Process explorer.exe "/select,`"$($s.Tag.Path)`"" } else { Start-Process explorer.exe "`"$($s.Tag.Path)`"" } } $h)
        }
        [void]$ui.PanelHidden.Children.Add($row)
    }

    # arquivos grandes (10 de cada vez)
    $script:BigAll = @($r.Big)
    $script:BigShown = 10
    Render-BigFiles

    # programas e jogos
    $ui.PanelBigApps.Children.Clear()
    $max = [double](@($r.Apps | ForEach-Object Size) | Measure-Object -Maximum).Maximum
    foreach ($a in $r.Apps) {
        $isGame = 'Steam', 'Epic', 'Jogo' -contains $a.Kind
        $kindTxt = switch ($a.Kind) { 'Steam' { 'Jogo da Steam' } 'Epic' { 'Jogo da Epic' } 'Jogo' { 'Jogo' } default { 'Programa' } }
        $row = New-SpaceRow $(if ($isGame) { 'E7FC' } else { 'E71D' }) $(if ($isGame) { '#38BDF8' } else { '#A78BFA' }) $a.Name $kindTxt (Format-Size $a.Size) ($a.Size / [math]::Max(1.0, $max))
        [void](Add-RowButton $row 'E74D' 'Desinstalar' { param($s) Invoke-UninstallApp $s.Tag } $a)
        [void]$ui.PanelBigApps.Children.Add($row)
    }

    # pastas da raiz
    $script:FolderStack.Clear()
    $script:FolderCache["$($r.Drive)\"] = $r.Folders
    Render-Folders "$($r.Drive)\" $r.Folders
}

function Render-Folders([string]$Path, $Items) {
    $ui.PanelFolders.Children.Clear()
    $ui.BtnFolderUp.Visibility = if ($script:FolderStack.Count) { 'Visible' } else { 'Collapsed' }
    $total = [int64](@($Items | ForEach-Object Size) | Measure-Object -Sum).Sum
    $ui.TxtFolderPath.Text = "$Path  ·  $(Format-Size $total)  ·  clique numa pasta para ver o que tem dentro"
    $max = [double](@($Items | ForEach-Object Size) | Measure-Object -Maximum).Maximum
    foreach ($it in ($Items | Where-Object { $_.Size -ge 1MB } | Select-Object -First 40)) {
        $pct = if ($total) { '{0:N0}% desta pasta' -f (100.0 * $it.Size / $total) } else { '' }
        $row = New-SpaceRow $(if ($it.IsDir) { 'E8B7' } else { Get-FileGlyph $it.Name }) $(if ($it.IsDir) { '#F5A524' } else { '#38BDF8' }) $it.Name $pct (Format-Size $it.Size) ($it.Size / [math]::Max(1.0, $max))
        if ($it.IsDir) {
            $row.Cursor = 'Hand'; $row.Tag = $it.Path
            # os botões da linha tratam o próprio clique, então isso só dispara clicando no resto da linha
            $row.Add_MouseLeftButtonUp({ param($s) Open-SpaceFolder $s.Tag })
            [void](Add-RowButton $row 'E8A7' 'Abrir no Explorador' { param($s) Start-Process explorer.exe "`"$($s.Tag.Path)`"" } $it)
        } else {
            [void](Add-RowButton $row 'E8DA' 'Mostrar' { param($s) Start-Process explorer.exe "/select,`"$($s.Tag.Path)`"" } $it)
        }
        if (Test-CanDelete $it.Path) {
            [void](Add-RowButton $row 'E74D' 'Apagar' { param($s) if (Invoke-DeleteItem $s.Tag.Path $s.Tag.Size) { $ui.PanelFolders.Children.Remove($s.Parent.Parent.Parent) } } $it)
        }
        [void]$ui.PanelFolders.Children.Add($row)
    }
}

function Open-SpaceFolder([string]$Path) {
    if ($sync.UpdateBusy -and $sync.UpdateDone) { Complete-UpdateCheck }
    if ($sync.FpsBusy) {
        $ui.FpsInfo.Text = $sync.FpsStatus; $ui.StatusText.Text = $sync.FpsStatus
        if ($sync.FpsDone) { Complete-FpsTest }
    }
    if ($sync.DiskBusy) { return }
    $current = if ($script:FolderStack.Count) { $script:FolderStack[$script:FolderStack.Count - 1] } else { "$($script:SpaceDrive)\" }
    if ($current -eq $Path) { return }
    [void]$script:FolderStack.Add($Path)
    if ($script:FolderCache.ContainsKey($Path)) { Render-Folders $Path $script:FolderCache[$Path] } else { Start-DiskScan $script:SpaceDrive $Path }
}

