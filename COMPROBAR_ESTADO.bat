@echo off
REM Diagnostico del timbre: usuario, tarea, programa, Cloudflare y hora. Solo lee, no cambia nada.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0herramientas\comprobar_estado.ps1"
