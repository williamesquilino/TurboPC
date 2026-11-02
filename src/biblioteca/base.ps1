# [parte] Início da biblioteca de tarefas: log, registro, serviços, desfazer, limpeza e utilitários (roda na interface e na thread de execução)
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
            # S: o valor que o TurboPC gravou (o desfazer de política confere se ainda é ele)
            $rec = [ordered]@{ T = 'reg'; P = $Path; N = $Name; E = $false; KX = [bool]$key; S = $Value }
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
