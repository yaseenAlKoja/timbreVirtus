# Timbre Escolar - silenciar los sonidos de Windows para que por la megafonía solo suene el timbre.
# Quita: sonido de inicio de Windows, sonidos del sistema (avisos, errores, inicio/cierre de sesión,
# bloqueo, USB...), sonidos y avisos de notificaciones (Outlook, Teams, Edge...) y la bajada
# automática de volumen de Windows. El timbre no se ve afectado.
#
# Uso: doble clic en SILENCIAR_WINDOWS.bat desde la sesión del usuario del timbre.
# INSTALAR.bat lo llama con -Usuario para aplicarlo al usuario del timbre.
param(
    [string]$Sid = "",
    [string]$Usuario = "",
    [switch]$Desatendido
)
function Ok($t)    { Write-Host "  [OK] $t" -ForegroundColor Green }
function Aviso($t) { Write-Host "  [!]  $t" -ForegroundColor Yellow }

# Quién: el usuario de esta sesión (antes de pedir permisos, para no confundirlo con el administrador)
if (-not $Sid) {
    if ($Usuario) { $Sid = (New-Object Security.Principal.NTAccount($Usuario)).Translate([Security.Principal.SecurityIdentifier]).Value }
    else { $Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
}
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Sid $Sid"
    exit
}

if (-not $Desatendido) {
    Clear-Host
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "   SILENCIAR WINDOWS: por la megafonia solo sonara el timbre"     -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
}
$nombre = $Sid
try { $nombre = (New-Object Security.Principal.SecurityIdentifier($Sid)).Translate([Security.Principal.NTAccount]).Value } catch {}

# Rama del registro del usuario (HKEY_USERS\SID: existe mientras ese usuario tiene la sesión abierta)
$hku = "Registry::HKEY_USERS\$Sid"
if (-not (Test-Path $hku)) {
    Aviso "El usuario $nombre no tiene la sesion abierta: inicia sesion con el y vuelve a ejecutar SILENCIAR_WINDOWS.bat"
} else {
    # 1. Combinación de sonidos "Sin sonidos": vaciar todos los eventos
    New-Item -Path "$hku\AppEvents\Schemes" -Force | Out-Null
    Set-ItemProperty -Path "$hku\AppEvents\Schemes" -Name "(default)" -Value ".None"
    $vaciados = 0
    Get-ChildItem -Path "$hku\AppEvents\Schemes\Apps" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -eq ".Current" } | ForEach-Object {
            Set-ItemProperty -Path $_.PSPath -Name "(default)" -Value ""
            $vaciados++
        }
    Ok "Sonidos del sistema desactivados ($vaciados eventos) para $nombre"

    # 2. Notificaciones: sin sonido y sin avisos emergentes (Outlook, Teams, Edge, Windows...)
    $not = "$hku\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"
    New-Item -Path $not -Force | Out-Null
    Set-ItemProperty -Path $not -Name "NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND" -Value 0 -Type DWord
    Set-ItemProperty -Path $not -Name "NOC_GLOBAL_SETTING_ALLOW_CRITICAL_TOASTS_ABOVE_LOCK" -Value 0 -Type DWord
    $push = "$hku\Software\Microsoft\Windows\CurrentVersion\PushNotifications"
    New-Item -Path $push -Force | Out-Null
    Set-ItemProperty -Path $push -Name "ToastEnabled" -Value 0 -Type DWord
    Ok "Notificaciones desactivadas (sin sonido ni ventanas emergentes)"

    # 3. Que Windows no baje el volumen solo (atenuación por comunicaciones)
    $aud = "$hku\Software\Microsoft\Multimedia\Audio"
    New-Item -Path $aud -Force | Out-Null
    Set-ItemProperty -Path $aud -Name "UserDuckingPreference" -Value 3 -Type DWord
    Ok "Windows no bajara el volumen automaticamente"
}

# 4. Sonido de inicio de Windows (para todo el equipo)
$boot = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation"
New-Item -Path $boot -Force | Out-Null
Set-ItemProperty -Path $boot -Name "DisableStartupSound" -Value 1 -Type DWord
$pol = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
New-Item -Path $pol -Force | Out-Null
Set-ItemProperty -Path $pol -Name "DisableStartupSound" -Value 1 -Type DWord
Ok "Sonido de inicio de Windows desactivado"

# 5. Programas que se abren solos y pueden sonar (solo se avisa, no se tocan)
$sospechosos = Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue |
    Where-Object { $_.Command -match "teams|outlook|olk|spotify|whatsapp|discord|zoom|skype" } |
    Select-Object -ExpandProperty Name -Unique
if ($sospechosos) {
    Aviso "Estos programas se abren al iniciar y podrian sonar: $($sospechosos -join ', ')"
    Write-Host "       Quitalos en Administrador de tareas > Aplicaciones de arranque si no se usan en este PC."
}
Write-Host ""
Write-Host "Listo. Algunos cambios se aplican del todo al cerrar sesion o reiniciar." -ForegroundColor Green
if (-not $Desatendido) { Read-Host "Pulsa Intro para cerrar" | Out-Null }
