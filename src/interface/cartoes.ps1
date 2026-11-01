# [parte] Cartões das otimizações e seleção
# ---------------------------------------------------------------- cartões de tarefa
function New-TaskCard($t) {
    $pill = ''
    if ($Global:Modes.Recomendado.Ids -contains $t.Id) {
        $pill += '<Border Background="#163326" CornerRadius="6" Padding="7,1" Margin="10,0,0,0" VerticalAlignment="Center"><TextBlock Text="Recomendado" FontSize="10.5" Foreground="#4ADE80" FontWeight="SemiBold"/></Border>'
    } elseif ($t.Rec) {
        $pill += '<Border Background="#272050" CornerRadius="6" Padding="7,1" Margin="10,0,0,0" VerticalAlignment="Center"><TextBlock Text="Escritório" FontSize="10.5" Foreground="#A99BFF" FontWeight="SemiBold"/></Border>'
    }
    if ($t.Game) {
        $pill += '<Border Background="#0C2E44" CornerRadius="6" Padding="7,1" Margin="6,0,0,0" VerticalAlignment="Center"><TextBlock Text="Jogos" FontSize="10.5" Foreground="#38BDF8" FontWeight="SemiBold"/></Border>'
    }
    $warn = if ($t.Warn) {
        "<TextBlock Text=""&#x26A0;  $(Esc $t.Warn)"" Foreground=""#F5A524"" FontSize=""12"" TextWrapping=""Wrap"" Margin=""0,5,0,0""/>"
    } else { '' }
    $cat = $Categories | Where-Object Name -eq $t.Cat
    $glyph = if ($TaskIcons[$t.Id]) { $TaskIcons[$t.Id] } else { $cat.Glyph }
    $card = [Windows.Markup.XamlReader]::Parse((New-IconCardXaml $glyph $cat.Color (Esc $t.Name) $pill (Esc $t.Desc) $warn))
    $card.Child.Style = $window.FindResource('ToggleRight')
    return $card
}

# Cartão com ícone à esquerda, textos no meio e o interruptor à direita (usado nas otimizações e nos programas)
function New-IconCardXaml([string]$Glyph, [string]$Color, [string]$Title, [string]$Pills, [string]$Desc, [string]$Extra = '', [string]$Margin = '0,0,0,8') {
    $tint = '#26' + $Color.TrimStart('#')
    @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Background="#171B24" BorderBrush="#232836" BorderThickness="1" CornerRadius="12" Padding="14,12" Margin="$Margin">
  <CheckBox>
    <DockPanel>
      <Border DockPanel.Dock="Left" Width="38" Height="38" CornerRadius="10" Background="$tint" VerticalAlignment="Top" Margin="0,0,14,0">
        <TextBlock Text="&#x$Glyph;" FontFamily="Segoe MDL2 Assets" FontSize="17" Foreground="$Color" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <StackPanel VerticalAlignment="Center">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="$Title" FontSize="14" FontWeight="SemiBold" Foreground="#F1F3F8" TextTrimming="CharacterEllipsis"/>$Pills
        </StackPanel>
        <TextBlock Text="$Desc" Foreground="#8A91A3" FontSize="12.3" TextWrapping="Wrap" Margin="0,3,0,0"/>$Extra
      </StackPanel>
    </DockPanel>
  </CheckBox>
</Border>
"@
}

function Update-SelCount {
    $n = @($script:CheckMap.Values | Where-Object { $_.IsChecked }).Count
    $ui.TxtSelCount.Text = "$n selecionada(s)"
    foreach ($c in $Categories) {
        $ts = @($TTasks | Where-Object Cat -eq $c.Name)
        $on = @($ts | Where-Object { $script:CheckMap[$_.Id].IsChecked }).Count
        $ui["Cnt$($c.Name)"].Text = "$on/$($ts.Count)"
    }
}

foreach ($t in $TTasks) {
    $card = New-TaskCard $t
    $cb = $card.Child
    $cb.IsChecked = ($Global:Modes.Recomendado.Ids -contains $t.Id)
    $cb.Add_Checked({ Update-SelCount })
    $cb.Add_Unchecked({ Update-SelCount })
    $script:CheckMap[$t.Id] = $cb
    [void]$ui["Panel$($t.Cat)"].Children.Add($card)
}
Update-SelCount

function Get-SelectedIds { $TTasks | Where-Object { $script:CheckMap[$_.Id].IsChecked } | ForEach-Object { $_.Id } }

function Set-Profile([string]$Name) {
    $ids = @(Get-ProfileIds $Name)
    foreach ($t in $TTasks) { $script:CheckMap[$t.Id].IsChecked = ($ids -contains $t.Id) }
}

