# [parte] Histórico e desfazer
# ---------------------------------------------------------------- histórico e desfazer
function Load-History {
    $ui.PanelHistory.Children.Clear()
    $script:UndoButtons = @()
    $runs = @(Get-UndoRuns | Select-Object -First 40)
    if (-not $runs) {
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Text = 'Nenhuma otimização feita ainda. Depois de aplicar um modo, ela aparece aqui e dá para desfazer.'
        $tb.Foreground = '#8A91A3'; $tb.FontSize = 13; $tb.Margin = '2,0,0,6'
        [void]$ui.PanelHistory.Children.Add($tb)
        return
    }
    foreach ($r in $runs) {
        $when = try { ([datetime]$r.Date).ToString("dd/MM/yyyy 'às' HH:mm") } catch { $r.Date }
        $nItems = @($r.Items).Count
        $info = "$when  ·  $(@($r.Tasks).Count) otimização(ões)  ·  $nItems configuração(ões) guardada(s)"
        $undone = [bool]$r.Undone
        $right = if ($undone) {
            $u = try { ([datetime]$r.Undone).ToString('dd/MM HH:mm') } catch { '' }
            "<Border DockPanel.Dock=""Right"" Background=""#232838"" CornerRadius=""8"" Padding=""10,5"" VerticalAlignment=""Center""><TextBlock Text=""Desfeito em $u"" FontSize=""12"" Foreground=""#8A91A3""/></Border>"
        } else { '<ContentControl DockPanel.Dock="Right" VerticalAlignment="Center"/>' }
        $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Background="#171B24" BorderBrush="#232836" BorderThickness="1" CornerRadius="12" Padding="14,12" Margin="0,0,0,8" Opacity="$(if ($undone) { '0.6' } else { '1' })">
  <DockPanel>
    $right
    <Border Width="38" Height="38" CornerRadius="10" Background="#26A78BFA" VerticalAlignment="Center" Margin="0,0,14,0">
      <TextBlock Text="&#xE81C;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="#A78BFA" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <StackPanel VerticalAlignment="Center">
      <TextBlock Text="$(Esc $r.Label)" FontSize="14" FontWeight="SemiBold" Foreground="#F1F3F8"/>
      <TextBlock Text="$(Esc $info)" FontSize="12.3" Foreground="#8A91A3" Margin="0,3,0,0"/>
    </StackPanel>
  </DockPanel>
</Border>
"@
        $card = [Windows.Markup.XamlReader]::Parse($x)
        $card.ToolTip = (@($r.Tasks) | ForEach-Object { "•  $_" }) -join "`n"
        if (-not $undone) {
            $btn = New-Object Windows.Controls.Button
            $btn.Style = $window.FindResource('BtnGhost')
            $btn.Padding = '14,8'
            $btn.Content = [Windows.Markup.XamlReader]::Parse('<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Orientation="Horizontal"><TextBlock Text="&#xE7A7;" FontFamily="Segoe MDL2 Assets" Margin="0,2,8,0"/><TextBlock Text="Desfazer"/></StackPanel>')
            $btn.Tag = $r
            $btn.IsEnabled = -not $sync.Running
            $btn.Add_Click({ param($s) Invoke-Undo $s.Tag })
            $card.Child.Children[0].Content = $btn
            $script:UndoButtons += $btn
        }
        [void]$ui.PanelHistory.Children.Add($card)
    }
}

function Invoke-Undo($Run) {
    if ($sync.Running) { return }
    $when = try { ([datetime]$Run.Date).ToString("dd/MM/yyyy 'às' HH:mm") } catch { $Run.Date }
    $notes = @($Run.Notes | Where-Object { $_ })
    $notesText = if ($notes) { "`n`nO que não tem como voltar:`n" + (($notes | ForEach-Object { "  •  $_" }) -join "`n") } else { '' }
    $msg = "Desfazer '$($Run.Label)' de $when?`n`nAs $(@($Run.Items).Count) configurações que o TurboPC mudou voltam a ser o que eram antes (registro, serviços, tarefas agendadas e energia).$notesText`n`nContinuar?"
    if ((Show-Msg $msg 'YesNo' 'Question') -ne 'Yes') { return }
    Start-Run @() $false 'undo' "Desfazer: $($Run.Label)" $Run.File
}

# Revisa e, se confirmado, executa. Não mexe no que está marcado na aba Otimizar.
