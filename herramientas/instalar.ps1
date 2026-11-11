# Timbre Escolar - instalador para Windows 10/11
# Se lanza con INSTALAR.bat (doble clic). Pide permisos de administrador.
param(
    [string]$UsuarioTimbre = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$NombreTarea      = "Timbre Escolar"
$TareaHora        = "Timbre Escolar - Sincronizar hora"
$TareaBloqueo     = "Timbre Escolar - Bloquear pantalla"
$Instal           = "C:\TimbreEscolar"
$Origen           = Split-Path $PSScriptRoot -Parent
$VersionesPython  = @("3.12.10", "3.11.9")

# ---------------------------------------------------------------- elevación
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) {
    if (-not $UsuarioTimbre) { $UsuarioTimbre = "$env:USERDOMAIN\$env:USERNAME" }
    Write-Host "Se necesitan permisos de administrador. Acepta el aviso de Windows..." -ForegroundColor Yellow
    $argumentos = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -UsuarioTimbre `"$UsuarioTimbre`""
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argumentos
    exit
}
if (-not $UsuarioTimbre) { $UsuarioTimbre = "$env:USERDOMAIN\$env:USERNAME" }

# Si algo falla, mostrar el error y esperar (si no, la ventana se cerraría sin verlo)
trap {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Linea: $($_.InvocationInfo.ScriptLineNumber)  -  $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch {}
    Read-Host "La instalacion no ha terminado. Pulsa Intro para salir"
    exit 1
}
if (-not (Test-Path (Join-Path $Origen "timbre.py"))) {
    Write-Host "No se encuentra timbre.py junto al instalador." -ForegroundColor Red
    Write-Host "Descomprime primero el archivo ZIP completo (clic derecho > Extraer todo) y ejecuta INSTALAR.bat desde la carpeta extraida."
    Read-Host "Pulsa Intro para salir"; exit 1
}

function Titulo($t) { Write-Host ""; Write-Host "== $t ==" -ForegroundColor Cyan }
function Ok($t)     { Write-Host "  [OK] $t" -ForegroundColor Green }
function Aviso($t)  { Write-Host "  [!]  $t" -ForegroundColor Yellow }
function Preguntar($texto, $defecto) {
    $r = Read-Host "$texto [$defecto]"
    if ([string]::IsNullOrWhiteSpace($r)) { return $defecto } else { return $r.Trim() }
}
function PreguntarSiNo($texto, $defecto = $true) {
    $d = if ($defecto) { "S/n" } else { "s/N" }
    $r = Read-Host "$texto ($d)"
    if ([string]::IsNullOrWhiteSpace($r)) { return $defecto }
    return $r.Trim().ToLower().StartsWith("s")
}
function TextoPlano($seguro) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seguro)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

Clear-Host
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "            INSTALACION DEL TIMBRE ESCOLAR"                    -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "Se configurara este PC para que, aunque se apague o se reinicie:"
Write-Host "  1. Windows entre solo en el usuario del timbre"
Write-Host "  2. El timbre arranque solo (y se relance si se cierra)"
Write-Host "  3. La hora se sincronice automaticamente por Internet"
Write-Host "  4. El PC no se suspenda"
Write-Host ""

# ---------------------------------------------------------------- preguntas
Titulo "Datos de configuracion"
$UsuarioTimbre = Preguntar "Usuario de Windows que usara el timbre" $UsuarioTimbre
if ($UsuarioTimbre -notmatch "\\") { $UsuarioTimbre = "$env:COMPUTERNAME\$UsuarioTimbre" }
$Dominio, $Usuario = $UsuarioTimbre.Split("\", 2)

$autologon = PreguntarSiNo "Iniciar sesion automaticamente con '$Usuario' al encender el PC?" $true
$Clave = $null
if ($autologon) {
    while ($true) {
        $Clave = TextoPlano (Read-Host "Contrasena de Windows de '$Usuario' (vacia si no tiene)" -AsSecureString)
        $valida = $null
        try {
            Add-Type -AssemblyName System.DirectoryServices.AccountManagement
            $tipo = if ($Dominio -ieq $env:COMPUTERNAME) { "Machine" } else { "Domain" }
            $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext($tipo, $Dominio)
            $valida = $ctx.ValidateCredentials($Usuario, $Clave)
        } catch { $valida = $null }
        if ($valida -eq $true) { Ok "Contrasena comprobada"; break }
        if ($valida -eq $false -and $Clave -ne "") {
            Aviso "Windows no ha aceptado esa contrasena."
            if (PreguntarSiNo "Volver a escribirla?" $true) { continue }
        }
        if ($Clave -eq "") { Aviso "Sin contrasena: el inicio automatico funcionara si la cuenta realmente no tiene contrasena." }
        break
    }
}
$Puerto = [int](Preguntar "Puerto del panel web" "8080")
$ClavePanel = Read-Host "Contrasena para el panel web (usuario 'admin'; vacia = sin contrasena)"
$bloquear = $false
if ($autologon) {
    $bloquear = PreguntarSiNo "Bloquear la pantalla 45 s despues de iniciar sesion? (el timbre sigue sonando con la pantalla bloqueada)" $true
}

Write-Host ""
Write-Host "Acceso desde fuera del colegio (timbre.virtuscollege.com) con Cloudflare Tunnel:"
Write-Host "pega el token del tunel (Cloudflare Zero Trust > Networks > Tunnels). Vacio = no configurar / dejar como esta."
$TokenTunel = (Read-Host "Token de Cloudflare Tunnel").Trim()
if ($TokenTunel) {
    # admite pegar el comando completo (incluso dos veces): se queda con el primer token
    $mTok = [regex]::Match($TokenTunel, "eyJ[A-Za-z0-9+/_-]{40,}={0,2}")
    if ($mTok.Success) { $TokenTunel = $mTok.Value } else { Aviso "No parece un token de Cloudflare; se omite el tunel"; $TokenTunel = "" }
}

New-Item -ItemType Directory -Force -Path "$Instal\datos" | Out-Null
try { Start-Transcript -Path "$Instal\datos\instalacion.log" -Append | Out-Null } catch {}

# ---------------------------------------------------------------- detener versión anterior
Titulo "Preparando"
foreach ($t in @($NombreTarea, $TareaBloqueo)) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    }
}
Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*timbre.py*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
Ok "Versiones anteriores detenidas"

# ---------------------------------------------------------------- copiar archivos
Titulo "Copiando el programa a $Instal"
if ((Resolve-Path $Origen).Path.TrimEnd("\") -ine $Instal) {
    Get-ChildItem -LiteralPath $Origen | Where-Object { $_.Name -ne "datos" } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Instal -Recurse -Force
    }
    if ((Test-Path "$Origen\datos\config.json") -and -not (Test-Path "$Instal\datos\config.json")) {
        Copy-Item "$Origen\datos\config.json" "$Instal\datos\config.json"
    }
    Ok "Archivos copiados (la configuracion existente se conserva)"
} else {
    Ok "Ya esta en $Instal"
}

# ---------------------------------------------------------------- Python
Titulo "Python"
$Pythonw = "$Instal\python\pythonw.exe"
if (-not (Test-Path $Pythonw)) {
    $arq = switch ($env:PROCESSOR_ARCHITECTURE) { "ARM64" { "arm64" } "AMD64" { "amd64" } default { "win32" } }
    foreach ($v in $VersionesPython) {
        $url = "https://www.python.org/ftp/python/$v/python-$v-embed-$arq.zip"
        $zip = Join-Path $env:TEMP "python-embed-timbre.zip"
        try {
            Write-Host "  Descargando Python portatil $v ($arq)..."
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
            Expand-Archive -LiteralPath $zip -DestinationPath "$Instal\python" -Force
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            break
        } catch {
            Aviso "No se pudo descargar $url"
        }
    }
}
if (-not (Test-Path $Pythonw)) {
    # Plan B: Python ya instalado en el equipo
    $candidatos = @()
    try { $candidatos += (& py -3 -c "import sys;print(sys.executable)" 2>$null) } catch {}
    $candidatos += (Get-Command python.exe -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
    foreach ($c in $candidatos) {
        if (-not $c -or $c -like "*WindowsApps*") { continue }
        $w = Join-Path (Split-Path $c) "pythonw.exe"
        if (Test-Path $w) {
            $ver = & $c -c "import sys;print(sys.version_info >= (3,8))"
            if ($ver -eq "True") { $Pythonw = $w; break }
        }
    }
}
if (-not (Test-Path $Pythonw)) {
    Write-Host ""
    Write-Host "No se ha encontrado Python y no se pudo descargar (sin Internet?)." -ForegroundColor Red
    Write-Host "Instala Python desde python.org (para todos los usuarios) y vuelve a ejecutar INSTALAR.bat."
    Read-Host "Pulsa Intro para salir"; exit 1
}
Ok "Python: $Pythonw"

# Permisos de escritura para el usuario del timbre
& icacls.exe $Instal /grant "${UsuarioTimbre}:(OI)(CI)M" /T /Q | Out-Null
Ok "Permisos de la carpeta para $UsuarioTimbre"

# Generar sonidos y configuración inicial (prueba rápida de que Python funciona)
$PythonConsola = Join-Path (Split-Path $Pythonw) "python.exe"
& $PythonConsola -c "import sys; sys.path.insert(0, r'$Instal'); import timbre; timbre.crear_sonidos_por_defecto()"
if ($LASTEXITCODE -ne 0) { Aviso "Python no ha podido ejecutar timbre.py (revisa el mensaje de arriba)" } else { Ok "Programa comprobado" }

# Logo y favicon oficiales de Virtus College para el panel (funciona sin Internet una vez descargados)
New-Item -ItemType Directory -Force -Path "$Instal\web\marca" | Out-Null
$marca = @{
    "logo-positivo.svg" = "https://virtuscollege.com/wp-content/uploads/2025/07/Logo-Virtus-College-2025-positivo.svg"
    "logo-negativo.png" = "https://virtuscollege.com/wp-content/uploads/2025/06/%E2%80%A2Logo-Virtus-College-2025-ok-01-1024x417.png"
    "favicon.png"       = "https://virtuscollege.com/wp-content/uploads/2025/12/cropped-favicon_virtus_college_of_madrid.png"
}
$okMarca = 0
foreach ($k in $marca.Keys) {
    $dest = "$Instal\web\marca\$k"
    if (Test-Path $dest) { $okMarca++; continue }
    try { Invoke-WebRequest -Uri $marca[$k] -OutFile $dest -UseBasicParsing; $okMarca++ } catch {}
}
if ($okMarca -eq $marca.Count) { Ok "Logo de Virtus College guardado para el panel" }
else { Aviso "No se pudo descargar el logo de Virtus (el panel lo cargara de virtuscollege.com cuando haya Internet)" }

# ---------------------------------------------------------------- tarea: timbre
Titulo "Arranque automatico del timbre"
$argumentosTimbre = "`"$Instal\timbre.py`" --puerto $Puerto"
if ($ClavePanel) { $argumentosTimbre += " --clave `"$ClavePanel`"" }
$accion = New-ScheduledTaskAction -Execute $Pythonw -Argument $argumentosTimbre -WorkingDirectory $Instal
$alEntrar = New-ScheduledTaskTrigger -AtLogOn -User $UsuarioTimbre
try {
    # Vigilancia: cada 5 minutos se intenta arrancar; si ya está en marcha no hace nada.
    $alEntrar.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)).Repetition
} catch { Aviso "No se pudo activar la vigilancia cada 5 minutos (se usara solo el reinicio por fallo)" }
$principal = New-ScheduledTaskPrincipal -UserId $UsuarioTimbre -LogonType Interactive -RunLevel Limited
$ajustes = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -DontStopOnIdleEnd -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
$ajustes.Priority = 4
Register-ScheduledTask -TaskName $NombreTarea -Action $accion -Trigger $alEntrar -Principal $principal `
    -Settings $ajustes -Force -Description "Hace sonar el timbre del colegio. Panel: http://localhost:$Puerto" | Out-Null
Ok "Tarea '$NombreTarea': arranca al iniciar sesion '$Usuario', se vigila cada 5 min y se relanza si falla"

# ---------------------------------------------------------------- inicio de sesión automático
Titulo "Inicio de sesion automatico"
$winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
if ($autologon) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class LsaTimbre {
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr SystemName, ref LSA_OBJECT_ATTRIBUTES ObjectAttributes, uint DesiredAccess, out IntPtr PolicyHandle);
    [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr PolicyHandle, ref LSA_UNICODE_STRING KeyName, IntPtr PrivateData);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr PolicyHandle);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint Status);
    static LSA_UNICODE_STRING Cadena(string s) {
        LSA_UNICODE_STRING u = new LSA_UNICODE_STRING();
        u.Buffer = Marshal.StringToHGlobalUni(s);
        u.Length = (ushort)(s.Length * 2);
        u.MaximumLength = (ushort)(s.Length * 2 + 2);
        return u;
    }
    public static int Guardar(string clave, string valor) {
        LSA_OBJECT_ATTRIBUTES atr = new LSA_OBJECT_ATTRIBUTES();
        atr.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
        IntPtr politica;
        uint st = LsaOpenPolicy(IntPtr.Zero, ref atr, 0x000F0FFF, out politica);
        if (st != 0) return LsaNtStatusToWinError(st);
        LSA_UNICODE_STRING k = Cadena(clave);
        IntPtr datos = IntPtr.Zero;
        if (valor != null) {
            LSA_UNICODE_STRING v = Cadena(valor);
            datos = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(LSA_UNICODE_STRING)));
            Marshal.StructureToPtr(v, datos, false);
        }
        st = LsaStorePrivateData(politica, ref k, datos);
        LsaClose(politica);
        return st == 0 ? 0 : LsaNtStatusToWinError(st);
    }
}
"@
    Set-ItemProperty $winlogon -Name AutoAdminLogon    -Value "1"
    Set-ItemProperty $winlogon -Name DefaultUserName   -Value $Usuario
    Set-ItemProperty $winlogon -Name DefaultDomainName -Value $Dominio
    Remove-ItemProperty $winlogon -Name AutoLogonCount -ErrorAction SilentlyContinue
    $err = [LsaTimbre]::Guardar("DefaultPassword", $Clave)
    if ($err -eq 0) {
        # La contraseña queda cifrada como secreto LSA (igual que Autologon de Microsoft), no en texto plano
        Remove-ItemProperty $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
        Ok "Contrasena guardada cifrada (secreto LSA)"
    } else {
        Set-ItemProperty $winlogon -Name DefaultPassword -Value $Clave
        Aviso "No se pudo cifrar la contrasena (error $err); se ha guardado en el registro"
    }
    # Windows 10/11: permitir inicio automático aunque esté activada "solo Windows Hello"
    $pl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device"
    if (Test-Path $pl) { Set-ItemProperty $pl -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord }
    Ok "Windows entrara solo con '$Usuario' al encender o reiniciar"

    if ($bloquear) {
        $tb = New-ScheduledTaskTrigger -AtLogOn -User $UsuarioTimbre
        $tb.Delay = "PT45S"
        Register-ScheduledTask -TaskName $TareaBloqueo -Force `
            -Action (New-ScheduledTaskAction -Execute "rundll32.exe" -Argument "user32.dll,LockWorkStation") `
            -Trigger $tb -Principal (New-ScheduledTaskPrincipal -UserId $UsuarioTimbre -LogonType Interactive) `
            -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) | Out-Null
        Ok "La pantalla se bloqueara 45 s despues de entrar"
    } else {
        Unregister-ScheduledTask -TaskName $TareaBloqueo -Confirm:$false -ErrorAction SilentlyContinue
    }
} else {
    Aviso "Inicio automatico NO configurado: alguien tendra que entrar en Windows tras cada reinicio"
}

# ---------------------------------------------------------------- hora
Titulo "Sincronizacion de la hora"
$enDominio = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
& sc.exe config w32time start= auto | Out-Null
& sc.exe triggerinfo w32time delete | Out-Null
Start-Service w32time -ErrorAction SilentlyContinue
$cfgReg = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config"
# Corregir siempre, aunque el reloj esté muy desviado (pila de la placa gastada)
Set-ItemProperty $cfgReg -Name MaxPosPhaseCorrection -Value 0xFFFFFFFF -Type DWord
Set-ItemProperty $cfgReg -Name MaxNegPhaseCorrection -Value 0xFFFFFFFF -Type DWord
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient" -Name SpecialPollInterval -Value 3600 -Type DWord
if ($enDominio) {
    & w32tm.exe /config /syncfromflags:domhier /update | Out-Null
    Ok "Equipo en dominio: la hora se toma del servidor del colegio"
} else {
    & w32tm.exe /config "/manualpeerlist:hora.roa.es,0x9 es.pool.ntp.org,0x9 time.windows.com,0x9" /syncfromflags:manual /reliable:no /update | Out-Null
    Ok "Servidores: hora.roa.es (hora oficial de Espana), es.pool.ntp.org, time.windows.com - cada hora"
}
Restart-Service w32time -ErrorAction SilentlyContinue

# Tarea del sistema: sincroniza al arrancar y cada hora (aunque no haya nadie conectado)
$accHora = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c net start w32time & w32tm /resync /force"
$tArranque = New-ScheduledTaskTrigger -AtStartup
$tArranque.Delay = "PT1M"
try {
    $disparadoresHora = @($tArranque, (New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 1)))
} catch {
    $disparadoresHora = @($tArranque, (New-ScheduledTaskTrigger -Daily -At "07:00"))
}
Register-ScheduledTask -TaskName $TareaHora -Force -Action $accHora -Trigger $disparadoresHora `
    -Principal (New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest) `
    -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
               -ExecutionTimeLimit (New-TimeSpan -Minutes 5)) | Out-Null
try {
    # Permitir que el timbre (usuario normal) pida una resincronización si detecta desfase
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $svc.GetFolder("\").GetTask($TareaHora).SetSecurityDescriptor("D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;GRGX;;;AU)", 0)
} catch { Aviso "No se pudo permitir la resincronizacion desde el timbre (no es grave)" }
Start-ScheduledTask -TaskName $TareaHora
Ok "Sincronizacion al arrancar el PC y cada hora"
Start-Sleep -Seconds 4
$zona = Get-TimeZone
Write-Host "  Hora del PC: $((Get-Date).ToString('dd/MM/yyyy HH:mm:ss'))   Zona: $($zona.DisplayName)"
if ($zona.Id -notin @("Romance Standard Time", "GMT Standard Time")) {
    Aviso "Comprueba que la zona horaria es la correcta (Configuracion > Hora e idioma)"
}

# ---------------------------------------------------------------- sonidos de Windows
Titulo "Silenciar Windows (por la megafonia solo suena el timbre)"
try { & (Join-Path $PSScriptRoot "silenciar_windows.ps1") -Usuario $UsuarioTimbre -Desatendido }
catch { Aviso "No se pudieron silenciar los sonidos de Windows: $($_.Exception.Message)" }

# ---------------------------------------------------------------- energía y actualizaciones
Titulo "Energia y Windows Update"
& powercfg.exe /change standby-timeout-ac 0
& powercfg.exe /change hibernate-timeout-ac 0
& powercfg.exe /change standby-timeout-dc 0
& powercfg.exe /change hibernate-timeout-dc 0
Ok "El PC no se suspendera (la pantalla si puede apagarse)"
$wu = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
if (-not (Test-Path $wu)) { New-Item -Path $wu -Force | Out-Null }
Set-ItemProperty $wu -Name ActiveHoursStart -Value 7 -Type DWord
Set-ItemProperty $wu -Name ActiveHoursEnd -Value 20 -Type DWord
Set-ItemProperty $wu -Name SmartActiveHoursState -Value 0 -Type DWord -ErrorAction SilentlyContinue
Ok "Windows Update no reiniciara entre las 7:00 y las 20:00"

# ---------------------------------------------------------------- cortafuegos
Titulo "Cortafuegos"
Get-NetFirewallRule -DisplayName "Timbre Escolar*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName "Timbre Escolar (panel web)" -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort $Puerto -RemoteAddress LocalSubnet -Profile Any | Out-Null
New-NetFirewallRule -DisplayName "Timbre Escolar (programa)" -Direction Inbound -Action Allow `
    -Program $Pythonw -RemoteAddress LocalSubnet -Profile Any | Out-Null
Ok "Panel accesible desde la red local del colegio (puerto $Puerto)"

# ---------------------------------------------------------------- acceso remoto (Cloudflare Tunnel)
if ($TokenTunel) {
    Titulo "Acceso remoto: Cloudflare Tunnel"
    & (Join-Path $PSScriptRoot "conectar_cloudflare.ps1") -Token $TokenTunel -Desatendido
}

# ---------------------------------------------------------------- acceso directo
$escritorio = [Environment]::GetFolderPath("CommonDesktopDirectory")
Set-Content -Path "$escritorio\Timbre Escolar.url" -Encoding ASCII -Value @(
    "[InternetShortcut]", "URL=http://localhost:$Puerto/", "IconFile=$env:SystemRoot\System32\SndVol.exe", "IconIndex=0")
Ok "Acceso directo 'Timbre Escolar' en el escritorio"

# ---------------------------------------------------------------- arrancar ya
Titulo "Arrancando el timbre"
Start-ScheduledTask -TaskName $NombreTarea -ErrorAction SilentlyContinue
$cabeceras = @{}
if ($ClavePanel) {
    $cabeceras["Authorization"] = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:$ClavePanel"))
}
$enMarcha = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 1
    try {
        Invoke-WebRequest -Uri "http://localhost:$Puerto/api/estado" -Headers $cabeceras -UseBasicParsing -TimeoutSec 2 | Out-Null
        $enMarcha = $true; break
    } catch {}
}
if ($enMarcha) {
    Ok "Timbre en marcha"
    if (PreguntarSiNo "Hacer sonar el timbre ahora para probar los altavoces?" $true) {
        Invoke-WebRequest -Uri "http://localhost:$Puerto/api/tocar" -Method Post -Headers $cabeceras -UseBasicParsing `
            -ContentType "application/json" -Body '{"sonido":"timbre_electrico.wav","etiqueta":"Prueba de instalacion"}' | Out-Null
    }
    Start-Process "http://localhost:$Puerto/"
} else {
    Aviso "El timbre arrancara cuando el usuario '$Usuario' inicie sesion (o al reiniciar el PC)."
}

try { Stop-Transcript | Out-Null } catch {}
Write-Host ""
Write-Host "==============================================================" -ForegroundColor Green
Write-Host " INSTALACION TERMINADA" -ForegroundColor Green
Write-Host "==============================================================" -ForegroundColor Green
Write-Host " Panel:  http://localhost:$Puerto  (o http://$env:COMPUTERNAME`:$Puerto desde otro PC)"
if ($TokenTunel) { Write-Host " Remoto: https://timbre.virtuscollege.com  (protegido con Cloudflare Access)" }
Write-Host ""
Write-Host " IMPORTANTE - si el PC se apaga por un corte de luz:" -ForegroundColor Yellow
Write-Host " entra en la BIOS/UEFI (F2 o Supr al encender) y activa" -ForegroundColor Yellow
Write-Host " 'Restore on AC Power Loss' = 'Power On' (o 'AC Recovery')," -ForegroundColor Yellow
Write-Host " para que el PC se encienda solo cuando vuelva la corriente." -ForegroundColor Yellow
Write-Host ""
if (PreguntarSiNo "Reiniciar ahora el PC para comprobar que todo arranca solo?" $false) {
    Restart-Computer -Force
}
Read-Host "Pulsa Intro para cerrar"
