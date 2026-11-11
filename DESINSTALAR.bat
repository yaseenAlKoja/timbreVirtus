@echo off
REM Timbre Escolar - desinstalador (doble clic).
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0herramientas\desinstalar.ps1"
