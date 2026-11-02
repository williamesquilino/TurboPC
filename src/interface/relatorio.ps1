# [parte] Exportar relatório HTML
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

