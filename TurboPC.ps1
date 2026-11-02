# ARQUIVO GERADO pelo build.ps1 a partir da pasta src\. Não edite aqui: edite os arquivos em src\ e rode o build.
#Requires -Version 5.1
<#
    TurboPC - Otimizador para Windows 10/11
    Criado por William Silva Esquilino
    Feito para PCs antigos em ambiente corporativo: só aplica ajustes seguros,
    cria ponto de restauração antes e registra tudo em log.

    Uso:
      TurboPC.ps1                  -> abre a interface gráfica
      TurboPC.ps1 -Auto            -> executa o modo Recomendado sem interface (RMM/GPO)
      TurboPC.ps1 -Auto -Perfil Jogos   (Recomendado, Escritorio, Jogos, Maximo, Gpu)
      TurboPC.ps1 -Auto -Tasks temp,dns,visualfx
      TurboPC.ps1 -List            -> lista os IDs das tarefas
      -NoRestorePoint              -> não cria ponto de restauração
#>
param(
    [switch]$Auto,
    [string[]]$Tasks,
    [switch]$List,
    [switch]$NoRestorePoint,
    [switch]$NoPause,
    [ValidateSet('Recomendado','Escritorio','Jogos','Maximo','Gpu')][string]$Perfil = 'Recomendado'
)

$AppName    = 'TurboPC'
$AppAuthor  = 'William Silva Esquilino'
$AppVersion = '1.9.0'

# Quando compilado com ps2exe: um .exe com "Auto" no nome roda direto um modo (o nome do arquivo diz qual).
$ExePath    = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$IsCompiled = $ExePath -notmatch '\\(powershell|pwsh|powershell_ise)\.exe$'
if ($IsCompiled -and [IO.Path]::GetFileNameWithoutExtension($ExePath) -match 'auto') {
    $Auto = $true
    $exeName = [IO.Path]::GetFileNameWithoutExtension($ExePath)
    $Perfil = if ($exeName -match 'jogo') { 'Jogos' } elseif ($exeName -match 'escrit') { 'Escritorio' } elseif ($exeName -match 'max') { 'Maximo' } else { 'Recomendado' }
}

# ---------------------------------------------------------------- elevação
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $List) {
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Auto)           { $argLine += ' -Auto' }
    if ($Tasks)          { $argLine += ' -Tasks ' + ($Tasks -join ',') }
    if ($NoRestorePoint) { $argLine += ' -NoRestorePoint' }
    $argLine += " -Perfil $Perfil"
    if (-not $Auto)      { $argLine = '-WindowStyle Hidden ' + $argLine }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine
    } catch {
        Write-Host 'O TurboPC precisa ser executado como administrador.' -ForegroundColor Red
    }
    exit
}

$LogDir = Join-Path $env:ProgramData 'TurboPC\logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$Global:TLogFile = Join-Path $LogDir ('TurboPC_{0}_{1}.log' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))

# ---------------------------------------------------------------- biblioteca de tarefas
# Fica num scriptblock para poder ser carregada tanto na interface quanto na thread de execução.
$TaskLibrary = {

    $Global:TotalFreed = [int64]0
    $Global:IsLaptop   = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    $gpuNames = (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object Name) -join ' '
    $Global:HasNvidia  = $gpuNames -match 'NVIDIA'
    $Global:HasAmd     = $gpuNames -match 'AMD|Radeon'
    $Global:IsDomain   = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).PartOfDomain

    # ---- usuário logado x conta que executa
    # Em PC de empresa o técnico digita a senha de admin dele: o app roda como o técnico, mas os ajustes "de usuário"
    # (HKCU) têm que ir para quem está logado na tela. Resolve-UserPath troca HKCU:\ pelo registro dessa pessoa.
    function Get-SessionUser {
        $console = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName   # DOMINIO\usuario na tela
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)) {
            $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction SilentlyContinue
            if (-not $o -or -not $o.User) { continue }
            $full = "$($o.Domain)\$($o.User)"
            if ($console -and $full -ne $console) { continue }
            $sid = (Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid
            if ($sid) { return [pscustomobject]@{ Name = $full; Sid = $sid } }
        }
        $null
    }
    $Global:RunAs       = "$env:USERDOMAIN\$env:USERNAME"
    $Global:SessionUser = Get-SessionUser
    $Global:UserHive    = $null
    if ($Global:SessionUser -and $Global:SessionUser.Sid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -and
        (Test-Path "Registry::HKEY_USERS\$($Global:SessionUser.Sid)")) {
        $Global:UserHive = $Global:SessionUser.Sid
    }
    $Global:TargetUser    = if ($Global:SessionUser) { $Global:SessionUser.Name } else { $Global:RunAs }
    $Global:TargetProfile = if ($Global:UserHive) { (Get-CimInstance Win32_UserProfile -Filter "SID='$($Global:UserHive)'" -ErrorAction SilentlyContinue).LocalPath } else { $env:USERPROFILE }
    if (-not $Global:TargetProfile) { $Global:TargetProfile = $env:USERPROFILE }

    function Resolve-UserPath([string]$Path) {
        if (-not $Global:UserHive -or $Path -notmatch '^HKCU:\\') { return $Path }
        $rest = $Path.Substring(6)
        # HKCU\Software\Classes fica num arquivo separado do perfil (SID_Classes)
        if ($rest -match '^Software\\Classes(\\|$)') { return "Registry::HKEY_USERS\$($Global:UserHive)_Classes$($rest.Substring(16))" }
        "Registry::HKEY_USERS\$($Global:UserHive)\$rest"
    }

    function Write-TLog {
        param([string]$Message, [string]$Level = 'INFO')
        $line = '[{0}] {1,-4} {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
        if ($Global:TLogFile) { try { Add-Content -Path $Global:TLogFile -Value $line -Encoding UTF8 } catch {} }
        if ($Global:TQueue) {
            $Global:TQueue.Enqueue($line)
        } else {
            $color = switch ($Level) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERRO' {'Red'} 'STEP' {'Cyan'} default {'Gray'} }
            Write-Host $line -ForegroundColor $color
        }
    }

    # ---- desfazer: durante uma execução, cada mudança guarda antes o valor antigo em $Global:UndoItems
    function Add-UndoItem($Item, [string]$Key = '') {
        if ($null -eq $Global:UndoItems) { return }
        if ($Key) { if ($Global:UndoSeen.ContainsKey($Key)) { return }; $Global:UndoSeen[$Key] = 1 }
        [void]$Global:UndoItems.Add($Item)
    }
    function Add-UndoNote([string]$Text) {
        if ($null -ne $Global:UndoNotes -and $Global:UndoNotes -notcontains $Text) { [void]$Global:UndoNotes.Add($Text) }
    }

    function Set-Reg {
        param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
        $Path = Resolve-UserPath $Path
        if ($null -ne $Global:UndoItems -and -not $Global:UndoSeen.ContainsKey("$Path|$Name")) {
            $vn = if ($Name -eq '(default)') { '' } else { $Name }
            $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
            # KX: a chave já existia? Se foi o TurboPC que criou, o desfazer apaga a chave inteira
            $rec = [ordered]@{ T = 'reg'; P = $Path; N = $Name; E = $false; KX = [bool]$key }
            if ($key -and ($key.GetValueNames() -contains $vn)) {
                $rec.E = $true
                $rec.K = "$($key.GetValueKind($vn))"
                $rec.V = $key.GetValue($vn, $null, 'DoNotExpandEnvironmentNames')
            }
            Add-UndoItem $rec "$Path|$Name"
        }
        try {
            if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
            New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-TLog "  falha ao gravar $Path\$Name : $($_.Exception.Message)" 'WARN'
        }
    }

    function Set-Svc {
        param([string]$Name, [string]$Startup)
        $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $s) { return }
        Add-UndoItem ([ordered]@{ T = 'svc'; N = $Name; S = "$($s.StartType)"; R = ($s.Status -eq 'Running') }) "svc|$Name"
        try {
            if ($Startup -eq 'Disabled' -and $s.Status -eq 'Running') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
            Set-Service -Name $Name -StartupType $Startup -ErrorAction Stop
            Write-TLog "  serviço $Name -> $Startup"
        } catch {
            Write-TLog "  não foi possível alterar o serviço $Name ($($_.Exception.Message))" 'WARN'
        }
    }

    function Disable-TTask([string]$TaskPath, [string]$TaskName) {
        $st = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $st) { return }
        if ("$($st.State)" -ne 'Disabled') { Add-UndoItem ([ordered]@{ T = 'task'; P = $TaskPath; N = $TaskName }) "task|$TaskPath$TaskName" }
        $st | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
    }

    function Save-PowerPlan {
        $g = [regex]::Match("$(powercfg /getactivescheme 2>$null)", '[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}').Value
        if ($g) { Add-UndoItem ([ordered]@{ T = 'power'; G = $g }) 'power' }
    }

    function Get-ProfilePaths {
        Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object { -not $_.Special -and $_.LocalPath -and (Test-Path $_.LocalPath) } |
            ForEach-Object { $_.LocalPath }
    }

    function Get-PathSize([string]$Path) {
        $s = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
              Measure-Object -Property Length -Sum).Sum
        if ($s) { [int64]$s } else { [int64]0 }
    }

    function Format-Size([int64]$Bytes) {
        if ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) }
        elseif ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) }
        else { '{0:N0} KB' -f ($Bytes / 1KB) }
    }

    # Apaga o conteúdo das pastas (ou os arquivos) informados; aceita curingas. Arquivos em uso são ignorados.
    function Clear-PathContents {
        param([string[]]$Paths)
        $freed = [int64]0
        foreach ($p in $Paths) {
            $items = Get-Item -Path $p -Force -ErrorAction SilentlyContinue |
                     Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }
            foreach ($item in $items) {
                if ($item.PSIsContainer) {
                    $before = Get-PathSize $item.FullName
                    Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue |
                        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    $after = Get-PathSize $item.FullName
                } else {
                    $before = [int64]$item.Length
                    Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
                    $after = if (Test-Path -LiteralPath $item.FullName) { $before } else { 0 }
                }
                $freed += [math]::Max(0, $before - $after)
            }
        }
        $Global:TotalFreed += $freed
        return $freed
    }

    function Invoke-Exe([string]$File, [string]$Arguments) {
        Write-TLog "  executando: $File $Arguments"
        $p = Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
        return $p.ExitCode
    }

    function Find-Winget {
        $c = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { return $c.Source }
        # rodando como outro admin o alias pode não existir: usa o executável do pacote do Instalador de Aplicativo
        $pkg = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -AllUsers -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
        if ($pkg -and (Test-Path "$($pkg.InstallLocation)\winget.exe")) { return "$($pkg.InstallLocation)\winget.exe" }
        $null
    }

    # NVIDIA Profile Inspector: grava as configurações do Painel de Controle NVIDIA direto no driver
    function Find-NvInspector {
        foreach ($root in "$env:ProgramFiles\WinGet\Packages", "$env:LOCALAPPDATA\Microsoft\WinGet\Packages") {
            $f = Get-ChildItem -Path $root -Filter nvidiaProfileInspector.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($f) { return $f.FullName }
        }
        $null
    }

    # Executáveis de jogos instalados pela Steam e pela Epic
    function Get-GameExes {
        $dirs = @()
        $steam = (Get-ItemProperty (Resolve-UserPath 'HKCU:\Software\Valve\Steam') -ErrorAction SilentlyContinue).SteamPath
        if (-not $steam) { $steam = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath }
        if ($steam -and (Test-Path "$steam\steamapps\libraryfolders.vdf")) {
            $libs = @($steam) + @(Select-String -Path "$steam\steamapps\libraryfolders.vdf" -Pattern '"path"\s+"(.+)"' | ForEach-Object { $_.Matches[0].Groups[1].Value -replace '\\\\', '\' })
            foreach ($l in ($libs | Sort-Object -Unique)) { $dirs += Get-ChildItem "$l\steamapps\common" -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName }
        }
        $exes = @()
        foreach ($m in Get-ChildItem "$env:ProgramData\Epic\EpicGamesLauncher\Data\Manifests\*.item" -ErrorAction SilentlyContinue) {
            try {
                $j = Get-Content $m.FullName -Raw | ConvertFrom-Json
                if ($j.InstallLocation -and $j.LaunchExecutable) { $exes += Join-Path $j.InstallLocation $j.LaunchExecutable }
            } catch {}
        }
        $skip = 'unins|crash|report|redist|setup|install|vc_?redist|dxsetup|dotnet|helper|EasyAntiCheat|BEService|UnityCrashHandler|launcher_|update'
        foreach ($d in $dirs) {
            $exes += Get-ChildItem $d -Filter *.exe -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -notmatch $skip } | ForEach-Object FullName
        }
        @($exes | Where-Object { Test-Path $_ } | Sort-Object -Unique | Select-Object -First 400)
    }

    function New-TRestorePoint {
        Write-TLog '> Ponto de restauração' 'STEP'
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
            # no máximo um por dia: cada ponto ocupa espaço e eles se acumulam (era o que enchia o 'Outros' do disco)
            $last = Get-ComputerRestorePoint -ErrorAction SilentlyContinue | ForEach-Object { $_.ConvertToDateTime($_.CreationTime) } | Sort-Object -Descending | Select-Object -First 1
            if ($last -and ((Get-Date) - $last).TotalHours -lt 24) {
                Write-TLog "  já existe um ponto de restauração de $($last.ToString('dd/MM HH:mm')): ele serve para voltar o PC, não precisa de outro hoje" 'OK'
                return
            }
            # versões antigas do TurboPC zeravam esse limite do Windows; volta ao padrão (um por dia)
            Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue
            Checkpoint-Computer -Description "TurboPC - antes da otimização" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            Write-TLog '  ponto de restauração criado' 'OK'
        } catch {
            Write-TLog "  não foi possível criar o ponto de restauração: $($_.Exception.Message)" 'WARN'
        }
    }

    $TTasks = @(
        # ======================= LIMPEZA =======================
        [pscustomobject]@{ Id='temp'; Cat='Limpeza'; Rec=$true; Warn=''
            Name='Arquivos temporários'
            Desc='Limpa a pasta Temp do Windows e de todos os usuários do PC. Arquivos em uso são ignorados.'
            Action={
                $paths = @("$env:windir\Temp")
                foreach ($p in Get-ProfilePaths) { $paths += "$p\AppData\Local\Temp" }
                $f = Clear-PathContents $paths
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        [pscustomobject]@{ Id='wucache'; Cat='Limpeza'; Rec=$true; Warn=''
            Name='Cache do Windows Update'
            Desc='Apaga instaladores de atualizações já baixados e o cache de Otimização de Entrega. O Windows baixa de novo se precisar.'
            Action={
                foreach ($s in 'wuauserv','bits') { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
                $f = Clear-PathContents @("$env:windir\SoftwareDistribution\Download")
                foreach ($s in 'bits','wuauserv') { Start-Service -Name $s -ErrorAction SilentlyContinue }
                try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop | Out-Null } catch {}
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        [pscustomobject]@{ Id='browsercache'; Cat='Limpeza'; Rec=$true; Warn=''
            Name='Cache dos navegadores'
            Desc='Chrome, Edge, Brave e Firefox (todos os usuários). Apaga só o cache: senhas, favoritos, histórico e logins continuam.'
            Action={
                $paths = @()
                foreach ($p in Get-ProfilePaths) {
                    foreach ($b in 'Google\Chrome','Microsoft\Edge','BraveSoftware\Brave-Browser') {
                        $ud = "$p\AppData\Local\$b\User Data"
                        $paths += "$ud\*\Cache", "$ud\*\Code Cache", "$ud\*\GPUCache", "$ud\ShaderCache"
                    }
                    $paths += "$p\AppData\Local\Mozilla\Firefox\Profiles\*\cache2"
                }
                $f = Clear-PathContents $paths
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        [pscustomobject]@{ Id='dumps'; Cat='Limpeza'; Rec=$true; Warn=''
            Name='Relatórios de erro e despejos de memória'
            Desc='Remove relatórios do Windows Error Reporting, minidumps e MEMORY.DMP de travamentos antigos.'
            Action={
                $paths = @("$env:windir\Minidump", "$env:windir\MEMORY.DMP", "$env:windir\LiveKernelReports\*.dmp",
                           "$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue")
                foreach ($p in Get-ProfilePaths) {
                    $paths += "$p\AppData\Local\CrashDumps", "$p\AppData\Local\Microsoft\Windows\WER\ReportArchive"
                }
                $f = Clear-PathContents $paths
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        [pscustomobject]@{ Id='dns'; Cat='Limpeza'; Rec=$true; Warn=''
            Name='Limpar cache de DNS'
            Desc='Resolve sites que não abrem ou abrem o endereço antigo depois de mudanças na rede.'
            Action={
                Clear-DnsClientCache -ErrorAction SilentlyContinue
                ipconfig /flushdns | Out-Null
                Write-TLog '  cache de DNS limpo' 'OK'
            } }

        [pscustomobject]@{ Id='recycle'; Cat='Limpeza'; Rec=$false; Warn='Apaga de vez o que está na Lixeira de TODOS os usuários.'
            Name='Esvaziar Lixeira'
            Desc='Esvazia a Lixeira da unidade do sistema.'
            Action={
                $f = Clear-PathContents @("$env:SystemDrive\`$Recycle.Bin\*")
                Clear-RecycleBin -Force -ErrorAction SilentlyContinue
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        [pscustomobject]@{ Id='thumbcache'; Cat='Limpeza'; Rec=$true; Warn=''
            Name='Cache de miniaturas'
            Desc='Apaga as miniaturas de fotos e vídeos guardadas pelo Explorador. Ele recria só as que forem abertas de novo.'
            Action={
                $paths = @()
                foreach ($p in Get-ProfilePaths) { $paths += "$p\AppData\Local\Microsoft\Windows\Explorer\thumbcache_*.db" }
                $f = Clear-PathContents $paths
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        [pscustomobject]@{ Id='appcache'; Cat='Limpeza'; Rec=$true; Warn=''
            Name='Cache de Teams, Discord, Slack, Spotify e Steam'
            Desc='Esses apps guardam GBs de cache que só crescem. Conversas, contas e configurações não são apagadas. Feche os apps antes.'
            Action={
                $paths = @()
                foreach ($p in Get-ProfilePaths) {
                    $r = "$p\AppData\Roaming"; $l = "$p\AppData\Local"
                    foreach ($app in "$r\Microsoft\Teams", "$r\discord", "$r\Slack", "$l\Steam\htmlcache",
                                     "$l\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\*") {
                        $paths += "$app\Cache", "$app\Code Cache", "$app\GPUCache"
                    }
                    $paths += "$r\Microsoft\Teams\Service Worker\CacheStorage", "$l\Spotify\Data"
                }
                $f = Clear-PathContents $paths
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        [pscustomobject]@{ Id='shadercache'; Cat='Limpeza'; Rec=$false
            Warn='Os jogos ficam com travadinhas nos primeiros minutos enquanto recriam o cache. Use depois de atualizar o driver de vídeo.'
            Name='Cache de shaders (DirectX, NVIDIA, AMD, Intel)'
            Desc='Resolve travadinhas e gráficos bugados que aparecem depois de trocar ou atualizar o driver de vídeo.'
            Action={
                $paths = @("$env:ProgramData\NVIDIA Corporation\NV_Cache")
                foreach ($p in Get-ProfilePaths) {
                    $l = "$p\AppData\Local"
                    $paths += "$l\D3DSCache", "$l\NVIDIA\DXCache", "$l\NVIDIA\GLCache", "$l\AMD\DxCache", "$l\AMD\DxcCache", "$l\AMD\GLCache", "$l\Intel\ShaderCache"
                }
                $f = Clear-PathContents $paths
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        [pscustomobject]@{ Id='driverinstallers'; Cat='Limpeza'; Rec=$false; Warn=''
            Name='Instaladores de driver antigos'
            Desc='Esvazia as pastas C:\NVIDIA e C:\AMD, onde ficam os arquivos extraídos na instalação do driver de vídeo. O driver instalado não é afetado.'
            Action={
                $f = Clear-PathContents @("$env:SystemDrive\NVIDIA", "$env:SystemDrive\AMD")
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        [pscustomobject]@{ Id='cleanmgr'; Cat='Limpeza'; Rec=$false
            Warn='Pode levar de 5 a 30 minutos. Apaga o Windows.old: depois não dá para voltar para a versão anterior do Windows.'
            Name='Limpeza de Disco completa do Windows'
            Desc='Roda a Limpeza de Disco do próprio Windows com todas as opções de sistema: instalações antigas do Windows, atualizações substituídas, logs de instalação e mais.'
            Action={
                $vc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
                $skip = 'DownloadsFolder', 'Recycle Bin', 'BranchCache', 'Windows Defender'
                foreach ($k in Get-ChildItem $vc -ErrorAction SilentlyContinue) {
                    if ($skip -notcontains $k.PSChildName) { Set-Reg $k.PSPath 'StateFlags0777' 2 }
                }
                $free = { (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace }
                $before = & $free
                [void](Invoke-Exe "$env:windir\System32\cleanmgr.exe" '/sagerun:777')
                $f = [math]::Max([int64]0, [int64](& $free) - [int64]$before)
                $Global:TotalFreed += $f
                Write-TLog "  liberado: $(Format-Size $f)" 'OK'
            } }

        # ======================= DESEMPENHO =======================
        [pscustomobject]@{ Id='powerplan'; Cat='Desempenho'; Rec=(-not $Global:IsLaptop)
            Warn=$(if ($Global:IsLaptop) { 'Notebook detectado: gasta mais bateria. Indicado só para notebooks que ficam na tomada.' } else { '' })
            Name='Plano de energia Alto Desempenho'
            Desc='Impede que o processador fique "economizando" e travando o sistema. Faz bastante diferença em PCs fracos.'
            Action={
                Save-PowerPlan
                powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { Write-TLog '  plano Alto Desempenho ativado' 'OK'; return }
                $out = (powercfg /duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null) -join ' '
                if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})') {
                    powercfg /setactive $Matches[1] | Out-Null
                    Write-TLog '  plano Alto Desempenho criado e ativado' 'OK'
                } else {
                    Write-TLog '  este PC não permite trocar o plano de energia (Modern Standby)' 'WARN'
                }
            } }

        [pscustomobject]@{ Id='visualfx'; Cat='Desempenho'; Rec=$true; Warn=''
            Name='Efeitos visuais para desempenho'
            Desc='Desliga animações, sombras e transições, mas mantém as fontes suaves para não ficar feio. Vale após sair e entrar de novo.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3
                Set-Reg 'HKCU:\Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) 'Binary'
                Set-Reg 'HKCU:\Control Panel\Desktop' 'FontSmoothing' '2' 'String'
                Set-Reg 'HKCU:\Control Panel\Desktop' 'DragFullWindows' '0' 'String'
                Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewShadow' 0
                Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
                Write-TLog '  efeitos visuais ajustados' 'OK'
            } }

        [pscustomobject]@{ Id='transparency'; Cat='Desempenho'; Rec=$true; Warn=''
            Name='Desligar transparência'
            Desc='Remove o efeito de vidro da barra de tarefas e do menu Iniciar, que pesa em placas de vídeo integradas antigas.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
                Write-TLog '  transparência desligada' 'OK'
            } }

        [pscustomobject]@{ Id='startupdelay'; Cat='Desempenho'; Rec=$true; Warn=''
            Name='Inicialização e menus mais rápidos'
            Desc='Tira o atraso artificial que o Windows coloca nos programas de inicialização e deixa os menus abrirem mais rápido.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'WaitForIdleState' 0
                Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '100' 'String'
                Write-TLog '  atrasos removidos' 'OK'
            } }

        [pscustomobject]@{ Id='gamedvr'; Cat='Desempenho'; Rec=$true; Warn=''
            Name='Desativar Xbox Game Bar / gravação de jogos'
            Desc='Desliga a gravação em segundo plano do Game DVR, que consome CPU e disco à toa em PC de escritório.'
            Action={
                Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
                Write-TLog '  Game DVR desativado' 'OK'
            } }

        [pscustomobject]@{ Id='services'; Cat='Desempenho'; Rec=$true; Warn='Não use em PC de jogos: quebra o Game Pass, o app Xbox e o login Xbox de vários jogos.'
            Name='Desativar serviços inúteis no escritório'
            Desc='Serviços do Xbox, modo demonstração de loja, mapas offline e compartilhamento do Windows Media Player.'
            Action={
                foreach ($s in 'XblAuthManager','XblGameSave','XboxNetApiSvc','XboxGipSvc','RetailDemo','MapsBroker','WMPNetworkSvc') {
                    Set-Svc $s 'Disabled'
                }
                Write-TLog '  serviços ajustados' 'OK'
            } }

        [pscustomobject]@{ Id='suggestions'; Cat='Desempenho'; Rec=$true; Warn=''
            Name='Desligar dicas, sugestões e apps instalados sozinhos'
            Desc='Impede o Windows de instalar Candy Crush & cia., mostrar propaganda no menu Iniciar e ficar dando "dicas".'
            Action={
                $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
                foreach ($v in 'SilentInstalledAppsEnabled','SystemPaneSuggestionsEnabled','SoftLandingEnabled','PreInstalledAppsEnabled',
                               'OemPreInstalledAppsEnabled','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled',
                               'SubscribedContent-353694Enabled','SubscribedContent-353696Enabled','SubscribedContent-310093Enabled',
                               'SubscribedContent-338387Enabled','RotatingLockScreenOverlayEnabled') {
                    Set-Reg $k $v 0
                }
                # "Vamos concluir a configuração do seu dispositivo" depois de atualizações
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
                Write-TLog '  sugestões desligadas' 'OK'
            } }

        [pscustomobject]@{ Id='bloat'; Cat='Desempenho'; Rec=$false
            Warn='Remove de todos os usuários. Não mexe em Calculadora, Fotos, Loja, Office, Teams nem Outlook. Não use em PC de jogos (remove o app Xbox).'
            Name='Remover apps inúteis pré-instalados'
            Desc='Xbox, Solitaire, Clipchamp, Notícias, Dicas, Hub de Comentários, Mixed Reality, Spotify, Disney+, jogos da King etc.'
            Action={
                $apps = 'Microsoft.BingNews','Microsoft.GamingApp','Microsoft.XboxApp','Microsoft.Xbox.TCUI','Microsoft.XboxGamingOverlay',
                        'Microsoft.XboxGameOverlay','Microsoft.XboxSpeechToTextOverlay','Microsoft.XboxIdentityProvider',
                        'Microsoft.MicrosoftSolitaireCollection','Microsoft.ZuneMusic','Microsoft.ZuneVideo','Microsoft.People',
                        'Microsoft.MixedReality.Portal','Microsoft.SkypeApp','Microsoft.GetHelp','Microsoft.Getstarted',
                        'Microsoft.WindowsFeedbackHub','Microsoft.549981C3F5F10','Clipchamp.Clipchamp','Microsoft.MicrosoftOfficeHub',
                        'MicrosoftCorporationII.MicrosoftFamily','Microsoft.3DBuilder','Microsoft.Microsoft3DViewer',
                        'king.com.*','SpotifyAB.SpotifyMusic','Disney.*','*.TikTok','*.Instagram','*.Facebook'
                $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
                foreach ($a in $apps) {
                    foreach ($p in @(Get-AppxPackage -AllUsers -Name $a -ErrorAction SilentlyContinue)) {
                        try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop; Write-TLog "  removido: $($p.Name)" }
                        catch { Write-TLog "  não removido: $($p.Name)" 'WARN' }
                    }
                    foreach ($p in ($prov | Where-Object { $_.DisplayName -like $a })) {
                        try { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null } catch {}
                    }
                }
                Add-UndoNote 'Apps removidos não voltam sozinhos: se precisar de algum, instale de novo pela Microsoft Store.'
                Write-TLog '  remoção concluída' 'OK'
            } }

        [pscustomobject]@{ Id='backgroundapps'; Cat='Desempenho'; Rec=$false
            Warn='Pode atrasar notificações de apps da Loja (inclusive o novo Teams).'
            Name='Bloquear apps da Loja em segundo plano'
            Desc='Impede que apps da Microsoft Store fiquem rodando escondidos depois de fechados.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0
                Write-TLog '  apps em segundo plano bloqueados' 'OK'
            } }

        [pscustomobject]@{ Id='indexing'; Cat='Desempenho'; Rec=$false
            Warn='A pesquisa do Outlook e do Explorador fica bem mais lenta. Use só em PC com HDD que vive com disco a 100%.'
            Name='Desativar indexação da pesquisa'
            Desc='Desliga o serviço Windows Search, que fica lendo o disco o tempo todo.'
            Action={ Set-Svc 'WSearch' 'Disabled'; Write-TLog '  indexação desativada' 'OK' } }

        [pscustomobject]@{ Id='hibernate'; Cat='Desempenho'; Rec=$false
            Warn='Desliga a hibernação e a Inicialização Rápida. Em notebook, perde a opção Hibernar.'
            Name='Desativar hibernação'
            Desc='Apaga o hiberfil.sys e libera alguns GB no C: (o tamanho depende da RAM).'
            Action={
                if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue).HibernateEnabled -eq 1) { Add-UndoItem ([ordered]@{ T = 'hib' }) 'hib' }
                powercfg /hibernate off | Out-Null
                Write-TLog '  hibernação desativada' 'OK'
            } }

        [pscustomobject]@{ Id='browserbg'; Cat='Desempenho'; Rec=$true; Warn='O Edge e o Chrome vão mostrar "Gerenciado pela sua organização". É normal, é assim que a configuração é aplicada.'
            Name='Navegadores não ficam abertos escondidos'
            Desc='Impede o Edge e o Chrome de continuarem rodando depois de fechados e de abrirem junto com o Windows (Inicialização Turbo). Economiza bastante RAM.'
            Action={
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
                Set-Reg 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'BackgroundModeEnabled' 0
                Write-TLog '  Edge e Chrome sem segundo plano' 'OK'
            } }

        # ======================= PRIVACIDADE =======================
        [pscustomobject]@{ Id='telemetry'; Cat='Privacidade'; Rec=$true; Warn=''
            Name='Reduzir telemetria'
            Desc='Desliga o serviço de coleta de dados (DiagTrack) e tarefas agendadas que pesam no PC, como o Compatibility Appraiser.'
            Action={
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
                Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
                Set-Svc 'DiagTrack' 'Disabled'
                Set-Svc 'dmwappushservice' 'Disabled'
                $sched = @(
                    @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
                    @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
                    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
                    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
                    @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticDataCollector')
                )
                foreach ($t in $sched) { Disable-TTask $t[0] $t[1] }
                Write-TLog '  telemetria reduzida' 'OK'
            } }

        [pscustomobject]@{ Id='adsid'; Cat='Privacidade'; Rec=$true; Warn=''
            Name='Desativar ID de anúncios'
            Desc='Impede que apps usem um identificador para mostrar propaganda personalizada.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
                Write-TLog '  ID de anúncios desativado' 'OK'
            } }

        [pscustomobject]@{ Id='activity'; Cat='Privacidade'; Rec=$true; Warn=''
            Name='Desativar histórico de atividades'
            Desc='Para de registrar e enviar tudo o que é aberto no PC (linha do tempo).'
            Action={
                $k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
                Set-Reg $k 'EnableActivityFeed' 0
                Set-Reg $k 'PublishUserActivities' 0
                Set-Reg $k 'UploadUserActivities' 0
                Write-TLog '  histórico de atividades desativado' 'OK'
            } }

        [pscustomobject]@{ Id='websearch'; Cat='Privacidade'; Rec=$true; Warn=''
            Name='Tirar pesquisa do Bing do menu Iniciar'
            Desc='A pesquisa do Iniciar passa a procurar só no PC. Fica mais rápida e não manda o que é digitado para a internet.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0
                Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
                Write-TLog '  pesquisa web removida do Iniciar' 'OK'
            } }

        [pscustomobject]@{ Id='widgets'; Cat='Privacidade'; Rec=$true; Warn=''
            Name='Desativar Widgets / Notícias e Interesses'
            Desc='Remove o painel de notícias e clima da barra de tarefas, que fica carregando conteúdo da internet.'
            Action={
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0
                Write-TLog '  widgets desativados' 'OK'
            } }

        [pscustomobject]@{ Id='copilot'; Cat='Privacidade'; Rec=$false; Warn=''
            Name='Desativar Copilot do Windows'
            Desc='Esconde o Copilot da barra de tarefas via política.'
            Action={
                Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
                Write-TLog '  Copilot desativado' 'OK'
            } }

        [pscustomobject]@{ Id='recall'; Cat='Privacidade'; Rec=$true; Warn=''
            Name='Desativar Recall'
            Desc='Impede o Windows 11 de tirar "fotos" da tela o tempo todo para a busca com IA. Só existe em PCs Copilot+, nos outros não muda nada.'
            Action={
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
                Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
                Write-TLog '  Recall desativado' 'OK'
            } }

        [pscustomobject]@{ Id='cortana'; Cat='Privacidade'; Rec=$true; Warn=''
            Name='Desativar Cortana'
            Desc='Desliga a assistente no Windows 10, que fica carregada na memória sem ninguém usar.'
            Action={
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
                Write-TLog '  Cortana desativada' 'OK'
            } }

        [pscustomobject]@{ Id='feedback'; Cat='Privacidade'; Rec=$true; Warn=''
            Name='Sem pedidos de feedback e "experiências personalizadas"'
            Desc='Para os pop-ups pedindo avaliação do Windows e o uso dos dados de diagnóstico para mostrar dicas e propaganda.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
                Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' 'DisableTailoredExperiencesWithDiagnosticData' 1
                Write-TLog '  feedback e experiências personalizadas desligados' 'OK'
            } }

        # ======================= JOGOS =======================
        [pscustomobject]@{ Id='gamemode'; Cat='Jogos'; Rec=$false; Warn=''
            Name='Ligar o Modo de Jogo'
            Desc='O Windows prioriza o jogo aberto e segura atualizações e notificações enquanto você joga. Reduz travadinhas.'
            Action={
                Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
                Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
                Write-TLog '  Modo de Jogo ligado' 'OK'
            } }

        [pscustomobject]@{ Id='hags'; Cat='Jogos'; Rec=$false; Warn='Em alguns jogos competitivos (como o Valorant) pode baixar o FPS. Ligue só se for usar o DLSS Frame Generation (RTX 4000 ou mais nova). Vale após reiniciar.'
            Name='Agendamento de GPU acelerado por hardware'
            Desc='A própria placa de vídeo gerencia sua memória. Menos latência e às vezes alguns FPS a mais; necessário para o DLSS Frame Generation.'
            Action={
                Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
                Write-TLog '  agendamento de GPU ativado (reinicie)' 'OK'
            } }

        [pscustomobject]@{ Id='gamepriority'; Cat='Jogos'; Rec=$false; Warn=''
            Name='Prioridade de CPU e GPU para jogos'
            Desc='Ajusta o agendador multimídia do Windows para dar mais prioridade a jogos do que a tarefas de fundo.'
            Action={
                $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
                Set-Reg $mm 'SystemResponsiveness' 10
                Set-Reg "$mm\Tasks\Games" 'GPU Priority' 8
                Set-Reg "$mm\Tasks\Games" 'Priority' 6
                Set-Reg "$mm\Tasks\Games" 'Scheduling Category' 'High' 'String'
                Set-Reg "$mm\Tasks\Games" 'SFIO Priority' 'High' 'String'
                Write-TLog '  prioridades ajustadas' 'OK'
            } }

        [pscustomobject]@{ Id='mouseaccel'; Cat='Jogos'; Rec=$false; Warn='O mouse vai parecer diferente no Windows nos primeiros minutos.'
            Name='Desligar aceleração do mouse'
            Desc='Desliga a "precisão aprimorada do ponteiro": o mesmo movimento da mão sempre gira a mesma distância. Melhora a mira em jogos de tiro.'
            Action={
                Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
                Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
                Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
                Write-TLog '  aceleração do mouse desligada (vale no próximo login)' 'OK'
            } }

        [pscustomobject]@{ Id='deliveryp2p'; Cat='Jogos'; Rec=$false; Warn='Em empresas que usam compartilhamento de atualizações na rede local, deixe desligado.'
            Name='Não enviar atualizações para outros PCs'
            Desc='Impede que o Windows use sua internet para enviar atualizações para outros computadores. Evita picos de ping no meio do jogo.'
            Action={
                Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
                Write-TLog '  compartilhamento P2P de atualizações desligado' 'OK'
            } }

        [pscustomobject]@{ Id='stickykeys'; Cat='Jogos'; Rec=$false; Warn=''
            Name='Sem a janela de Teclas de Aderência'
            Desc='Apertar Shift 5 vezes (comum em jogos) não abre mais o aviso de Teclas de Aderência e minimiza o jogo. A acessibilidade continua disponível nas Configurações.'
            Action={
                Set-Reg 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'
                Set-Reg 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String'
                Set-Reg 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' 'String'
                Write-TLog '  atalhos de acessibilidade desligados' 'OK'
            } }

        [pscustomobject]@{ Id='ultimate'; Cat='Jogos'; Rec=$false
            Warn='Só para PC de mesa. Consome mais energia mesmo parado; em notebook acaba com a bateria.'
            Name='Plano de energia Desempenho Máximo'
            Desc='Plano escondido do Windows que tira até as micro-economias de energia do processador. Um passo além do Alto Desempenho.'
            Action={
                $guid = $null
                foreach ($line in (powercfg /list)) {
                    if ($line -match '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27}).*(Ultimate|Máximo|Maximo)') { $guid = $Matches[1] }
                }
                if (-not $guid) {
                    $out = (powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null) -join ' '
                    if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})') { $guid = $Matches[1] }
                }
                if ($guid) { Save-PowerPlan; powercfg /setactive $guid | Out-Null; Write-TLog '  plano Desempenho Máximo ativado' 'OK' }
                else { Write-TLog '  este PC não permite o plano Desempenho Máximo' 'WARN' }
            } }

        [pscustomobject]@{ Id='powerthrottle'; Cat='Jogos'; Rec=$false; Warn='Em notebook, gasta mais bateria.'
            Name='Desligar limitação de energia de processos'
            Desc='O Windows 10/11 "freia" programas que ele acha que estão em segundo plano. Às vezes freia o jogo, o Discord ou o OBS junto.'
            Action={
                Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
                Write-TLog '  limitação de energia desligada (reinicie)' 'OK'
            } }

        [pscustomobject]@{ Id='nvidiadrv'; Cat='Jogos'; Rec=$false
            Warn=$(if ($Global:HasNvidia) { 'Para desfazer: Painel de Controle NVIDIA > Gerenciar as configurações 3D > Restaurar. Precisa de internet na primeira vez.' } else { 'Nenhuma placa NVIDIA neste PC: este item não faz nada aqui.' })
            Name='Otimizar driver NVIDIA'
            Desc='Muda as configurações globais do Painel de Controle NVIDIA só no que não tem efeito colateral: placa sempre em velocidade máxima durante o jogo, filtragem de textura em desempenho e o monitor na taxa mais alta. Não mexe em baixa latência nem no cache (use o NVIDIA Reflex dentro do jogo).'
            Action={
                if (-not $Global:HasNvidia) { Write-TLog '  nenhuma placa NVIDIA encontrada' 'WARN'; return }
                $npi = Find-NvInspector
                if (-not $npi) {
                    $wg = Find-Winget
                    if (-not $wg) { Write-TLog '  precisa do winget para baixar o NVIDIA Profile Inspector (veja Programas > Instalar)' 'WARN'; return }
                    Write-TLog '  baixando o NVIDIA Profile Inspector pelo winget...'
                    $base = 'install --id Orbmu2k.nvidiaProfileInspector -e --source winget --silent --accept-package-agreements --accept-source-agreements'
                    $c = Invoke-Exe $wg "$base --scope machine --disable-interactivity"
                    if (-not (Find-NvInspector)) { $c = Invoke-Exe $wg $base }
                    $npi = Find-NvInspector
                    if (-not $npi) { Write-TLog "  não foi possível baixar o NVIDIA Profile Inspector (código $c)" 'ERRO'; return }
                }
                # ID e valor de cada configuração, conforme a lista do próprio Profile Inspector.
                # Só o que nunca baixa FPS. Ficam de fora de propósito: modo de baixa latência (em jogo que depende do processador,
                # como Valorant e CS2, derruba o FPS; o NVIDIA Reflex do jogo faz isso melhor) e tamanho do cache de shaders
                # (mudar pode descartar o cache e fazer os jogos recompilarem tudo).
                $settings = @(
                    @('Power Management - Mode: Prefer maximum performance', 0x1057EB71, 1),
                    @('Texture Filtering - Quality: High performance',        0x00CE2691, 20),
                    @('Prefered Refreshrate: Highest available',              0x0064B541, 1)
                )
                $xmlSettings = foreach ($s in $settings) {
                    "<ProfileSetting><SettingNameInfo>$($s[0])</SettingNameInfo><SettingID>$([uint32]$s[1])</SettingID><SettingValue>$([uint32]$s[2])</SettingValue><ValueType>Dword</ValueType></ProfileSetting>"
                }
                $nip = Join-Path $env:TEMP 'TurboPC_NVIDIA.nip'
                $xml = '<?xml version="1.0" encoding="utf-8"?><ArrayOfProfile xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">' +
                       "<Profile><ProfileName>Base Profile</ProfileName><Executeables /><Settings>$($xmlSettings -join '')</Settings></Profile></ArrayOfProfile>"
                [IO.File]::WriteAllText($nip, $xml, (New-Object Text.UTF8Encoding $true))
                Write-TLog "  aplicando $($settings.Count) configurações no perfil global do driver"
                $p = Start-Process -FilePath $npi -ArgumentList "`"$nip`" -silentImport -mergeImport" -PassThru -WindowStyle Hidden
                if (-not $p.WaitForExit(90000)) { try { $p.Kill() } catch {}; Write-TLog '  o Profile Inspector não respondeu' 'ERRO'; return }
                foreach ($s in $settings) { Write-TLog "    $($s[0])" }
                Add-UndoNote 'Driver NVIDIA: para voltar ao padrão, abra o Painel de Controle NVIDIA > Gerenciar as configurações 3D > Restaurar.'
                Set-Svc 'NvTelemetryContainer' 'Disabled'
                Write-TLog '  driver NVIDIA otimizado' 'OK'
            } }

        [pscustomobject]@{ Id='amddrv'; Cat='Jogos'; Rec=$false
            Warn=$(if ($Global:HasAmd) { 'A AMD não documenta essas chaves. O backup fica em C:\ProgramData\TurboPC\backup (dois cliques no .reg desfaz). Para o resto, ligue o HYPR-RX no AMD Software.' } else { 'Nenhuma placa AMD neste PC: este item não faz nada aqui.' })
            Name='Otimizar driver AMD Radeon'
            Desc='Deixa o cache de shaders do driver sempre ligado, o que reduz as travadinhas quando o jogo carrega efeitos novos. Depois, aperte Alt+R e ligue o HYPR-RX (Anti-Lag + Radeon Boost), o modo de desempenho oficial da AMD.'
            Action={
                if (-not $Global:HasAmd) { Write-TLog '  nenhuma placa AMD encontrada' 'WARN'; return }
                $cls = 'SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
                $bk = "$env:ProgramData\TurboPC\backup"
                New-Item -ItemType Directory -Path $bk -Force | Out-Null
                $n = 0
                foreach ($k in Get-ChildItem "HKLM:\$cls" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' }) {
                    $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
                    if ("$($p.ProviderName) $($p.DriverDesc)" -notmatch 'AMD|ATI|Advanced Micro|Radeon') { continue }
                    if (-not (Test-Path "$($k.PSPath)\UMD")) { continue }
                    $file = "$bk\AMD_UMD_$($k.PSChildName)_$(Get-Date -Format 'yyyy-MM-dd_HH-mm').reg"
                    [void](Invoke-Exe "$env:windir\System32\reg.exe" "export `"HKLM\$cls\$($k.PSChildName)\UMD`" `"$file`" /y")
                    # texto em UTF-16 dentro de um valor binário: "2" = sempre ligado ("1" = otimizado pela AMD)
                    Set-Reg "$($k.PSPath)\UMD" 'ShaderCache' ([byte[]](0x32, 0x00)) 'Binary'
                    Write-TLog "  $($p.DriverDesc): cache de shaders sempre ligado (backup em $file)"
                    $n++
                }
                if ($n) { Write-TLog '  driver AMD ajustado (vale depois de reiniciar)' 'OK' } else { Write-TLog '  não encontrei as configurações do driver AMD' 'WARN' }
            } }

        [pscustomobject]@{ Id='gpupref'; Cat='Jogos'; Rec=$false; Warn=''
            Name='Jogos sempre na placa de vídeo dedicada'
            Desc='Marca os jogos da Steam e da Epic como "Alto desempenho" nas configurações de gráficos do Windows (em notebook, impede o jogo de rodar no vídeo integrado) e liga as otimizações para jogos em janela do Windows 11.'
            Action={
                $k = Resolve-UserPath 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
                $cur = [string](Get-ItemProperty $k -Name DirectXUserGlobalSettings -ErrorAction SilentlyContinue).DirectXUserGlobalSettings
                $opts = [ordered]@{}
                foreach ($kv in ($cur -split ';' | Where-Object { $_ -match '=' })) { $a = $kv -split '=', 2; $opts[$a[0]] = $a[1] }
                $opts['SwapEffectUpgradeEnable'] = '1'
                Set-Reg $k 'DirectXUserGlobalSettings' ((($opts.Keys | ForEach-Object { "$_=$($opts[$_])" }) -join ';') + ';') 'String'
                $games = Get-GameExes
                foreach ($g in $games) { Set-Reg $k $g 'GpuPreference=2;' 'String' }
                Write-TLog "  $($games.Count) executável(is) de jogos marcados como Alto desempenho" 'OK'
            } }

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

        # ======================= REPARO =======================
        [pscustomobject]@{ Id='optimizedisk'; Cat='Reparo'; Rec=$false
            Warn='Em HD antigo a desfragmentação pode levar mais de uma hora.'
            Name='Otimizar disco (TRIM / desfragmentar)'
            Desc='Detecta sozinho: faz TRIM se for SSD e desfragmenta se for HD mecânico.'
            Action={
                $letter = $env:SystemDrive.TrimEnd(':')
                Optimize-Volume -DriveLetter $letter -ErrorAction Stop
                Write-TLog "  unidade $letter`: otimizada" 'OK'
            } }

        [pscustomobject]@{ Id='sfc'; Cat='Reparo'; Rec=$false; Warn='Leva de 10 a 30 minutos.'
            Name='Verificar arquivos do sistema (SFC)'
            Desc='Procura e corrige arquivos do Windows corrompidos. Bom para PC com erros estranhos ou tela azul.'
            Action={
                $c = Invoke-Exe "$env:windir\System32\sfc.exe" '/scannow'
                Write-TLog "  SFC terminou (código $c). Detalhes em C:\Windows\Logs\CBS\CBS.log" 'OK'
            } }

        [pscustomobject]@{ Id='dism'; Cat='Reparo'; Rec=$false; Warn='Precisa de internet e pode levar de 15 a 40 minutos.'
            Name='Reparar imagem do Windows (DISM)'
            Desc='Conserta a base que o SFC usa. Rode antes do SFC quando o SFC não conseguir corrigir.'
            Action={
                $c = Invoke-Exe "$env:windir\System32\dism.exe" '/Online /Cleanup-Image /RestoreHealth'
                if ($c -eq 0) { Write-TLog '  DISM concluído sem erros' 'OK' } else { Write-TLog "  DISM terminou com código $c" 'WARN' }
            } }

        [pscustomobject]@{ Id='componentcleanup'; Cat='Reparo'; Rec=$false; Warn='Pode levar de 5 a 20 minutos.'
            Name='Limpar componentes antigos do Windows (WinSxS)'
            Desc='Remove versões antigas de atualizações já instaladas. Costuma liberar alguns GB.'
            Action={
                $c = Invoke-Exe "$env:windir\System32\dism.exe" '/Online /Cleanup-Image /StartComponentCleanup'
                if ($c -eq 0) { Write-TLog '  limpeza de componentes concluída' 'OK' } else { Write-TLog "  DISM terminou com código $c" 'WARN' }
            } }

        [pscustomobject]@{ Id='chkdsk'; Cat='Reparo'; Rec=$false; Warn=''
            Name='Verificar erros no disco'
            Desc='Analisa o sistema de arquivos do C: sem precisar reiniciar (chkdsk /scan).'
            Action={
                $c = Invoke-Exe "$env:windir\System32\chkdsk.exe" "$env:SystemDrive /scan"
                if ($c -eq 0) { Write-TLog '  nenhum erro encontrado no disco' 'OK' } else { Write-TLog "  chkdsk encontrou problemas (código $c). Rode 'chkdsk C: /f' e reinicie." 'WARN' }
            } }

        [pscustomobject]@{ Id='netreset'; Cat='Reparo'; Rec=$false
            Warn='Precisa reiniciar. Configurações de IP fixo e VPN podem precisar ser refeitas.'
            Name='Resetar rede (Winsock / TCP-IP)'
            Desc='Para quando a internet "está conectada" mas nada abre.'
            Action={
                Add-UndoNote 'Reset de rede não tem como desfazer (IP fixo e VPN podem precisar ser configurados de novo).'
                netsh winsock reset | Out-Null
                netsh int ip reset | Out-Null
                ipconfig /flushdns | Out-Null
                Write-TLog '  pilha de rede resetada (reinicie o PC)' 'OK'
            } }

        [pscustomobject]@{ Id='wureset'; Cat='Reparo'; Rec=$false; Warn='O próximo Windows Update demora mais, porque ele reconstrói o histórico.'
            Name='Consertar o Windows Update'
            Desc='Para quando as atualizações ficam travadas em 0% ou falham sempre. Recria as pastas SoftwareDistribution e catroot2 (as antigas ficam com ".old").'
            Action={
                $svcs = 'wuauserv', 'bits', 'cryptsvc', 'msiserver'
                foreach ($s in $svcs) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
                foreach ($d in "$env:windir\SoftwareDistribution", "$env:windir\System32\catroot2") {
                    try {
                        if (Test-Path "$d.old") { Remove-Item "$d.old" -Recurse -Force -ErrorAction SilentlyContinue }
                        if (Test-Path $d) { Rename-Item -Path $d -NewName "$(Split-Path $d -Leaf).old" -ErrorAction Stop }
                        Write-TLog "  $d recriada"
                    } catch { Write-TLog "  não foi possível renomear $d ($($_.Exception.Message))" 'WARN' }
                }
                foreach ($s in $svcs) { Start-Service -Name $s -ErrorAction SilentlyContinue }
                Write-TLog '  Windows Update resetado' 'OK'
            } }

        [pscustomobject]@{ Id='printqueue'; Cat='Reparo'; Rec=$false; Warn='Cancela todas as impressões que estão na fila.'
            Name='Destravar fila de impressão'
            Desc='Para quando um documento trava a fila e nada mais imprime. Reinicia o Spooler e limpa os trabalhos presos.'
            Action={
                Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
                [void](Clear-PathContents @("$env:windir\System32\spool\PRINTERS"))
                Start-Service -Name Spooler -ErrorAction SilentlyContinue
                Write-TLog '  fila de impressão limpa' 'OK'
            } }

        [pscustomobject]@{ Id='timesync'; Cat='Reparo'; Rec=$false; Warn=''
            Name='Acertar o relógio'
            Desc='Sincroniza a hora com a internet ou com o servidor da empresa. Hora errada causa erro de certificado em sites e sistemas.'
            Action={
                if ((Get-Service w32time -ErrorAction SilentlyContinue).StartType -eq 'Disabled') { Set-Svc 'w32time' 'Manual' }
                Start-Service -Name w32time -ErrorAction SilentlyContinue
                $c = Invoke-Exe "$env:windir\System32\w32tm.exe" '/resync /force'
                if ($c -eq 0) { Write-TLog '  relógio sincronizado' 'OK' } else { Write-TLog "  w32tm terminou com código $c" 'WARN' }
            } }

        [pscustomobject]@{ Id='iconcache'; Cat='Reparo'; Rec=$false; Warn='Vale depois de reiniciar.'
            Name='Reconstruir cache de ícones'
            Desc='Corrige ícones em branco, trocados ou que não atualizam na área de trabalho e no Explorador.'
            Action={
                $paths = @()
                foreach ($p in Get-ProfilePaths) { $paths += "$p\AppData\Local\IconCache.db", "$p\AppData\Local\Microsoft\Windows\Explorer\iconcache_*.db" }
                [void](Clear-PathContents $paths)
                [void](Invoke-Exe "$env:windir\System32\ie4uinit.exe" '-show')
                Write-TLog '  cache de ícones marcado para reconstrução' 'OK'
            } }
    )

    # Rec = perfil Escritório; Game = perfil Jogos (nunca inclui o que mexe no Xbox)
    $GameIds = 'temp','wucache','browsercache','dumps','dns','thumbcache','appcache',
               'powerplan','startupdelay','gamedvr','suggestions','browserbg',
               'telemetry','adsid','activity','websearch','widgets','recall','cortana','feedback',
               'gamemode','mouseaccel','deliveryp2p','stickykeys','gpupref'
    if ($Global:HasNvidia) { $GameIds += 'nvidiadrv' }
    if ($Global:HasAmd)    { $GameIds += 'amddrv' }
    # ajustes de energia que gastam bateria: em notebook nunca entram sozinhos, só como extra
    $EnergyIds = 'powerplan', 'ultimate', 'powerthrottle'
    if ($Global:IsLaptop) { $GameIds = @($GameIds | Where-Object { $EnergyIds -notcontains $_ }) }
    foreach ($t in $TTasks) { $t | Add-Member -NotePropertyName Game -NotePropertyValue ($GameIds -contains $t.Id) }

    # o que o botão "Otimizar placa de vídeo" aplica
    $Global:GpuIds = @('gpupref') + @($(if ($Global:HasNvidia) { 'nvidiadrv' })) + @($(if ($Global:HasAmd) { 'amddrv' }))

    # Modos: o que cada um aplica (Ids) e o que oferece desligado na revisão (Extras)
    $Global:Modes = [ordered]@{
        # só o que melhora sem tirar nada que a pessoa use ou veja
        Recomendado = @{
            Ids    = @('temp','wucache','browsercache','dumps','dns','thumbcache','startupdelay','suggestions',
                       'telemetry','adsid','activity','websearch','widgets','recall','cortana','feedback','fileext','numlock','powerplan')
            Extras = @('appcache','gamedvr','browserbg','visualfx','transparency','cleanmgr','recycle')
        }
        Escritorio = @{
            Ids    = @($TTasks | Where-Object Rec | ForEach-Object Id)
            Extras = @('cleanmgr','recycle','bloat','backgroundapps','hibernate','copilot','thispc','classicmenu','taskbarleft','endtask')
        }
        Jogos = @{
            Ids    = @($GameIds)
            Extras = @('hags','gamepriority','ultimate','powerthrottle','shadercache','visualfx','transparency','cleanmgr','recycle','hibernate','copilot')
        }
        Maximo = @{
            Ids    = @($GameIds) + @('visualfx','transparency','backgroundapps','ultimate','powerthrottle')
            Extras = @('hags','gamepriority','hibernate','cleanmgr','shadercache','copilot','indexing','recycle')
        }
        Gpu = @{
            Ids    = @($Global:GpuIds)
            Extras = @('hags','gamemode','shadercache','ultimate','powerthrottle')
        }
    }
    if ($Global:IsLaptop) {
        foreach ($name in @($Global:Modes.Keys)) {
            $m = $Global:Modes[$name]
            # o Alto Desempenho vira opção em todos os modos (exceto Placa de vídeo), para notebook que vive na tomada
            $plan = if ($name -ne 'Gpu') { 'powerplan' }
            $m.Extras = @($m.Extras) + @($m.Ids | Where-Object { $EnergyIds -contains $_ }) + @($plan) | Where-Object { $_ } | Select-Object -Unique
            $m.Ids    = @($m.Ids | Where-Object { $EnergyIds -notcontains $_ })
        }
    }

    # PC no domínio: política de navegador e atualizações entre PCs costumam ser da TI da empresa (GPO, WSUS, cache de rede)
    if ($Global:IsDomain) {
        $DomainIds = 'browserbg', 'deliveryp2p'
        foreach ($name in @($Global:Modes.Keys)) {
            $m = $Global:Modes[$name]
            $m.Extras = @($m.Extras) + @($m.Ids | Where-Object { $DomainIds -contains $_ }) | Select-Object -Unique
            $m.Ids    = @($m.Ids | Where-Object { $DomainIds -notcontains $_ })
        }
    }

    # na ordem das abas, sem repetidos e sem o que não existe
    function Get-ProfileIds([string]$Name) {
        $ids = $Global:Modes[$Name].Ids
        $TTasks | Where-Object { $ids -contains $_.Id } | ForEach-Object Id
    }
    function Get-ModeExtras([string]$Name) {
        $ids = $Global:Modes[$Name].Ids; $ex = $Global:Modes[$Name].Extras
        $TTasks | Where-Object { $ex -contains $_.Id -and $ids -notcontains $_.Id } | ForEach-Object Id
    }

    $Global:UndoDir = Join-Path $env:ProgramData 'TurboPC\desfazer'

    function Invoke-TTasks {
        param([string[]]$Ids, [switch]$RestorePoint, [scriptblock]$OnProgress, [string]$Label = 'Otimização')
        $sel   = @($TTasks | Where-Object { $Ids -contains $_.Id })
        $total = [math]::Max(1, $sel.Count + [int][bool]$RestorePoint)
        $i = 0
        $Global:TotalFreed = [int64]0
        $Global:UndoItems = New-Object Collections.ArrayList
        $Global:UndoNotes = New-Object Collections.ArrayList
        $Global:UndoSeen  = @{}
        Write-TLog "==== $Label | $env:COMPUTERNAME | $($sel.Count) tarefa(s) | executado por $Global:RunAs ====" 'STEP'
        if ($Global:UserHive) { Write-TLog "  ajustes de usuário vão para quem está logado: $Global:TargetUser" }
        elseif (-not $Global:SessionUser) { Write-TLog '  ninguém logado na tela: ajustes de usuário vão para a conta que executou' 'WARN' }

        if ($RestorePoint) {
            if ($OnProgress) { & $OnProgress 0 'Criando ponto de restauração...' }
            New-TRestorePoint
            $i++
        }
        foreach ($t in $sel) {
            if ($OnProgress) { & $OnProgress ([int](100 * $i / $total)) $t.Name }
            Write-TLog "> $($t.Name)" 'STEP'
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try {
                & $t.Action | Out-Null
                Write-TLog ('  concluído em {0:N1}s' -f $sw.Elapsed.TotalSeconds)
            } catch {
                Write-TLog "  falhou: $($_.Exception.Message)" 'ERRO'
            }
            $i++
        }
        if (@($sel | Where-Object Cat -eq 'Limpeza').Count) { Add-UndoNote 'Arquivos apagados na limpeza não voltam (eram temporários e cache, o Windows recria o que precisar).' }
        if ($Global:UndoItems.Count -or $Global:UndoNotes.Count) {
            try {
                New-Item -ItemType Directory -Path $Global:UndoDir -Force | Out-Null
                $file = Join-Path $Global:UndoDir ('{0}.json' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
                [ordered]@{
                    Date = (Get-Date).ToString('s'); Label = $Label; User = $Global:RunAs; Target = $Global:TargetUser; Version = 1
                    Tasks = @($sel | ForEach-Object Name); Items = @($Global:UndoItems); Notes = @($Global:UndoNotes); Undone = $null
                } | ConvertTo-Json -Depth 6 | Set-Content -Path $file -Encoding UTF8
                Write-TLog "  $($Global:UndoItems.Count) alteração(ões) guardada(s): dá para desfazer em Histórico" 'OK'
            } catch { Write-TLog "  não foi possível salvar o desfazer: $($_.Exception.Message)" 'WARN' }
        }
        $Global:UndoItems = $null
        if ($OnProgress) { & $OnProgress 100 'Concluído' }
        Write-TLog "==== Fim. Espaço liberado: $(Format-Size $Global:TotalFreed). Reinicie o PC para aplicar tudo. ====" 'STEP'
    }

    function Get-UndoRuns {
        Get-ChildItem -Path $Global:UndoDir -Filter *.json -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object {
            try { $r = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json; $r | Add-Member -NotePropertyName File -NotePropertyValue $_.FullName -Force; $r } catch {}
        }
    }

    # Volta cada valor guardado, do último para o primeiro
    function Undo-TRun {
        param([string]$File, [scriptblock]$OnProgress)
        $rec = Get-Content $File -Raw -Encoding UTF8 | ConvertFrom-Json
        $items = @($rec.Items)
        [array]::Reverse($items)
        # ajustes de usuário de outra pessoa só voltam com ela logada (o registro dela precisa estar carregado)
        $away = @($items | Where-Object { $_.T -eq 'reg' -and $_.P -match '^Registry::HKEY_USERS\\(S-[\d-]+)' -and -not (Test-Path "Registry::HKEY_USERS\$($Matches[1])") })
        if ($away) { Write-TLog "  $($away.Count) ajuste(s) de usuário são de $($rec.Target), que não está logado agora: entre com esse usuário e desfaça de novo para voltar esses também" 'WARN' }
        Write-TLog "==== Desfazendo: $($rec.Label) de $(([datetime]$rec.Date).ToString('dd/MM/yyyy HH:mm')) ($($items.Count) alterações) ====" 'STEP'
        $ok = 0; $fail = 0; $i = 0
        foreach ($it in $items) {
            $i++
            if ($OnProgress) { & $OnProgress ([int](100 * $i / [math]::Max(1, $items.Count))) "Desfazendo $i de $($items.Count)" }
            try {
                switch ($it.T) {
                    'reg' {
                        if ($it.E) {
                            $val = switch ($it.K) {
                                'Binary'      { [byte[]]@($it.V) }
                                'DWord'       { [int]$it.V }
                                'QWord'       { [long]$it.V }
                                'MultiString' { [string[]]@($it.V) }
                                default       { [string]$it.V }
                            }
                            if (-not (Test-Path -LiteralPath $it.P)) { New-Item -Path $it.P -Force | Out-Null }
                            New-ItemProperty -LiteralPath $it.P -Name $it.N -Value $val -PropertyType $it.K -Force -ErrorAction Stop | Out-Null
                        } elseif (Test-Path -LiteralPath $it.P) {
                            $k = Get-Item -LiteralPath $it.P
                            if ($it.PSObject.Properties.Name -contains 'KX' -and -not $it.KX -and $k.SubKeyCount -eq 0 -and $k.ValueCount -le 1) {
                                # chave criada pelo TurboPC e sem mais nada dentro: sai inteira (ex.: menu de clique direito clássico)
                                Remove-Item -LiteralPath $it.P -Force -ErrorAction Stop
                            } else {
                                # pelo .NET porque o Remove-ItemProperty não apaga o valor "(padrão)" de uma chave
                                $hives = @{ HKEY_LOCAL_MACHINE = [Microsoft.Win32.Registry]::LocalMachine; HKEY_USERS = [Microsoft.Win32.Registry]::Users; HKEY_CURRENT_USER = [Microsoft.Win32.Registry]::CurrentUser }
                                $full = $k.Name   # ex.: HKEY_USERS\S-1-5-...\Software\...
                                $root, $sub = $full -split '\\', 2
                                $w = $hives[$root].OpenSubKey($sub, $true)
                                if ($w) { $w.DeleteValue($(if ($it.N -eq '(default)') { '' } else { $it.N }), $false); $w.Close() }
                            }
                        }
                    }
                    'svc' {
                        if ('Automatic', 'Manual', 'Disabled' -contains $it.S) { Set-Service -Name $it.N -StartupType $it.S -ErrorAction Stop }
                        if ($it.R) { Start-Service -Name $it.N -ErrorAction SilentlyContinue }
                        Write-TLog "  serviço $($it.N) -> $($it.S)"
                    }
                    'task'  { Enable-ScheduledTask -TaskPath $it.P -TaskName $it.N -ErrorAction Stop | Out-Null; Write-TLog "  tarefa $($it.N) religada" }
                    'power' { powercfg /setactive $it.G | Out-Null; Write-TLog '  plano de energia anterior restaurado' }
                    'hib'   { powercfg /hibernate on | Out-Null; Write-TLog '  hibernação religada' }
                }
                $ok++
            } catch {
                $fail++
                Write-TLog "  não deu para desfazer $($it.T) $($it.P) $($it.N): $($_.Exception.Message)" 'WARN'
            }
        }
        foreach ($n in @($rec.Notes)) { if ($n) { Write-TLog "  atenção: $n" 'WARN' } }
        $rec.Undone = (Get-Date).ToString('s')
        $rec.PSObject.Properties.Remove('File')
        $rec | ConvertTo-Json -Depth 6 | Set-Content -Path $File -Encoding UTF8
        Write-TLog "==== Desfeito: $ok alteração(ões) revertida(s), $fail com problema. Reinicie o PC. ====" 'STEP'
    }
}

. $TaskLibrary

# ---------------------------------------------------------------- modo linha de comando
if ($List) {
    $modeCol = @{ n = 'Modos'; e = { $id = $_.Id; ($Global:Modes.Keys | Where-Object { $Global:Modes[$_].Ids -contains $id }) -join ',' } }
    $TTasks | Format-Table @{n='ID';e={$_.Id}}, @{n='Categoria';e={$_.Cat}}, $modeCol, Name -AutoSize
    exit
}

if ($Auto) {
    $ids = if ($Tasks) { $Tasks | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } }
           else { Write-Host "Perfil: $Perfil" -ForegroundColor Cyan; Get-ProfileIds $Perfil }
    Invoke-TTasks -Ids $ids -RestorePoint:(-not $NoRestorePoint) -Label $(if ($Tasks) { 'Automático (tarefas escolhidas)' } else { "Automático: $Perfil" })
    Write-Host "Log salvo em $Global:TLogFile"
    if ($IsCompiled -and -not $NoPause) { Read-Host 'Pressione Enter para fechar' | Out-Null }
    exit
}

# ---------------------------------------------------------------- interface
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="TurboPC - Otimizador para Windows  |  por William Silva Esquilino" Width="1240" Height="820" MinWidth="1120" MinHeight="700"
        WindowStartupLocation="CenterScreen" Background="#0E1117" FontFamily="Segoe UI" Foreground="#E6E8EE">
  <Window.Resources>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="26"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#F4F5F9"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#8A91A3"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,4,0,0"/>
    </Style>
    <Style x:Key="CardBox" TargetType="Border">
      <Setter Property="Background" Value="#171B24"/>
      <Setter Property="BorderBrush" Value="#232836"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="Padding" Value="18,16"/>
      <Setter Property="Margin" Value="0,0,14,14"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#7C849A"/>
    </Style>
    <Style x:Key="CardValue" TargetType="TextBlock">
      <Setter Property="FontSize" Value="19"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#F4F5F9"/>
      <Setter Property="Margin" Value="0,6,0,2"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="CardSub" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#8A91A3"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Bar" TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Margin" Value="0,10,0,0"/>
      <Setter Property="Foreground" Value="#7C5CFF"/>
      <Setter Property="Background" Value="#262B37"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Maximum" Value="100"/>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="#7C5CFF"/>
      <Setter Property="Padding" Value="18,10"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnGhost" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#232838"/>
      <Setter Property="Foreground" Value="#D5D9E3"/>
    </Style>
    <Style x:Key="Toggle" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border x:Name="Track" Width="42" Height="24" CornerRadius="12" Background="#2A3040" VerticalAlignment="Top" Margin="0,1,14,0">
                <Ellipse x:Name="Knob" Width="18" Height="18" Fill="#8A91A3" HorizontalAlignment="Left" Margin="3,0"/>
              </Border>
              <ContentPresenter Grid.Column="1" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#7C5CFF"/>
                <Setter TargetName="Knob" Property="Fill" Value="White"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ToggleRight" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <ContentPresenter VerticalAlignment="Center"/>
              <Border x:Name="Track" Grid.Column="1" Width="42" Height="24" CornerRadius="12" Background="#2A3040" VerticalAlignment="Center" Margin="16,0,0,0">
                <Ellipse x:Name="Knob" Width="18" Height="18" Fill="#8A91A3" HorizontalAlignment="Left" Margin="3,0"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#7C5CFF"/>
                <Setter TargetName="Knob" Property="Fill" Value="White"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CardIcon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#8B7CFF"/>
      <Setter Property="Margin" Value="0,1,8,0"/>
    </Style>
    <Style x:Key="SectionIcon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Foreground" Value="#8B7CFF"/>
      <Setter Property="Margin" Value="0,3,10,0"/>
    </Style>
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="FontSize" Value="17"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#F4F5F9"/>
    </Style>
    <Style x:Key="Chip" TargetType="TabItem">
      <Setter Property="Foreground" Value="#AEB4C2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Margin="0,0,8,8" Padding="14,8" CornerRadius="9" Background="#171B24" BorderBrush="#232836" BorderThickness="1">
              <ContentPresenter ContentSource="Header"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#1E2333"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#7C5CFF"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#7C5CFF"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ChipTabs" TargetType="TabControl">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabControl">
            <DockPanel>
              <WrapPanel DockPanel.Dock="Top" IsItemsHost="True" Margin="0,0,0,10"/>
              <ContentPresenter ContentSource="SelectedContent"/>
            </DockPanel>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ModeCard" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,12,12"/>
      <Setter Property="BorderBrush" Value="#232836"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="#171B24" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1.5" CornerRadius="14" Padding="16,16,16,14">
              <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Stretch"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1C2130"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#7C5CFF"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <ControlTemplate x:Key="ThumbTpl" TargetType="Thumb">
      <Border Background="#2E3445" CornerRadius="4"/>
    </ControlTemplate>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb><Thumb Template="{StaticResource ThumbTpl}"/></Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="8"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Track x:Name="PART_Track">
                  <Track.Thumb><Thumb Template="{StaticResource ThumbTpl}"/></Track.Thumb>
                </Track>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#AEB4C2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Margin="12,2" Padding="16,11" CornerRadius="10" Background="Transparent">
              <ContentPresenter ContentSource="Header"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#1B2030"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#272050"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TabControl">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabControl">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="232"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Background="#12151D" BorderBrush="#1F2430" BorderThickness="0,0,1,0">
                <DockPanel>
                  <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="24,26,10,28">
                    <Border Width="40" Height="40" CornerRadius="11">
                      <Border.Background>
                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                          <GradientStop Color="#7C5CFF" Offset="0"/>
                          <GradientStop Color="#22D3EE" Offset="1"/>
                        </LinearGradientBrush>
                      </Border.Background>
                      <TextBlock Text="&#xE945;" FontFamily="Segoe MDL2 Assets" FontSize="19" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
                      <TextBlock Text="TurboPC" FontSize="19" FontWeight="Bold" Foreground="White"/>
                      <TextBlock Text="Otimizador Windows 10/11" FontSize="11" Foreground="#7C849A"/>
                    </StackPanel>
                  </StackPanel>
                  <StackPanel DockPanel.Dock="Bottom" Margin="28,0,16,18">
                    <TextBlock Text="Criado por" FontSize="10.5" Foreground="#555C6E"/>
                    <TextBlock Text="William Silva Esquilino" FontSize="12" FontWeight="SemiBold" Foreground="#9AA1B4" TextWrapping="Wrap" Margin="0,1,0,6"/>
                    <TextBlock x:Name="VersionText" Text="v1.7.0" FontSize="11" Foreground="#555C6E"/>
                    <Button x:Name="BtnUpdate" Style="{StaticResource BtnGhost}" HorizontalAlignment="Left" Margin="0,8,0,0" Padding="10,5" FontSize="11.5">
                      <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE895;" FontFamily="Segoe MDL2 Assets" Margin="0,2,6,0"/><TextBlock x:Name="TxtUpdate" Text="Procurar atualização"/></StackPanel>
                    </Button>
                  </StackPanel>
                  <StackPanel IsItemsHost="True"/>
                </DockPanel>
              </Border>
              <ContentPresenter Grid.Column="1" ContentSource="SelectedContent" Margin="30,26,30,12"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TabControl x:Name="Tabs">

      <!-- ===================== PAINEL ===================== -->
      <TabItem x:Name="TabHome">
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE80F;" FontFamily="Segoe MDL2 Assets" FontSize="15" Margin="0,2,14,0"/>
            <TextBlock Text="Painel" FontSize="14"/>
          </StackPanel>
        </TabItem.Header>
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="0,0,14,0">
            <TextBlock Text="Visão geral" Style="{StaticResource H1}"/>
            <TextBlock x:Name="TxtHost" Style="{StaticResource Sub}" Margin="0,4,0,20" Text="Carregando informações do computador..."/>

            <Grid Margin="0,0,-14,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="230"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Style="{StaticResource CardBox}">
                <StackPanel HorizontalAlignment="Center">
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Center"><TextBlock Text="&#xE95E;" Style="{StaticResource CardIcon}"/><TextBlock Text="SAÚDE DO PC" Style="{StaticResource CardTitle}"/></StackPanel>
                  <Grid Width="132" Height="132" Margin="0,14,0,4">
                    <Ellipse Stroke="#262B37" StrokeThickness="11"/>
                    <Ellipse x:Name="ScoreRing" Stroke="#4ADE80" StrokeThickness="11" StrokeDashArray="0 1000" StrokeDashCap="Round" RenderTransformOrigin="0.5,0.5">
                      <Ellipse.RenderTransform><RotateTransform Angle="-90"/></Ellipse.RenderTransform>
                    </Ellipse>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock x:Name="ScoreText" Text="-" FontSize="40" FontWeight="Bold" HorizontalAlignment="Center" Foreground="White"/>
                      <TextBlock x:Name="ScoreLabel" FontSize="12.5" FontWeight="SemiBold" HorizontalAlignment="Center" Foreground="#8A91A3"/>
                    </StackPanel>
                  </Grid>
                </StackPanel>
              </Border>
              <Border Grid.Column="1" Style="{StaticResource CardBox}">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE9D9;" Style="{StaticResource CardIcon}"/><TextBlock Text="DIAGNÓSTICO" Style="{StaticResource CardTitle}"/></StackPanel>
                  <StackPanel x:Name="PanelDiag" Margin="0,10,0,0"/>
                </StackPanel>
              </Border>
            </Grid>

            <StackPanel Orientation="Horizontal" Margin="2,4,0,4"><TextBlock Text="&#xE945;" Style="{StaticResource SectionIcon}"/><TextBlock Text="Modos de otimização" Style="{StaticResource Section}"/></StackPanel>
            <TextBlock Text="Escolha um. Antes de aplicar, você vê em palavras simples o que vai acontecer." Style="{StaticResource Sub}" Margin="2,0,0,12"/>
            <Border Background="#141821" BorderBrush="#232836" BorderThickness="1" CornerRadius="12" Padding="16,12" Margin="0,0,0,12">
              <DockPanel>
                <Border x:Name="PcPowerPill" DockPanel.Dock="Right" CornerRadius="8" Padding="10,5" VerticalAlignment="Center" Background="#163326" Margin="12,0,0,0">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock x:Name="PcPowerIcon" Text="&#xE83E;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="#4ADE80" Margin="0,1,7,0"/>
                    <TextBlock x:Name="PcPowerText" Text="-" FontSize="12.5" FontWeight="SemiBold" Foreground="#4ADE80"/>
                  </StackPanel>
                </Border>
                <Border Width="42" Height="42" CornerRadius="11" Background="#262050" VerticalAlignment="Center" Margin="0,0,14,0">
                  <TextBlock x:Name="PcIcon" Text="&#xE977;" FontFamily="Segoe MDL2 Assets" FontSize="19" Foreground="#A99BFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <StackPanel VerticalAlignment="Center">
                  <TextBlock x:Name="PcTitle" Text="Identificando o computador..." FontSize="14" FontWeight="SemiBold" Foreground="#F1F3F8"/>
                  <TextBlock x:Name="PcDetail" FontSize="12.5" Foreground="#8A91A3" TextWrapping="Wrap" Margin="0,3,0,0"/>
                  <StackPanel Orientation="Horizontal" Margin="0,7,0,0">
                    <TextBlock x:Name="PcUsage" FontSize="12.5" FontWeight="SemiBold" Foreground="#A99BFF" VerticalAlignment="Center"/>
                    <Button x:Name="BtnUsage" Content="Mudar" Style="{StaticResource BtnGhost}" Padding="10,3" FontSize="11.5" Margin="10,0,0,0"/>
                  </StackPanel>
                </StackPanel>
              </DockPanel>
            </Border>
            <UniformGrid x:Name="PanelModes" Columns="4" Margin="0,0,-12,0"/>
            <WrapPanel Margin="0,0,0,6">
              <Button x:Name="BtnDriver" Style="{StaticResource BtnGhost}" Padding="16,10" Margin="0,0,8,8" Visibility="Collapsed">
                <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" Margin="0,2,8,0"/><TextBlock Text="Baixar driver de vídeo"/></StackPanel>
              </Button>
              <Button x:Name="BtnReport" Style="{StaticResource BtnGhost}" Padding="16,10" Margin="0,0,8,8">
                <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8A5;" FontFamily="Segoe MDL2 Assets" Margin="0,2,8,0"/><TextBlock Text="Exportar relatório"/></StackPanel>
              </Button>
              <Button x:Name="BtnUndo" Style="{StaticResource BtnGhost}" Padding="16,10" Margin="0,0,8,8">
                <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7A7;" FontFamily="Segoe MDL2 Assets" Margin="0,2,8,0"/><TextBlock Text="Desfazer otimização"/></StackPanel>
              </Button>
              <Button x:Name="BtnRefresh" Style="{StaticResource BtnGhost}" Padding="16,10" Margin="0,0,8,8">
                <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" Margin="0,2,8,0"/><TextBlock Text="Atualizar informações"/></StackPanel>
              </Button>
            </WrapPanel>
            <Border Background="#171B24" BorderBrush="#232836" BorderThickness="1" CornerRadius="14" Padding="18,16" Margin="0,4,0,8">
              <DockPanel>
                <Button x:Name="BtnFps" DockPanel.Dock="Right" Style="{StaticResource Btn}" Background="#0EA5E9" VerticalAlignment="Center" Padding="18,11" Margin="16,0,0,0">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7FC;" FontFamily="Segoe MDL2 Assets" FontSize="15" Margin="0,1,9,0"/><TextBlock Text="Medir FPS"/></StackPanel>
                </Button>
                <Border Width="42" Height="42" CornerRadius="11" Background="#2638BDF8" VerticalAlignment="Top" Margin="0,0,14,0">
                  <TextBlock Text="&#xE9D2;" FontFamily="Segoe MDL2 Assets" FontSize="19" Foreground="#38BDF8" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <StackPanel VerticalAlignment="Center">
                  <TextBlock Text="Teste de FPS" FontSize="15" FontWeight="SemiBold" Foreground="#F4F5F9"/>
                  <TextBlock x:Name="FpsInfo" Text="Mede o FPS de um jogo em 30 segundos. Meça antes e depois de otimizar: se piorar, o TurboPC mostra e oferece desfazer." FontSize="12.5" Foreground="#8A91A3" TextWrapping="Wrap" Margin="0,3,0,0"/>
                  <StackPanel x:Name="FpsResult"/>
                </StackPanel>
              </DockPanel>
            </Border>
            <TextBlock x:Name="TxtFreed" Style="{StaticResource Sub}" Margin="0"/>

            <StackPanel Orientation="Horizontal" Margin="2,4,0,12">
              <TextBlock Text="&#xE9D2;" Style="{StaticResource SectionIcon}"/>
              <TextBlock Text="Agora" Style="{StaticResource Section}"/>
              <Border CornerRadius="8" Background="#163326" Padding="8,2" Margin="12,2,0,0" VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal">
                  <Ellipse Width="7" Height="7" Fill="#4ADE80" VerticalAlignment="Center" Margin="0,0,6,0"/>
                  <TextBlock Text="ao vivo" FontSize="11" FontWeight="SemiBold" Foreground="#4ADE80"/>
                </StackPanel>
              </Border>
            </StackPanel>
            <UniformGrid Columns="4" Margin="0,0,-14,0">
<!--GAUGES-->
            </UniformGrid>
            <Grid Margin="0,0,-14,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="2*"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Style="{StaticResource CardBox}">
                <DockPanel>
                  <Grid DockPanel.Dock="Top">
                    <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE839;" Style="{StaticResource CardIcon}" Foreground="#4ADE80"/><TextBlock Text="INTERNET" Style="{StaticResource CardTitle}"/></StackPanel>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                      <Ellipse Width="8" Height="8" Fill="#4ADE80" VerticalAlignment="Center" Margin="0,0,6,0"/>
                      <TextBlock Text="Recebendo" FontSize="12" Foreground="#8A91A3" Margin="0,0,6,0"/>
                      <TextBlock x:Name="MonNet" Text="-" FontSize="12.5" FontWeight="SemiBold" Foreground="#F1F3F8" Margin="0,0,18,0"/>
                      <Ellipse Width="8" Height="8" Fill="#60A5FA" VerticalAlignment="Center" Margin="0,0,6,0"/>
                      <TextBlock Text="Enviando" FontSize="12" Foreground="#8A91A3" Margin="0,0,6,0"/>
                      <TextBlock x:Name="MonNetSub" Text="-" FontSize="12.5" FontWeight="SemiBold" Foreground="#F1F3F8"/>
                    </StackPanel>
                  </Grid>
                  <TextBlock x:Name="MonNetPeak" DockPanel.Dock="Top" Style="{StaticResource CardSub}" Margin="0,6,0,0"/>
                  <Canvas x:Name="ChartNet" Height="150" Margin="0,12,0,0" ClipToBounds="True"/>
                </DockPanel>
              </Border>
              <Border Grid.Column="1" Style="{StaticResource CardBox}">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xEDA2;" Style="{StaticResource CardIcon}"/><TextBlock Text="ARMAZENAMENTO" Style="{StaticResource CardTitle}"/></StackPanel>
                  <Grid Width="118" Height="118" Margin="0,12,0,10" HorizontalAlignment="Center">
                    <Ellipse Stroke="#232838" StrokeThickness="12"/>
                    <Ellipse x:Name="DiskRing" Stroke="#7C5CFF" StrokeThickness="12" StrokeDashArray="0 1000" StrokeDashCap="Round" RenderTransformOrigin="0.5,0.5">
                      <Ellipse.RenderTransform><RotateTransform Angle="-90"/></Ellipse.RenderTransform>
                    </Ellipse>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock x:Name="DiskPct" Text="-" FontSize="24" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center"/>
                      <TextBlock Text="ocupado" FontSize="11" Foreground="#8A91A3" HorizontalAlignment="Center"/>
                    </StackPanel>
                  </Grid>
                  <StackPanel x:Name="PanelDrives"/>
                </StackPanel>
              </Border>
            </Grid>

            <StackPanel Orientation="Horizontal" Margin="2,10,0,12"><TextBlock Text="&#xE770;" Style="{StaticResource SectionIcon}"/><TextBlock Text="Este computador" Style="{StaticResource Section}"/></StackPanel>
            <UniformGrid Columns="3" Margin="0,0,-14,0">
              <Border Style="{StaticResource CardBox}">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE770;" Style="{StaticResource CardIcon}"/><TextBlock Text="SISTEMA" Style="{StaticResource CardTitle}"/></StackPanel>
                  <TextBlock x:Name="InfoOS" Style="{StaticResource CardValue}" Text="-"/>
                  <TextBlock x:Name="InfoOSSub" Style="{StaticResource CardSub}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBox}">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE945;" Style="{StaticResource CardIcon}"/><TextBlock Text="PROCESSADOR" Style="{StaticResource CardTitle}"/></StackPanel>
                  <TextBlock x:Name="InfoCPU" Style="{StaticResource CardValue}" Text="-"/>
                  <TextBlock x:Name="InfoCPUSub" Style="{StaticResource CardSub}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBox}">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE964;" Style="{StaticResource CardIcon}"/><TextBlock Text="MEMÓRIA RAM" Style="{StaticResource CardTitle}"/></StackPanel>
                  <TextBlock x:Name="InfoRAM" Style="{StaticResource CardValue}" Text="-"/>
                  <TextBlock x:Name="InfoRAMSub" Style="{StaticResource CardSub}"/>
                  <ProgressBar x:Name="BarRAM" Style="{StaticResource Bar}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBox}">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8B7;" Style="{StaticResource CardIcon}"/><TextBlock Text="ESPAÇO NO C:" Style="{StaticResource CardTitle}"/></StackPanel>
                  <TextBlock x:Name="InfoDisk" Style="{StaticResource CardValue}" Text="-"/>
                  <TextBlock x:Name="InfoDiskSub" Style="{StaticResource CardSub}"/>
                  <ProgressBar x:Name="BarDisk" Style="{StaticResource Bar}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBox}">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xEDA2;" Style="{StaticResource CardIcon}"/><TextBlock Text="TIPO DE DISCO" Style="{StaticResource CardTitle}"/></StackPanel>
                  <TextBlock x:Name="InfoMedia" Style="{StaticResource CardValue}" Text="-"/>
                  <TextBlock x:Name="InfoMediaSub" Style="{StaticResource CardSub}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBox}">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE823;" Style="{StaticResource CardIcon}"/><TextBlock Text="LIGADO HÁ" Style="{StaticResource CardTitle}"/></StackPanel>
                  <TextBlock x:Name="InfoUptime" Style="{StaticResource CardValue}" Text="-"/>
                  <TextBlock x:Name="InfoUptimeSub" Style="{StaticResource CardSub}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBox}">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7F4;" Style="{StaticResource CardIcon}"/><TextBlock Text="PLACA DE VÍDEO" Style="{StaticResource CardTitle}"/></StackPanel>
                  <TextBlock x:Name="InfoGPU" Style="{StaticResource CardValue}" Text="-"/>
                  <TextBlock x:Name="InfoGPUSub" Style="{StaticResource CardSub}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBox}">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE895;" Style="{StaticResource CardIcon}"/><TextBlock Text="DRIVER DE VÍDEO" Style="{StaticResource CardTitle}"/></StackPanel>
                  <TextBlock x:Name="InfoDrv" Style="{StaticResource CardValue}" Text="-"/>
                  <TextBlock x:Name="InfoDrvSub" Style="{StaticResource CardSub}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardBox}">
                <StackPanel>
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7F8;" Style="{StaticResource CardIcon}"/><TextBlock Text="MONITOR" Style="{StaticResource CardTitle}"/></StackPanel>
                  <TextBlock x:Name="InfoMon" Style="{StaticResource CardValue}" Text="-"/>
                  <TextBlock x:Name="InfoMonSub" Style="{StaticResource CardSub}"/>
                </StackPanel>
              </Border>
            </UniformGrid>

            <Border Style="{StaticResource CardBox}" Margin="0,0,0,14">
              <DockPanel>
                <Grid DockPanel.Dock="Top" Margin="0,0,0,10">
                  <StackPanel VerticalAlignment="Center">
                    <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE9F9;" Style="{StaticResource CardIcon}"/><TextBlock Text="PROGRAMAS QUE MAIS PESAM AGORA" Style="{StaticResource CardTitle}"/></StackPanel>
                    <TextBlock Text="Programas com várias janelas ou abas (Chrome, Teams) aparecem somados." Style="{StaticResource CardSub}" Margin="0,3,0,0"/>
                  </StackPanel>
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                    <Button x:Name="BtnSortCpu" Content="Por CPU" Style="{StaticResource BtnGhost}" Padding="12,7" Margin="0,0,6,0"/>
                    <Button x:Name="BtnSortRam" Content="Por memória" Style="{StaticResource BtnGhost}" Padding="12,7" Margin="0,0,14,0"/>
                    <Button x:Name="BtnKill" Style="{StaticResource Btn}" Background="#B4374A" Padding="14,7">
                      <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE711;" FontFamily="Segoe MDL2 Assets" Margin="0,2,8,0"/><TextBlock Text="Encerrar programa"/></StackPanel>
                    </Button>
                  </StackPanel>
                </Grid>
                <Grid DockPanel.Dock="Top" Margin="12,0,12,6">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="90"/>
                    <ColumnDefinition Width="110"/>
                    <ColumnDefinition Width="80"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="Programa" Foreground="#6F778A" FontSize="11.5"/>
                  <TextBlock Grid.Column="1" Text="CPU" Foreground="#6F778A" FontSize="11.5" HorizontalAlignment="Right"/>
                  <TextBlock Grid.Column="2" Text="Memória" Foreground="#6F778A" FontSize="11.5" HorizontalAlignment="Right"/>
                  <TextBlock Grid.Column="3" Text="Processos" Foreground="#6F778A" FontSize="11.5" HorizontalAlignment="Right"/>
                </Grid>
                <ListBox x:Name="ProcList" Background="Transparent" BorderThickness="0" Height="330"
                         ScrollViewer.HorizontalScrollBarVisibility="Disabled" HorizontalContentAlignment="Stretch">
                  <ListBox.ItemContainerStyle>
                    <Style TargetType="ListBoxItem">
                      <Setter Property="Template">
                        <Setter.Value>
                          <ControlTemplate TargetType="ListBoxItem">
                            <Border x:Name="Bd" Background="Transparent" CornerRadius="8" Padding="12,7">
                              <ContentPresenter/>
                            </Border>
                            <ControlTemplate.Triggers>
                              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#1B2030"/></Trigger>
                              <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#272050"/></Trigger>
                            </ControlTemplate.Triggers>
                          </ControlTemplate>
                        </Setter.Value>
                      </Setter>
                    </Style>
                  </ListBox.ItemContainerStyle>
                </ListBox>
              </DockPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ===================== ESPAÇO ===================== -->
      <TabItem x:Name="TabSpace">
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xEDA2;" FontFamily="Segoe MDL2 Assets" FontSize="15" Margin="0,2,14,0"/>
            <TextBlock Text="Espaço" FontSize="14"/>
          </StackPanel>
        </TabItem.Header>
        <ScrollViewer x:Name="SpaceScroll" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="0,0,14,0">
            <Grid Margin="0,0,0,18">
              <StackPanel Margin="0,0,330,0">
                <TextBlock Text="Espaço em disco" Style="{StaticResource H1}"/>
                <TextBlock Text="O que está ocupando o seu disco e o que dá para apagar com segurança. Nada é apagado sem você confirmar." Style="{StaticResource Sub}"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
                <WrapPanel x:Name="PanelDriveBtns" VerticalAlignment="Center"/>
                <Button x:Name="BtnSpaceScan" Style="{StaticResource BtnGhost}" Margin="8,0,0,0">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" Margin="0,2,8,0"/><TextBlock Text="Analisar de novo"/></StackPanel>
                </Button>
              </StackPanel>
            </Grid>

            <Border Style="{StaticResource CardBox}" Margin="0,0,0,18">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="170"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid Width="136" Height="136" HorizontalAlignment="Left">
                  <Ellipse Stroke="#232838" StrokeThickness="13"/>
                  <Ellipse x:Name="SpaceRing" Stroke="#7C5CFF" StrokeThickness="13" StrokeDashArray="0 1000" StrokeDashCap="Round" RenderTransformOrigin="0.5,0.5">
                    <Ellipse.RenderTransform><RotateTransform Angle="-90"/></Ellipse.RenderTransform>
                  </Ellipse>
                  <StackPanel VerticalAlignment="Center">
                    <TextBlock x:Name="SpaceFree" Text="-" FontSize="25" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center"/>
                    <TextBlock Text="livres" FontSize="12" Foreground="#8A91A3" HorizontalAlignment="Center"/>
                  </StackPanel>
                </Grid>
                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                  <TextBlock x:Name="SpaceTitle" Text="Analisando o disco..." FontSize="17" FontWeight="SemiBold" Foreground="#F4F5F9"/>
                  <TextBlock x:Name="SpaceStatus" FontSize="12.5" Foreground="#8A91A3" Margin="0,4,0,12" TextWrapping="Wrap"/>
                  <ProgressBar x:Name="SpaceProgress" Height="6" Maximum="100" Foreground="#7C5CFF" Background="#262B37" BorderThickness="0" Margin="0,0,0,12"/>
                  <Border CornerRadius="7" ClipToBounds="True" Height="16" Background="#232838">
                    <Grid x:Name="SpaceBar"/>
                  </Border>
                  <WrapPanel x:Name="SpaceLegend" Margin="0,12,0,0"/>
                </StackPanel>
              </Grid>
            </Border>

            <DockPanel Margin="2,0,0,4">
              <Button x:Name="BtnFreeSafe" DockPanel.Dock="Right" Style="{StaticResource Btn}" Visibility="Collapsed">
                <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE74D;" FontFamily="Segoe MDL2 Assets" Margin="0,2,8,0"/><TextBlock x:Name="TxtFreeSafe" Text="Liberar o que é seguro"/></StackPanel>
              </Button>
              <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE74D;" Style="{StaticResource SectionIcon}"/><TextBlock Text="Dá para liberar agora" Style="{StaticResource Section}"/></StackPanel>
            </DockPanel>
            <TextBlock Text="Lixo que o Windows e os programas deixam para trás. Os de cima são seguros; os outros têm um aviso." Style="{StaticResource Sub}" Margin="2,0,0,12"/>
            <UniformGrid x:Name="PanelJunk" Columns="3" Margin="0,0,-12,8"/>
            <StackPanel x:Name="SecHidden" Visibility="Collapsed">
              <StackPanel Orientation="Horizontal" Margin="2,12,0,4"><TextBlock Text="&#xE721;" Style="{StaticResource SectionIcon}"/><TextBlock Text="Coisas escondidas que ocupam muito" Style="{StaticResource Section}"/></StackPanel>
              <TextBlock Text="Não aparecem como programa instalado, mas costumam ser o que mais enche o disco. Cada uma explica o que é e o que dá para fazer." Style="{StaticResource Sub}" Margin="2,0,0,12"/>
              <StackPanel x:Name="PanelHidden" Margin="0,0,0,8"/>
            </StackPanel>

            <StackPanel Orientation="Horizontal" Margin="2,12,0,4"><TextBlock Text="&#xE8A5;" Style="{StaticResource SectionIcon}"/><TextBlock Text="Arquivos grandes" Style="{StaticResource Section}"/></StackPanel>
            <TextBlock Text="Arquivos de 500 MB ou mais nas suas pastas. Veja se ainda precisa deles: o que você apagar vai para a Lixeira (dá para recuperar)." Style="{StaticResource Sub}" Margin="2,0,0,12"/>
            <StackPanel x:Name="PanelBigFiles" Margin="0,0,0,8"/>

            <StackPanel Orientation="Horizontal" Margin="2,12,0,4"><TextBlock Text="&#xE71D;" Style="{StaticResource SectionIcon}"/><TextBlock Text="Programas e jogos que mais ocupam" Style="{StaticResource Section}"/></StackPanel>
            <TextBlock Text="Desinstalar remove o programa por completo, pelo desinstalador do próprio fabricante (ou pela Steam, no caso dos jogos dela)." Style="{StaticResource Sub}" Margin="2,0,0,12"/>
            <StackPanel x:Name="PanelBigApps" Margin="0,0,0,8"/>

            <DockPanel Margin="2,12,0,4">
              <Button x:Name="BtnFolderUp" DockPanel.Dock="Right" Style="{StaticResource BtnGhost}" Padding="12,7" Visibility="Collapsed">
                <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE72B;" FontFamily="Segoe MDL2 Assets" Margin="0,2,8,0"/><TextBlock Text="Voltar"/></StackPanel>
              </Button>
              <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8B7;" Style="{StaticResource SectionIcon}"/><TextBlock Text="Pastas que mais ocupam" Style="{StaticResource Section}"/></StackPanel>
            </DockPanel>
            <TextBlock x:Name="TxtFolderPath" Style="{StaticResource Sub}" Margin="2,0,0,12" Text="Clique numa pasta para ver o que tem dentro."/>
            <StackPanel x:Name="PanelFolders" Margin="0,0,0,14"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ===================== OTIMIZAR ===================== -->
      <TabItem x:Name="TabOpt">
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xEC4A;" FontFamily="Segoe MDL2 Assets" FontSize="15" Margin="0,2,14,0"/>
            <TextBlock Text="Personalizar" FontSize="14"/>
          </StackPanel>
        </TabItem.Header>
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="0,0,0,16">
            <TextBlock Text="Personalizar" Style="{StaticResource H1}"/>
            <TextBlock Text="Para quem quer escolher item por item. Se não sabe o que escolher, use os modos do Painel: eles já fazem a escolha certa." Style="{StaticResource Sub}"/>
          </StackPanel>
          <TabControl x:Name="SubOpt" Style="{StaticResource ChipTabs}">
<!--OPTCHIPS-->
          </TabControl>
        </DockPanel>
      </TabItem>

      <!-- ===================== PROGRAMAS ===================== -->
      <TabItem x:Name="TabProg">
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE71D;" FontFamily="Segoe MDL2 Assets" FontSize="15" Margin="0,2,14,0"/>
            <TextBlock Text="Programas" FontSize="14"/>
          </StackPanel>
        </TabItem.Header>
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="0,0,0,16">
            <TextBlock Text="Programas" Style="{StaticResource H1}"/>
            <TextBlock Text="Instale vários programas de uma vez e escolha o que abre junto com o Windows." Style="{StaticResource Sub}"/>
          </StackPanel>
          <TabControl x:Name="SubProg" Style="{StaticResource ChipTabs}">
            <TabItem Style="{StaticResource Chip}">
              <TabItem.Header>
                <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" FontSize="13" Margin="0,2,8,0"/><TextBlock Text="Instalar programas" FontSize="13"/></StackPanel>
              </TabItem.Header>
              <DockPanel>
                <Border DockPanel.Dock="Top" Style="{StaticResource CardBox}" Margin="0,0,0,12" Padding="16,12">
                  <DockPanel>
                    <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                      <Button x:Name="BtnInstallChoco" Content="Instalar Chocolatey" Style="{StaticResource BtnGhost}" Padding="14,8" Margin="0,0,8,0"/>
                      <Button x:Name="BtnGetWinget" Content="Instalar winget" Style="{StaticResource BtnGhost}" Padding="14,8" Margin="0,0,8,0" Visibility="Collapsed"/>
                      <Button x:Name="BtnUpgradeAll" Style="{StaticResource BtnGhost}" Padding="14,8">
                        <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE895;" FontFamily="Segoe MDL2 Assets" Margin="0,2,8,0"/><TextBlock Text="Atualizar todos os programas do PC"/></StackPanel>
                      </Button>
                    </StackPanel>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock x:Name="TxtWinget" FontSize="13" Foreground="#D5D9E3"/>
                      <TextBlock x:Name="TxtChoco" FontSize="13" Foreground="#D5D9E3" Margin="0,3,0,0"/>
                    </StackPanel>
                  </DockPanel>
                </Border>
                <Grid DockPanel.Dock="Top" Margin="0,0,0,12">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="320"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Border Background="#171B24" BorderBrush="#2A3040" BorderThickness="1" CornerRadius="9">
                    <Grid>
                      <TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" Foreground="#5F6679" FontSize="13" Margin="12,10,0,0" IsHitTestVisible="False"/>
                      <TextBlock x:Name="TxtAppHint" Text="Pesquisar programa..." Foreground="#5F6679" FontSize="13" Margin="34,9,0,9" IsHitTestVisible="False"/>
                      <TextBox x:Name="TxtAppSearch" Background="Transparent" BorderThickness="0" Foreground="#E6E8EE" CaretBrush="White" FontSize="13" Padding="31,8,10,8"/>
                    </Grid>
                  </Border>
                  <CheckBox x:Name="ChkChoco" Grid.Column="1" Style="{StaticResource Toggle}" IsChecked="True" VerticalAlignment="Center" Margin="20,0,0,0">
                    <TextBlock Text="Usar o Chocolatey se o winget falhar" Foreground="#C9CFDB" FontSize="12.5"/>
                  </CheckBox>
                </Grid>
                <Border DockPanel.Dock="Bottom" Margin="0,12,0,0">
                  <DockPanel>
                    <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                      <Button x:Name="BtnAppsNone" Content="Limpar seleção" Style="{StaticResource BtnGhost}" Margin="0,0,8,0"/>
                      <Button x:Name="BtnUninstall" Style="{StaticResource BtnGhost}" Margin="0,0,8,0">
                        <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE74D;" FontFamily="Segoe MDL2 Assets" Margin="0,2,8,0"/><TextBlock Text="Desinstalar marcados"/></StackPanel>
                      </Button>
                      <Button x:Name="BtnInstall" Style="{StaticResource Btn}">
                        <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" Margin="0,2,8,0"/><TextBlock Text="Instalar marcados"/></StackPanel>
                      </Button>
                    </StackPanel>
                    <TextBlock x:Name="TxtAppSel" VerticalAlignment="Center" Foreground="#8A91A3" FontSize="12.5" Text="Nenhum programa marcado."/>
                  </DockPanel>
                </Border>
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="PanelApps" Margin="0,0,14,0"/></ScrollViewer>
              </DockPanel>
            </TabItem>
            <TabItem Style="{StaticResource Chip}">
              <TabItem.Header>
                <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7E8;" FontFamily="Segoe MDL2 Assets" FontSize="13" Margin="0,2,8,0"/><TextBlock Text="Inicialização" FontSize="13"/></StackPanel>
              </TabItem.Header>
              <DockPanel>
                <Grid DockPanel.Dock="Top" Margin="0,0,0,14">
                  <TextBlock Text="Programas que abrem junto com o Windows. Desligue o que não for necessário: é o mesmo que fazer pelo Gerenciador de Tarefas, dá para religar depois." Style="{StaticResource Sub}" Margin="0,0,320,0" VerticalAlignment="Center"/>
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Button x:Name="BtnReloadStartup" Content="Recarregar" Style="{StaticResource BtnGhost}" Margin="0,0,8,0"/>
                    <Button x:Name="BtnSaveStartup" Content="Salvar alterações" Style="{StaticResource Btn}"/>
                  </StackPanel>
                </Grid>
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="PanelStartup" Margin="0,0,14,0"/></ScrollViewer>
              </DockPanel>
            </TabItem>
          </TabControl>
        </DockPanel>
      </TabItem>

      <!-- ===================== HISTÓRICO ===================== -->
      <TabItem x:Name="TabLog">
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE81C;" FontFamily="Segoe MDL2 Assets" FontSize="15" Margin="0,2,14,0"/>
            <TextBlock Text="Histórico" FontSize="14"/>
          </StackPanel>
        </TabItem.Header>
        <DockPanel>
          <Grid DockPanel.Dock="Top" Margin="0,0,0,16">
            <StackPanel Margin="0,0,620,0">
              <TextBlock Text="Histórico" Style="{StaticResource H1}"/>
              <TextBlock Text="Tudo o que o TurboPC mudou neste PC. Se algo ficou diferente do que você queria, clique em Desfazer: as configurações voltam a ser o que eram antes." Style="{StaticResource Sub}"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
              <Button x:Name="BtnRestore" Style="{StaticResource BtnGhost}" Margin="0,0,8,0">
                <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE710;" FontFamily="Segoe MDL2 Assets" Margin="0,2,8,0"/><TextBlock Text="Criar ponto de restauração"/></StackPanel>
              </Button>
              <Button x:Name="BtnSysRestore" Style="{StaticResource BtnGhost}" Margin="0,0,8,0">
                <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE777;" FontFamily="Segoe MDL2 Assets" Margin="0,2,8,0"/><TextBlock Text="Restauração do sistema"/></StackPanel>
              </Button>
              <Button x:Name="BtnOpenLogs" Style="{StaticResource BtnGhost}">
                <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8B7;" FontFamily="Segoe MDL2 Assets" Margin="0,2,8,0"/><TextBlock Text="Pasta de logs"/></StackPanel>
              </Button>
            </StackPanel>
          </Grid>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="2,0,0,10"><TextBlock Text="&#xE7A7;" Style="{StaticResource SectionIcon}"/><TextBlock Text="Otimizações feitas" Style="{StaticResource Section}"/></StackPanel>
          <ScrollViewer DockPanel.Dock="Top" MaxHeight="300" VerticalScrollBarVisibility="Auto" Margin="0,0,0,16"><StackPanel x:Name="PanelHistory" Margin="0,0,14,0"/></ScrollViewer>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="2,0,0,4"><TextBlock Text="&#xE9D9;" Style="{StaticResource SectionIcon}"/><TextBlock Text="Registro desta sessão" Style="{StaticResource Section}"/></StackPanel>
          <TextBlock x:Name="TxtLogPath" DockPanel.Dock="Top" Style="{StaticResource Sub}" Margin="2,0,0,10"/>
          <Border Background="#0A0C11" BorderBrush="#232836" BorderThickness="1" CornerRadius="12" Padding="4">
            <TextBox x:Name="LogBox" IsReadOnly="True" Background="Transparent" BorderThickness="0" Foreground="#C9D1E0"
                     FontFamily="Consolas" FontSize="12.5" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Padding="10"/>
          </Border>
        </DockPanel>
      </TabItem>
    </TabControl>

    <!-- ===================== RODAPÉ ===================== -->
    <Border Grid.Row="1" Background="#12151D" BorderBrush="#1F2430" BorderThickness="0,1,0,0" Padding="24,14">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel VerticalAlignment="Center" Margin="0,0,24,0">
          <DockPanel>
            <TextBlock x:Name="TxtSelCount" DockPanel.Dock="Right" Foreground="#8A91A3" FontSize="12"/>
            <TextBlock x:Name="StatusText" Text="Pronto." Foreground="#C9CFDB" FontSize="13" TextTrimming="CharacterEllipsis"/>
          </DockPanel>
          <ProgressBar x:Name="Progress" Style="{StaticResource Bar}" Margin="0,8,0,0"/>
        </StackPanel>
        <StackPanel x:Name="FooterTasks" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <CheckBox x:Name="ChkRestore" Style="{StaticResource Toggle}" IsChecked="True" VerticalAlignment="Center" Margin="0,0,20,0">
            <TextBlock Text="Ponto de restauração antes" Foreground="#C9CFDB" FontSize="12.5"/>
          </CheckBox>
          <Button x:Name="BtnRec" Content="Marcar Escritório" Style="{StaticResource BtnGhost}" Margin="0,0,8,0"/>
          <Button x:Name="BtnRecGame" Content="Marcar Jogos" Style="{StaticResource BtnGhost}" Margin="0,0,8,0"/>
          <Button x:Name="BtnNone" Content="Limpar seleção" Style="{StaticResource BtnGhost}" Margin="0,0,8,0"/>
          <Button x:Name="BtnRun" Content="Executar selecionados" Style="{StaticResource Btn}"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

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
function Initialize-Usage([switch]$Ask) {
    $script:UsageGuess = Get-UsageGuess
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

# ---------------------------------------------------------------- painel
function Add-Diag([string]$Text, [string]$Color) {
    $x = @"
<DockPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Margin="0,0,0,8">
  <Ellipse Width="9" Height="9" Fill="$Color" VerticalAlignment="Top" Margin="0,5,12,0"/>
  <TextBlock Text="$(Esc $Text)" Foreground="#D5D9E3" FontSize="13" TextWrapping="Wrap"/>
</DockPanel>
"@
    [void]$ui.PanelDiag.Children.Add([Windows.Markup.XamlReader]::Parse($x))
    $script:Penalty += switch ($Color) { '#F87171' { 22 } '#F5A524' { 8 } default { 0 } }
}

function Set-Score {
    $score = [math]::Max(5, 100 - $script:Penalty)
    $label, $color = if ($score -ge 85) { 'Ótimo', '#4ADE80' } elseif ($score -ge 65) { 'Bom', '#A3E635' }
                     elseif ($score -ge 45) { 'Regular', '#F5A524' } else { 'Precisa de atenção', '#F87171' }
    $ui.ScoreText.Text = "$score"
    $ui.ScoreLabel.Text = $label
    $ui.ScoreLabel.Foreground = $color
    $ui.ScoreRing.Stroke = $color
    # circunferência em unidades de espessura do traço: pi * (132 - 11) / 11
    $ui.ScoreRing.StrokeDashArray = New-Object Windows.Media.DoubleCollection (,[double[]]@((([math]::PI * 121 / 11) * $score / 100), 1000))
}

function Update-Info {
    $ui.PanelDiag.Children.Clear()
    $script:Penalty = 0
    $red = '#F87171'; $yellow = '#F5A524'; $green = '#4ADE80'; $blue = '#60A5FA'
    $issues = 0
    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cs  = Get-CimInstance Win32_ComputerSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $cv  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue

        $who = if ($Global:UserHive) { "aplicado por $($Global:RunAs) no usuário $($Global:TargetUser)" } else { "executando como $($Global:RunAs)" }
        $ui.TxtHost.Text = "$($cs.Manufacturer) $($cs.Model)  •  $env:COMPUTERNAME  •  $who"

        $ui.InfoOS.Text = ($os.Caption -replace '^Microsoft\s+', '')
        $ui.InfoOSSub.Text = "Versão $($cv.DisplayVersion)  •  build $($os.BuildNumber).$($cv.UBR)"

        $ui.InfoCPU.Text = ($cpu.Name -replace '\(R\)|\(TM\)|CPU|Processor', '' -replace '\s+', ' ').Trim()
        $ui.InfoCPUSub.Text = "$($cpu.NumberOfCores) núcleos / $($cpu.NumberOfLogicalProcessors) threads  •  uso atual $($cpu.LoadPercentage)%"

        $ramTotal = $os.TotalVisibleMemorySize * 1KB
        $ramFree  = $os.FreePhysicalMemory * 1KB
        $ramPct   = [int](100 * ($ramTotal - $ramFree) / $ramTotal)
        $ramGB    = [math]::Round($ramTotal / 1GB)
        $ui.InfoRAM.Text = "$ramGB GB"
        $ui.InfoRAMSub.Text = "$ramPct% em uso  •  $(Format-Size $ramFree) livres"
        $ui.BarRAM.Value = $ramPct

        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
        $freePct = [int](100 * $disk.FreeSpace / $disk.Size)
        $ui.InfoDisk.Text = "$(Format-Size $disk.FreeSpace) livres"
        $ui.InfoDiskSub.Text = "de $(Format-Size $disk.Size)  •  $freePct% livre"
        $ui.BarDisk.Value = 100 - $freePct

        $media = 'Não identificado'; $model = ''; $wear = $null; $sick = @()
        try {
            $dn = (Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop).DiskNumber
            $allPd = @(Get-PhysicalDisk -ErrorAction Stop)
            $pd = $allPd | Where-Object { $_.DeviceId -eq "$dn" } | Select-Object -First 1
            $model = $pd.FriendlyName
            $media = switch ("$($pd.MediaType)") { 'SSD' { if ("$($pd.BusType)" -eq 'NVMe') { 'SSD NVMe' } else { 'SSD' } } 'HDD' { 'HD mecânico' } default { 'Não identificado' } }
            $sick = @($allPd | Where-Object { $_.HealthStatus -and "$($_.HealthStatus)" -ne 'Healthy' })
            $rel = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            $parts = @($model)
            if ("$($pd.HealthStatus)" -eq 'Healthy') { $parts += 'saúde boa' }
            if ($null -ne $rel.Wear -and $media -like 'SSD*') { $wear = [int]$rel.Wear; $parts += "desgaste $wear%" }
            if ($rel.Temperature) { $parts += "$($rel.Temperature) °C" }
            $model = $parts -join '  •  '
        } catch {}
        $ui.InfoMedia.Text = $media
        $ui.InfoMediaSub.Text = $model

        $up = (Get-Date) - $os.LastBootUpTime
        $ui.InfoUptime.Text = '{0}d {1}h {2}min' -f $up.Days, $up.Hours, $up.Minutes
        $ui.InfoUptimeSub.Text = "desde $($os.LastBootUpTime.ToString('dd/MM/yyyy HH:mm'))"

        # vídeo: prefere a placa dedicada quando há mais de uma
        $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -notmatch 'Remote|Virtual|Parsec|Mirage|DisplayLink|Meta ' })
        $gpu = $gpus | Sort-Object { if ($_.Name -match 'NVIDIA|Radeon|Arc') { 0 } else { 1 } } | Select-Object -First 1
        $script:DriverUrl = $null
        $drvAge = 0
        if ($gpu) {
            $ui.InfoGPU.Text = ($gpu.Name -replace '\(R\)|\(TM\)', '').Trim()
            $ui.InfoGPUSub.Text = if ($gpus.Count -gt 1) { 'Também: ' + (($gpus | Where-Object Name -ne $gpu.Name | ForEach-Object Name) -join ', ') } else { $gpu.VideoProcessor }
            $script:DriverUrl = switch -Regex ($gpu.Name) {
                'NVIDIA'            { 'https://www.nvidia.com/pt-br/drivers/' }
                'AMD|Radeon'        { 'https://www.amd.com/pt/support/download/drivers.html' }
                'Intel'             { 'https://www.intel.com.br/content/www/br/pt/support/detect.html' }
            }
            $ui.InfoDrv.Text = "$($gpu.DriverVersion)"
            if ($gpu.DriverDate) {
                $drvAge = [int]((Get-Date) - $gpu.DriverDate).TotalDays
                $ui.InfoDrvSub.Text = "de $($gpu.DriverDate.ToString('dd/MM/yyyy'))  •  há $([math]::Round($drvAge / 30)) meses"
            }
        } else {
            $ui.InfoGPU.Text = 'Não identificada'
        }
        $ui.BtnDriver.Visibility = if ($script:DriverUrl) { 'Visible' } else { 'Collapsed' }

        # [largura, altura, Hz atual, Hz máximo na resolução atual], lido dos modos que o driver de vídeo oferece
        $mon = $null
        $active = $gpus | Where-Object CurrentRefreshRate | Select-Object -First 1
        if ($active) {
            $w = $active.CurrentHorizontalResolution; $h = $active.CurrentVerticalResolution
            $maxHz = (Get-CimInstance CIM_VideoControllerResolution -ErrorAction SilentlyContinue |
                      Where-Object { $_.HorizontalResolution -eq $w -and $_.VerticalResolution -eq $h } |
                      Measure-Object RefreshRate -Maximum).Maximum
            $maxHz = [math]::Max([int]$maxHz, [int]$active.CurrentRefreshRate)
            $mon = @($w, $h, [int]$active.CurrentRefreshRate, $maxHz)
        }
        $script:MonitorHz = if ($mon) { $mon[2] } else { $null }
        if ($mon) {
            $ui.InfoMon.Text = "$($mon[2]) Hz"
            $ui.InfoMonSub.Text = "$($mon[0]) x $($mon[1])  •  máximo nesta resolução: $($mon[3]) Hz"
        }

        # diagnóstico
        foreach ($d in $sick) { Add-Diag "O disco '$($d.FriendlyName)' está avisando que vai falhar ($($d.HealthStatus)). Faça backup dos arquivos e troque o disco o quanto antes." $red; $issues++ }
        if ($wear -ge 80) { Add-Diag "O SSD já gastou $wear% da vida útil. Planeje a troca." $yellow; $issues++ }
        if ([int]$os.BuildNumber -lt 22000) { Add-Diag 'Windows 10: o suporte gratuito acabou em outubro de 2025. Sem o programa ESU, o PC não recebe mais correções de segurança. Se o hardware for compatível, migre para o Windows 11.' $yellow; $issues++ }
        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            if (-not $mp.AMRunningMode -or $mp.AMRunningMode -eq 'Normal') {
                if (-not $mp.RealTimeProtectionEnabled) { Add-Diag 'A proteção em tempo real do Microsoft Defender está DESLIGADA. Ligue em Segurança do Windows > Proteção contra vírus e ameaças.' $red; $issues++ }
                elseif ($mp.AntivirusSignatureAge -gt 7) { Add-Diag "O antivírus está com as definições de $($mp.AntivirusSignatureAge) dias atrás. Rode o Windows Update." $yellow; $issues++ }
            }
        } catch {}
        if ((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
            (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')) {
            Add-Diag 'Há atualizações do Windows esperando o PC reiniciar para terminar de instalar.' $yellow; $issues++
        }
        if ($Global:IsLaptop) {
            try {
                $full   = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
                $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
                if ($full -and $design) {
                    $bh = [math]::Min(100, [int](100 * $full / $design))
                    if ($bh -lt 60) { Add-Diag "A bateria segura só $bh% da carga original. Está na hora de trocar." $yellow; $issues++ }
                    else { Add-Diag "Bateria com $bh% da capacidade original." $blue }
                }
            } catch {}
        }
        if ($gpu -and $gpu.Name -match 'Microsoft Basic|Básico') { Add-Diag 'A placa de vídeo está sem driver (usando o driver básico da Microsoft). Instale o driver: muda tudo em jogos e até no uso normal.' $red; $issues++ }
        elseif ($drvAge -gt 365 -and $gpu.Name -match 'NVIDIA|Radeon|Arc') { Add-Diag "Driver de vídeo com mais de $([math]::Floor($drvAge / 365)) ano(s). Para jogos, atualizar o driver é o que mais dá FPS. Use o botão 'Baixar driver de vídeo'." $yellow; $issues++ }
        if ($mon -and $mon[3] -gt $mon[2]) { Add-Diag "O monitor está em $($mon[2]) Hz, mas aceita até $($mon[3]) Hz. Mude em Configurações > Sistema > Vídeo > Vídeo avançado: fica muito mais fluido em jogos." $yellow; $issues++ }
        if ($media -eq 'HD mecânico') { Add-Diag 'O Windows está num HD mecânico. Trocar por um SSD é, de longe, o upgrade que mais deixa um PC antigo rápido (custa pouco).' $red; $issues++ }
        if ($ramGB -lt 4)     { Add-Diag "Só $ramGB GB de RAM. Windows 10/11 com navegador e Office precisa de pelo menos 8 GB." $red; $issues++ }
        elseif ($ramGB -lt 8) { Add-Diag "$ramGB GB de RAM é o limite. Se der, coloque mais um pente para chegar em 8 GB." $yellow; $issues++ }
        if ($freePct -lt 10)     { Add-Diag "Só $freePct% livre no $env:SystemDrive. Com pouco espaço o Windows fica lento e as atualizações falham." $red; $issues++ }
        elseif ($freePct -lt 20) { Add-Diag "$freePct% livre no $env:SystemDrive. Rode a Limpeza para ganhar espaço." $yellow; $issues++ }
        if ($up.TotalDays -ge 7) { Add-Diag "PC ligado há $($up.Days) dias sem reiniciar. Reiniciar de vez em quando libera memória e conclui atualizações." $yellow; $issues++ }
        $hw = @($media, "$ramGB GB de RAM", $(if ($gpu) { ($gpu.Name -replace '\(R\)|\(TM\)|NVIDIA |AMD |GeForce ', '').Trim() })) | Where-Object { $_ -and $_ -ne 'Não identificado' }
        $powerWarn = Update-PcBanner ($hw -join '  ·  ')
        if ($powerWarn) { Add-Diag $powerWarn $yellow; $issues++ }

        $enabledStartup = @($script:StartupBoxes | Where-Object { $_.IsChecked }).Count
        if ($enabledStartup -gt 8) { Add-Diag "$enabledStartup programas abrem junto com o Windows. Veja Programas > Inicialização." $yellow; $issues++ }

        # senha de admin do técnico com outra pessoa logada: os ajustes de usuário vão para quem está na tela
        if ($Global:UserHive) {
            Add-Diag "Rodando com a conta de admin '$($Global:RunAs)'. Os ajustes de usuário (visual, mouse, Iniciar, extensões...) vão para quem está logado: '$($Global:TargetUser)'. Os programas são instalados para todos os usuários." $blue
        } elseif (-not $Global:SessionUser) {
            Add-Diag "Ninguém está logado na tela (acesso remoto?): os ajustes de usuário vão para a conta '$($Global:RunAs)'." $yellow
        }
        if ($Global:IsDomain) {
            $dom = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Domain
            Add-Diag "PC no domínio '$dom'. As políticas da empresa (GPO) mandam no que configuram: se alguma delas mexer na mesma coisa, a da empresa vale. Por isso os ajustes de navegador e de atualizações entre PCs ficam fora dos modos aqui." $blue
        }
        if ($issues -eq 0) { Add-Diag 'Nada crítico encontrado. Use o modo Recomendado de vez em quando para manter tudo em dia.' $green }
    } catch {
        Add-Diag "Não foi possível ler todas as informações: $($_.Exception.Message)" $yellow
    }
    Set-Score
}

# ---------------------------------------------------------------- relatório
function Export-Report {
    $h   = { param($s) [Net.WebUtility]::HtmlEncode([string]$s) }
    $css = { param($brush) '#{0:X2}{1:X2}{2:X2}' -f $brush.Color.R, $brush.Color.G, $brush.Color.B }
    $cards = foreach ($n in 'OS','CPU','RAM','Disk','Media','Uptime','GPU','Drv','Mon') {
        $title = $ui["Info$n"].Parent.Children[0].Children[1].Text
        "<div class='c'><div class='t'>$(& $h $title)</div><div class='v'>$(& $h $ui["Info$n"].Text)</div><div class='s'>$(& $h $ui["Info$($n)Sub"].Text)</div></div>"
    }
    $diag = foreach ($d in $ui.PanelDiag.Children) {
        "<li><span style='background:$(& $css $d.Children[0].Fill)'></span>$(& $h $d.Children[1].Text)</li>"
    }
    $html = @"
<!doctype html><html lang="pt-br"><head><meta charset="utf-8"><title>TurboPC - $env:COMPUTERNAME</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;background:#f5f6fa;color:#1d2130;margin:0;padding:32px}
.w{max-width:1000px;margin:auto} h1{margin:0} .sub{color:#667;margin:4px 0 24px}
.score{display:inline-block;background:$(& $css $ui.ScoreLabel.Foreground);color:#000;border-radius:12px;padding:10px 18px;font-size:22px;font-weight:700;margin-bottom:20px}
.g{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}
.c{background:#fff;border:1px solid #e3e5ec;border-radius:12px;padding:14px 16px}
.t{font-size:11px;font-weight:600;color:#778;letter-spacing:.5px}.v{font-size:18px;font-weight:600;margin:6px 0 2px}.s{font-size:12px;color:#667}
ul{list-style:none;padding:0} li{background:#fff;border:1px solid #e3e5ec;border-radius:10px;padding:10px 14px;margin-bottom:8px;display:flex;gap:12px;align-items:flex-start}
li span{width:10px;height:10px;border-radius:50%;flex:none;margin-top:5px}
pre{background:#0e1117;color:#c9d1e0;padding:16px;border-radius:12px;white-space:pre-wrap;font-size:12px}
@media print{body{background:#fff;padding:0}pre{background:#fff;color:#000;border:1px solid #ccc}}
</style></head><body><div class="w">
<h1>Relatório TurboPC</h1>
<div class="sub">$(& $h $ui.TxtHost.Text)<br>Gerado em $(Get-Date -Format 'dd/MM/yyyy HH:mm') pelo TurboPC $AppVersion, criado por William Silva Esquilino</div>
<div class="score">Saúde do PC: $($ui.ScoreText.Text) / 100 - $(& $h $ui.ScoreLabel.Text)</div>
<div class="g">$($cards -join '')</div>
<h2>Diagnóstico</h2><ul>$($diag -join '')</ul>
<h2>O que foi feito nesta sessão</h2><pre>$(& $h $(if ($ui.LogBox.Text) { $ui.LogBox.Text } else { 'Nenhuma otimização executada ainda.' }))</pre>
</div></body></html>
"@
    $name = 'Relatorio_TurboPC_{0}_{1}.html' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd_HH-mm')
    # uma cópia fica sempre no PC, num lugar fixo para o técnico achar depois
    $keep = Join-Path $env:ProgramData 'TurboPC\relatorios'
    New-Item -ItemType Directory -Path $keep -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $keep $name), $html, (New-Object Text.UTF8Encoding $true))
    $file = Join-Path (Get-UserDesktop) $name
    try { [IO.File]::WriteAllText($file, $html, (New-Object Text.UTF8Encoding $true)) } catch { $file = Join-Path $keep $name }
    Write-TLog "Relatório salvo em $file (cópia em $keep)" 'OK'
    Start-Process $file
}

# Área de Trabalho de quem está logado (pode estar no OneDrive); sem outro usuário, a da conta atual
function Get-UserDesktop {
    if (-not $Global:UserHive) { return [Environment]::GetFolderPath('Desktop') }
    $key = Get-Item (Resolve-UserPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders') -ErrorAction SilentlyContinue
    $raw = if ($key) { [string]$key.GetValue('Desktop', $null, 'DoNotExpandEnvironmentNames') }
    $path = if ($raw) { $raw -replace '%USERPROFILE%', $Global:TargetProfile } else { "$($Global:TargetProfile)\Desktop" }
    if (Test-Path -LiteralPath $path) { $path } else { "$($Global:TargetProfile)\Desktop" }
}

# ---------------------------------------------------------------- monitor em tempo real
# Thread separada que lê os contadores de desempenho do Windows uma vez por segundo enquanto a aba Monitor está aberta.
$monitorWorker = {
    param($sync)
    function New-PC([string]$Cat, [string]$Ctr, [string]$Inst = '') {
        try { $c = New-Object Diagnostics.PerformanceCounter $Cat, $Ctr, $Inst, $true; [void]$c.NextValue(); $c } catch { $null }
    }
    function Get-Val($c) { if ($c) { try { return [double]$c.NextValue() } catch {} }; 0.0 }

    $cpu = New-PC 'Processor Information' '% Processor Utility' '_Total'
    if (-not $cpu) { $cpu = New-PC 'Processor' '% Processor Time' '_Total' }
    $idle   = New-PC 'PhysicalDisk' '% Idle Time' '_Total'
    $dRead  = New-PC 'PhysicalDisk' 'Disk Read Bytes/sec' '_Total'
    $dWrite = New-PC 'PhysicalDisk' 'Disk Write Bytes/sec' '_Total'
    $avail  = New-PC 'Memory' 'Available Bytes'
    $ramTotal = [double](Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    $gpuCat = try { New-Object Diagnostics.PerformanceCounterCategory 'GPU Engine' } catch { $null }
    $gpuPrev = $null
    $nets = @(); $netAt = [datetime]::MinValue
    $cpuPrev = @{}; $procAt = $null
    $cores = [Environment]::ProcessorCount
    $tick = 0

    while (-not $sync.Quit) {
        if (-not $sync.MonActive) { Start-Sleep -Milliseconds 300; continue }
        $t0 = [datetime]::Now
        if (($t0 - $netAt).TotalSeconds -ge 30) {
            $nets = @()
            try {
                foreach ($n in (New-Object Diagnostics.PerformanceCounterCategory 'Network Interface').GetInstanceNames()) {
                    $nets += ,@((New-PC 'Network Interface' 'Bytes Received/sec' $n), (New-PC 'Network Interface' 'Bytes Sent/sec' $n))
                }
            } catch {}
            $netAt = $t0
        }
        $m = @{}
        $m.Cpu   = [math]::Min(100.0, (Get-Val $cpu))
        $m.Disk  = if ($idle) { [math]::Max(0.0, [math]::Min(100.0, 100 - (Get-Val $idle))) } else { 0 }
        $m.DiskR = Get-Val $dRead
        $m.DiskW = Get-Val $dWrite
        $m.RamTotal = $ramTotal
        $m.RamUsed  = $ramTotal - (Get-Val $avail)
        $down = 0.0; $up = 0.0
        foreach ($n in $nets) { $down += Get-Val $n[0]; $up += Get-Val $n[1] }
        $m.Down = $down; $m.Up = $up

        # GPU: soma o uso de cada motor (3D, vídeo, cópia) entre os processos e mostra o motor mais ocupado, como o Gerenciador de Tarefas
        $m.Gpu = -1
        if ($gpuCat) {
            try {
                $all = $gpuCat.ReadCategory()
                $key = @($all.Keys) | Where-Object { $_ -match 'tiliz' } | Select-Object -First 1
                $cur = $all[$key]
                if ($gpuPrev) {
                    $grp = @{}
                    foreach ($s in $cur.Values) {
                        $p = $gpuPrev[$s.InstanceName]
                        if (-not $p) { continue }
                        $grp[($s.InstanceName -replace '^.*?_luid_', '')] += [Diagnostics.CounterSample]::Calculate($p.Sample, $s.Sample)
                    }
                    $m.Gpu = [math]::Min(100.0, [double](($grp.Values | Measure-Object -Maximum).Maximum))
                }
                $gpuPrev = $cur
            } catch { $gpuCat = $null }
        }

        # processos agrupados por nome (Chrome com 30 abas vira uma linha só)
        if ($tick % 2 -eq 0) {
            $now  = [datetime]::Now
            $span = if ($procAt) { ($now - $procAt).TotalMilliseconds } else { 0 }
            $procAt = $now
            $agg = @{}; $seen = @{}; $count = 0
            foreach ($p in [Diagnostics.Process]::GetProcesses()) {
                $count++
                if ($p.Id -le 4) { $p.Dispose(); continue }
                $ms = 0.0
                try { $ms = $p.TotalProcessorTime.TotalMilliseconds } catch {}
                $seen[$p.Id] = $ms
                $d = if ($span -gt 0 -and $cpuPrev.ContainsKey($p.Id)) { [math]::Max(0.0, $ms - $cpuPrev[$p.Id]) } else { 0 }
                $name = $p.ProcessName
                if (-not $agg.ContainsKey($name)) { $agg[$name] = @{ Name = $name; Cpu = 0.0; Ram = [int64]0; Count = 0 } }
                $a = $agg[$name]
                $a.Cpu += $d; $a.Ram += $p.WorkingSet64; $a.Count++
                $p.Dispose()
            }
            $cpuPrev = $seen
            foreach ($a in $agg.Values) { $a.Cpu = if ($span -gt 0) { [math]::Min(100.0, 100 * $a.Cpu / ($span * $cores)) } else { 0 } }
            $sortKey = if ($sync.ProcSort -eq 'ram') { 'Ram' } else { 'Cpu' }
            $sync.Procs = @($agg.Values | Sort-Object { $_[$sortKey] }, { $_.Ram } -Descending | Select-Object -First 14)
            $sync.ProcCount = $count
        }
        $sync.Mon = $m
        $sync.MonSeq++
        $tick++
        $wait = 1000 - ([datetime]::Now - $t0).TotalMilliseconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
    }
}

$HistLen = 60
$script:Hist = @{}
foreach ($k in 'Cpu','Ram','Gpu','Disk','Down','Up') { $script:Hist[$k] = New-Object 'System.Collections.Generic.List[double]' }
$script:MonSeq = -1
$script:LastProcs = $null
$ProtectedProcs = 'system','idle','registry','smss','csrss','wininit','winlogon','services','lsass','lsaiso','svchost','dwm',
                  'fontdrvhost','memory compression','msmpeng','nissrv','securityhealthservice','sihost','ctfmon','explorer','audiodg',
                  [Diagnostics.Process]::GetCurrentProcess().ProcessName.ToLower()

function Format-Rate([double]$b) {
    if ($b -ge 1MB) { '{0:N1} MB/s' -f ($b / 1MB) } elseif ($b -ge 1KB) { '{0:N0} KB/s' -f ($b / 1KB) } else { '{0:N0} B/s' -f $b }
}

function Push-Hist([string]$Key, [double]$Value) {
    $l = $script:Hist[$Key]
    $l.Add($Value)
    if ($l.Count -gt $HistLen) { $l.RemoveAt(0) }
}

# Cor com transparência a partir de "#RRGGBB"
function Get-Color([string]$Hex, [byte]$Alpha = 255) {
    $c = [Windows.Media.ColorConverter]::ConvertFromString($Hex)
    [Windows.Media.Color]::FromArgb($Alpha, $c.R, $c.G, $c.B)
}

# Curva suave (Catmull-Rom convertida em Bézier) passando pelos pontos; com -Area fecha até a base para preencher
function New-SmoothFigure([Windows.Point[]]$P, [double]$Height, [switch]$Area) {
    $fig = New-Object Windows.Media.PathFigure
    $n = $P.Count
    if ($Area) {
        $fig.StartPoint = [Windows.Point]::new($P[0].X, $Height)
        $fig.Segments.Add([Windows.Media.LineSegment]::new($P[0], $false))
    } else {
        $fig.StartPoint = $P[0]
    }
    for ($i = 0; $i -lt $n - 1; $i++) {
        $p0 = $P[[math]::Max(0, $i - 1)]; $p1 = $P[$i]; $p2 = $P[$i + 1]; $p3 = $P[[math]::Min($n - 1, $i + 2)]
        $c1 = [Windows.Point]::new($p1.X + ($p2.X - $p0.X) / 6, [math]::Min($Height, [math]::Max(0.0, $p1.Y + ($p2.Y - $p0.Y) / 6)))
        $c2 = [Windows.Point]::new($p2.X - ($p3.X - $p1.X) / 6, [math]::Min($Height, [math]::Max(0.0, $p2.Y - ($p3.Y - $p1.Y) / 6)))
        $fig.Segments.Add([Windows.Media.BezierSegment]::new($c1, $c2, $p2, $true))
    }
    if ($Area) {
        $fig.Segments.Add([Windows.Media.LineSegment]::new([Windows.Point]::new($P[$n - 1].X, $Height), $false))
        $fig.IsClosed = $true
    }
    $g = New-Object Windows.Media.PathGeometry
    $g.Figures.Add($fig)
    $g
}

# Gráfico de área com curva suave, degradê embaixo e um ponto no valor atual. -Grid desenha linhas-guia.
function Draw-Chart($Canvas, [object[]]$Series, [double]$Max, [switch]$Grid) {
    $w = $Canvas.ActualWidth; $h = $Canvas.ActualHeight
    if ($w -le 0 -or $h -le 0) { return }
    $Canvas.Children.Clear()
    if ($Grid) {
        foreach ($k in 1..3) {
            $ln = New-Object Windows.Shapes.Line
            $ln.X1 = 0; $ln.X2 = $w; $ln.Y1 = [math]::Round($h * $k / 4) + 0.5; $ln.Y2 = $ln.Y1
            $ln.Stroke = '#222736'; $ln.StrokeThickness = 1; $ln.StrokeDashArray = New-Object Windows.Media.DoubleCollection (,[double[]]@(3, 4))
            [void]$Canvas.Children.Add($ln)
        }
    }
    $step = $w / ($HistLen - 1)
    $top = 5.0
    foreach ($s in $Series) {
        $vals = $s.Values; $n = $vals.Count
        if ($n -lt 2) { continue }
        $x0 = $w - ($n - 1) * $step
        $pts = [Windows.Point[]]@(for ($i = 0; $i -lt $n; $i++) {
            [Windows.Point]::new($x0 + $i * $step, $h - 1.5 - [math]::Min(1.0, $vals[$i] / $Max) * ($h - 1.5 - $top))
        })
        $area = New-Object Windows.Shapes.Path
        $area.Data = New-SmoothFigure $pts $h -Area
        $area.Fill = New-Object Windows.Media.LinearGradientBrush ((Get-Color $s.Color 105), (Get-Color $s.Color 0), 90.0)
        [void]$Canvas.Children.Add($area)
        $line = New-Object Windows.Shapes.Path
        $line.Data = New-SmoothFigure $pts $h
        $line.Stroke = New-Object Windows.Media.SolidColorBrush (Get-Color $s.Color)
        $line.StrokeThickness = 2; $line.StrokeLineJoin = 'Round'
        [void]$Canvas.Children.Add($line)
        $last = $pts[$n - 1]
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width = 9; $dot.Height = 9; $dot.Fill = $line.Stroke; $dot.Stroke = '#171B24'; $dot.StrokeThickness = 2
        [Windows.Controls.Canvas]::SetLeft($dot, $last.X - 7); [Windows.Controls.Canvas]::SetTop($dot, $last.Y - 4.5)
        [void]$Canvas.Children.Add($dot)
    }
}

# Arco de velocímetro (270°, abrindo embaixo) para os medidores 150x124
function New-GaugeArc([double]$Pct) {
    $cx = 75.0; $cy = 66.0; $r = 54.0
    $sweep = [math]::Max(0.6, 270.0 * [math]::Max(0.0, [math]::Min(100.0, $Pct)) / 100)
    $at = { param($deg) $rad = $deg * [math]::PI / 180; [Windows.Point]::new($cx + $r * [math]::Cos($rad), $cy + $r * [math]::Sin($rad)) }
    $fig = New-Object Windows.Media.PathFigure
    $fig.StartPoint = & $at 135.0
    $fig.Segments.Add([Windows.Media.ArcSegment]::new((& $at (135.0 + $sweep)), [Windows.Size]::new($r, $r), 0.0, ($sweep -gt 180), [Windows.Media.SweepDirection]::Clockwise, $true))
    $g = New-Object Windows.Media.PathGeometry
    $g.Figures.Add($fig)
    $g
}

# Palavra simples para quem não entende porcentagem
function Get-LoadState([double]$Pct) {
    if ($Pct -lt 50) { 'Tranquilo', '#4ADE80' } elseif ($Pct -lt 80) { 'Moderado', '#F5A524' } else { 'Pesado', '#F87171' }
}

function Set-Gauge([string]$Key, [double]$Pct, [string]$Text) {
    $ui["Gauge$($Key)Arc"].Data = New-GaugeArc $Pct
    $state, $color = Get-LoadState $Pct
    $ui["Gauge$($Key)Arc"].Stroke = New-Object Windows.Media.LinearGradientBrush ((Get-Color $color 150), (Get-Color $color), 0.0)
    $ui["Mon$Key"].Text = $Text
    $ui["Mon$($Key)State"].Text = $state
    $ui["Mon$($Key)State"].Foreground = $color
}

foreach ($g in $GaugeDefs) { $ui["Gauge$($g.Key)Track"].Data = New-GaugeArc 100 }

function Update-ProcList {
    $script:LastProcs = $sync.Procs
    $selName = if ($ui.ProcList.SelectedItem) { $ui.ProcList.SelectedItem.Tag } else { $null }
    $ui.ProcList.Items.Clear()
    foreach ($p in $script:LastProcs) {
        $g = New-Object Windows.Controls.Grid
        foreach ($wd in 0, 90, 110, 80) {
            $cd = New-Object Windows.Controls.ColumnDefinition
            $cd.Width = if ($wd) { New-Object Windows.GridLength $wd } else { New-Object Windows.GridLength 1, 'Star' }
            $g.ColumnDefinitions.Add($cd)
        }
        $cpuColor = if ($p.Cpu -ge 50) { '#F87171' } elseif ($p.Cpu -ge 15) { '#F5A524' } else { '#D5D9E3' }
        $cells = @(
            @($p.Name, '#F1F3F8', 'Left'),
            @(('{0:N1}%' -f $p.Cpu), $cpuColor, 'Right'),
            @((Format-Size $p.Ram), '#D5D9E3', 'Right'),
            @("$($p.Count)", '#8A91A3', 'Right')
        )
        for ($i = 0; $i -lt 4; $i++) {
            $tb = New-Object Windows.Controls.TextBlock
            $tb.Text = $cells[$i][0]; $tb.Foreground = $cells[$i][1]; $tb.HorizontalAlignment = $cells[$i][2]
            $tb.FontSize = 13; $tb.TextTrimming = 'CharacterEllipsis'
            [Windows.Controls.Grid]::SetColumn($tb, $i)
            [void]$g.Children.Add($tb)
        }
        $item = New-Object Windows.Controls.ListBoxItem
        $item.Content = $g; $item.Tag = $p.Name
        [void]$ui.ProcList.Items.Add($item)
        if ($p.Name -eq $selName) { $item.IsSelected = $true }
    }
}

function Update-Monitor {
    $m = $sync.Mon
    if (-not $m) { return }
    $ramPct = 100 * $m.RamUsed / $m.RamTotal
    Push-Hist Cpu $m.Cpu; Push-Hist Ram $ramPct; Push-Hist Disk $m.Disk
    Push-Hist Gpu ([math]::Max(0, $m.Gpu)); Push-Hist Down $m.Down; Push-Hist Up $m.Up

    Set-Gauge Cpu $m.Cpu ('{0:N0}%' -f $m.Cpu)
    $ui.MonCpuSub.Text = "$($sync.ProcCount) processos abertos"
    Set-Gauge Ram $ramPct ('{0:N0}%' -f $ramPct)
    $ui.MonRamSub.Text = "$(Format-Size $m.RamUsed) de $(Format-Size $m.RamTotal)"
    if ($m.Gpu -ge 0) {
        Set-Gauge Gpu $m.Gpu ('{0:N0}%' -f $m.Gpu)
    } else {
        Set-Gauge Gpu 0 'n/d'; $ui.MonGpuState.Text = 'sem leitura'; $ui.MonGpuState.Foreground = '#8A91A3'
    }
    $ui.MonGpuSub.Text = $ui.InfoGPU.Text
    Set-Gauge Disk $m.Disk ('{0:N0}%' -f $m.Disk)
    $ui.MonDiskSub.Text = "Lê $(Format-Rate $m.DiskR)  ·  grava $(Format-Rate $m.DiskW)"

    $ui.MonNet.Text = Format-Rate $m.Down
    $ui.MonNetSub.Text = Format-Rate $m.Up
    $peakDown = [double]($script:Hist.Down | Measure-Object -Maximum).Maximum
    $peakUp   = [double]($script:Hist.Up | Measure-Object -Maximum).Maximum
    $ui.MonNetPeak.Text = "Pico no último minuto: $(Format-Rate $peakDown) recebendo  ·  $(Format-Rate $peakUp) enviando"
    $netMax = [math]::Max([double]128KB, [math]::Max($peakDown, $peakUp)) * 1.15

    foreach ($g in $GaugeDefs) { Draw-Chart $ui["Chart$($g.Key)"] @(@{ Values = $script:Hist[$g.Key]; Color = $g.Color }) 100 }
    Draw-Chart $ui.ChartNet @(@{ Values = $script:Hist.Down; Color = '#4ADE80' }, @{ Values = $script:Hist.Up; Color = '#60A5FA' }) $netMax -Grid

    if ($sync.Procs -and -not [object]::ReferenceEquals($sync.Procs, $script:LastProcs)) { Update-ProcList }
}

function Update-Drives {
    $ui.PanelDrives.Children.Clear()
    foreach ($d in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue) {
        if (-not $d.Size) { continue }
        $pct = [int](100 * ($d.Size - $d.FreeSpace) / $d.Size)
        $color = if ($pct -ge 90) { '#F87171' } elseif ($pct -ge 80) { '#F5A524' } else { '#7C5CFF' }
        if ($d.DeviceID -eq $env:SystemDrive) {
            # anel grande: unidade do Windows. Circunferência em unidades de espessura do traço: pi * (118 - 12) / 12
            $ui.DiskRing.StrokeDashArray = New-Object Windows.Media.DoubleCollection (,[double[]]@((([math]::PI * 106 / 12) * $pct / 100), 1000))
            $ui.DiskRing.Stroke = $color
            $ui.DiskPct.Text = "$pct%"
        }
        $label = if ($d.VolumeName) { "$($d.DeviceID) $($d.VolumeName)" } else { $d.DeviceID }
        $x = @"
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Margin="0,0,0,10">
  <DockPanel>
    <TextBlock DockPanel.Dock="Right" Text="$(Esc "$(Format-Size $d.FreeSpace) livres")" Foreground="#8A91A3" FontSize="12"/>
    <TextBlock Text="$(Esc $label)" Foreground="#F1F3F8" FontSize="13" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
  </DockPanel>
  <ProgressBar Height="6" Margin="0,6,0,0" Maximum="100" Value="$pct" Foreground="$color" Background="#262B37" BorderThickness="0"/>
</StackPanel>
"@
        [void]$ui.PanelDrives.Children.Add([Windows.Markup.XamlReader]::Parse($x))
    }
}

# ---------------------------------------------------------------- espaço em disco: análise (thread separada)
# Mede pastas com o robocopy em modo lista (/L): não copia nada e é bem mais rápido que o PowerShell em pastas grandes.
$diskWorker = {
    param($sync, $Drive, $Folder)

    # Roda um programa sem janela e devolve a saída inteira
    function Invoke-Hidden([string]$Exe, [string]$Arguments) {
        $psi = New-Object Diagnostics.ProcessStartInfo $Exe, $Arguments
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
        # o robocopy escreve na página de código OEM do sistema (850 no Brasil): sem isso os acentos dos caminhos quebram
        $psi.StandardOutputEncoding = $oem
        $p = [Diagnostics.Process]::Start($psi)
        [pscustomobject]@{ Proc = $p; Out = $p.StandardOutput.ReadToEndAsync() }
    }

    # Total de bytes no resumo do robocopy: a 3ª linha com 6 números (Pastas, Arquivos, Bytes), primeira coluna
    function Get-RoboBytes([string]$Text) {
        $rows = [regex]::Matches($Text, '(?m)^\s*[^:\r\n]+:\s*(\d+)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s*$')
        if ($rows.Count -ge 3) { [int64]$rows[2].Groups[1].Value } else { [int64]0 }
    }

    # Mede várias pastas, 6 de cada vez
    # OneDrive: arquivos "só online" aparecem com o tamanho cheio, mas não ocupam o disco.
    # As pastas do OneDrive são medidas pelos atributos (só o que está mesmo no PC) e ficam fora do robocopy.
    $OnlineOnly = 0x441000   # RECALL_ON_DATA_ACCESS | RECALL_ON_OPEN | OFFLINE
    $cloudRoots = @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special -and $_.LocalPath } |
                    ForEach-Object { Get-ChildItem -LiteralPath $_.LocalPath -Directory -Force -Filter 'OneDrive*' -ErrorAction SilentlyContinue } | ForEach-Object FullName)
    $cloudCache = @{}
    function Get-CloudRoot([string]$Path) { $cloudRoots | Where-Object { $Path -eq $_ -or $Path.StartsWith("$_\", 'OrdinalIgnoreCase') } | Select-Object -First 1 }
    function Measure-CloudLocal([string]$Path) {
        if ($cloudCache.ContainsKey($Path)) { return $cloudCache[$Path] }
        $s = [int64]0
        Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { if (-not ([int64]$_.Attributes -band $OnlineOnly)) { $s += $_.Length } }
        $cloudCache[$Path] = $s
        $s
    }

    function Measure-Paths([string[]]$Paths) {
        $res = @{}
        $queue = New-Object Collections.Queue
        foreach ($p in ($Paths | Where-Object { $_ } | Select-Object -Unique)) {
            if (-not (Test-Path -LiteralPath $p -PathType Container)) { continue }
            if (Get-CloudRoot $p) { $res[$p] = Measure-CloudLocal $p } else { $queue.Enqueue($p) }
        }
        $total = $queue.Count; $done = 0
        $running = New-Object Collections.ArrayList
        while ($queue.Count -or $running.Count) {
            while ($queue.Count -and $running.Count -lt 6) {
                $p = $queue.Dequeue()
                $inside = @($cloudRoots | Where-Object { $_.StartsWith("$($p.TrimEnd('\'))\", 'OrdinalIgnoreCase') })
                $xd = if ($inside) { ' /XD ' + (($inside | ForEach-Object { "`"$_`"" }) -join ' ') } else { '' }
                $job = Invoke-Hidden "$env:windir\System32\robocopy.exe" "`"$($p.TrimEnd('\'))`" NUL /L /S /NJH /NFL /NDL /NC /BYTES /XJ /R:0 /W:0 /NP$xd"
                [void]$running.Add([pscustomobject]@{ P = $p; Job = $job; Inside = $inside })
            }
            foreach ($r in @($running)) {
                if ($r.Job.Proc.HasExited -and $r.Job.Out.IsCompleted) {
                    $res[$r.P] = (Get-RoboBytes $r.Job.Out.Result) + [int64](@($r.Inside | ForEach-Object { Measure-CloudLocal $_ }) | Measure-Object -Sum).Sum
                    $running.Remove($r); $done++
                    $sync.DiskStatus = "Medindo pastas: $done de $total"
                    $sync.DiskProgress = [int](100 * $done / [math]::Max(1, $total))
                }
            }
            if ($running.Count) { Start-Sleep -Milliseconds 120 }
        }
        $res
    }

    function Get-FileSize([string]$Path) {
        $i = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($i -and -not $i.PSIsContainer) { [int64]$i.Length } else { [int64]0 }
    }

    $oem = try { [Text.Encoding]::GetEncoding([int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage').OEMCP) } catch { [Text.Encoding]::Default }
    $skipRoot = 'System Volume Information', '$Recycle.Bin', 'Recovery', 'Config.Msi', 'Documents and Settings'
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        # ---- só uma pasta (quando a pessoa clica para entrar)
        if ($Folder) {
            $sync.DiskStatus = 'Medindo a pasta...'
            $children = @(Get-ChildItem -LiteralPath $Folder -Force -ErrorAction SilentlyContinue | Where-Object { (-not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $cloudRoots -contains $_.FullName) -and $skipRoot -notcontains $_.Name })
            $sizes = Measure-Paths @($children | Where-Object PSIsContainer | ForEach-Object FullName)
            $items = foreach ($c in $children) {
                if (-not $c.PSIsContainer -and ([int64]$c.Attributes -band $OnlineOnly)) { continue }
                [pscustomobject]@{ Name = $c.Name; Path = $c.FullName; IsDir = $c.PSIsContainer
                                   Size = $(if ($c.PSIsContainer) { [int64]$sizes[$c.FullName] } else { [int64]$c.Length }) }
            }
            $sync.FolderResult = [pscustomobject]@{ Path = $Folder; Items = @($items | Sort-Object Size -Descending | Select-Object -First 80) }
            return
        }

        # ---- análise completa da unidade
        $root = "$Drive\"
        $sys  = $Drive -eq $env:SystemDrive
        $vol  = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$Drive'"
        $sync.DiskStatus = 'Procurando pastas...'
        $rootDirs = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
                      Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $skipRoot -notcontains $_.Name })
        $profiles = if ($sys) { @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special -and $_.LocalPath -and (Test-Path $_.LocalPath) } | ForEach-Object LocalPath) } else { @() }
        $userParts = @(foreach ($p in $profiles) {
            Get-ChildItem -LiteralPath $p -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $cloudRoots -contains $_.FullName } | ForEach-Object FullName
        })

        # o que dá para limpar com segurança (cada item aponta para a otimização que limpa)
        $junk = @()
        if ($sys) {
            $L = @(); $tmp = @("$env:windir\Temp"); $br = @(); $ap = @(); $wer = @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue", "$env:windir\Minidump", "$env:windir\LiveKernelReports"); $sh = @()
            foreach ($p in $profiles) {
                $l = "$p\AppData\Local"; $r = "$p\AppData\Roaming"
                $tmp += "$l\Temp"
                foreach ($b in 'Google\Chrome', 'Microsoft\Edge', 'BraveSoftware\Brave-Browser') { $br += "$l\$b\User Data\*\Cache", "$l\$b\User Data\*\Code Cache", "$l\$b\User Data\*\GPUCache" }
                $br += "$l\Mozilla\Firefox\Profiles\*\cache2"
                foreach ($a in "$r\Microsoft\Teams", "$r\discord", "$r\Slack", "$l\Steam\htmlcache") { $ap += "$a\Cache", "$a\Code Cache", "$a\GPUCache" }
                $ap += "$l\Spotify\Data"
                $wer += "$l\CrashDumps", "$l\Microsoft\Windows\WER\ReportArchive"
                $sh += "$l\D3DSCache", "$l\NVIDIA\DXCache", "$l\NVIDIA\GLCache", "$l\AMD\DxCache", "$l\AMD\DxcCache"
            }
            $expand = { param($list) @($list | ForEach-Object { Get-Item -Path $_ -Force -ErrorAction SilentlyContinue } | Where-Object PSIsContainer | ForEach-Object FullName) }
            $junk = @(
                [pscustomobject]@{ Key = 'temp';    Ids = @('temp');          Glyph = 'E74D'; Title = 'Arquivos temporários'; Desc = 'Sobras de instalações e programas. O Windows não precisa deles.'; Paths = (& $expand $tmp); Extra = 0; Safe = $true }
                [pscustomobject]@{ Key = 'wu';      Ids = @('wucache');       Glyph = 'E777'; Title = 'Atualizações já instaladas'; Desc = 'Instaladores do Windows Update que já foram usados.'; Paths = (& $expand @("$env:windir\SoftwareDistribution\Download")); Extra = 0; Safe = $true }
                [pscustomobject]@{ Key = 'browser'; Ids = @('browsercache');  Glyph = 'E774'; Title = 'Cache dos navegadores'; Desc = 'Só o cache. Senhas, favoritos e logins continuam.'; Paths = (& $expand $br); Extra = 0; Safe = $true }
                [pscustomobject]@{ Key = 'apps';    Ids = @('appcache');      Glyph = 'E8BD'; Title = 'Cache de Teams, Discord, Spotify, Steam'; Desc = 'Conversas e contas não são apagadas. Feche os apps antes.'; Paths = (& $expand $ap); Extra = 0; Safe = $true }
                [pscustomobject]@{ Key = 'dumps';   Ids = @('dumps');         Glyph = 'E7BA'; Title = 'Relatórios de erro'; Desc = 'Registros de travamentos antigos.'; Paths = (& $expand $wer); Extra = (Get-FileSize "$env:windir\MEMORY.DMP"); Safe = $true }
                [pscustomobject]@{ Key = 'drivers'; Ids = @('driverinstallers'); Glyph = 'E7F4'; Title = 'Instaladores de driver antigos'; Desc = 'Pastas C:\NVIDIA e C:\AMD que sobram depois de instalar o driver de vídeo.'; Paths = (& $expand @("${root}NVIDIA", "${root}AMD")); Extra = 0; Safe = $true }
                [pscustomobject]@{ Key = 'recycle'; Ids = @('recycle');       Glyph = 'E107'; Title = 'Lixeira'; Desc = 'Arquivos que já foram apagados. Depois de esvaziar, não dá para recuperar.'; Paths = (& $expand @("$root`$Recycle.Bin")); Extra = 0; Safe = $false }
                [pscustomobject]@{ Key = 'winold';  Ids = @('cleanmgr');      Glyph = 'E8B7'; Title = 'Versão anterior do Windows'; Desc = 'Windows.old e instalações antigas. Depois não dá para voltar para a versão anterior. Demora até 30 minutos.'; Paths = (& $expand @("${root}Windows.old")); Extra = 0; Safe = $false }
                [pscustomobject]@{ Key = 'shader';  Ids = @('shadercache');   Glyph = 'E7F4'; Title = 'Cache de shaders'; Desc = 'Os jogos recriam aos poucos (pode dar travadinhas nas primeiras partidas). Útil depois de trocar o driver.'; Paths = (& $expand $sh); Extra = 0; Safe = $false }
                [pscustomobject]@{ Key = 'hiber';   Ids = @('hibernate');     Glyph = 'E708'; Title = 'Arquivo de hibernação'; Desc = 'Some a opção Hibernar e a Inicialização Rápida.'; Paths = @(); Extra = (Get-FileSize "${root}hiberfil.sys"); Safe = $false }
            )
        }

        # ---- coisas escondidas que ocupam muito (não aparecem como programa instalado)
        # Cada item: Kind (define o botão na tela), Paths (pastas a medir) ou Size já conhecido.
        $hidden = New-Object Collections.ArrayList
        $newHidden = { param($Kind, $Glyph, $Title, $Desc, $Path, $Paths, $Size, $Date, $Extra)
            [void]$hidden.Add([pscustomobject]@{ Kind = $Kind; Glyph = $Glyph; Title = $Title; Desc = $Desc; Path = $Path; Paths = @($Paths | Where-Object { $_ })
                                                  Size = [int64]$Size; Date = $Date; Extra = $Extra }) }
        if ($sys) {
            $sync.DiskStatus = 'Procurando coisas escondidas...'
            foreach ($p in $profiles) {
                $l = "$p\AppData\Local"; $r = "$p\AppData\Roaming"
                # Docker: disco virtual que não diminui sozinho
                $dv = @(Get-Item "$l\Docker\wsl\disk\*.vhdx", "$l\Docker\wsl\data\*.vhdx", "$l\Docker\wsl\main\*.vhdx" -Force -ErrorAction SilentlyContinue)
                if ($dv) {
                    & $newHidden 'docker' 'E7F4' 'Docker (disco virtual)' 'Imagens e containers do Docker. Esse disco não diminui sozinho, mesmo apagando imagens. Não usa Docker? Desinstale o Docker Desktop. Usa? Docker Desktop > Troubleshoot > Clean / Purge data.' `
                        "$l\Docker" $null ([int64](@($dv | ForEach-Object Length) | Measure-Object -Sum).Sum) (($dv | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime) $null
                }
                # Linux do WSL (Ubuntu, Debian...)
                foreach ($v in Get-ChildItem "$l\Packages\*\LocalState\ext4.vhdx" -Force -ErrorAction SilentlyContinue) {
                    $pkg = Split-Path (Split-Path (Split-Path $v.FullName)) -Leaf
                    $name = ($pkg -replace '_[a-z0-9]{13}$', '' -replace '^[^.]+\.', '' -replace '(Ubuntu|Debian|kali|SUSE|Fedora|Alpine).*', '$1')
                    & $newHidden 'wsl' 'E756' "Linux do WSL: $name" "Disco do Linux instalado pelo WSL. Para remover (apaga tudo dentro dele), abra o Terminal e rode: wsl --unregister <nome> (veja o nome com wsl -l)." `
                        $v.DirectoryName $null $v.Length $v.LastWriteTime $name
                }
                # máquinas virtuais
                foreach ($vmRoot in "$p\VirtualBox VMs", "$p\Documents\Virtual Machines", "$p\VMs") {
                    foreach ($d in Get-ChildItem -LiteralPath $vmRoot -Directory -Force -ErrorAction SilentlyContinue) {
                        $disks = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(vdi|vhdx?|vmdk|sav|vmem)$' })
                        if ($disks) {
                            & $newHidden 'vm' 'E7F4' "Máquina virtual: $($d.Name)" 'Se não precisa mais dela, apague pelo próprio VirtualBox/VMware (Remover > Excluir todos os arquivos) ou mova a pasta para um HD externo.' `
                                $d.FullName $null ([int64](@($disks | ForEach-Object Length) | Measure-Object -Sum).Sum) (($disks | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime) $null
                        }
                    }
                }
                # Minecraft: launchers, modpacks e mundos
                $mc = @("$p\curseforge\minecraft", "$l\.ftba", "$r\.minecraft", "$r\PrismLauncher", "$r\.tlauncher", "$r\ATLauncher", "$r\com.modrinth.theseus", "$r\gdlauncher_next") | Where-Object { Test-Path -LiteralPath $_ }
                if ($mc) { & $newHidden 'mc' 'E7FC' 'Minecraft (launchers, modpacks e mundos)' 'Modpacks, mundos e versões baixadas pelos launchers (CurseForge, FTB, Prism...). Abra o launcher e apague os modpacks e instâncias que não joga mais.' $mc[0] $mc 0 $null $null }
                # caches de programação
                $caches = [ordered]@{ 'npm' = "$l\npm-cache"; 'NuGet' = "$p\.nuget\packages"; 'pip' = "$l\pip\cache"; 'Gradle' = "$p\.gradle\caches"; 'Maven' = "$p\.m2\repository"; 'Yarn' = "$l\Yarn\Cache"; 'Cargo' = "$p\.cargo\registry" }
                foreach ($c in $caches.Keys) {
                    if (Test-Path -LiteralPath $caches[$c]) { & $newHidden 'cache' 'E943' "Cache de programação: $c" 'Pacotes baixados por ferramentas de programação. Pode limpar: eles baixam de novo quando algum projeto precisar.' $caches[$c] $caches[$c] 0 $null $null }
                }
                # logs gigantes dentro do AppData
                foreach ($base in $l, $r) {
                    $job = Invoke-Hidden "$env:windir\System32\robocopy.exe" "`"$base`" NUL /L /S /NJH /NJS /NDL /NC /BYTES /FP /XJ /R:0 /W:0 /NP /MIN:314572800 /IF *.log *.json *.txt *.etl *.old *.bak"
                    $job.Proc.WaitForExit()
                    foreach ($mm in [regex]::Matches($job.Out.Result, '(?m)^\s+(\d+)\s+([A-Za-z]:\\[^\r\n]+?)\s*$')) {
                        $fp = $mm.Groups[2].Value
                        $app = ($fp.Substring($base.Length + 1) -split '\\')[0]
                        & $newHidden 'log' 'E9F9' "Arquivo de log gigante ($app)" "Registro de erros que o programa '$app' foi acumulando. Pode apagar: o programa cria outro." `
                            $fp $null ([int64]$mm.Groups[1].Value) ((Get-Item -LiteralPath $fp -Force -ErrorAction SilentlyContinue).LastWriteTime) $null
                    }
                }
                # Windows extraído de uma ISO (pasta com sources\install.wim): cópia do que já está na ISO
                $job = Invoke-Hidden "$env:windir\System32\robocopy.exe" "`"$p`" NUL /L /S /NJH /NJS /NDL /NC /BYTES /FP /XJ /R:0 /W:0 /NP /IF install.wim install.esd /XD AppData `"Application Data`""
                $job.Proc.WaitForExit()
                foreach ($mm in [regex]::Matches($job.Out.Result, '(?m)^\s+\d+\s+([A-Za-z]:\\[^\r\n]+?)\\sources\\install\.(wim|esd)\s*$')) {
                    $dir = $mm.Groups[1].Value
                    if (Get-CloudRoot $dir) { continue }
                    & $newHidden 'isoext' 'EDA2' "Windows extraído de uma ISO: $(Split-Path $dir -Leaf)" 'Conteúdo de uma ISO do Windows já descompactado. Se você tem a ISO, isto é cópia e pode ser apagado (a ISO serve para criar o pendrive de novo).' $dir $dir 0 $null $null
                }
            }
            # pontos de restauração (só como administrador)
            try {
                $volId = (Get-CimInstance Win32_Volume -Filter "DriveLetter='$Drive'" -ErrorAction Stop).DeviceID
                $ss = Get-CimInstance Win32_ShadowStorage -ErrorAction Stop | Where-Object { $_.Volume.DeviceID -eq $volId } | Select-Object -First 1
                if ($ss) {
                    $limit = if ($ss.MaxSpace -ge [int64]::MaxValue / 2) { 'sem limite' } else { "limite de $([math]::Round($ss.MaxSpace / 1GB, 1)) GB" }
                    & $newHidden 'restore' 'E777' 'Pontos de restauração' "Cópias que o Windows guarda para voltar o PC no tempo ($limit). Em Proteção do Sistema > Configurar dá para apagar os antigos ou diminuir o limite (5% a 10% é suficiente)." `
                        "${root}System Volume Information" $null ([int64]$ss.UsedSpace) $null $null
                }
            } catch {}
        }

        $toMeasure = @($rootDirs | Where-Object { $_.Name -ne 'Users' -or -not $sys } | ForEach-Object FullName) + $userParts + @($junk | ForEach-Object { $_.Paths }) + @($hidden | ForEach-Object { $_.Paths })
        $sizes = Measure-Paths $toMeasure
        $sz = { param($p) if ($p) { [int64]$sizes[$p] } else { [int64]0 } }
        $sum = { param($list) [int64](@($list | Where-Object { $_ } | ForEach-Object { [int64]$sizes[$_] }) | Measure-Object -Sum).Sum }

        # jogos (tamanho real informado pela Steam e pela Epic)
        $sync.DiskStatus = 'Vendo jogos e programas...'
        $games = @()
        $steam = @(Get-ItemProperty 'Registry::HKEY_USERS\*\Software\Valve\Steam' -ErrorAction SilentlyContinue | Where-Object SteamPath | ForEach-Object SteamPath) | Select-Object -First 1
        if (-not $steam) { $steam = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath }
        if ($steam -and (Test-Path "$steam\steamapps")) {
            $libs = @($steam) + @(Select-String -Path "$steam\steamapps\libraryfolders.vdf" -Pattern '"path"\s+"(.+)"' -ErrorAction SilentlyContinue | ForEach-Object { $_.Matches[0].Groups[1].Value -replace '\\\\', '\' })
            foreach ($lib in ($libs | ForEach-Object { $_ -replace '/', '\' } | Sort-Object -Unique)) {
                foreach ($m in Get-ChildItem "$lib\steamapps\appmanifest_*.acf" -ErrorAction SilentlyContinue) {
                    $txt = Get-Content $m.FullName -Raw -ErrorAction SilentlyContinue
                    $name = [regex]::Match($txt, '"name"\s+"(.+?)"').Groups[1].Value
                    $sv   = [regex]::Match($txt, '"SizeOnDisk"\s+"(\d+)"').Groups[1].Value
                    $size = if ($sv) { [int64]$sv } else { [int64]0 }
                    $id   = [regex]::Match($txt, '"appid"\s+"(\d+)"').Groups[1].Value
                    $dir  = [regex]::Match($txt, '"installdir"\s+"(.+?)"').Groups[1].Value
                    if ($name -match 'Steamworks|Redistributable') { continue }
                    $games += [pscustomobject]@{ Name = $name; Size = $size; Kind = 'Steam'; AppId = $id; Path = "$lib\steamapps\common\$dir"; Uninstall = '' }
                }
            }
        }
        foreach ($m in Get-ChildItem "$env:ProgramData\Epic\EpicGamesLauncher\Data\Manifests\*.item" -ErrorAction SilentlyContinue) {
            try { $j = Get-Content $m.FullName -Raw | ConvertFrom-Json; $games += [pscustomobject]@{ Name = $j.DisplayName; Size = [int64]$j.InstallSize; Kind = 'Epic'; AppId = ''; Path = $j.InstallLocation; Uninstall = '' } } catch {}
        }
        $games = @($games | Where-Object { $_.Path -and $_.Path.StartsWith($Drive, 'OrdinalIgnoreCase') })

        # programas instalados (tamanho informado pelo próprio programa)
        $u = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        $progs = @(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*", "Registry::HKEY_USERS\*\$u" -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and $_.EstimatedSize -and $_.UninstallString -and -not $_.SystemComponent -and -not $_.ParentKeyName -and $_.DisplayName -notmatch 'Update for|Hotfix|Security Update|Steam App \d' } |
            Where-Object { -not $_.InstallLocation -or "$($_.InstallLocation)".StartsWith($Drive, 'OrdinalIgnoreCase') } |
            Where-Object { $gn = $_.DisplayName; -not @($games | Where-Object { $_.Name -eq $gn }).Count } |
            ForEach-Object { [pscustomobject]@{ Name = $_.DisplayName; Size = [int64]$_.EstimatedSize * 1KB; Kind = $(if ("$($_.InstallLocation) $($_.DisplayName)" -match 'Riot Games|Epic Games|XboxGames|steamapps|VALORANT|League of Legends|Fortnite') { 'Jogo' } else { 'Programa' }); AppId = ''; Path = $_.InstallLocation; Uninstall = $_.UninstallString } } |
            Sort-Object Name -Unique)
        if (-not $sys) { $progs = @($progs | Where-Object { $_.Path }) }
        $apps = @(@($games) + @($progs) | Sort-Object Size -Descending | Select-Object -First 20)

        # arquivos grandes (500 MB ou mais) nas pastas da pessoa; jogos e AppData ficam de fora
        $sync.DiskStatus = 'Procurando arquivos grandes...'
        $big = @()
        $bigRoots = if ($sys) { $profiles } else { @($rootDirs | ForEach-Object FullName) }
        $jobs = foreach ($b in $bigRoots) {
            Invoke-Hidden "$env:windir\System32\robocopy.exe" "`"$($b.TrimEnd('\'))`" NUL /L /S /NJH /NJS /NDL /NC /BYTES /FP /XJ /R:0 /W:0 /NP /MIN:524288000 /XD AppData `"Application Data`" steamapps SteamLibrary `"Epic Games`" `"Riot Games`" XboxGames"
        }
        foreach ($j in $jobs) {
            $j.Proc.WaitForExit()
            foreach ($mm in [regex]::Matches($j.Out.Result, '(?m)^\s+(\d+)\s+([A-Za-z]:\\[^\r\n]+?)\s*$')) {
                $path = $mm.Groups[2].Value
                $fi = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                # só na nuvem: não ocupa o disco, apagar não libera nada
                if (-not $fi -or ([int64]$fi.Attributes -band $OnlineOnly)) { continue }
                $big += [pscustomobject]@{ Path = $path; Name = [IO.Path]::GetFileName($path); Folder = [IO.Path]::GetDirectoryName($path); Size = [int64]$mm.Groups[1].Value; Date = $fi.LastWriteTime; Cloud = [bool](Get-CloudRoot $path) }
            }
        }
        $big = @($big | Sort-Object Size -Descending | Select-Object -First 40)

        # pastas da raiz (com Usuários somado das pastas de cada perfil)
        $folders = foreach ($d in $rootDirs) {
            $s = if ($sys -and $d.Name -eq 'Users') { & $sum $userParts } else { & $sz $d.FullName }
            [pscustomobject]@{ Name = $d.Name; Path = $d.FullName; IsDir = $true; Size = $s }
        }
        $sysFiles = foreach ($n in 'pagefile.sys', 'hiberfil.sys', 'swapfile.sys') { $s = Get-FileSize "$root$n"; if ($s) { [pscustomobject]@{ Name = $n; Path = "$root$n"; IsDir = $false; Size = $s } } }
        $folders = @(@($folders) + @($sysFiles) | Sort-Object Size -Descending)

        # divisão do disco para o gráfico
        $used = [int64]($vol.Size - $vol.FreeSpace)
        $gamesSize = [int64](@($games | ForEach-Object Size) | Measure-Object -Sum).Sum
        foreach ($n in 'Riot Games', 'XboxGames') { $gamesSize += & $sz "$root$n" }
        $sysSize = [int64](@($sysFiles | ForEach-Object Size) | Measure-Object -Sum).Sum
        $buckets = [ordered]@{}
        if ($sys) {
            $pf = & $sum @("${root}Program Files", "${root}Program Files (x86)", "${root}ProgramData")
            $gamesInPf = [int64](@($games | Where-Object { $_.Path -match '\\Program Files' } | ForEach-Object Size) | Measure-Object -Sum).Sum
            $buckets['Windows']            = & $sz "${root}Windows"
            $buckets['Programas']          = [math]::Max([int64]0, $pf - $gamesInPf)
            $buckets['Jogos']              = $gamesSize
            $buckets['Seus arquivos']      = & $sum @($userParts | Where-Object { (Split-Path $_ -Leaf) -ne 'AppData' })
            $buckets['Dados de programas'] = & $sum @($userParts | Where-Object { (Split-Path $_ -Leaf) -eq 'AppData' })
            $buckets['Arquivos do sistema'] = $sysSize
        } else {
            $buckets['Jogos'] = $gamesSize
            $buckets['Seus arquivos e pastas'] = [math]::Max([int64]0, [int64](@($folders | Where-Object IsDir | ForEach-Object Size) | Measure-Object -Sum).Sum - $gamesSize)
        }
        $known = [int64](@($buckets.Values) | Measure-Object -Sum).Sum
        $buckets['Outros'] = [math]::Max([int64]0, $used - $known)

        foreach ($j in $junk) { $j | Add-Member -NotePropertyName Size -NotePropertyValue ((& $sum $j.Paths) + [int64]$j.Extra) }
        foreach ($h in $hidden) { if ($h.Paths.Count) { $h.Size = & $sum $h.Paths } }
        $hidden = @($hidden | Where-Object { $_.Size -ge 500MB } | Sort-Object Size -Descending)
        $sync.DiskResult = [pscustomobject]@{
            Drive = $Drive; System = $sys; Total = [int64]$vol.Size; Free = [int64]$vol.FreeSpace; Used = $used
            Buckets = $buckets; Junk = @($junk | Where-Object { $_.Size -ge 1MB } | Sort-Object Size -Descending); Big = $big; Apps = $apps; Folders = $folders; Hidden = $hidden
            Seconds = [int]$sw.Elapsed.TotalSeconds
        }
    } catch {
        $sync.DiskStatus = "Não foi possível analisar: $($_.Exception.Message)"
    } finally {
        $sync.DiskDone = $true
    }
}

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

# ---------------------------------------------------------------- teste de FPS (PresentMon, da Intel)
# O PresentMon lê os quadros pelo próprio Windows (ETW): não toca no jogo, então não mexe com anti-cheat.
$Global:FpsFile = Join-Path $env:ProgramData 'TurboPC\fps.json'

# Analisa o CSV do PresentMon (colunas 1.x): pega o programa com mais quadros e calcula FPS médio e 1% baixo
function Get-FpsFromCsv([string]$Path) {
    $rows = @(Import-Csv -LiteralPath $Path)
    if (-not $rows) { return $null }
    $col = @('MsBetweenPresents', 'FrameTime') | Where-Object { $rows[0].PSObject.Properties.Name -contains $_ } | Select-Object -First 1
    if (-not $col) { return $null }
    $skip = '^(dwm|explorer|TurboPC.*|PresentMon.*|powershell|chrome|msedge|firefox|opera|brave|Discord|Spotify|steamwebhelper|EpicWebHelper|ShellExperienceHost|SearchHost|StartMenuExperienceHost|TextInputHost)\.exe$'
    $g = $rows | Where-Object { $_.Application -and $_.Application -notmatch $skip } | Group-Object Application | Sort-Object Count -Descending | Select-Object -First 1
    if (-not $g) { return $null }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $ms = @($g.Group | ForEach-Object { $v = 0.0; if ([double]::TryParse($_.$col, [Globalization.NumberStyles]::Float, $inv, [ref]$v)) { $v } } | Where-Object { $_ -gt 0 -and $_ -lt 1000 } | Sort-Object)
    if ($ms.Count -lt 30) { return $null }
    $sum = [double](($ms | Measure-Object -Sum).Sum)
    $p99 = $ms[[int][math]::Floor(0.99 * ($ms.Count - 1))]
    [pscustomobject]@{
        Game = ($g.Name -replace '\.exe$', '' -replace '(-Win64)?-Shipping$', '' -replace '_x64$', '')
        Exe = $g.Name; Avg = [math]::Round(1000.0 * $ms.Count / $sum, 1); Low1 = [math]::Round(1000.0 / $p99, 1)
        Frames = $ms.Count; Seconds = [math]::Round($sum / 1000, 1); Date = (Get-Date).ToString('s')
    }
}

$fpsWorker = {
    param($sync, $Delay, $Seconds, $OutFile, $Winget, $Parser)
    function Find-PresentMon {
        foreach ($root in "$env:ProgramFiles\WinGet\Packages", "$env:LOCALAPPDATA\Microsoft\WinGet\Packages") {
            $f = Get-ChildItem -Path $root -Filter 'PresentMon*.exe' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'Service' } | Select-Object -First 1
            if ($f) { return $f.FullName }
        }
        $null
    }
    function Run-Hidden([string]$Exe, [string]$Arguments) {
        $psi = New-Object Diagnostics.ProcessStartInfo $Exe, $Arguments
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $p = [Diagnostics.Process]::Start($psi)
        [pscustomobject]@{ Proc = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
    }
    try {
        . ([scriptblock]::Create($Parser))
        $exe = Find-PresentMon
        if (-not $exe) {
            if (-not $Winget) { $sync.FpsError = 'O medidor precisa do winget para ser baixado. Veja a aba Programas > Instalar programas.'; return }
            $sync.FpsStatus = 'Baixando o medidor de FPS da Intel (só na primeira vez)...'
            $base = 'install --id Intel.PresentMon.Console -e --source winget --silent --accept-package-agreements --accept-source-agreements'
            $j = Run-Hidden $Winget "$base --scope machine --disable-interactivity"; $j.Proc.WaitForExit()
            $exe = Find-PresentMon
            if (-not $exe) { $j = Run-Hidden $Winget $base; $j.Proc.WaitForExit(); $exe = Find-PresentMon }
            if (-not $exe) { $sync.FpsError = 'Não foi possível baixar o medidor (PresentMon). Confira a internet e tente de novo.'; return }
        }
        for ($i = [int]$Delay; $i -gt 0; $i--) { $sync.FpsStatus = "Volte para o jogo: a medição começa em $i s"; Start-Sleep -Seconds 1 }
        [System.Media.SystemSounds]::Exclamation.Play()
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        $args2 = "--output_file `"$OutFile`" --timed $Seconds --terminate_after_timed --stop_existing_session --no_console_stats --v1_metrics --session_name TurboPC_FPS"
        $j = Run-Hidden $exe $args2
        $t0 = [datetime]::Now
        while (-not $j.Proc.HasExited) {
            $left = [int]($Seconds - ([datetime]::Now - $t0).TotalSeconds)
            $sync.FpsStatus = if ($left -gt 0) { "Medindo o FPS... faltam $left s (continue jogando)" } else { 'Terminando a medição...' }
            if (([datetime]::Now - $t0).TotalSeconds -gt $Seconds + 40) { try { $j.Proc.Kill() } catch {}; break }
            Start-Sleep -Milliseconds 500
        }
        [System.Media.SystemSounds]::Asterisk.Play()
        if (-not (Test-Path -LiteralPath $OutFile)) {
            $err = "$($j.Err.Result) $($j.Out.Result)".Trim()
            $sync.FpsError = "O medidor não gerou resultado. $(if ($err) { $err.Substring(0, [math]::Min(300, $err.Length)) })"
            return
        }
        $r = Get-FpsFromCsv $OutFile
        if (-not $r) { $sync.FpsError = 'Nenhum jogo foi detectado durante a medição. Deixe o jogo aberto e na tela (não minimizado) enquanto mede.'; return }
        $sync.FpsResult = $r
    } catch {
        $sync.FpsError = $_.Exception.Message
    } finally {
        $sync.FpsDone = $true
    }
}

function Get-FpsHistory {
    # no PowerShell 5 o ConvertFrom-Json devolve a lista inteira como um item só: o ForEach-Object desmonta
    try { if (Test-Path $Global:FpsFile) { return @(Get-Content $Global:FpsFile -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) } } catch {}
    @()
}

function Start-FpsTest {
    if ($sync.UpdateBusy -and $sync.UpdateDone) { Complete-UpdateCheck }
    if ($sync.FpsBusy) { return }
    $msg = "Como funciona:`n`n1. Abra o jogo e vá para um lugar que dê para repetir depois (no Valorant, o The Range).`n2. Clique em OK e volte para o jogo.`n3. Em 10 segundos começa a medição, que dura 30 segundos. Você ouve um aviso sonoro no começo e no fim.`n4. Continue jogando normalmente nesse tempo.`n`nMeça antes e depois de otimizar, no mesmo lugar, para comparar. Na primeira vez o TurboPC baixa o medidor da Intel (PresentMon)."
    if ((Show-Msg $msg 'OKCancel' 'Information') -ne 'OK') { return }
    $sync.FpsBusy = $true; $sync.FpsDone = $false; $sync.FpsResult = $null; $sync.FpsError = $null; $sync.FpsStatus = 'Preparando...'
    $ui.BtnFps.IsEnabled = $false
    $parser = (Get-Item function:Get-FpsFromCsv).ScriptBlock.Ast.Extent.Text
    $out = Join-Path $env:ProgramData 'TurboPC\fps_ultima_medicao.csv'
    New-Item -ItemType Directory -Path (Split-Path $out) -Force | Out-Null
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($fpsWorker.ToString()).AddArgument($sync).AddArgument(10).AddArgument(30).AddArgument($out).AddArgument((Find-Winget)).AddArgument($parser)
    $script:fpsJob = @{ PS = $ps; H = $ps.BeginInvoke() }
}

function Complete-FpsTest {
    $sync.FpsBusy = $false
    try { [void]$script:fpsJob.PS.EndInvoke($script:fpsJob.H); $script:fpsJob.PS.Runspace.Dispose(); $script:fpsJob.PS.Dispose() } catch {}
    $ui.BtnFps.IsEnabled = $true
    if ($sync.FpsError -or -not $sync.FpsResult) {
        $ui.FpsInfo.Text = "Não deu para medir: $($sync.FpsError)"
        $ui.StatusText.Text = 'Teste de FPS não concluído.'
        return
    }
    $r = $sync.FpsResult
    $hist = @(Get-FpsHistory)
    try {
        New-Item -ItemType Directory -Path (Split-Path $Global:FpsFile) -Force | Out-Null
        ConvertTo-Json -InputObject @(@($hist) + @($r) | Select-Object -Last 100) -Depth 3 | Set-Content -Path $Global:FpsFile -Encoding UTF8
    } catch {}
    Write-TLog ("Teste de FPS: {0} | média {1} | 1% baixo {2} | {3} quadros em {4} s" -f $r.Game, $r.Avg, $r.Low1, $r.Frames, $r.Seconds) 'OK'
    $ui.StatusText.Text = "Teste de FPS concluído: $($r.Game), $([int]$r.Avg) FPS."
    Render-FpsResult $r $hist
}

# Mostra o resultado e compara com a medição anterior do mesmo jogo; se caiu depois de uma otimização, oferece desfazer
function Render-FpsResult($r, $hist) {
    $ui.FpsResult.Children.Clear()
    $prev = @($hist | Where-Object { $_.Game -eq $r.Game -and [datetime]$_.Date -lt [datetime]$r.Date }) | Select-Object -Last 1
    $line = "<StackPanel xmlns=""http://schemas.microsoft.com/winfx/2006/xaml/presentation"" Orientation=""Horizontal"" Margin=""0,2,0,0""><TextBlock Text=""$(Esc $r.Game)"" FontSize=""13"" Foreground=""#8A91A3"" VerticalAlignment=""Bottom"" Margin=""0,0,14,3""/><TextBlock Text=""$([int]$r.Avg)"" FontSize=""30"" FontWeight=""Bold"" Foreground=""White""/><TextBlock Text="" FPS médio"" FontSize=""13"" Foreground=""#C9CFDB"" VerticalAlignment=""Bottom"" Margin=""4,0,18,5""/><TextBlock Text=""$([int]$r.Low1)"" FontSize=""20"" FontWeight=""SemiBold"" Foreground=""#E6E8EE"" VerticalAlignment=""Bottom"" Margin=""0,0,0,2""/><TextBlock Text="" no 1% mais baixo"" FontSize=""13"" Foreground=""#8A91A3"" VerticalAlignment=""Bottom"" Margin=""4,0,0,5""/></StackPanel>"
    [void]$ui.FpsResult.Children.Add([Windows.Markup.XamlReader]::Parse($line))

    $text = ''; $color = '#8A91A3'; $undoRun = $null
    if (-not $prev) {
        $text = 'Primeira medição deste jogo. Depois de otimizar, meça de novo no mesmo lugar para comparar.'
    } else {
        $diff = 100.0 * ($r.Avg - $prev.Avg) / [math]::Max(1.0, $prev.Avg)
        $run = @(Get-UndoRuns | Where-Object { -not $_.Undone -and [datetime]$_.Date -gt [datetime]$prev.Date -and [datetime]$_.Date -lt [datetime]$r.Date }) | Select-Object -First 1
        $what = if ($run) { "depois da otimização '$($run.Label)' de $(([datetime]$run.Date).ToString('dd/MM HH:mm'))" } else { "comparado com a medição de $(([datetime]$prev.Date).ToString('dd/MM HH:mm'))" }
        $nums = "$([int]$prev.Avg) → $([int]$r.Avg) FPS ($('{0:+0.0;-0.0}' -f $diff)%)"
        if ($diff -ge 3) { $text = "Melhorou: $nums $what."; $color = '#4ADE80' }
        elseif ($diff -gt -3) { $text = "Ficou igual: $nums $what. Até 3% para cima ou para baixo é variação normal entre medições."; $color = '#C9CFDB' }
        elseif ($diff -gt -6) { $text = "Caiu um pouco: $nums $what. Pode ser variação; meça de novo no mesmo lugar para confirmar."; $color = '#F5A524' }
        else { $text = "O FPS caiu: $nums $what."; $color = '#F87171'; $undoRun = $run }
    }
    # jogo travado no limite de FPS (V-Sync ou limite do próprio jogo): a comparação perde o sentido
    $caps = @(30, 60, 75, 120, 144, 165, 240, 360) + @($script:MonitorHz | Where-Object { $_ })
    $cap = $caps | Where-Object { [math]::Abs($r.Avg - $_) -le ($_ * 0.02) } | Select-Object -First 1
    if ($cap) { $text += " Parece que o jogo está limitado em $cap FPS (V-Sync ou limite do jogo): para comparar o desempenho, tire o limite antes de medir." }
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $text; $tb.Foreground = $color; $tb.FontSize = 12.8; $tb.TextWrapping = 'Wrap'; $tb.Margin = '0,6,0,0'
    [void]$ui.FpsResult.Children.Add($tb)
    if ($undoRun) {
        $b = New-Object Windows.Controls.Button
        $b.Style = $window.FindResource('Btn'); $b.Background = '#B4374A'; $b.HorizontalAlignment = 'Left'; $b.Margin = '0,10,0,0'; $b.Padding = '14,8'
        $b.Content = "Desfazer a otimização '$($undoRun.Label)'"
        $b.Tag = $undoRun
        $b.Add_Click({ param($s) Invoke-Undo $s.Tag })
        [void]$ui.FpsResult.Children.Add($b)
    }
    $ui.FpsInfo.Text = "Medido em $(([datetime]$r.Date).ToString("dd/MM 'às' HH:mm")): $($r.Frames) quadros em $($r.Seconds) s."
}

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
                    if ($action -eq 'uninstall') { $c = Run-Winget "uninstall --id $($a.Winget) -e --silent" }
                    else {
                        # para todos os usuários do PC: com a senha de admin do técnico, "só para este usuário" instalaria na conta do técnico
                        $install = "install --id $($a.Winget) -e --source $($a.Source) --silent --accept-package-agreements"
                        $c = Run-Winget "$install --scope machine"
                        if ($okCodes -notcontains $c) { Log '  o programa não instala para todos os usuários; tentando só para este usuário...'; $c = Run-Winget $install }
                    }
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

# ---------------------------------------------------------------- execução em segundo plano
function Start-Worker([scriptblock]$Script, [object[]]$Arguments) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Script.ToString())
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    $script:job = @{ PS = $ps; Handle = $ps.BeginInvoke() }
}

$worker = {
    param($sync, $libText, $ids, $makeRP, $logFile, $label, $undoFile)
    try {
        $Global:TLogFile = $logFile
        $Global:TQueue   = $sync.Queue
        . ([scriptblock]::Create($libText))
        $progress = { param($p, $n) $sync.Progress = $p; $sync.Current = $n }
        if ($undoFile) { Undo-TRun -File $undoFile -OnProgress $progress }
        else { Invoke-TTasks -Ids $ids -RestorePoint:$makeRP -OnProgress $progress -Label $label }
        $sync.Freed = $Global:TotalFreed
    } catch {
        $sync.Queue.Enqueue("[ERRO] $($_.Exception.Message)")
    } finally {
        $sync.Done = $true
    }
}

function Set-Busy([bool]$Busy) {
    foreach ($b in @($script:ModeButtons) + @($script:UndoButtons)) { if ($b) { $b.IsEnabled = -not $Busy } }
    foreach ($n in 'BtnRun','BtnRec','BtnRecGame','BtnNone','BtnRestore','BtnSaveStartup',
                   'AllLimpeza','AllDesempenho','AllPrivacidade','AllJogos','AllAjustes','AllReparo',
                   'BtnInstall','BtnUninstall','BtnUpgradeAll','BtnInstallChoco') {
        $ui[$n].IsEnabled = -not $Busy
    }
    foreach ($cb in $script:CheckMap.Values) { $cb.IsEnabled = -not $Busy }
}

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

# ---------------------------------------------------------------- atualização (releases do GitHub)
# O GitHub Actions publica os .exe a cada tag de versão; o app confere a última release e se troca sozinho.
$UpdateRepo = 'williamesquilino/TurboPC'

$updateWorker = {
    param($sync, $Repo)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent' = 'TurboPC' }
        $sync.UpdateInfo = [pscustomobject]@{
            Version = ($rel.tag_name -replace '^v', ''); Notes = "$($rel.body)"; Url = $rel.html_url
            Assets = @($rel.assets | ForEach-Object { [pscustomobject]@{ Name = $_.name; Url = $_.browser_download_url; Size = [int64]$_.size; Digest = "$($_.digest)" } })
        }
    } catch {
        $sync.UpdateError = $_.Exception.Message
    } finally {
        $sync.UpdateDone = $true
    }
}

function Start-UpdateCheck([switch]$Manual) {
    if ($sync.UpdateBusy) { return }
    $script:UpdateManual = [bool]$Manual
    $sync.UpdateBusy = $true; $sync.UpdateDone = $false; $sync.UpdateInfo = $null; $sync.UpdateError = $null
    if ($script:TxtUpdate) { $script:TxtUpdate.Text = 'Procurando...' }
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($updateWorker.ToString()).AddArgument($sync).AddArgument($UpdateRepo)
    $script:updJob = @{ PS = $ps; H = $ps.BeginInvoke() }
}

function Complete-UpdateCheck {
    $sync.UpdateBusy = $false
    try { [void]$script:updJob.PS.EndInvoke($script:updJob.H); $script:updJob.PS.Runspace.Dispose(); $script:updJob.PS.Dispose() } catch {}
    $info = $sync.UpdateInfo
    $newer = $false
    if ($info) { try { $newer = [version]$info.Version -gt [version]$AppVersion } catch {} }
    $script:PendingUpdate = if ($newer) { $info } else { $null }
    if ($newer) {
        $script:TxtUpdate.Text = "Atualizar para v$($info.Version)"
        $script:BtnUpdate.Style = $window.FindResource('Btn'); $script:BtnUpdate.Background = '#10B981'
        $ui.StatusText.Text = "Tem versão nova do TurboPC (v$($info.Version)). Clique em 'Atualizar' na barra lateral."
        if ($script:UpdateManual) { Install-Update $info }
    } else {
        $script:TxtUpdate.Text = 'Procurar atualização'
        if ($script:UpdateManual) {
            if ($info) { Show-Msg "Você já está na versão mais nova (v$AppVersion)." | Out-Null }
            else { Show-Msg "Não deu para procurar atualização agora. Confira a internet.`n`n$($sync.UpdateError)" 'OK' 'Warning' | Out-Null }
        }
    }
}

# Baixa os .exe novos (conferindo o SHA-256 publicado pelo GitHub), troca os atuais e reinicia.
# O Windows deixa renomear um .exe em uso: o atual vira .old e é apagado na próxima abertura.
function Install-Update($Info) {
    if (-not $IsCompiled) {
        Show-Msg "Tem versão nova (v$($Info.Version)). Como você está usando o TurboPC.ps1, a página da release vai abrir para baixar." | Out-Null
        Start-Process $Info.Url
        return
    }
    $dir = Split-Path $ExePath
    $targets = @(Get-ChildItem -LiteralPath $dir -Filter 'TurboPC*.exe' -ErrorAction SilentlyContinue | Where-Object { @($Info.Assets.Name) -contains $_.Name })
    if (-not $targets) { Start-Process $Info.Url; return }
    $notes = ($Info.Notes -replace '\r', '').Trim()
    if ($notes.Length -gt 700) { $notes = $notes.Substring(0, 700) + '...' }
    $msg = "Versão nova do TurboPC: v$($Info.Version) (você tem a v$AppVersion).$(if ($notes) { "`n`nO que mudou:`n$notes" })`n`nAtualizar agora? O TurboPC fecha e abre de novo sozinho."
    if ((Show-Msg $msg 'YesNo' 'Question') -ne 'Yes') { return }
    $ui.StatusText.Text = 'Baixando a atualização...'
    $done = @()
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        foreach ($t in $targets) {
            $a = $Info.Assets | Where-Object Name -eq $t.Name | Select-Object -First 1
            $new = "$($t.FullName).new"
            Invoke-WebRequest -Uri $a.Url -OutFile $new -UseBasicParsing -TimeoutSec 120 -Headers @{ 'User-Agent' = 'TurboPC' }
            if ($a.Digest -match '^sha256:([0-9a-fA-F]{64})$' -and (Get-FileHash -LiteralPath $new -Algorithm SHA256).Hash -ne $Matches[1].ToUpper()) {
                throw "o arquivo $($t.Name) chegou diferente do publicado (SHA-256 não confere)"
            }
            $done += $t
        }
        foreach ($t in $done) {
            Remove-Item -LiteralPath "$($t.FullName).old" -Force -ErrorAction SilentlyContinue
            Rename-Item -LiteralPath $t.FullName -NewName "$($t.Name).old"
            Rename-Item -LiteralPath "$($t.FullName).new" -NewName $t.Name
        }
    } catch {
        foreach ($t in $targets) { Remove-Item -LiteralPath "$($t.FullName).new" -Force -ErrorAction SilentlyContinue }
        Show-Msg "A atualização não foi feita: $($_.Exception.Message)`n`nO TurboPC continua na versão atual." 'OK' 'Warning' | Out-Null
        $ui.StatusText.Text = 'Atualização não concluída.'
        return
    }
    Write-TLog "Atualizado para a v$($Info.Version) ($($done.Count) arquivo(s))" 'OK'
    Start-Process -FilePath $ExePath
    $window.Close()
}

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
function Invoke-Review([string]$Title, [string]$Subtitle, [string[]]$Ids, [string[]]$Extras = @()) {
    if ($sync.Running) { return }
    $r = Show-Review $Title $Subtitle $Ids $Extras
    if ($r -and $r.Ids) { Start-Run $r.Ids $r.Restore 'tasks' $Title }
}

function Start-Run([string[]]$Ids, [bool]$RestorePoint, [string]$Mode = 'tasks', [string]$Label = 'Otimização', [string]$UndoFile = '') {
    if ($sync.Running) { return }
    $sync.Done = $false; $sync.Running = $true; $sync.Progress = 0; $sync.Freed = 0; $sync.Mode = $Mode
    Set-Busy $true
    $ui.Tabs.SelectedItem = $ui.TabLog
    Start-Worker $worker @($sync, $TaskLibrary.ToString(), [string[]]@($Ids), $RestorePoint, $Global:TLogFile, $Label, $UndoFile)
}

function Complete-Run {
    $sync.Running = $false
    try { [void]$script:job.PS.EndInvoke($script:job.Handle) } catch {}
    try { $script:job.PS.Runspace.Dispose(); $script:job.PS.Dispose() } catch {}
    Set-Busy $false
    $ui.StatusText.Text = 'Concluído.'
    if ($sync.Mode -eq 'restore') {
        Show-Msg 'Pronto. Veja o resultado no Histórico.' | Out-Null
        return
    }
    if ($sync.Mode -eq 'undo') {
        Load-History
        Update-Info
        $r = Show-Msg "Pronto, as alterações foram desfeitas. Veja os detalhes no Histórico.`n`nReiniciar agora para valer tudo?" 'YesNo' 'Information'
        if ($r -eq 'Yes') { shutdown.exe /r /t 5 /c "Reiniciando após desfazer (TurboPC)" }
        return
    }
    if ($sync.Mode -eq 'apps') {
        Load-Apps
        $icon = if ($sync.AppFail) { 'Warning' } else { 'Information' }
        Show-Msg "Concluído: $($sync.AppOk) com sucesso, $($sync.AppFail) com problema.`n`nOs detalhes estão no Histórico." 'OK' $icon | Out-Null
        return
    }
    Load-History
    $script:SpaceStale = $true
    $script:SessionFreed += [int64]$sync.Freed
    $ui.TxtFreed.Text = "Espaço liberado nesta sessão: $(Format-Size $script:SessionFreed)"
    Update-Info
    $r = Show-Msg "Otimização concluída!`n`nEspaço liberado: $(Format-Size $sync.Freed)`n`nSe algo ficar diferente do que você queria, dá para desfazer no Histórico.`n`nAlgumas mudanças só valem depois de reiniciar. Reiniciar agora?" 'YesNo' 'Information'
    if ($r -eq 'Yes') { shutdown.exe /r /t 5 /c "Reiniciando após otimização (TurboPC)" }
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$timer.Add_Tick({
    $line = $null
    $sb = New-Object Text.StringBuilder
    while ($sync.Queue.TryDequeue([ref]$line)) { [void]$sb.AppendLine($line) }
    if ($sb.Length -gt 0) { $ui.LogBox.AppendText($sb.ToString()); $ui.LogBox.ScrollToEnd() }
    if ($sync.Running) {
        $ui.Progress.Value = $sync.Progress
        if ($sync.Current) { $ui.StatusText.Text = "Executando: $($sync.Current)" }
        if ($sync.Done) { Complete-Run }
    }
    if ($sync.UpdateBusy -and $sync.UpdateDone) { Complete-UpdateCheck }
    if ($sync.FpsBusy) {
        $ui.FpsInfo.Text = $sync.FpsStatus; $ui.StatusText.Text = $sync.FpsStatus
        if ($sync.FpsDone) { Complete-FpsTest }
    }
    if ($sync.DiskBusy) {
        if ($script:DiskMode -eq 'full') { $ui.SpaceStatus.Text = $sync.DiskStatus; $ui.SpaceProgress.Value = $sync.DiskProgress }
        if ($sync.DiskDone) { Complete-DiskScan }
    }
    if ($sync.MonActive -and $sync.MonSeq -ne $script:MonSeq) {
        $script:MonSeq = $sync.MonSeq
        Update-Monitor
    }
})
$timer.Start()

# ---------------------------------------------------------------- eventos
$ui.BtnRun.Add_Click({
    Invoke-Review 'Executar selecionados' 'Estas são as otimizações que você marcou. Feche os programas abertos antes de aplicar.' @(Get-SelectedIds)
})
$ui.BtnRec.Add_Click({ Set-Profile 'Escritorio' })
$ui.BtnRecGame.Add_Click({ Set-Profile 'Jogos' })
$ui.BtnNone.Add_Click({ foreach ($cb in $script:CheckMap.Values) { $cb.IsChecked = $false } })
foreach ($b in $script:ModeButtons) { $b.Add_Click({ param($s) Invoke-Mode $s.Tag }) }
$ui.BtnDriver.Add_Click({ if ($script:DriverUrl) { Start-Process $script:DriverUrl } })
$ui.BtnRestore.Add_Click({ Start-Run @() $true 'restore' })
$ui.BtnRefresh.Add_Click({ Update-Info })
$ui.BtnReport.Add_Click({
    try { Export-Report } catch { Show-Msg "Não foi possível gerar o relatório: $($_.Exception.Message)" 'OK' 'Error' | Out-Null }
})
$ui.BtnOpenLogs.Add_Click({ Start-Process explorer.exe $LogDir })
$ui.BtnUndo.Add_Click({ $ui.Tabs.SelectedItem = $ui.TabLog })
$ui.BtnUsage.Add_Click({ Initialize-Usage -Ask })
$ui.BtnFps.Add_Click({ Start-FpsTest })
# espaço em disco
$ui.BtnSpaceScan.Add_Click({ Start-DiskScan $script:SpaceDrive $null })
$ui.BtnFreeSafe.Add_Click({ if ($script:SafeJunkIds) { Start-Run @($script:SafeJunkIds) ([bool]$ui.ChkRestore.IsChecked) 'tasks' 'Liberar espaço'; $script:SpaceStale = $true } })
$ui.BtnFolderUp.Add_Click({
    if ($script:FolderStack.Count) { $script:FolderStack.RemoveAt($script:FolderStack.Count - 1) }
    $p = if ($script:FolderStack.Count) { $script:FolderStack[$script:FolderStack.Count - 1] } else { "$($script:SpaceDrive)\" }
    Render-Folders $p $script:FolderCache[$p]
})
$ui.BtnSysRestore.Add_Click({ Start-Process "$env:windir\System32\rstrui.exe" })

# monitor
$ui.BtnSortCpu.Add_Click({ $sync.ProcSort = 'cpu' })
$ui.BtnSortRam.Add_Click({ $sync.ProcSort = 'ram' })
$ui.BtnKill.Add_Click({
    $item = $ui.ProcList.SelectedItem
    if (-not $item) { Show-Msg 'Clique primeiro num programa da lista.' | Out-Null; return }
    $name = [string]$item.Tag
    if ($ProtectedProcs -contains $name.ToLower()) {
        Show-Msg "'$name' faz parte do Windows (ou é o próprio TurboPC) e não deve ser encerrado." 'OK' 'Warning' | Out-Null
        return
    }
    if ((Show-Msg "Encerrar '$name'? O que não foi salvo nesse programa será perdido." 'YesNo' 'Warning') -ne 'Yes') { return }
    Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object Id -ne $PID | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-TLog "Monitor: programa encerrado: $name" 'OK'
})

# programas
$ui.TxtAppSearch.Add_TextChanged({ Filter-Apps })
$ui.BtnInstall.Add_Click({ Start-AppJob 'install' @($AppCatalog | Where-Object { $script:AppBoxes[$_.Id].IsChecked }) })
$ui.BtnUninstall.Add_Click({ Start-AppJob 'uninstall' @($AppCatalog | Where-Object { $script:AppBoxes[$_.Id].IsChecked }) })
$ui.BtnUpgradeAll.Add_Click({ Start-AppJob 'upgrade' @() })
$ui.BtnInstallChoco.Add_Click({
    Start-AppJob 'install' @([pscustomobject]@{ Name = 'Chocolatey'; Winget = 'Chocolatey.Chocolatey'; Choco = ''; Source = 'winget' })
})
$ui.BtnGetWinget.Add_Click({ Start-Process 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1' })
$ui.BtnAppsNone.Add_Click({ foreach ($cb in $script:AppBoxes.Values) { $cb.IsChecked = $false } })

$ui.Tabs.Add_SelectionChanged({
    param($s, $e)
    if ($e.OriginalSource -ne $ui.Tabs) { return }
    $sel = $ui.Tabs.SelectedItem
    $sync.MonActive = ($sel -eq $ui.TabHome)
    $ui.FooterTasks.Visibility = if ($sel -eq $ui.TabOpt) { 'Visible' } else { 'Collapsed' }
    if ($sel -eq $ui.TabHome) { Update-Drives }
    if ($sel -eq $ui.TabSpace -and $script:SpaceStale -and -not $sync.DiskBusy) { Start-DiskScan $script:SpaceDrive $null }
    if ($sel -eq $ui.TabProg -and -not $script:AppsLoaded) {
        $ui.StatusText.Text = 'Verificando programas instalados...'
        Load-Apps
        $ui.StatusText.Text = 'Pronto.'
    }
})

foreach ($n in 'AllLimpeza','AllDesempenho','AllPrivacidade','AllJogos','AllAjustes','AllReparo') {
    $ui[$n].Add_Click({
        param($s)
        foreach ($t in ($TTasks | Where-Object Cat -eq $s.Tag)) { $script:CheckMap[$t.Id].IsChecked = $true }
    })
}

$ui.BtnReloadStartup.Add_Click({ [void](Load-Startup) })
$ui.BtnSaveStartup.Add_Click({
    $changed = 0
    foreach ($cb in $script:StartupBoxes) {
        $e = $cb.Tag
        if ([bool]$cb.IsChecked -ne $e.Enabled) {
            try {
                Set-StartupEntry $e ([bool]$cb.IsChecked)
                $e.Enabled = [bool]$cb.IsChecked
                Write-TLog ("Inicialização: {0} -> {1}" -f $e.Name, $(if ($e.Enabled) { 'ativado' } else { 'desativado' })) 'OK'
                $changed++
            } catch {
                Write-TLog "Inicialização: falha em $($e.Name): $($_.Exception.Message)" 'ERRO'
            }
        }
    }
    Show-Msg "$changed alteração(ões) salva(s). Vale a partir do próximo login." | Out-Null
})

$window.Add_ContentRendered({
    $mrs = [runspacefactory]::CreateRunspace()
    $mrs.Open()
    $script:monPS = [powershell]::Create()
    $script:monPS.Runspace = $mrs
    [void]$script:monPS.AddScript($monitorWorker.ToString()).AddArgument($sync)
    [void]$script:monPS.BeginInvoke()
    $ui.StatusText.Text = 'Lendo informações do computador...'
    $ui.FooterTasks.Visibility = 'Collapsed'
    [void](Load-Startup)
    Load-History
    Update-Info
    Update-Drives
    $sync.MonActive = $true
    $ui.StatusText.Text = 'Vendo para que este PC é usado...'
    Initialize-Usage
    # barra lateral fica no modelo visual das abas: os elementos dela são achados por lá
    $tpl = $ui.Tabs.Template
    $tpl.FindName('VersionText', $ui.Tabs).Text = "v$AppVersion"
    $script:BtnUpdate = $tpl.FindName('BtnUpdate', $ui.Tabs)
    $script:TxtUpdate = $tpl.FindName('TxtUpdate', $ui.Tabs)
    $script:BtnUpdate.Add_Click({ if ($script:PendingUpdate) { Install-Update $script:PendingUpdate } else { Start-UpdateCheck -Manual } })
    if ($IsCompiled) { Remove-Item -Path (Join-Path (Split-Path $ExePath) 'TurboPC*.exe.old') -Force -ErrorAction SilentlyContinue }
    Start-UpdateCheck
    $lastFps = @(Get-FpsHistory) | Select-Object -Last 1
    if ($lastFps) { Render-FpsResult $lastFps @(Get-FpsHistory | Select-Object -SkipLast 1) }
    $ui.StatusText.Text = 'Pronto. Escolha um modo no Painel.'
})

$window.Add_Closing({
    param($s, $e)
    if ($sync.Running) {
        Show-Msg 'Aguarde a otimização terminar antes de fechar.' 'OK' 'Warning' | Out-Null
        $e.Cancel = $true
        return
    }
    $sync.Quit = $true
})

Write-TLog "TurboPC $AppVersion (por $AppAuthor) iniciado em $env:COMPUTERNAME"
[void]$window.ShowDialog()
$timer.Stop()
$sync.Quit = $true
if ($script:monPS) { try { $script:monPS.Stop(); $script:monPS.Runspace.Dispose(); $script:monPS.Dispose() } catch {} }
