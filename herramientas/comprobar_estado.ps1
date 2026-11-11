# Timbre Escolar - diagnóstico completo (solo lee, no cambia nada)
# Se lanza con COMPROBAR_ESTADO.bat desde la sesión que se quiere comprobar.
# NO pide permisos de administrador a propósito: así muestra el usuario real de esta sesión.
# Nunca muestra contraseñas ni el token de Cloudflare (solo una huella para compararlo).
$ErrorActionPreference = "SilentlyContinue"
function Titulo($t) { Write-Host ""; Write-Host "== $t ==" -ForegroundColor Cyan }
function Bien($t)   { Write-Host "  [OK] $t" -ForegroundColor Green }
function Mal($t)    { Write-Host "  [X]  $t" -ForegroundColor Red }
function Info($t)   { Write-Host "       $t" }

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

Clear-Host
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "        DIAGNOSTICO DEL TIMBRE ESCOLAR  $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan

# ---------------------------------------------------------------- usuario
Titulo "1. Usuario con el que estas ahora"
$yo = [Security.Principal.WindowsIdentity]::GetCurrent()
$yoNombre = $yo.Name                                # DOMINIO\usuario
$esAdmin = (New-Object Security.Principal.WindowsPrincipal($yo)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Info "Usuario de esta sesion : $yoNombre"
Info "Equipo                 : $env:COMPUTERNAME"
Info "Ventana como admin     : $(if ($esAdmin) { 'si' } else { 'no' })"
$cuenta = Get-LocalUser -Name $env:USERNAME
if ($cuenta) { Info "Tipo de cuenta         : local$(if ($cuenta.PrincipalSource -eq 'MicrosoftAccount') { ' (vinculada a cuenta Microsoft)' })" }
else { Info "Tipo de cuenta         : de dominio o Microsoft (no es una cuenta local)" }

# ---------------------------------------------------------------- inicio automático
Titulo "2. Inicio de sesion automatico (configurado por el instalador)"
$wl = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$autoUser = "$($wl.DefaultDomainName)\$($wl.DefaultUserName)"
if ($wl.AutoAdminLogon -eq "1") { Bien "Activado para: $autoUser" } else { Mal "Desactivado (Windows no entrara solo al reiniciar)" }
if ($wl.DefaultPassword) { Info "Aviso: hay una contrasena en texto plano en el registro (deberia estar cifrada)" }

# ---------------------------------------------------------------- tarea del timbre
Titulo "3. Tarea que arranca el timbre"
$tarea = Get-ScheduledTask -TaskName "Timbre Escolar"
if (-not $tarea) { Mal "No existe la tarea 'Timbre Escolar' (hay que ejecutar INSTALAR.bat)" }
else {
    $tareaUser = $tarea.Principal.UserId
    Info "Configurada para el usuario: $tareaUser"
    Info "Estado de la tarea         : $($tarea.State)"
    $infoT = Get-ScheduledTaskInfo -TaskName "Timbre Escolar"
    if ($infoT) { Info "Ultima ejecucion           : $($infoT.LastRunTime)  (resultado $($infoT.LastTaskResult))" }
}

# ---------------------------------------------------------------- comparación de usuarios
Titulo "4. Coinciden los usuarios?"
function Corto($n) { if ($n) { ($n -split "\\")[-1].ToLower() } else { "" } }
$c1 = Corto $yoNombre; $c2 = Corto $autoUser; $c3 = Corto $tareaUser
Info "Sesion actual: $c1   |   Inicio automatico: $c2   |   Tarea del timbre: $c3"
if ($c1 -eq $c2 -and $c2 -eq $c3) { Bien "Los tres coinciden" }
else {
    Mal "NO coinciden."
    if ($c1 -ne $c3) { Info "El timbre solo arranca en la sesion de '$c3'. En esta sesion ('$c1') no arrancara solo." }
    if ($c2 -ne $c3) { Info "Al reiniciar, Windows entrara con '$c2' pero el timbre esta configurado para '$c3'." }
    Info "Solucion: inicia sesion con el usuario correcto y vuelve a ejecutar INSTALAR.bat indicando ese usuario."
}

# ---------------------------------------------------------------- programa del timbre
Titulo "5. Programa del timbre"
$procs = Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" | Where-Object { $_.CommandLine -like "*timbre.py*" }
if ($procs) {
    foreach ($p in $procs) {
        $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner
        Bien "En marcha (PID $($p.ProcessId)) con el usuario $($o.Domain)\$($o.User)"
    }
} else { Mal "El programa del timbre NO esta en marcha" }
try {
    $r = Invoke-WebRequest -Uri "http://localhost:8080/api/estado" -UseBasicParsing -TimeoutSec 4
    Bien "El panel responde en http://localhost:8080"
} catch {
    if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401) { Bien "El panel responde en http://localhost:8080 (pide contrasena)" }
    else { Mal "El panel NO responde en http://localhost:8080" }
}
$log = "C:\TimbreEscolar\datos\registro.log"
if (Test-Path $log) { Info "Ultimas lineas del registro:"; Get-Content $log -Tail 4 -Encoding UTF8 | ForEach-Object { Info "  $_" } }

# ---------------------------------------------------------------- Cloudflare
Titulo "6. Tunel de Cloudflare (timbre.virtuscollege.com)"
$svc = Get-Service -Name cloudflared
if (-not $svc) { Mal "El servicio cloudflared no esta instalado (ejecuta CONECTAR_CLOUDFLARE.bat)" }
else {
    if ($svc.Status -eq "Running") { Bien "Servicio cloudflared en marcha" } else { Mal "Servicio cloudflared: $($svc.Status)" }
    $img = [string](Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\cloudflared").ImagePath
    $tok = [regex]::Match($img, "eyJ[A-Za-z0-9+/_-]{40,}={0,2}")
    $fich = [regex]::Match($img, '--token-file\s+"?([^"]+?)"?(\s+--|\s*$)')
    if ($tok.Success) { Info "Huella del token instalado: $(Huella $tok.Value)" }
    elseif ($fich.Success) {
        $ruta = $fich.Groups[1].Value.Trim()
        try {
            $contenido = (Get-Content -LiteralPath $ruta -Raw -ErrorAction Stop).Trim()
            Info "Huella del token instalado: $(Huella $contenido)   (comparala con la que te diga Claude)"
        } catch { Info "El token esta guardado en un archivo protegido (normal). Para ver su huella, ejecuta este diagnostico como administrador." }
    } else { Mal "El servicio no tiene token (se instalo sin el texto eyJ...)" }
    $con = Estado-Tunel
    if ($con -gt 0) { Bien "Conectado a Cloudflare ($con conexiones): timbre.virtuscollege.com funciona" }
    elseif ($con -eq 0) { Mal "Cloudflare RECHAZA la conexion: token antiguo. Recarga Cloudflare (F5), copia de nuevo y ejecuta CONECTAR_CLOUDFLARE.bat" }
    else { Info "No se pudo leer el estado de conexion de cloudflared" }
    $ev = Get-WinEvent -FilterHashtable @{ LogName = "Application"; ProviderName = "cloudflared" } -MaxEvents 4
    if ($ev) { Info "Ultimos mensajes de cloudflared:"; $ev | ForEach-Object { Info ("  " + $_.TimeCreated.ToString("HH:mm:ss") + "  " + (($_.Message -split "`n")[0]).Substring(0, [Math]::Min(110, (($_.Message -split "`n")[0]).Length))) } }
}
foreach ($dest in @("region1.v2.argotunnel.com", "api.cloudflare.com")) {
    $t = Test-NetConnection -ComputerName $dest -Port $(if ($dest -like "*argotunnel*") { 7844 } else { 443 }) -WarningAction SilentlyContinue
    if ($t.TcpTestSucceeded) { Bien "Conexion de salida a $dest correcta" } else { Mal "La red del colegio bloquea la salida a $dest" }
}

# ---------------------------------------------------------------- hora
Titulo "7. Hora"
Info "Hora del PC : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')   Zona: $((Get-TimeZone).DisplayName)"
$st = & w32tm /query /status 2>$null | Select-String -Pattern "Fuente|Source|ltima|Last Successful"
$st | ForEach-Object { Info $_.ToString().Trim() }

Write-Host ""
Write-Host "Haz una foto de esta ventana y mandasela a Claude (no contiene contrasenas ni el token)." -ForegroundColor Yellow
Read-Host "Pulsa Intro para cerrar"
