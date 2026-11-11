@echo off
REM Silencia los sonidos de Windows (inicio, avisos, notificaciones) para que por la megafonia solo suene el timbre.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0herramientas\silenciar_windows.ps1"
