# [parte] Espaço em disco: análise em segundo plano (robocopy, OneDrive, coisas escondidas)
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

