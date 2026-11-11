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

function Estado-Tunel {
    # cloudflared publica su estado en 127.0.0.1:20241-20245/ready (readyConnections > 0 = conectado a Cloudflare)
    foreach ($puerto in 20241..20245) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$puerto/ready" -UseBasicParsing -TimeoutSec 2
            return [int](($r.Content | ConvertFrom-Json).readyConnections)
        } catch {
            if ($_.Exception.Response) {
                try {
                    $lector = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
                    return [int](($lector.ReadToEnd() | ConvertFrom-Json).readyConnections)
                } catch { return 0 }
            }
        }
    }
    return -1   # no se encontró cloudflared escuchando
}
function Huella($texto) {
    $sha = [Security.Cryptography.SHA256]::Create()
    (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($texto)) | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 12).ToUpper()
}

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
Ok "Token reconocido (huella $(Huella $token))"

Write-Host ""
Write-Host "Limpiando intentos anteriores..."
if (Get-Service -Name cloudflared -ErrorAction SilentlyContinue) {
    Stop-Service -Name cloudflared -Force -ErrorAction SilentlyContinue
    & sc.exe delete cloudflared | Out-Null
}
Get-Process -Name cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
# Esperar a que Windows borre de verdad el servicio anterior (si no, la instalación nueva falla)
for ($i = 0; $i -lt 20 -and (Get-Service -Name cloudflared -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 1 }
if (Get-Service -Name cloudflared -ErrorAction SilentlyContinue) {
    Write-Host ""
    Write-Host "Windows todavia esta borrando el servicio anterior de Cloudflare." -ForegroundColor Red
    Write-Host "REINICIA EL PC y, al volver, ejecuta otra vez CONECTAR_CLOUDFLARE.bat." -ForegroundColor Yellow
    Read-Host "Pulsa Intro para salir"; exit 1
}
Start-Sleep -Seconds 2
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
$salida = Join-Path $env:TEMP "cloudflared-install-out.txt"
$errores = Join-Path $env:TEMP "cloudflared-install-err.txt"
$inst = Start-Process -FilePath $cfExe -ArgumentList "service", "install", $token -Wait -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $salida -RedirectStandardError $errores
if ($inst.ExitCode -ne 0) {
    Aviso "cloudflared termino con codigo $($inst.ExitCode). Su mensaje:"
    (@(Get-Content $salida -ErrorAction SilentlyContinue) + @(Get-Content $errores -ErrorAction SilentlyContinue)) |
        Where-Object { $_ -and $_ -notmatch "eyJ" } | Select-Object -Last 6 | ForEach-Object { Write-Host "       $_" -ForegroundColor Yellow }
}
Remove-Item $salida, $errores -Force -ErrorAction SilentlyContinue
$enMarcha = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    $s = Get-Service -Name cloudflared -ErrorAction SilentlyContinue
    if ($s -and $s.Status -eq "Running") { $enMarcha = $true; break }
}
if (-not $enMarcha) {
    Aviso "El servicio no ha arrancado. Comprueba que el token es el actual (copialo de nuevo de Cloudflare)."
} else {
    Set-Service -Name cloudflared -StartupType Automatic
    Ok "Servicio del tunel en marcha (arranca solo con el PC)"
    Write-Host "Comprobando que Cloudflare acepta la conexion (hasta 40 s)..."
    $conexiones = -1
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 2
        $conexiones = Estado-Tunel
        if ($conexiones -gt 0) { break }
    }
    Write-Host ""
    if ($conexiones -gt 0) {
        Ok "CONECTADO a Cloudflare ($conexiones conexiones)"
        Write-Host "https://timbre.virtuscollege.com ya muestra el panel del timbre." -ForegroundColor Green
    } elseif ($conexiones -eq 0) {
        Write-Host "  [X]  Cloudflare RECHAZA la conexion: el token no es el actual." -ForegroundColor Red
        Write-Host "       Recarga la pagina de Cloudflare con F5, vuelve a copiar el comando y ejecuta otra vez CONECTAR_CLOUDFLARE.bat."
    } else {
        Aviso "No se pudo comprobar la conexion desde aqui. Pregunta a Claude si el tunel aparece conectado."
    }
}
Read-Host "Pulsa Intro para cerrar"
