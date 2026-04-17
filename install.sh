#!/bin/bash
set -euo pipefail

# =============================================================================
# Windows 11 KVM + PCI Passthrough Setup Script
# =============================================================================
# Host GPU:     RX 7700 XT (05:00.0)
# Passthrough:  RX 9070 XT (0f:00.0 + 0f:00.1)
#               USB xHCI   (11:00.3) - Razer, Arturia KeyLab, UGREEN BT
# VM:           32 vCPUs, 64GB RAM, 3TB disk, Secure Boot + TPM 2.0
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

VM_NAME="win11"
VM_DIR="/var/lib/libvirt/images"
DISK_SIZE="5120"  # GB
# Vendor:Device IDs (GPU only - unique IDs safe for vfio-pci.ids)
GPU_VGA_ID="1002:7550"
GPU_AUDIO_ID="1002:ab40"
# USB controller 11:00.3 [1022:149c] managed by libvirt (managed='yes' handles bind/unbind)

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || error "Este script debe ejecutarse como root: sudo ./install.sh"
}

install_packages() {
    info "Instalando paquetes necesarios..."
    dnf install -y \
        qemu-kvm \
        libvirt \
        libvirt-daemon-kvm \
        virt-manager \
        virt-install \
        edk2-ovmf \
        swtpm \
        swtpm-tools \
        libguestfs-tools \
        wimlib-utils \
        xorriso \
        dnsmasq
}

configure_iommu() {
    info "Configurando IOMMU en el kernel..."

    # Limpieza: 'amd_iommu=on' no es una opcion valida (los valores aceptados
    # son off/fullflush/force_isolation/force_enable). Versiones anteriores
    # de este script la añadian; en kernels <7.0 era ignorada silenciosamente,
    # pero en Linux 7.0 el parser rechaza el init de AMD-Vi al verla, dejando
    # la IOMMU sin inicializar y VFIO sin funcionar. La eliminamos siempre.
    if grubby --info=ALL 2>/dev/null | grep -q "amd_iommu=on"; then
        grubby --update-kernel=ALL --remove-args='amd_iommu=on'
        warn "Eliminado 'amd_iommu=on' (invalido) del cmdline de todos los kernels"
    fi

    # AMD-Vi arranca por defecto si la CPU/BIOS soportan IOMMU.
    # Solo necesitamos iommu=pt (passthrough) y el bind temprano de vfio-pci.
    local needed_args="iommu=pt vfio-pci.ids=${GPU_VGA_ID},${GPU_AUDIO_ID}"

    # grubby --args es idempotente: actualiza si cambia el valor, no duplica.
    grubby --update-kernel=ALL --args="$needed_args"
    info "Parametros del kernel asegurados: $needed_args"
}

configure_vfio() {
    info "Configurando vfio-pci para la RX 9070 XT..."

    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    local need_dracut=false

    # Load vfio modules early
    if ! diff -q "${SCRIPT_DIR}/configs/vfio-modules.conf" /etc/modules-load.d/vfio-pci.conf &>/dev/null; then
        cp "${SCRIPT_DIR}/configs/vfio-modules.conf" /etc/modules-load.d/vfio-pci.conf
        need_dracut=true
    fi

    # Bind GPU to vfio-pci by vendor:device ID
    # Only GPU IDs here - USB controller shares IDs with host controllers
    local new_modprobe
    new_modprobe=$(GPU_VGA_ID="${GPU_VGA_ID}" GPU_AUDIO_ID="${GPU_AUDIO_ID}" \
        envsubst '${GPU_VGA_ID} ${GPU_AUDIO_ID}' \
        < "${SCRIPT_DIR}/configs/vfio-modprobe.conf.template")

    if [ ! -f /etc/modprobe.d/vfio.conf ] || [ "$new_modprobe" != "$(cat /etc/modprobe.d/vfio.conf)" ]; then
        echo "$new_modprobe" > /etc/modprobe.d/vfio.conf
        need_dracut=true
    fi

    if $need_dracut; then
        info "Regenerando initramfs..."
        dracut -f --kver "$(uname -r)"
    else
        info "Configs vfio sin cambios, no es necesario regenerar initramfs"
    fi
}

enable_services() {
    info "Habilitando servicios de libvirt..."
    systemctl enable --now libvirtd
    systemctl enable --now virtlogd
}

configure_user() {
    info "Configurando permisos de usuario..."
    local REAL_USER="${SUDO_USER:-$USER}"

    usermod -aG libvirt "$REAL_USER" 2>/dev/null || true
    usermod -aG kvm "$REAL_USER" 2>/dev/null || true

    # Configure libvirt to run QEMU as root for PCI passthrough
    sed -i 's/^#\?user = .*/user = "root"/' /etc/libvirt/qemu.conf
    sed -i 's/^#\?group = .*/group = "root"/' /etc/libvirt/qemu.conf
}

create_amd_drivers_iso() {
    local AMD_ISO="${VM_DIR}/amd-drivers.iso"

    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    local AMD_EXE
    AMD_EXE=$(find "${SCRIPT_DIR}" -maxdepth 1 -name "*.exe" -path "*amd*adrenalin*" | head -1)

    if [ -f "$AMD_ISO" ]; then
        info "La ISO de drivers AMD ya existe: ${AMD_ISO}"
        return
    fi

    if [ -z "$AMD_EXE" ]; then
        warn "No se encuentra el instalador de AMD Adrenalin en ${SCRIPT_DIR}, saltando"
        return
    fi

    info "Creando ISO con $(basename "$AMD_EXE")..."
    mkisofs -o "$AMD_ISO" -J -r "$AMD_EXE" 2>&1 | tail -1

    info "ISO de drivers AMD creada: ${AMD_ISO}"
}

create_autounattend_iso() {
    info "Creando ISO con autounattend.xml..."

    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    local ISO_IMG="${VM_DIR}/${VM_NAME}_autounattend.iso"

    if [ ! -f "${SCRIPT_DIR}/autounattend.xml" ]; then
        error "No se encuentra autounattend.xml en ${SCRIPT_DIR}"
    fi

    mkisofs -o "$ISO_IMG" -J -r "${SCRIPT_DIR}/autounattend.xml"

    info "ISO creada: ${ISO_IMG}"
}

create_disk() {
    info "Creando disco virtual de ${DISK_SIZE}GB..."
    mkdir -p "$VM_DIR"

    if [ ! -f "${VM_DIR}/${VM_NAME}.raw" ]; then
        qemu-img create -f raw "${VM_DIR}/${VM_NAME}.raw" "${DISK_SIZE}G"
        info "Disco creado: ${VM_DIR}/${VM_NAME}.raw"
    else
        warn "El disco ${VM_DIR}/${VM_NAME}.raw ya existe, no se sobreescribe"
    fi
}

reset_vm() {
    warn "Reseteando la VM '${VM_NAME}' — se borrara disco, NVRAM, TPM y floppy..."

    # Apagar si esta corriendo
    virsh destroy "${VM_NAME}" 2>/dev/null || true
    # Eliminar definicion y NVRAM
    virsh undefine "${VM_NAME}" --nvram 2>/dev/null || true

    # Borrar disco, NVRAM, ISO autounattend y TPM
    rm -f "${VM_DIR}/${VM_NAME}.raw"
    rm -f "${VM_DIR}/${VM_NAME}.qcow2"
    rm -f "${VM_DIR}/${VM_NAME}_VARS.fd"
    rm -f "${VM_DIR}/${VM_NAME}_autounattend.iso"
    rm -f "${VM_DIR}/amd-drivers.iso"
    rm -rf "/var/lib/libvirt/swtpm/${VM_NAME}"

    info "VM '${VM_NAME}' eliminada completamente"
}

create_vm() {
    info "Definiendo la maquina virtual ${VM_NAME}..."

    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

    # Copy NVRAM template (each VM needs its own writable copy)
    local OVMF_VARS="/usr/share/edk2/ovmf/OVMF_VARS_4M.secboot.qcow2"
    local VM_VARS="${VM_DIR}/${VM_NAME}_VARS.fd"
    if [ ! -f "$VM_VARS" ]; then
        cp "$OVMF_VARS" "$VM_VARS"
        info "NVRAM copiado a ${VM_VARS}"
    fi

    # Create TPM state directory
    mkdir -p "/var/lib/libvirt/swtpm/${VM_NAME}"

    # Redefinir siempre con el domain.xml actual
    virsh undefine "${VM_NAME}" --nvram 2>/dev/null || true
    virsh define "${SCRIPT_DIR}/domain.xml"

    info "VM '${VM_NAME}' definida correctamente"
}

print_summary() {
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}  INSTALACION COMPLETADA${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""
    echo "Dispositivos PCI para passthrough:"
    echo "  GPU:  RX 9070 XT    -> 0f:00.0 + 0f:00.1 (vfio-pci al boot)"
    echo "  USB:  xHCI 11:00.3  -> bind/unbind gestionado por libvirt (managed='yes')"
    echo ""
    echo "VM: ${VM_NAME}"
    echo "  CPU:    32 vCPUs (16C/32T, host-passthrough)"
    echo "  RAM:    64 GB"
    echo "  Disco:  ${DISK_SIZE} GB (qcow2)"
    echo "  UEFI:   Secure Boot habilitado"
    echo "  TPM:    2.0 (swtpm emulado)"
    echo ""
    echo -e "${YELLOW}PASOS SIGUIENTES:${NC}"
    echo "  1. REINICIA el sistema para activar IOMMU y vfio-pci"
    echo "  2. Inicia la VM:"
    echo "     sudo virsh start ${VM_NAME}"
    echo "  3. La instalacion de Windows cargara los drivers VirtIO automaticamente"
    echo ""
    echo -e "${YELLOW}NOTA:${NC} Al iniciar la VM, tus perifericos Razer, Arturia KeyLab"
    echo "  y UGREEN BT dejaran de funcionar en el host (pasan a la VM)."
    echo "  Al apagar la VM, vuelven al host automaticamente."
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

RESET=false
if [[ "${1:-}" == "--reset" ]]; then
    RESET=true
fi

check_root
install_packages
configure_iommu
configure_vfio
enable_services
configure_user

if $RESET; then
    reset_vm
fi

create_amd_drivers_iso
create_autounattend_iso
create_disk
create_vm
print_summary
