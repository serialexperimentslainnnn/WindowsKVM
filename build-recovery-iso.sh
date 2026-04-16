#!/bin/bash
# build-recovery-iso.sh - Construye la ISO de recovery con drivers VirtIO incluidos
set -e

VIRTIO_ISO="/var/lib/libvirt/images/virtio-win.iso"
OUTPUT_ISO="/var/lib/libvirt/images/win11_recovery.iso"
WORK_DIR="/tmp/recovery-iso-build"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Construyendo ISO de recovery ==="

# Limpiar directorio temporal
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/drivers/viostor"

# Copiar archivos de repair
echo "[1/3] Copiando archivos de reparacion..."
cp "$SCRIPT_DIR/repair/autounattend.xml" "$WORK_DIR/"
cp "$SCRIPT_DIR/repair/repair-bcd.bat" "$WORK_DIR/"

# Extraer drivers VirtIO (solo viostor para W11 amd64)
echo "[2/3] Extrayendo drivers VirtIO de $VIRTIO_ISO..."
MOUNT_DIR="/tmp/virtio-mount"
mkdir -p "$MOUNT_DIR"
sudo mount -o loop,ro "$VIRTIO_ISO" "$MOUNT_DIR"

# Copiar driver de almacenamiento viostor
if [ -d "$MOUNT_DIR/viostor/w11/amd64" ]; then
    cp "$MOUNT_DIR/viostor/w11/amd64/"* "$WORK_DIR/drivers/viostor/"
    echo "  - viostor w11/amd64 copiado"
elif [ -d "$MOUNT_DIR/viostor/2k22/amd64" ]; then
    cp "$MOUNT_DIR/viostor/2k22/amd64/"* "$WORK_DIR/drivers/viostor/"
    echo "  - viostor 2k22/amd64 copiado (fallback)"
else
    echo "ERROR: No se encontro viostor en la ISO de VirtIO"
    sudo umount "$MOUNT_DIR"
    exit 1
fi

sudo umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"

# Crear ISO
echo "[3/3] Creando ISO..."
echo ""
echo "Contenido de la ISO:"
find "$WORK_DIR" -type f | sed "s|$WORK_DIR|  |"
echo ""

genisoimage -o "$OUTPUT_ISO" \
    -J -R \
    -V "WIN11_RECOVERY" \
    -input-charset utf-8 \
    "$WORK_DIR"

# Ajustar permisos para libvirt
sudo chown root:root "$OUTPUT_ISO"
sudo chmod 644 "$OUTPUT_ISO"

# Limpiar
rm -rf "$WORK_DIR"

echo ""
echo "=== ISO creada: $OUTPUT_ISO ==="
ls -lh "$OUTPUT_ISO"
echo ""
echo "Para usarla, asegurate de que domain.xml tiene:"
echo "  - windows.iso en sda con boot order='1'"
echo "  - win11_recovery.iso en sdc (contiene autounattend.xml + repair bat + drivers)"
echo ""
echo "Luego: virsh define domain.xml && virsh start win11"
