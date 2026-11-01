# [parte] Pede administrador e prepara a pasta de logs
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

