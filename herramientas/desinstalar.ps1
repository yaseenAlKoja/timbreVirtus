# Timbre Escolar - desinstalador para Windows
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
Write-Host "Desinstalando el Timbre Escolar..." -ForegroundColor Cyan
foreach ($t in @("Timbre Escolar", "Timbre Escolar - Bloquear pantalla", "Timbre Escolar - Sincronizar hora")) {
    Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
}
Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*timbre.py*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$cfExe = "C:\TimbreEscolar\cloudflared\cloudflared.exe"
if ((Get-Service -Name cloudflared -ErrorAction SilentlyContinue) -and (Test-Path $cfExe)) {
    & $cfExe service uninstall 2>&1 | Out-Null
    Write-Host "  [OK] Tunel de Cloudflare desinstalado de este PC" -ForegroundColor Green
}
Get-NetFirewallRule -DisplayName "Timbre Escolar*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Remove-Item "$([Environment]::GetFolderPath('CommonDesktopDirectory'))\Timbre Escolar.url" -ErrorAction SilentlyContinue
Write-Host "  [OK] Timbre detenido y tareas eliminadas" -ForegroundColor Green

$r = Read-Host "Desactivar tambien el inicio de sesion automatico de Windows? (s/N)"
if ($r.Trim().ToLower().StartsWith("s")) {
    $winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Set-ItemProperty $winlogon -Name AutoAdminLogon -Value "0"
    Remove-ItemProperty $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class LsaBorrar {
    [StructLayout(LayoutKind.Sequential)] struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr s, ref LSA_OBJECT_ATTRIBUTES a, uint acc, out IntPtr h);
    [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr h, ref LSA_UNICODE_STRING k, IntPtr d);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr h);
    public static uint Borrar(string clave) {
        LSA_OBJECT_ATTRIBUTES a = new LSA_OBJECT_ATTRIBUTES(); a.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
        IntPtr h; uint st = LsaOpenPolicy(IntPtr.Zero, ref a, 0x000F0FFF, out h); if (st != 0) return st;
        LSA_UNICODE_STRING k = new LSA_UNICODE_STRING(); k.Buffer = Marshal.StringToHGlobalUni(clave);
        k.Length = (ushort)(clave.Length * 2); k.MaximumLength = (ushort)(clave.Length * 2 + 2);
        st = LsaStorePrivateData(h, ref k, IntPtr.Zero); LsaClose(h); return st;
    }
}
"@
    [LsaBorrar]::Borrar("DefaultPassword") | Out-Null
    Write-Host "  [OK] Inicio de sesion automatico desactivado" -ForegroundColor Green
}
Write-Host ""
Write-Host "La carpeta C:\TimbreEscolar (horarios y sonidos) se conserva. Puedes borrarla a mano si ya no la necesitas."
Write-Host "La sincronizacion de hora de Windows se deja activada."
Read-Host "Pulsa Intro para cerrar"
