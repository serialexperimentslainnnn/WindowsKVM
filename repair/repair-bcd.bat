@echo off
echo ============================================
echo  Reparacion BCD - Windows KVM Gaming VM
echo ============================================
echo.

REM --- Paso 1: Cargar drivers VirtIO para ver el disco ---
echo [1/4] Buscando drivers VirtIO...
set DRVFOUND=0
for %%d in (D E F G H I J) do (
    if exist %%d:\drivers\viostor\viostor.inf (
        echo Cargando viostor desde %%d:\drivers\viostor\
        drvload %%d:\drivers\viostor\viostor.inf
        set DRVFOUND=1
        goto :drivers_ok
    )
)
REM Buscar tambien en virtio-win ISO directamente
for %%d in (D E F G H I J) do (
    if exist %%d:\viostor\w11\amd64\viostor.inf (
        echo Cargando viostor desde %%d:\viostor\w11\amd64\
        drvload %%d:\viostor\w11\amd64\viostor.inf
        set DRVFOUND=1
        goto :drivers_ok
    )
)
echo ERROR: No se encontraron drivers VirtIO!
echo El disco no sera visible sin ellos.
pause
exit /b 1

:drivers_ok
echo Driver VirtIO cargado correctamente.
echo Esperando a que el disco aparezca...
timeout /t 3 /nobreak >nul

REM --- Paso 2: Asignar letra a la particion EFI ---
echo.
echo [2/4] Montando particion EFI...
echo sel disk 0> X:\diskpart.txt
echo list par>> X:\diskpart.txt
echo sel par 1>> X:\diskpart.txt
echo assign letter=S>> X:\diskpart.txt
echo exit>> X:\diskpart.txt
diskpart /s X:\diskpart.txt

REM Verificar que la EFI esta montada
if not exist S:\EFI\Microsoft\Boot\BCD (
    echo.
    echo Particion 1 no es EFI, probando particion 2...
    echo sel disk 0> X:\diskpart2.txt
    echo sel par 2>> X:\diskpart2.txt
    echo assign letter=S>> X:\diskpart2.txt
    echo exit>> X:\diskpart2.txt
    diskpart /s X:\diskpart2.txt
)

if not exist S:\EFI\Microsoft\Boot\BCD (
    echo ERROR: No se encontro BCD en la particion EFI!
    echo.
    echo Contenido de S:\
    dir S:\ 2>nul
    pause
    exit /b 1
)

echo Particion EFI montada en S:
echo BCD encontrado en S:\EFI\Microsoft\Boot\BCD

REM --- Paso 3: Reparar BCD ---
echo.
echo [3/4] Reparando BCD...
echo.

echo Eliminando disabledynamictick...
bcdedit /store S:\EFI\Microsoft\Boot\BCD /deletevalue {default} disabledynamictick
echo.

echo Eliminando useplatformclock...
bcdedit /store S:\EFI\Microsoft\Boot\BCD /deletevalue {default} useplatformclock
echo.

echo Eliminando useplatformtick...
bcdedit /store S:\EFI\Microsoft\Boot\BCD /deletevalue {default} useplatformtick
echo.

REM Verificar estado actual del BCD
echo.
echo Estado actual del BCD:
echo ----------------------
bcdedit /store S:\EFI\Microsoft\Boot\BCD /enum {default}

REM --- Paso 4: Reiniciar ---
echo.
echo [4/4] Reparacion completada!
echo ============================================
echo Reiniciando en 10 segundos...
echo (Cierra esta ventana para cancelar)
echo ============================================
timeout /t 10
wpeutil reboot
