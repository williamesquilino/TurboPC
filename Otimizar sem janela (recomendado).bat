@echo off
rem Aplica o modo Recomendado sem interface (so o que nao muda nada que a pessoa use). Bom para varios PCs (GPO, RMM, pendrive).
rem Precisa ser executado como administrador. Outros modos: -Perfil Escritorio / Jogos / Maximo / Gpu
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TurboPC.ps1" -Auto -Perfil Recomendado
pause
