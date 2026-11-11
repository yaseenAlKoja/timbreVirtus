# Timbre Escolar - conectar (o reconectar) el PC a Cloudflare Tunnel
# Se lanza con CONECTAR_CLOUDFLARE.bat. No toca horarios ni el resto de la instalación.
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
trap {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "Pulsa Intro para salir"
    exit 1
}
function Ok($t)    { Write-Host "  [OK] $t" -ForegroundColor Green }
function Aviso($t) { Write-Host "  [!]  $t" -ForegroundColor Yellow }

$cfDir = "C:\TimbreEscolar\cloudflared"
$cfExe = "$cfDir\cloudflared.exe"

Clear-Host
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "   CONECTAR EL TIMBRE A CLOUDFLARE (timbre.virtuscollege.com)"   -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "En Cloudflare: Networks > Tunnels > timbre-colegio > Configure > Windows,"
Write-Host "pulsa el boton de copiar del recuadro gris y pegalo aqui (clic derecho) y pulsa Intro."
Write-Host ""
$texto = Read-Host "Pega aqui"
# Coge solo el primer token aunque se haya pegado el comando entero o dos veces
$m = [regex]::Match($texto, "eyJ[A-Za-z0-9+/_-]{40,}={0,2}")
if (-not $m.Success) {
    Write-Host "No se ha encontrado el token (debe empezar por eyJ). Vuelve a copiarlo desde Cloudflare." -ForegroundColor Red
    Read-Host "Pulsa Intro para salir"; exit 1
}
$token = $m.Value
Ok "Token reconocido ($($token.Length) caracteres)"

Write-Host ""
Write-Host "Limpiando intentos anteriores..."
if (Get-Service -Name cloudflared -ErrorAction SilentlyContinue) {
    Stop-Service -Name cloudflared -Force -ErrorAction SilentlyContinue
    & sc.exe delete cloudflared | Out-Null
}
Get-Process -Name cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
New-Item -ItemType Directory -Force -Path $cfDir | Out-Null
if (Test-Path $cfExe) {
    try { Remove-Item $cfExe -Force }
    catch {
        Write-Host "El archivo cloudflared.exe sigue bloqueado. Reinicia el PC y vuelve a ejecutar CONECTAR_CLOUDFLARE.bat." -ForegroundColor Red
        Read-Host "Pulsa Intro para salir"; exit 1
    }
}
Ok "Limpio"

Write-Host "Descargando cloudflared (programa oficial de Cloudflare)..."
$arq = if ($env:PROCESSOR_ARCHITECTURE -eq "x86") { "386" } else { "amd64" }
Invoke-WebRequest -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-$arq.exe" `
    -OutFile $cfExe -UseBasicParsing
$ver = Start-Process -FilePath $cfExe -ArgumentList "--version" -Wait -PassThru -WindowStyle Hidden
if ($ver.ExitCode -ne 0) { throw "cloudflared.exe no funciona en este equipo (codigo $($ver.ExitCode))" }
Ok "cloudflared descargado y comprobado"

Write-Host "Instalando el servicio del tunel..."
$inst = Start-Process -FilePath $cfExe -ArgumentList "service", "install", $token -Wait -PassThru -WindowStyle Hidden
if ($inst.ExitCode -ne 0) { Aviso "cloudflared termino con codigo $($inst.ExitCode)" }
$enMarcha = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    $s = Get-Service -Name cloudflared -ErrorAction SilentlyContinue
    if ($s -and $s.Status -eq "Running") { $enMarcha = $true; break }
}
if ($enMarcha) {
    Set-Service -Name cloudflared -StartupType Automatic
    Ok "Tunel instalado y en marcha (arranca solo con el PC)"
    Write-Host ""
    Write-Host "En 1 minuto, https://timbre.virtuscollege.com mostrara el panel del timbre." -ForegroundColor Green
} else {
    Aviso "El servicio no ha arrancado. Comprueba que el token es el actual (copialo de nuevo de Cloudflare)."
}
Read-Host "Pulsa Intro para cerrar"
