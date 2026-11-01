# [parte] Categorias, medidores e ícones; cria a janela, $ui, $sync e utilitários da interface

# categorias da aba Otimizar: nome, ícone (Segoe MDL2), cor e descrição
$Categories = @(
    [pscustomobject]@{ Name = 'Limpeza';     Glyph = 'E74D'; Color = '#22D3EE'; Desc = 'Remove arquivos inúteis e libera espaço. Não apaga documentos, senhas nem favoritos.' }
    [pscustomobject]@{ Name = 'Desempenho';  Glyph = 'E945'; Color = '#A78BFA'; Desc = 'Deixa o Windows mais leve em hardware antigo. Os marcados com Escritório são seguros para qualquer PC da empresa.' }
    [pscustomobject]@{ Name = 'Jogos';       Glyph = 'E7FC'; Color = '#38BDF8'; Desc = 'Menos travadinhas, menos latência e mais FPS, incluindo as configurações do driver da placa de vídeo.' }
    [pscustomobject]@{ Name = 'Privacidade'; Glyph = 'E72E'; Color = '#4ADE80'; Desc = 'Menos coleta de dados e menos coisa rodando escondida. Não mexe no Windows Update nem no antivírus.' }
    [pscustomobject]@{ Name = 'Ajustes';     Glyph = 'E713'; Color = '#F5A524'; Desc = 'Pequenas mudanças que evitam chamados no suporte e deixam o Windows mais prático.' }
    [pscustomobject]@{ Name = 'Reparo';      Glyph = 'E90F'; Color = '#F472B6'; Desc = 'Ferramentas do próprio Windows para corrigir problemas. Algumas demoram; deixe o PC na tomada.' }
)
$chips = foreach ($c in $Categories) {
@"
            <TabItem Style="{StaticResource Chip}">
              <TabItem.Header>
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#x$($c.Glyph);" FontFamily="Segoe MDL2 Assets" FontSize="13" Margin="0,2,8,0"/>
                  <TextBlock Text="$($c.Name)" FontSize="13"/>
                  <TextBlock x:Name="Cnt$($c.Name)" FontSize="11.5" Margin="8,1,0,0" Opacity="0.65"/>
                </StackPanel>
              </TabItem.Header>
              <DockPanel>
                <Grid DockPanel.Dock="Top" Margin="0,0,0,14">
                  <TextBlock Text="$($c.Desc)" Style="{StaticResource Sub}" Margin="0,0,150,0" VerticalAlignment="Center"/>
                  <Button x:Name="All$($c.Name)" Tag="$($c.Name)" Content="Marcar todos" Style="{StaticResource BtnGhost}" HorizontalAlignment="Right" VerticalAlignment="Center" Padding="14,8"/>
                </Grid>
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="Panel$($c.Name)" Margin="0,0,14,0"/></ScrollViewer>
              </DockPanel>
            </TabItem>
"@
}
$Xaml = $Xaml.Replace('<!--OPTCHIPS-->', ($chips -join "`r`n"))

# medidores do bloco "Agora": chave, ícone, título e cor do gráfico
$GaugeDefs = @(
    [pscustomobject]@{ Key = 'Cpu';  Glyph = 'E945'; Title = 'PROCESSADOR';    Color = '#8B7CFF' }
    [pscustomobject]@{ Key = 'Ram';  Glyph = 'E964'; Title = 'MEMÓRIA RAM';    Color = '#22D3EE' }
    [pscustomobject]@{ Key = 'Gpu';  Glyph = 'E7F4'; Title = 'PLACA DE VÍDEO'; Color = '#F472B6' }
    [pscustomobject]@{ Key = 'Disk'; Glyph = 'EDA2'; Title = 'DISCO';          Color = '#F5A524' }
)
$gauges = foreach ($g in $GaugeDefs) {
@"
              <Border Style="{StaticResource CardBox}">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#x$($g.Glyph);" Style="{StaticResource CardIcon}" Foreground="$($g.Color)"/><TextBlock Text="$($g.Title)" Style="{StaticResource CardTitle}"/></StackPanel>
                  <Grid Width="150" Height="124" Margin="0,8,0,0" HorizontalAlignment="Center">
                    <Path x:Name="Gauge$($g.Key)Track" Stroke="#232838" StrokeThickness="11" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    <Path x:Name="Gauge$($g.Key)Arc" Stroke="#4ADE80" StrokeThickness="11" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    <StackPanel VerticalAlignment="Center" Margin="0,4,0,0">
                      <TextBlock x:Name="Mon$($g.Key)" Text="-" FontSize="30" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center"/>
                      <TextBlock x:Name="Mon$($g.Key)State" FontSize="12" FontWeight="SemiBold" Foreground="#8A91A3" HorizontalAlignment="Center"/>
                    </StackPanel>
                  </Grid>
                  <TextBlock x:Name="Mon$($g.Key)Sub" Style="{StaticResource CardSub}" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
                  <Canvas x:Name="Chart$($g.Key)" Height="46" Margin="0,12,0,0" ClipToBounds="True"/>
                </StackPanel>
              </Border>
"@
}
$Xaml = $Xaml.Replace('<!--GAUGES-->', ($gauges -join "`r`n"))

# ícone de cada otimização
$TaskIcons = @{
    temp='E74D'; wucache='E777'; browsercache='E774'; dumps='E7BA'; dns='E839'; recycle='E107'; thumbcache='E91B'; appcache='E8BD'; shadercache='E7F4'; cleanmgr='EDA2'
    powerplan='E945'; visualfx='E790'; transparency='E890'; startupdelay='E916'; gamedvr='E714'; services='E713'; suggestions='E789'; bloat='E71D'
    backgroundapps='E7C4'; indexing='E721'; hibernate='E708'; browserbg='E774'
    telemetry='E9D9'; adsid='E8EC'; activity='E81C'; websearch='E721'; widgets='E909'; copilot='E8BD'; recall='E722'; cortana='E720'; feedback='E939'
    gamemode='E7FC'; hags='E7F4'; gamepriority='E8CB'; mouseaccel='E962'; deliveryp2p='E898'; stickykeys='E765'; ultimate='E945'; powerthrottle='EC4A'
    nvidiadrv='E7F4'; amddrv='E7F4'; gpupref='E7F4'
    fileext='E8A5'; numlock='E765'; thispc='E80F'; classicmenu='E700'; taskbarleft='E8E4'; endtask='E711'
    optimizedisk='EDA2'; sfc='E73E'; dism='E90F'; componentcleanup='E74D'; chkdsk='EDA2'; netreset='E839'; wureset='E777'; printqueue='E749'; timesync='E823'; iconcache='E91B'
}
$AppIcons = @{ 'Navegadores'='E774'; 'Escritório'='E8A5'; 'Comunicação'='E8BD'; 'Acesso remoto'='E7F4'; 'Utilitários'='E713'; 'Mídia'='E714'
               'Jogos'='E7FC'; 'Componentes'='E8F1'; 'Diagnóstico'='E9D9'; 'Desenvolvimento'='E943' }

$window = [Windows.Markup.XamlReader]::Parse($Xaml)
$ui = @{}
foreach ($m in [regex]::Matches($Xaml, 'x:Name="(\w+)"')) {
    $n = $m.Groups[1].Value
    $el = $window.FindName($n)
    if ($el) { $ui[$n] = $el }
}
$ui.TxtLogPath.Text = "Log desta sessão: $Global:TLogFile"

$sync = [hashtable]::Synchronized(@{
    Queue    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    Progress = 0
    Current  = ''
    Running  = $false
    Done     = $false
    Freed    = [int64]0
    Mode     = 'tasks'
    AppOk    = 0
    AppFail  = 0
    Mon      = $null
    MonSeq   = 0
    MonActive = $false
    Procs    = $null
    ProcCount = 0
    ProcSort = 'cpu'
    Quit     = $false
    DiskBusy = $false
    DiskDone = $false
    DiskStatus = ''
    DiskProgress = 0
    DiskResult = $null
    FolderResult = $null
    FpsBusy  = $false
    FpsDone  = $false
    FpsStatus = ''
    FpsResult = $null
    FpsError = $null
    UpdateBusy = $false
    UpdateDone = $false
    UpdateInfo = $null
    UpdateError = $null
})
$Global:TQueue = $sync.Queue
$script:SessionFreed = [int64]0
$script:CheckMap = @{}
$script:StartupBoxes = @()

function Esc([string]$s) { [Security.SecurityElement]::Escape(($s -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')) }

function Show-Msg([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information') {
    [Windows.MessageBox]::Show($window, $Text, $AppName, $Buttons, $Icon)
}

