@echo off
REM Conecta (o reconecta) este PC a Cloudflare para timbre.virtuscollege.com
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0herramientas\conectar_cloudflare.ps1"
