# [parte] Programas que abrem com o Windows
# ---------------------------------------------------------------- inicialização (startup)
function Get-StartupEntries {
    $base = 'Software\Microsoft\Windows\CurrentVersion'
    # "do usuário" é de quem está logado na tela, mesmo se o app roda com a senha de admin do técnico
    $userLabel = "Usuário $(($Global:TargetUser -split '\\')[-1])"
    $userStartup = if ($Global:UserHive) { "$($Global:TargetProfile)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup" } else { [Environment]::GetFolderPath('Startup') }
    $sources = @(
        @{ Run=(Resolve-UserPath "HKCU:\$base\Run"); Approved=(Resolve-UserPath "HKCU:\$base\Explorer\StartupApproved\Run"); Scope=$userLabel },
        @{ Run="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run";             Approved="HKLM:\$base\Explorer\StartupApproved\Run";   Scope='Todos os usuários' },
        @{ Run="HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"; Approved="HKLM:\$base\Explorer\StartupApproved\Run32"; Scope='Todos os usuários' }
    )
    $list = @()
    foreach ($s in $sources) {
        $key = Get-Item -Path $s.Run -ErrorAction SilentlyContinue
        if (-not $key) { continue }
        foreach ($name in $key.GetValueNames()) {
            if (-not $name) { continue }
            $list += [pscustomobject]@{ Name=$name; Command=[string]$key.GetValue($name); Approved=$s.Approved; Scope=$s.Scope; Enabled=$true }
        }
    }
    $folders = @(
        @{ Path=$userStartup; Approved=(Resolve-UserPath "HKCU:\$base\Explorer\StartupApproved\StartupFolder"); Scope=$userLabel },
        @{ Path=[Environment]::GetFolderPath('CommonStartup'); Approved="HKLM:\$base\Explorer\StartupApproved\StartupFolder"; Scope='Todos os usuários' }
    )
    foreach ($f in $folders) {
        if (-not $f.Path -or -not (Test-Path $f.Path)) { continue }
        foreach ($file in Get-ChildItem -Path $f.Path -File -ErrorAction SilentlyContinue | Where-Object Name -ne 'desktop.ini') {
            $list += [pscustomobject]@{ Name=$file.Name; Command=$file.FullName; Approved=$f.Approved; Scope="$($f.Scope) (pasta)"; Enabled=$true }
        }
    }
    foreach ($e in $list) {
        $v = (Get-ItemProperty -Path $e.Approved -Name $e.Name -ErrorAction SilentlyContinue).($e.Name)
        if ($v -and $v.Length -gt 0 -and ($v[0] -band 1)) { $e.Enabled = $false }
    }
    return $list
}

function Set-StartupEntry($Entry, [bool]$Enabled) {
    if (-not (Test-Path $Entry.Approved)) { New-Item -Path $Entry.Approved -Force | Out-Null }
    $bytes = if ($Enabled) { [byte[]](2,0,0,0,0,0,0,0,0,0,0,0) }
             else { [byte[]](@(3,0,0,0) + [BitConverter]::GetBytes((Get-Date).ToFileTime())) }
    New-ItemProperty -Path $Entry.Approved -Name $Entry.Name -Value $bytes -PropertyType Binary -Force | Out-Null
}

function Load-Startup {
    $ui.PanelStartup.Children.Clear()
    $script:StartupBoxes = @()
    $entries = @(Get-StartupEntries | Sort-Object Name)
    if (-not $entries) {
        [void]$ui.PanelStartup.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text='Nenhum programa de inicialização encontrado.'; Foreground='#8A91A3' }))
    }
    foreach ($e in $entries) {
        $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Background="#171B24" BorderBrush="#232836" BorderThickness="1" CornerRadius="12" Padding="16,12" Margin="0,0,0,8">
  <CheckBox>
    <StackPanel>
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="$(Esc $e.Name)" FontSize="14" FontWeight="SemiBold" Foreground="#F1F3F8"/>
        <Border Background="#232838" CornerRadius="6" Padding="7,1" Margin="10,0,0,0" VerticalAlignment="Center"><TextBlock Text="$(Esc $e.Scope)" FontSize="10.5" Foreground="#AEB4C2"/></Border>
      </StackPanel>
      <TextBlock Text="$(Esc $e.Command)" Foreground="#6F778A" FontSize="11.5" FontFamily="Consolas" TextTrimming="CharacterEllipsis" Margin="0,4,0,0"/>
    </StackPanel>
  </CheckBox>
</Border>
"@
        $card = [Windows.Markup.XamlReader]::Parse($x)
        $cb = $card.Child
        $cb.Style = $window.FindResource('Toggle')
        $cb.IsChecked = $e.Enabled
        $cb.Tag = $e
        $script:StartupBoxes += $cb
        [void]$ui.PanelStartup.Children.Add($card)
    }
    return $entries
}

