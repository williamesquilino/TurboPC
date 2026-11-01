# [parte] Cartões de modo, perguntas e tela do modo (resumo + Otimizar agora)
# Perguntas simples (sim/não) que aparecem dentro dos modos. Cada uma liga ou desliga um grupo de ajustes.
$gpuBrand = if ($Global:HasNvidia) { 'NVIDIA' } elseif ($Global:HasAmd) { 'AMD' } else { '' }
$Questions = @{
    gpu = [pscustomobject]@{
        Glyph = 'E7F4'; Color = '#10B981'; Ids = @($Global:GpuIds)
        Title = if ($gpuBrand) { "Otimizar a placa de vídeo $gpuBrand" } else { 'Otimizar para a placa de vídeo' }
        Desc  = if ($Global:HasNvidia) { 'Ajusta o driver para jogos: placa sempre em velocidade máxima durante o jogo, texturas no modo desempenho e o monitor na taxa mais alta. Só o que não tem efeito colateral.' }
                elseif ($Global:HasAmd) { 'Liga o cache de shaders do driver (menos travadinhas) e faz os jogos da Steam e da Epic usarem sempre a placa de vídeo dedicada.' }
                else { 'Faz os jogos da Steam e da Epic usarem sempre a placa de vídeo dedicada (importante em notebook com vídeo integrado).' }
        Graphics = if ($Global:HasNvidia) { 'Ficam praticamente iguais. Resolução, sombras e efeitos não mudam. Só a filtragem de texturas vai para o modo desempenho: texturas bem ao longe podem ficar um pouquinho menos nítidas, difícil de notar.' }
                   else { 'Não mudam nada. Só o jeito como a placa trabalha.' }
    }
    power = [pscustomobject]@{
        Glyph = 'E945'; Color = '#F5A524'
        Ids   = if ($Global:IsLaptop) { @('powerplan', 'ultimate', 'powerthrottle') } else { @('ultimate', 'powerthrottle') }
        Title = if ($Global:IsLaptop) { 'Energia no máximo (notebook)' } else { 'Energia no máximo' }
        Desc  = if ($Global:IsLaptop) { 'Só vale a pena se o notebook vive na tomada: na bateria ela acaba bem mais rápido e ele esquenta mais.' }
                else { 'Tira até as pequenas economias de energia do processador. Ganho pequeno, e o PC gasta um pouco mais de luz.' }
        Graphics = ''
    }
    mouse = [pscustomobject]@{
        Glyph = 'E962'; Color = '#38BDF8'; Ids = @('mouseaccel'); Graphics = ''
        Title = 'Mira mais precisa (mouse sem aceleração)'
        Desc  = 'O mesmo movimento da mão sempre gira a mesma distância na tela. Nos primeiros minutos o mouse vai parecer diferente.'
    }
    visual = [pscustomobject]@{
        Glyph = 'E790'; Color = '#A78BFA'; Ids = @('visualfx', 'transparency'); Graphics = ''
        Title = 'Visual do Windows mais leve'
        Desc  = 'Desliga animações, sombras e transparência. PC antigo fica mais ágil; o Windows fica com uma cara mais simples (as letras continuam bonitas).'
    }
    bloat = [pscustomobject]@{
        Glyph = 'E71D'; Color = '#F472B6'; Ids = @('bloat'); Graphics = ''
        Title = 'Remover apps que vêm de fábrica'
        Desc  = 'Paciência, Notícias, Clipchamp, Xbox, jogos da King e parecidos. Calculadora, Fotos, Office, Teams e Outlook ficam. Para ter algum de volta, instale pela Microsoft Store.'
    }
    hags = [pscustomobject]@{
        Glyph = 'E7F4'; Color = '#F472B6'; Ids = @('hags')
        Title = 'Agendamento de GPU (DLSS Frame Generation)'
        Desc  = 'Necessário para o DLSS Frame Generation das RTX 4000/5000, que pode quase dobrar o FPS em jogos pesados. Vale depois de reiniciar.'
        Graphics = 'Não mudam. Mas em jogos competitivos, como o Valorant, ele pode baixar o FPS: por isso só vem ligado quando o PC é de jogos pesados.'
    }
    deep = [pscustomobject]@{
        Glyph = 'E74D'; Color = '#22D3EE'; Ids = @('cleanmgr'); Graphics = ''
        Title = 'Limpeza profunda do Windows'
        Desc  = 'Apaga instalações antigas do Windows e atualizações velhas. Pode liberar vários GB, mas demora até 30 minutos e depois não dá para voltar para a versão anterior do Windows.'
    }
}

$energyNote = @()
if ($Global:IsLaptop) { $energyNote = @(, @('Notebook: a energia não é mexida, para não gastar bateria.', 'info')) }
$browserNote = @('Edge e Chrome passam a mostrar "Gerenciado pela sua organização". É só o aviso de que a configuração foi aplicada.', 'info')
$ModeInfo = @(
    [pscustomobject]@{ Key = 'Recomendado'; Title = 'Recomendado'; For = 'Para qualquer PC'; Glyph = 'E73E'; Color = '#4ADE80'; Badge = 'Mais indicado'
        Desc = 'Os ajustes mais simples e seguros. Mais rápido sem mudar nada que você use ou veja.'
        Bullets = @('Liga e abre os programas mais rápido', 'Apaga lixo e arquivos temporários, liberando espaço', 'Menos coisa rodando escondida e menos propaganda no Windows') +
                  @($(if (-not $Global:IsLaptop) { 'Processador sempre pronto (plano de energia Alto desempenho)' }))
        Changes = @(, @('Nada que você note: aparência, arquivos e programas ficam iguais.', 'ok')) + $energyNote
        Questions = @(, @('deep', $false)) }
    [pscustomobject]@{ Key = 'Escritorio'; Title = 'Escritório'; For = 'Para PC de trabalho'; Glyph = 'E821'; Color = '#A78BFA'; Badge = ''
        Desc = 'Tudo do Recomendado e um Windows mais leve para PC antigo de empresa.'
        Bullets = @('Tudo do Recomendado', 'Desliga serviços de jogos (Xbox) e o que pesa em PC antigo', 'Mostra a extensão dos arquivos (.pdf, .exe), o que ajuda a não cair em vírus', 'Num Lock já ligado na tela de senha')
        Changes = @(@('Xbox e Game Pass param de funcionar: não use em PC que joga.', 'warn'), $browserNote) + $energyNote
        Questions = @(@('visual', $true), @('bloat', $false), @('deep', $false)) }
    [pscustomobject]@{ Key = 'Jogos'; Title = 'Jogos'; For = 'Para PC de jogos'; Glyph = 'E7FC'; Color = '#38BDF8'; Badge = ''
        Desc = 'Mais FPS e menos travadinhas, com a otimização da placa de vídeo inclusa.'
        Bullets = @('Tudo do Recomendado', 'O Modo de Jogo do Windows fica ligado: ele segura atualizações e notificações enquanto você joga', 'Menos interrupções no meio do jogo (sem gravação em segundo plano e sem atualizações enviadas para outros PCs)', 'Apertar Shift 5 vezes não minimiza mais o jogo')
        Changes = @(@('A aparência do Windows fica igual. Xbox e Game Pass continuam funcionando.', 'ok'), @('Em jogo competitivo (Valorant, CS2, Fortnite), ligue o NVIDIA Reflex no próprio jogo: é o que mais reduz o atraso, sem perder FPS.', 'info'), $browserNote) + $energyNote
        Questions = @(@('gpu', $true), @('mouse', $true), @('power', $false)) }
    [pscustomobject]@{ Key = 'Maximo'; Title = 'Máximo'; For = 'Para PC muito fraco'; Glyph = 'E945'; Color = '#F472B6'; Badge = ''
        Desc = 'Tudo do Jogos e o Windows no modo mais leve possível. Para quando cada gota conta.'
        Bullets = @('Tudo do modo Jogos', 'Windows no visual mais leve', 'Apps da Loja não ficam rodando escondidos depois de fechados')
        Changes = @(@('Notificações de apps da Loja, como o novo Teams, podem chegar atrasadas.', 'warn'), @('Xbox e Game Pass continuam funcionando.', 'ok')) + $energyNote
        Questions = @(@('gpu', $true), @('visual', $true), @('power', (-not $Global:IsLaptop)), @('mouse', $true), @('deep', $false)) }
)

# Ajustes finais de um modo a partir das respostas: o pacote do modo, trocando o que as perguntas controlam
function Get-WizardIds([string]$Key, [hashtable]$Answers, [object[]]$QList) {
    if (-not $QList) { $QList = @(($ModeInfo | Where-Object Key -eq $Key).Questions) }
    $qIds = @($QList | ForEach-Object { $Questions[$_[0]].Ids })
    $on   = @($QList | Where-Object { $Answers[$_[0]] } | ForEach-Object { $Questions[$_[0]].Ids })
    $base = @(Get-ProfileIds $Key | Where-Object { $qIds -notcontains $_ })
    @($TTasks | Where-Object { $base -contains $_.Id -or $on -contains $_.Id } | ForEach-Object Id)
}

function Build-ModeCards {
    $ui.PanelModes.Children.Clear()
    $script:ModeButtons = @()
    foreach ($m in $ModeInfo) {
        $defaults = @{}; foreach ($q in $m.Questions) { $defaults[$q[0]] = $q[1] }
        $n = @(Get-WizardIds $m.Key $defaults).Count
        $tint = '#26' + $m.Color.TrimStart('#')
        # selo no modo que combina com o uso do PC (sem uso definido, no Recomendado)
        $pick = if ($script:UsageKind) { $UsageKinds[$script:UsageKind].Mode -eq $m.Key } else { [bool]$m.Badge }
        $badgeText = if ($script:UsageKind) { 'Indicado para este PC' } else { $m.Badge }
        $badge = if ($pick) { "<Border DockPanel.Dock=""Right"" Background=""#163326"" CornerRadius=""7"" Padding=""8,2"" VerticalAlignment=""Top""><TextBlock Text=""$badgeText"" FontSize=""10.5"" FontWeight=""SemiBold"" Foreground=""#4ADE80""/></Border>" } else { '' }
        $x = @"
<DockPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" LastChildFill="True">
  <DockPanel DockPanel.Dock="Top">
    $badge
    <Border Width="44" Height="44" CornerRadius="12" Background="$tint" HorizontalAlignment="Left">
      <TextBlock Text="&#x$($m.Glyph);" FontFamily="Segoe MDL2 Assets" FontSize="20" Foreground="$($m.Color)" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
  </DockPanel>
  <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,14,0,0">
    <TextBlock Text="Ver o que muda" FontSize="12.5" FontWeight="SemiBold" Foreground="$($m.Color)"/>
    <TextBlock Text="&#xE72A;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="$($m.Color)" Margin="8,3,0,0"/>
  </StackPanel>
  <StackPanel Margin="0,14,0,0">
    <TextBlock Text="$(Esc $m.For.ToUpper())" FontSize="10.5" FontWeight="SemiBold" Foreground="$($m.Color)"/>
    <TextBlock Text="$(Esc $m.Title)" FontSize="17" FontWeight="SemiBold" Foreground="#F4F5F9" Margin="0,3,0,0"/>
    <TextBlock Text="$(Esc $m.Desc)" FontSize="12.5" Foreground="#8A91A3" TextWrapping="Wrap" Margin="0,5,0,0"/>
  </StackPanel>
</DockPanel>
"@
        $btn = New-Object Windows.Controls.Button
        $btn.Style = $window.FindResource('ModeCard')
        $btn.Content = [Windows.Markup.XamlReader]::Parse($x)
        $btn.HorizontalContentAlignment = 'Stretch'
        $btn.Tag = $m.Key
        $btn.ToolTip = "$n ajustes"
        if ($pick) { $btn.BorderBrush = '#2F6B4C' }
        [void]$ui.PanelModes.Children.Add($btn)
        $script:ModeButtons += $btn
    }
}

# Tela do modo: o que vai acontecer, o que muda, poucas perguntas e um botão. A lista técnica fica em "Ver detalhes técnicos".
function Show-ModeWizard([string]$Key) {
    $m = $ModeInfo | Where-Object Key -eq $Key
    $tint = '#26' + $m.Color.TrimStart('#')
    $bullets = foreach ($b in ($m.Bullets | Where-Object { $_ })) {
        "<DockPanel Margin=""0,0,0,9""><TextBlock Text=""&#xE73E;"" FontFamily=""Segoe MDL2 Assets"" FontSize=""13"" Foreground=""#4ADE80"" Margin=""0,2,12,0""/><TextBlock Text=""$(Esc $b)"" FontSize=""13.5"" Foreground=""#E6E8EE"" TextWrapping=""Wrap""/></DockPanel>"
    }
    # o que foi detectado e escolhido muda os avisos e as perguntas
    $g = $script:UsageGuess
    $comp = @($g.Competitive); $games = @($comp) + @($g.Heavy)
    $changeList = @($m.Changes)
    if ($comp.Count -and ('Jogos', 'Maximo' -contains $Key)) {
        $changeList = @(, @("Encontramos jogos competitivos ($(($comp | Select-Object -First 3) -join ', ')): nada que possa baixar o FPS neles é aplicado.", 'ok')) + $changeList
    }
    if ('Jogos', 'Maximo' -contains $Key) {
        $changeList += , @('Quer ter certeza de que melhorou? Use o Teste de FPS do Painel antes e depois de otimizar, no mesmo lugar do jogo.', 'info')
    }
    if ($games.Count -and $Key -eq 'Escritorio') {
        $changeList = @(, @("Encontramos jogos neste PC ($(($games | Select-Object -First 3) -join ', ')). Para quem joga, use Recomendado ou Jogos.", 'warn')) + $changeList
    }
    $qList = @($m.Questions | ForEach-Object { , @($_[0], $_[1]) })
    $gpuName = "$($ui.InfoGPU.Text)"
    if (('Jogos', 'Maximo' -contains $Key) -and $gpuName -match 'RTX\s*(40|50)\d\d') {
        # Frame Generation só nas RTX 4000/5000; vem ligado só em PC de jogos pesados sem jogo competitivo
        $qList += , @('hags', ($script:UsageKind -eq 'Pesado' -and -not $comp.Count))
    }
    $saved = $script:SavedAnswers[$Key]
    if ($saved) { foreach ($q in $qList) { if ($saved.ContainsKey($q[0])) { $q[1] = $saved[$q[0]] } } }
    $script:WzQList = $qList
    $changes = foreach ($c in $changeList) {
        $glyph, $color = switch ($c[1]) { 'ok' { 'E73E', '#4ADE80' } 'warn' { 'E7BA', '#F5A524' } default { 'E946', '#60A5FA' } }
        "<DockPanel Margin=""0,0,0,9""><TextBlock Text=""&#x$glyph;"" FontFamily=""Segoe MDL2 Assets"" FontSize=""13"" Foreground=""$color"" Margin=""0,2,12,0""/><TextBlock Text=""$(Esc $c[0])"" FontSize=""13.5"" Foreground=""#E6E8EE"" TextWrapping=""Wrap""/></DockPanel>"
    }
    $x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$(Esc $m.Title) - TurboPC" Width="760" Height="780" MinWidth="620" MinHeight="520" WindowStartupLocation="CenterOwner"
        Background="#0E1117" FontFamily="Segoe UI" Foreground="#E6E8EE" ShowInTaskbar="False">
  <DockPanel Margin="30,26,30,22">
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,20">
      <Border Width="56" Height="56" CornerRadius="15" Background="$tint">
        <TextBlock Text="&#x$($m.Glyph);" FontFamily="Segoe MDL2 Assets" FontSize="25" Foreground="$($m.Color)" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <StackPanel Margin="16,0,0,0" VerticalAlignment="Center">
        <TextBlock Text="$(Esc $m.For.ToUpper())" FontSize="11" FontWeight="SemiBold" Foreground="$($m.Color)"/>
        <TextBlock Text="$(Esc $m.Title)" FontSize="25" FontWeight="SemiBold" Foreground="#F4F5F9"/>
      </StackPanel>
    </DockPanel>
    <Border DockPanel.Dock="Bottom" BorderBrush="#1F2430" BorderThickness="0,1,0,0" Padding="0,16,0,0" Margin="0,14,0,0">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="WzCancel" Content="Cancelar" IsCancel="True" Margin="0,0,10,0" Padding="18,12"/>
          <Button x:Name="WzGo" IsDefault="True" Padding="26,9">
            <StackPanel>
              <TextBlock Text="Otimizar agora" FontSize="15" HorizontalAlignment="Center"/>
              <TextBlock x:Name="WzCount" FontSize="11.5" FontWeight="Normal" Opacity="0.85" HorizontalAlignment="Center"/>
            </StackPanel>
          </Button>
        </StackPanel>
        <StackPanel VerticalAlignment="Center">
          <CheckBox x:Name="WzRestore"><TextBlock Text="Criar ponto de restauração antes" Foreground="#C9CFDB" FontSize="12.5"/></CheckBox>
          <Button x:Name="WzDetails" HorizontalAlignment="Left" Margin="0,8,0,0" Padding="0" Background="Transparent" Foreground="#A99BFF" FontWeight="Normal" FontSize="12.5">
            <StackPanel Orientation="Horizontal"><TextBlock Text="Ver detalhes técnicos"/><TextBlock Text="&#xE72A;" FontFamily="Segoe MDL2 Assets" FontSize="10" Margin="6,3,0,0"/></StackPanel>
          </Button>
        </StackPanel>
      </DockPanel>
    </Border>
    <ScrollViewer VerticalScrollBarVisibility="Auto">
      <StackPanel Margin="0,0,14,0">
        <Border Background="#171B24" BorderBrush="#232836" BorderThickness="1" CornerRadius="14" Padding="18,16,18,8" Margin="0,0,0,12">
          <StackPanel>
            <TextBlock Text="O QUE VAI ACONTECER" FontSize="11" FontWeight="SemiBold" Foreground="#7C849A" Margin="0,0,0,12"/>
            $($bullets -join "`n")
          </StackPanel>
        </Border>
        <Border Background="#171B24" BorderBrush="#232836" BorderThickness="1" CornerRadius="14" Padding="18,16,18,8" Margin="0,0,0,20">
          <StackPanel>
            <TextBlock Text="O QUE MUDA PARA VOCÊ" FontSize="11" FontWeight="SemiBold" Foreground="#7C849A" Margin="0,0,0,12"/>
            $($changes -join "`n")
          </StackPanel>
        </Border>
        <TextBlock Text="Suas escolhas" FontSize="17" FontWeight="SemiBold" Foreground="#F4F5F9"/>
        <TextBlock Text="Já deixamos ligado o mais indicado para este PC. Mude só se quiser." FontSize="12.5" Foreground="#8A91A3" Margin="0,3,0,12"/>
        <StackPanel x:Name="WzQuestions"/>
        <DockPanel Margin="2,8,0,4">
          <TextBlock Text="&#xE823;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="#8A91A3" Margin="0,2,10,0"/>
          <TextBlock x:Name="WzTime" FontSize="12.5" Foreground="#8A91A3" TextWrapping="Wrap"/>
        </DockPanel>
      </StackPanel>
    </ScrollViewer>
  </DockPanel>
</Window>
"@
    $wz = [Windows.Markup.XamlReader]::Parse($x)
    $wz.Owner = $window
    $wz.Resources = $window.Resources
    $wz.FindName('WzGo').Style = $window.FindResource('Btn')
    $wz.FindName('WzCancel').Style = $window.FindResource('BtnGhost')
    $wz.FindName('WzRestore').Style = $window.FindResource('Toggle')
    $wz.FindName('WzRestore').IsChecked = $ui.ChkRestore.IsChecked
    $details = $wz.FindName('WzDetails')
    $details.Style = $window.FindResource('BtnGhost')
    $details.Background = 'Transparent'; $details.Foreground = '#A99BFF'; $details.Padding = '0'
    $script:WzKey = $Key
    $script:WzBoxes = [ordered]@{}
    $script:WzWin = $wz

    $qPanel = $wz.FindName('WzQuestions')
    foreach ($q in $qList) {
        $def = $Questions[$q[0]]
        $extra = if ($def.Graphics) {
            "<Border Background=""#0F2A36"" CornerRadius=""8"" Padding=""11,8"" Margin=""0,9,0,0""><TextBlock TextWrapping=""Wrap"" FontSize=""12.3"" Foreground=""#BAE6FD""><Run Text=""E os gráficos? "" FontWeight=""SemiBold""/><Run Text=""$(Esc $def.Graphics)""/></TextBlock></Border>"
        } else { '' }
        $card = [Windows.Markup.XamlReader]::Parse((New-IconCardXaml $def.Glyph $def.Color (Esc $def.Title) '' (Esc $def.Desc) $extra '0,0,0,10'))
        $card.Child.Style = $window.FindResource('ToggleRight')
        $card.Child.IsChecked = [bool]$q[1]
        $card.Child.Add_Checked({ Update-Wizard })
        $card.Child.Add_Unchecked({ Update-Wizard })
        $script:WzBoxes[$q[0]] = $card.Child
        [void]$qPanel.Children.Add($card)
    }
    Update-Wizard

    $script:WzResult = $null
    $wz.FindName('WzGo').Add_Click({
        $ans = Get-WizardAnswers
        $script:WzResult = @{ Ids = @(Get-WizardIds $script:WzKey $ans $script:WzQList); Restore = [bool]$script:WzWin.FindName('WzRestore').IsChecked }
        $script:SavedAnswers[$script:WzKey] = $ans
        Save-Prefs
        $script:WzWin.Close()
    })
    $details.Add_Click({
        # lista técnica completa; o que ficou de fora (extras e perguntas desligadas) aparece desligado no final
        $ids = @(Get-WizardIds $script:WzKey (Get-WizardAnswers) $script:WzQList)
        $mm = $ModeInfo | Where-Object Key -eq $script:WzKey
        $offQ = @($script:WzQList | ForEach-Object { $Questions[$_[0]].Ids })
        $extras = @(@(Get-ModeExtras $script:WzKey) + $offQ | Where-Object { $ids -notcontains $_ } | Select-Object -Unique)
        $ui.ChkRestore.IsChecked = $script:WzWin.FindName('WzRestore').IsChecked
        $r = Show-Review $mm.Title 'Lista técnica de tudo o que será aplicado. Ligue ou desligue item por item.' $ids $extras
        if ($r) { $script:WzResult = $r; $script:WzWin.Close() }
    })
    [void]$wz.ShowDialog()
    if ($script:WzResult) { $ui.ChkRestore.IsChecked = $script:WzResult.Restore }
    return $script:WzResult
}

function Get-WizardAnswers {
    $a = @{}
    foreach ($k in $script:WzBoxes.Keys) { $a[$k] = [bool]$script:WzBoxes[$k].IsChecked }
    $a
}

function Update-Wizard {
    $ans = Get-WizardAnswers
    $ids = @(Get-WizardIds $script:WzKey $ans $script:WzQList)
    $script:WzWin.FindName('WzCount').Text = "$($ids.Count) ajustes  ·  dá para desfazer depois"
    $time = if ($ids -contains 'cleanmgr') { 'Leva até 30 minutos por causa da limpeza profunda. Pode continuar usando o PC enquanto isso.' }
            elseif ($ids -contains 'nvidiadrv' -and -not (Find-NvInspector)) { 'Leva uns 2 a 4 minutos (na primeira vez baixa uma ferramenta da NVIDIA). Depois, é só reiniciar o PC.' }
            else { 'Leva cerca de 1 a 2 minutos. Depois, é só reiniciar o PC.' }
    $script:WzWin.FindName('WzTime').Text = $time
}

function Invoke-Mode([string]$Key) {
    if ($sync.Running) { return }
    $m = $ModeInfo | Where-Object Key -eq $Key
    $r = Show-ModeWizard $Key
    if ($r -and $r.Ids) { Start-Run $r.Ids $r.Restore 'tasks' $m.Title }
}

Build-ModeCards

# Faixa "Este PC" acima dos modos: tipo de PC, plano de energia e tomada/bateria. Devolve um aviso para o diagnóstico, se houver.
function Update-PcBanner([string]$Hardware) {
    $plan = (Get-CimInstance -Namespace root\cimv2\power -ClassName Win32_PowerPlan -Filter 'IsActive=True' -ErrorAction SilentlyContinue | Select-Object -First 1).ElementName
    if (-not $plan) {
        $out = "$(powercfg /getactivescheme 2>$null)"
        $known = @{ '381b4222-f694-41f0-9685-ff5bb260df2e' = 'Equilibrado'; '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'Alto desempenho'
                    'a1841308-3541-4fab-bc81-f71556f20b4a' = 'Economia de energia'; 'e9a42b02-d5df-448d-aa00-03f14749eb61' = 'Desempenho Máximo' }
        $guid = [regex]::Match($out, '[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}').Value.ToLower()
        $plan = if ($known[$guid]) { $known[$guid] } elseif ($out -match '\(([^)]+)\)\s*$') { $Matches[1] } else { 'não identificado' }
    }
    $fast = $plan -match 'Alto|High|M.ximo|Ultimate|Desempenho'
    $saver = $plan -match 'Economia|saver'
    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    $warn = $null
    if ($Global:IsLaptop -and $bat) {
        $onAC = $bat.BatteryStatus -ne 1
        $ui.PcIcon.Text = [string][char]0xE7F8
        $ui.PcTitle.Text = "Notebook detectado  ·  $Hardware"
        $ui.PcDetail.Text = "Plano de energia: $plan. Para não gastar bateria, nenhum modo mexe na energia. Se ele vive na tomada, dá para ligar os ajustes de energia nos Extras da revisão."
        $ui.PcPowerText.Text = if ($onAC) { "Na tomada  ·  $($bat.EstimatedChargeRemaining)%" } else { "Na bateria  ·  $($bat.EstimatedChargeRemaining)%" }
        $ui.PcPowerIcon.Text = [string][char]$(if ($onAC) { 0xE945 } else { 0xE7F8 })
        $fg = if ($onAC) { '#4ADE80' } else { '#F5A524' }
        $ui.PcPowerPill.Background = if ($onAC) { '#163326' } else { '#3A2E12' }
        if (-not $onAC -and $fast) { $warn = "Notebook na bateria com o plano '$plan': a bateria acaba bem mais rápido. Para trabalho fora da tomada, use o plano Equilibrado." }
    } else {
        $fg = '#4ADE80'
        $ui.PcIcon.Text = [string][char]0xE7F4
        $ui.PcTitle.Text = "PC de mesa detectado  ·  $Hardware"
        $ui.PcDetail.Text = if ($fast) { "Plano de energia: $plan. Já está no modo de desempenho." }
                            else { "Plano de energia: $plan. Os modos colocam em Alto Desempenho, que deixa o processador sempre pronto (em PC de mesa o gasto de luz a mais é pequeno)." }
        $ui.PcPowerText.Text = 'Ligado na tomada'
        $ui.PcPowerIcon.Text = [string][char]0xE945
        $ui.PcPowerPill.Background = '#163326'
        if ($saver) { $warn = "PC de mesa no plano '$plan': o processador fica limitado sem necessidade. Qualquer modo resolve." }
    }
    $ui.PcPowerText.Foreground = $fg
    $ui.PcPowerIcon.Foreground = $fg
    return $warn
}

