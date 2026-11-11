@echo off
REM Timbre Escolar - instalador (doble clic). Pedira permisos de administrador.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0herramientas\instalar.ps1"
