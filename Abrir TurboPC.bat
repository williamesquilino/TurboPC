@echo off
rem Abre o TurboPC (pede permissao de administrador)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0TurboPC.ps1"
