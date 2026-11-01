# [parte] Atualização automática pelas releases do GitHub
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

