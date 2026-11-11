@echo off
REM Arranca el timbre CON ventana para ver mensajes (diagnostico).
REM Si el timbre ya esta en marcha en segundo plano, avisara y se cerrara.
cd /d "%~dp0.."
title Timbre Escolar (diagnostico)
if exist "python\python.exe" ( "python\python.exe" timbre.py %* ) else ( py -3 timbre.py %* )
echo.
pause
