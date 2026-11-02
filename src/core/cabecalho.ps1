# [parte] Cabeçalho, parâmetros, versão e modo automático pelo nome do .exe
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
$AppVersion = '1.10.0'

# Quando compilado com ps2exe: um .exe com "Auto" no nome roda direto um modo (o nome do arquivo diz qual).
$ExePath    = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$IsCompiled = $ExePath -notmatch '\\(powershell|pwsh|powershell_ise)\.exe$'
if ($IsCompiled -and [IO.Path]::GetFileNameWithoutExtension($ExePath) -match 'auto') {
    $Auto = $true
    $exeName = [IO.Path]::GetFileNameWithoutExtension($ExePath)
    $Perfil = if ($exeName -match 'jogo') { 'Jogos' } elseif ($exeName -match 'escrit') { 'Escritorio' } elseif ($exeName -match 'max') { 'Maximo' } else { 'Recomendado' }
}

