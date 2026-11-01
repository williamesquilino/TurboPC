# [parte] Janela de revisão (lista técnica)
# ---------------------------------------------------------------- janela de revisão
# os extras de cada modo vêm de Get-ModeExtras (biblioteca de tarefas)

function Add-ReviewHeader($List, [string]$Glyph, [string]$Color, [string]$Text, [string]$Sub = '') {
    $subXaml = if ($Sub) { "<TextBlock Text=""$(Esc $Sub)"" Foreground=""#8A91A3"" FontSize=""12.3"" TextWrapping=""Wrap"" Margin=""0,3,0,0""/>" } else { '' }
    $x = @"
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Margin="2,14,0,10">
  <StackPanel Orientation="Horizontal">
    <TextBlock Text="&#x$Glyph;" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="$Color" Margin="0,3,10,0"/>
    <TextBlock Text="$(Esc $Text)" FontSize="15" FontWeight="SemiBold" Foreground="#F4F5F9"/>
  </StackPanel>$subXaml
</StackPanel>
"@
    [void]$List.Children.Add([Windows.Markup.XamlReader]::Parse($x))
}

# Mostra o que vai ser aplicado, separado por categoria, e deixa desligar ou somar extras.
# Devolve @{ Ids; Restore } ou $null se cancelar.
function Show-Review([string]$Title, [string]$Subtitle, [string[]]$Ids, [string[]]$Extras = @()) {
    if (-not $Ids) { Show-Msg 'Selecione pelo menos uma otimização.' 'OK' 'Warning' | Out-Null; return $null }
    $Extras = @($Extras | Where-Object { $Ids -notcontains $_ -and $script:CheckMap.ContainsKey($_) })
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$(Esc $Title) - TurboPC" Width="800" Height="740" MinWidth="640" MinHeight="480" WindowStartupLocation="CenterOwner"
        Background="#0E1117" FontFamily="Segoe UI" Foreground="#E6E8EE" ShowInTaskbar="False">
  <DockPanel Margin="28,22,28,20">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,6">
      <TextBlock Text="$(Esc $Title)" FontSize="24" FontWeight="SemiBold" Foreground="#F4F5F9"/>
      <TextBlock Text="$(Esc $Subtitle)" FontSize="13" Foreground="#8A91A3" TextWrapping="Wrap" Margin="0,4,0,0"/>
    </StackPanel>
    <Border DockPanel.Dock="Bottom" BorderBrush="#1F2430" BorderThickness="0,1,0,0" Padding="0,16,0,0" Margin="0,12,0,0">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <Button x:Name="RvCancel" Content="Cancelar" IsCancel="True" Margin="0,0,8,0"/>
          <Button x:Name="RvApply" IsDefault="True"/>
        </StackPanel>
        <CheckBox x:Name="RvRestore" VerticalAlignment="Center">
          <TextBlock Text="Criar ponto de restauração antes" Foreground="#C9CFDB" FontSize="12.5"/>
        </CheckBox>
      </DockPanel>
    </Border>
    <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="RvList" Margin="0,0,14,0"/></ScrollViewer>
  </DockPanel>
</Window>
"@
    $rw = [Windows.Markup.XamlReader]::Parse($x)
    $rw.Owner = $window
    $rw.Resources = $window.Resources
    $list = $rw.FindName('RvList')
    $script:RvApply = $rw.FindName('RvApply')
    $rvRestore = $rw.FindName('RvRestore')
    $rvRestore.Style = $window.FindResource('Toggle')
    $rvRestore.IsChecked = $ui.ChkRestore.IsChecked
    $script:RvApply.Style = $window.FindResource('Btn')
    $rw.FindName('RvCancel').Style = $window.FindResource('BtnGhost')
    $script:RvBoxes = [ordered]@{}
    $refresh = {
        $n = @($script:RvBoxes.Values | Where-Object { $_.IsChecked }).Count
        $script:RvApply.Content = "Aplicar $n otimização(ões)"
        $script:RvApply.IsEnabled = $n -gt 0
    }
    $addCard = {
        param($t, [bool]$On)
        $card = New-TaskCard $t
        $card.Child.IsChecked = $On
        $card.Child.Add_Checked($refresh)
        $card.Child.Add_Unchecked($refresh)
        $script:RvBoxes[$t.Id] = $card.Child
        [void]$list.Children.Add($card)
    }
    foreach ($c in $Categories) {
        $ts = @($TTasks | Where-Object { $_.Cat -eq $c.Name -and $Ids -contains $_.Id })
        if (-not $ts) { continue }
        Add-ReviewHeader $list $c.Glyph $c.Color "$($c.Name)  ·  $($ts.Count)"
        foreach ($t in $ts) { & $addCard $t $true }
    }
    if ($Extras) {
        Add-ReviewHeader $list 'E734' '#F5A524' "Extras opcionais  ·  $($Extras.Count)" 'Ficam de fora do pacote porque têm algum efeito colateral (veja o aviso em laranja de cada um). Ligue os que fizerem sentido para este PC.'
        foreach ($t in ($TTasks | Where-Object { $Extras -contains $_.Id })) { & $addCard $t $false }
    }
    & $refresh
    $script:RvResult = $null
    $script:RvApply.Add_Click({
        $script:RvResult = @{
            Ids     = @($TTasks | Where-Object { $script:RvBoxes.Contains($_.Id) -and $script:RvBoxes[$_.Id].IsChecked } | ForEach-Object Id)
            Restore = [bool]$rvRestore.IsChecked
        }
        $rw.Close()
    })
    [void]$rw.ShowDialog()
    if ($script:RvResult) { $ui.ChkRestore.IsChecked = $script:RvResult.Restore }
    return $script:RvResult
}

