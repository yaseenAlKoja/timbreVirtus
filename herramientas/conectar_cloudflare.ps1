# Timbre Escolar - conectar (o reconectar) el PC a Cloudflare Tunnel
# Doble clic en CONECTAR_CLOUDFLARE.bat. Tambien lo usa INSTALAR.bat (con -Token y -Desatendido).
#
# No usa "cloudflared service install": ese comando borra y recrea el servicio, y Windows a veces lo
# deja "pendiente de eliminar" (codigo 1). Aqui el servicio se crea una vez y despues solo se
# reconfigura: el token va en un archivo que solo pueden leer SYSTEM y los administradores.
param(
    [string]$Token = "",
    [switch]$Desatendido
)
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Ok($t)    { Write-Host "  [OK] $t" -ForegroundColor Green }
function Aviso($t) { Write-Host "  [!]  $t" -ForegroundColor Yellow }
function Fallo($t) { Write-Host "  [X]  $t" -ForegroundColor Red }
function Pausa     { if (-not $Desatendido) { Read-Host "Pulsa Intro para cerrar" | Out-Null } }
function Huella($texto) {
    $sha = [Security.Cryptography.SHA256]::Create()
    (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($texto)) | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 12).ToUpper()
}
function Estado-Tunel {
    # cloudflared publica su estado en 127.0.0.1:20241/ready (readyConnections > 0 = conectado)
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:20241/ready" -UseBasicParsing -TimeoutSec 2
        return [int](($r.Content | ConvertFrom-Json).readyConnections)
    } catch {
        if ($_.Exception.Response) {
            try {
                $lector = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
                return [int](($lector.ReadToEnd() | ConvertFrom-Json).readyConnections)
            } catch { return 0 }
        }
        return -1
    }
}
trap {
    Fallo "ERROR: $($_.Exception.Message)"
    Pausa
    exit 1   # si lo llama INSTALAR.bat, solo termina este paso y la instalacion continua
}

$cfDir   = "C:\TimbreEscolar\cloudflared"
$cfExe   = "$cfDir\cloudflared.exe"
$tokFile = "$cfDir\token.txt"
$svcReg  = "HKLM:\SYSTEM\CurrentControlSet\Services\cloudflared"

if (-not $Desatendido) {
    Clear-Host
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "   CONECTAR EL TIMBRE A CLOUDFLARE (timbre.virtuscollege.com)"   -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "Abre Cloudflare EN ESTE PC: Networks > Tunnels > timbre-colegio > Configure > Windows."
    Write-Host "Pulsa F5, despues el boton de copiar del recuadro gris, y pegalo aqui (clic derecho) + Intro."
    Write-Host "No lo pegues en webs de copiar/pegar ni lo envies en fotos: es una clave secreta."
    Write-Host ""
    $Token = Read-Host "Pega aqui"
    Clear-Host   # que el token no quede a la vista en la ventana
}
$m = [regex]::Match([string]$Token, "eyJ[A-Za-z0-9+/_-]{40,}={0,2}")
if (-not $m.Success) { Fallo "No se ha encontrado el token (debe empezar por eyJ). Vuelve a copiarlo de Cloudflare."; Pausa; return }
$Token = $m.Value
Ok "Token reconocido (huella $(Huella $Token))"

# 1. Parar lo que haya en marcha (sin borrar el servicio)
if (Get-Service -Name cloudflared -ErrorAction SilentlyContinue) {
    Stop-Service -Name cloudflared -Force -ErrorAction SilentlyContinue
}
Get-Process -Name cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# 2. Programa cloudflared (se descarga si falta o esta dañado)
New-Item -ItemType Directory -Force -Path $cfDir | Out-Null
if (Test-Path $cfExe) {
    $v = Start-Process -FilePath $cfExe -ArgumentList "--version" -Wait -PassThru -WindowStyle Hidden
    if ($v.ExitCode -ne 0) { Remove-Item $cfExe -Force }
}
if (-not (Test-Path $cfExe)) {
    Write-Host "Descargando cloudflared (programa oficial de Cloudflare)..."
    $arq = if ($env:PROCESSOR_ARCHITECTURE -eq "x86") { "386" } else { "amd64" }
    Invoke-WebRequest -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-$arq.exe" `
        -OutFile $cfExe -UseBasicParsing
    $v = Start-Process -FilePath $cfExe -ArgumentList "--version" -Wait -PassThru -WindowStyle Hidden
    if ($v.ExitCode -ne 0) { throw "cloudflared.exe no funciona en este equipo (codigo $($v.ExitCode))" }
}
Ok "Programa cloudflared listo"

# 3. Token en un archivo protegido (solo SYSTEM y Administradores)
Set-Content -LiteralPath $tokFile -Value $Token -NoNewline -Encoding ASCII
& icacls.exe $tokFile /inheritance:r /grant:r "*S-1-5-18:F" "*S-1-5-32-544:F" | Out-Null
Ok "Token guardado en un archivo protegido"

# 4. Servicio de Windows: se crea si no existe; si existe, solo se reconfigura
$bin = "`"$cfExe`" tunnel --no-autoupdate --metrics 127.0.0.1:20241 run --token-file `"$tokFile`""
if (Get-Service -Name cloudflared -ErrorAction SilentlyContinue) {
    Set-ItemProperty -Path $svcReg -Name ImagePath -Value $bin
    Set-Service -Name cloudflared -StartupType Automatic
} else {
    New-Service -Name cloudflared -DisplayName "Cloudflared (Timbre Escolar)" -BinaryPathName $bin `
        -StartupType Automatic -Description "Conecta el timbre a timbre.virtuscollege.com" | Out-Null
}
& sc.exe failure cloudflared reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
Ok "Servicio configurado (arranca solo con el PC y se reinicia si falla)"

# 5. Arrancar y comprobar que Cloudflare acepta la conexion
try { Start-Service -Name cloudflared }
catch {
    Fallo "Windows no deja arrancar el servicio: $($_.Exception.Message)"
    Write-Host "       Reinicia el PC y vuelve a ejecutar CONECTAR_CLOUDFLARE.bat." -ForegroundColor Yellow
    Pausa; return
}
Write-Host "Comprobando la conexion con Cloudflare (hasta 45 s)..."
$conexiones = -1
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 3
    $conexiones = Estado-Tunel
    if ($conexiones -gt 0) { break }
}
Write-Host ""
if ($conexiones -gt 0) {
    Ok "CONECTADO a Cloudflare ($conexiones conexiones)"
    Write-Host "  https://timbre.virtuscollege.com ya muestra el panel del timbre." -ForegroundColor Green
} elseif ($conexiones -eq 0) {
    Fallo "Cloudflare RECHAZA la conexion: el token no es el actual."
    Write-Host "       En Cloudflare pulsa F5, vuelve a copiar el comando y ejecuta otra vez CONECTAR_CLOUDFLARE.bat."
} else {
    $s = Get-Service -Name cloudflared -ErrorAction SilentlyContinue
    Aviso "No se pudo leer el estado de cloudflared (servicio: $($s.Status)). Pregunta a Claude si el tunel aparece conectado."
}
Pausa
