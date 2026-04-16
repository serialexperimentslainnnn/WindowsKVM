# optimize-gaming-no-context.ps1 - Optimizaciones de Windows 11 para gaming en VM KVM
# Ejecutar como Administrador: Right-click > Run with PowerShell (Admin)

#Requires -RunAsAdministrator

Write-Host "=== Optimizacion de Windows 11 para Gaming (KVM VM) ===" -ForegroundColor Cyan
Write-Host ""

# --- 1. Plan de energia: Alto rendimiento ---
Write-Host "[1/15] Plan de energia: Alto rendimiento" -ForegroundColor Yellow
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /hibernate off

# --- 2. Desactivar Game Bar y Game DVR ---
Write-Host "[2/15] Desactivar Game Bar y Game DVR" -ForegroundColor Yellow
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled" -Value 0 -Type DWord -Force
Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0 -Type DWord -Force
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Value 0 -Type DWord -Force

# --- 3. Desactivar Nagle (reducir latencia de red) ---
Write-Host "[3/15] Desactivar Nagle en interfaces de red" -ForegroundColor Yellow
$interfaces = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
foreach ($iface in $interfaces) {
    Set-ItemProperty -Path $iface.PSPath -Name "TcpAckFrequency" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $iface.PSPath -Name "TCPNoDelay" -Value 1 -Type DWord -Force
}

# --- 4. Desactivar HPET ---
Write-Host "[4/15] Desactivar HPET" -ForegroundColor Yellow
bcdedit /deletevalue useplatformclock 2>$null
bcdedit /set disabledynamictick yes

# --- 5. Desactivar servicios innecesarios ---
Write-Host "[5/15] Desactivar servicios innecesarios" -ForegroundColor Yellow
$services = @(
    "DiagTrack"           # Telemetria
    "dmwappushservice"    # WAP Push
    "SysMain"             # Superfetch
    "WSearch"             # Windows Search indexer
    "MapsBroker"          # Mapas
    "Fax"                 # Fax
    "lfsvc"               # Geolocalizacion
    "RetailDemo"          # Retail Demo
    "WMPNetworkSvc"       # Windows Media Player sharing
    "XblAuthManager"      # Xbox Live Auth
    "XblGameSave"         # Xbox Live Game Save
    "XboxGipSvc"          # Xbox Accessory Management
    "XboxNetApiSvc"       # Xbox Live Networking
    "WerSvc"              # Windows Error Reporting
    "wisvc"               # Windows Insider
    "TabletInputService"  # Tablet input
    "PhoneSvc"            # Phone Service
    "TrkWks"              # Distributed Link Tracking
    "RemoteRegistry"      # Remote Registry
    "Spooler"             # Print Spooler (no necesario sin impresora)
)
foreach ($svc in $services) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Host "  - $svc desactivado" -ForegroundColor DarkGray
    }
}

# --- 6. Desactivar tareas programadas innecesarias ---
Write-Host "[6/15] Desactivar tareas programadas de telemetria" -ForegroundColor Yellow
$tasks = @(
    "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser"
    "\Microsoft\Windows\Application Experience\ProgramDataUpdater"
    "\Microsoft\Windows\Autochk\Proxy"
    "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator"
    "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip"
    "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector"
    "\Microsoft\Windows\Maintenance\WinSAT"
)
foreach ($task in $tasks) {
    schtasks /Change /TN $task /Disable 2>$null
}

# --- 7. Desactivar efectos visuales ---
Write-Host "[7/15] Ajustar efectos visuales para rendimiento" -ForegroundColor Yellow
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 2 -Type DWord -Force
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "UserPreferencesMask" -Value ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) -Type Binary -Force
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -Value "0" -Type String -Force
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop\WindowMetrics" -Name "MinAnimate" -Value "0" -Type String -Force
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\DWM" -Name "EnableAeroPeek" -Value 0 -Type DWord -Force
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\DWM" -Name "AlwaysHibernateThumbnails" -Value 0 -Type DWord -Force

# --- 8. Desactivar transparencia ---
Write-Host "[8/15] Desactivar transparencia" -ForegroundColor Yellow
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "EnableTransparency" -Value 0 -Type DWord -Force

# --- 9. Desactivar notificaciones ---
Write-Host "[9/15] Desactivar notificaciones" -ForegroundColor Yellow
New-Item -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Name "DisableNotificationCenter" -Value 1 -Type DWord -Force
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications" -Name "ToastEnabled" -Value 0 -Type DWord -Force

# --- 10. Desactivar Windows Update automatico ---
Write-Host "[10/15] Pausar Windows Update" -ForegroundColor Yellow
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Value 1 -Type DWord -Force

# --- 11. Desactivar Windows Defender (maximo rendimiento) ---
Write-Host "[11/15] Desactivar Windows Defender real-time protection" -ForegroundColor Yellow
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Name "DisableAntiSpyware" -Value 1 -Type DWord -Force
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" -Name "DisableRealtimeMonitoring" -Value 1 -Type DWord -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" -Name "DisableBehaviorMonitoring" -Value 1 -Type DWord -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" -Name "DisableOnAccessProtection" -Value 1 -Type DWord -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" -Name "DisableScanOnRealtimeEnable" -Value 1 -Type DWord -Force

# --- 12. Desactivar Cortana ---
Write-Host "[12/15] Desactivar Cortana" -ForegroundColor Yellow
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowCortana" -Value 0 -Type DWord -Force

# --- 13. Desactivar fullscreen optimizations ---
Write-Host "[13/15] Desactivar fullscreen optimizations" -ForegroundColor Yellow
Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_FSEBehavior" -Value 2 -Type DWord -Force
Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_FSEBehaviorMode" -Value 2 -Type DWord -Force
Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_HonorUserFSEBehaviorMode" -Value 1 -Type DWord -Force
Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_DXGIHonorFSEWindowsCompatible" -Value 1 -Type DWord -Force

# --- 14. Prioridad GPU ---
Write-Host "[14/15] Configurar prioridad GPU" -ForegroundColor Yellow
Set-ItemProperty -Path "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences" -Name "DirectXUserGlobalSettings" -Value "SwapEffectUpgradeEnable=1;VRROptimizeEnable=1;" -Type String -Force -ErrorAction SilentlyContinue

# --- 15. Desactivar Connected Standby y power saving agresivo ---
Write-Host "[15/15] Desactivar Connected Standby y power saving" -ForegroundColor Yellow
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name "CsEnabled" -Value 0 -Type DWord -Force
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name "HibernateEnabled" -Value 0 -Type DWord -Force
# Desactivar USB selective suspend
powercfg /setacvalueindex 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
# Desactivar PCI Express Link State Power Management
powercfg /setacvalueindex 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

# --- Eliminar apps preinstaladas innecesarias ---
Write-Host "[BONUS] Eliminar apps preinstaladas innecesarias" -ForegroundColor Yellow
$bloatware = @(
    "Microsoft.BingNews"
    "Microsoft.BingWeather"
    "Microsoft.GetHelp"
    "Microsoft.Getstarted"
    "Microsoft.MicrosoftOfficeHub"
    "Microsoft.MicrosoftSolitaireCollection"
    "Microsoft.People"
    "Microsoft.PowerAutomate"
    "Microsoft.Todos"
    "Microsoft.WindowsAlarms"
    "Microsoft.WindowsFeedbackHub"
    "Microsoft.WindowsMaps"
    "Microsoft.WindowsSoundRecorder"
    "Microsoft.YourPhone"
    "Microsoft.ZuneMusic"
    "Microsoft.ZuneVideo"
    "MicrosoftTeams"
    "Clipchamp.Clipchamp"
    "Microsoft.549981C3F5F10"  # Cortana
)
foreach ($app in $bloatware) {
    Get-AppxPackage -Name $app -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object {$_.PackageName -like "*$app*"} | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
    Write-Host "  - $app eliminado" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "=== Optimizacion completada ===" -ForegroundColor Green
Write-Host "Reinicia Windows para aplicar todos los cambios." -ForegroundColor Cyan
Write-Host ""
pause
