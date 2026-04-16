# optimize-gaming.ps1 - Optimizaciones de Windows para gaming en VM KVM
# Ejecutar como Administrador: Right-click > Run with PowerShell (Admin)
# SAFE: Solo registry tweaks, powercfg y servicios. No toca bcdedit.

#Requires -RunAsAdministrator

Write-Host "=== Optimizacion de Windows para Gaming (KVM VM) ===" -ForegroundColor Cyan
Write-Host ""

# --- 1. Plan de energia: Alto rendimiento ---
Write-Host "[1/11] Plan de energia: Alto rendimiento" -ForegroundColor Yellow
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /change monitor-timeout-ac 0
powercfg /change monitor-timeout-dc 0
powercfg /change hibernate-timeout-ac 0
powercfg /change hibernate-timeout-dc 0
powercfg /hibernate off

# --- 2. Desactivar Game Bar y Game DVR ---
Write-Host "[2/11] Desactivar Game Bar y Game DVR" -ForegroundColor Yellow
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled" -Value 0 -Type DWord -Force
Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0 -Type DWord -Force
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Value 0 -Type DWord -Force

# --- 3. Desactivar Nagle (reducir latencia de red) ---
Write-Host "[3/11] Desactivar Nagle en interfaces de red" -ForegroundColor Yellow
$interfaces = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
foreach ($iface in $interfaces) {
    Set-ItemProperty -Path $iface.PSPath -Name "TcpAckFrequency" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $iface.PSPath -Name "TCPNoDelay" -Value 1 -Type DWord -Force
}

# --- 4. Desactivar servicios innecesarios para gaming ---
Write-Host "[4/11] Desactivar servicios innecesarios" -ForegroundColor Yellow
$services = @(
    "DiagTrack"         # Telemetria
    "SysMain"           # Superfetch (innecesario con RAM fija)
    "WSearch"           # Windows Search indexer
    "MapsBroker"        # Mapas
    "Fax"               # Fax
    "lfsvc"             # Geolocalizacion
    "RetailDemo"        # Retail Demo
    "WMPNetworkSvc"     # Windows Media Player sharing
    "wisvc"             # Windows Insider
)
foreach ($svc in $services) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Host "  - $svc desactivado" -ForegroundColor DarkGray
    }
}

# --- 5. Desactivar efectos visuales (priorizar rendimiento) ---
Write-Host "[5/11] Ajustar efectos visuales para rendimiento" -ForegroundColor Yellow
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 2 -Type DWord -Force
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "UserPreferencesMask" -Value ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) -Type Binary -Force
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -Value "0" -Type String -Force
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop\WindowMetrics" -Name "MinAnimate" -Value "0" -Type String -Force
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\DWM" -Name "EnableAeroPeek" -Value 0 -Type DWord -Force

# --- 6. Desactivar transparencia ---
Write-Host "[6/11] Desactivar transparencia" -ForegroundColor Yellow
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "EnableTransparency" -Value 0 -Type DWord -Force

# --- 7. Desactivar notificaciones ---
Write-Host "[7/11] Desactivar notificaciones" -ForegroundColor Yellow
New-Item -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Name "DisableNotificationCenter" -Value 1 -Type DWord -Force
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications" -Name "ToastEnabled" -Value 0 -Type DWord -Force

# --- 8. Desactivar Windows Update automatico ---
Write-Host "[8/11] Pausar Windows Update (no interrumpir gaming)" -ForegroundColor Yellow
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Value 1 -Type DWord -Force

# --- 9. Prioridad GPU y aceleracion por hardware ---
Write-Host "[9/11] Configurar GPU: aceleracion por hardware y rendimiento" -ForegroundColor Yellow
# Hardware-accelerated GPU scheduling
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value 2 -Type DWord -Force
# Preferir rendimiento en DirectX
Set-ItemProperty -Path "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences" -Name "DirectXUserGlobalSettings" -Value "SwapEffectUpgradeEnable=1;VRROptimizeEnable=1;" -Type String -Force -ErrorAction SilentlyContinue

# --- 10. Desactivar fullscreen optimizations ---
Write-Host "[10/11] Desactivar fullscreen optimizations" -ForegroundColor Yellow
Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_FSEBehavior" -Value 2 -Type DWord -Force
Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_FSEBehaviorMode" -Value 2 -Type DWord -Force
Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_HonorUserFSEBehaviorMode" -Value 1 -Type DWord -Force
Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_DXGIHonorFSEWindowsCompatible" -Value 1 -Type DWord -Force

# --- 11. Desactivar power saving (VM no necesita ahorro) ---
Write-Host "[11/11] Desactivar power saving innecesario en VM" -ForegroundColor Yellow
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name "HibernateEnabled" -Value 0 -Type DWord -Force
# USB selective suspend off
powercfg /setacvalueindex 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
# PCI Express Link State Power Management off
powercfg /setacvalueindex 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

Write-Host ""
Write-Host "=== Optimizacion completada ===" -ForegroundColor Green
Write-Host "Reinicia Windows para aplicar todos los cambios." -ForegroundColor Cyan
Write-Host ""
pause
