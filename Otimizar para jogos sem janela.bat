@echo off
rem Executa o perfil Jogos sem interface. Precisa ser executado como administrador.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TurboPC.ps1" -Auto -Perfil Jogos
pause
