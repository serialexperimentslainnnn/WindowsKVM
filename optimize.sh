#!/bin/bash
set -euo pipefail

# =============================================================================
# Fedora 44 Performance Optimization - Ryzen 9 5950X + 128GB RAM
# 2x NVMe MSI M460 1TB + 8x SATA SSD (btrfs 10 devices)
# Host GPU: RX 7700 XT | Passthrough: RX 9070 XT
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[[ $EUID -eq 0 ]] || error "Ejecutar como root: sudo ./optimize.sh"

# =============================================================================
# KERNEL PARAMETERS
# =============================================================================
optimize_kernel_params() {
    info "Optimizando parametros del kernel..."

    local current_args
    current_args=$(cat /proc/cmdline)
    local new_args=""

    # Desactivar mitigaciones de CPU (Spectre, Meltdown, etc.) — max rendimiento
    if ! echo "$current_args" | grep -q "mitigations=off"; then
        new_args+=" mitigations=off"
    fi

    # Desactivar watchdog (reduce interrupciones innecesarias)
    if ! echo "$current_args" | grep -q "nowatchdog"; then
        new_args+=" nowatchdog nmi_watchdog=0"
    fi

    # Tickless full para todos los cores excepto el 0
    if ! echo "$current_args" | grep -q "nohz_full"; then
        new_args+=" nohz_full=1-31"
    fi

    # Desactivar audit (overhead en cada syscall)
    if ! echo "$current_args" | grep -q "audit=0"; then
        new_args+=" audit=0"
    fi

    # Desactivar split lock detection (penaliza rendimiento en VMs)
    if ! echo "$current_args" | grep -q "split_lock_detect=off"; then
        new_args+=" split_lock_detect=off"
    fi

    # Preempt=full para menor latencia
    if ! echo "$current_args" | grep -q "preempt=full"; then
        new_args+=" preempt=full"
    fi

    if [ -n "$new_args" ]; then
        grubby --update-kernel=ALL --args="$new_args"
        info "Kernel params añadidos:$new_args"
    else
        info "Kernel params ya optimizados"
    fi
}

# =============================================================================
# SYSCTL — VM, Network, Kernel
# =============================================================================
optimize_sysctl() {
    info "Aplicando sysctl optimizations..."

    cat > /etc/sysctl.d/99-performance.conf <<'EOF'
# --- VM / Memory ---
# Swappiness bajo (128GB RAM, swap solo para emergencias)
vm.swappiness = 1
# Dirty pages: flush mas agresivo para evitar stalls en escritura
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.dirty_expire_centisecs = 500
vm.dirty_writeback_centisecs = 100
# VFS cache pressure: mantener dentries/inodes en cache
vm.vfs_cache_pressure = 50
# Mas memoria para page cache
vm.page-cluster = 0
# Zone reclaim off (NUMA single node, no tiene sentido)
vm.zone_reclaim_mode = 0

# --- Kernel ---
# Desactivar NMI watchdog via sysctl (belt and suspenders con kernel param)
kernel.nmi_watchdog = 0
# Scheduler autogroup (agrupa procesos por TTY)
kernel.sched_autogroup_enabled = 1

# --- Network ---
# TCP BBR congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# Buffers de red mas grandes
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
# TCP fastopen
net.ipv4.tcp_fastopen = 3
# Reuse sockets
net.ipv4.tcp_tw_reuse = 1

# --- FS ---
# Mas file handles
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
EOF

    sysctl -p /etc/sysctl.d/99-performance.conf
    info "sysctl aplicado"
}

# =============================================================================
# I/O SCHEDULER + READ-AHEAD
# =============================================================================
optimize_io() {
    info "Optimizando I/O..."

    # NVMe: none es optimo (hardware queue)
    # SATA SSDs: mq-deadline mejor para SSDs con menos queues
    cat > /etc/udev/rules.d/60-io-scheduler.rules <<'EOF'
# NVMe: no scheduler (hardware handles it)
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
# SATA SSD: mq-deadline
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
EOF

    # Read-ahead optimizado: 256KB para NVMe, 1MB para SATA
    cat > /etc/udev/rules.d/61-read-ahead.rules <<'EOF'
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/read_ahead_kb}="256"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/read_ahead_kb}="1024"
EOF

    # Aplicar ahora sin esperar reboot
    for dev in /sys/block/nvme*/queue; do
        echo "none" > "$dev/scheduler" 2>/dev/null || true
        echo 256 > "$dev/read_ahead_kb" 2>/dev/null || true
    done
    for dev in /sys/block/sd[a-h]/queue; do
        echo "mq-deadline" > "$dev/scheduler" 2>/dev/null || true
        echo 1024 > "$dev/read_ahead_kb" 2>/dev/null || true
    done

    info "I/O schedulers y read-ahead configurados"
}

# =============================================================================
# CPU GOVERNOR + ENERGY
# =============================================================================
optimize_cpu() {
    info "Optimizando CPU..."

    # Crear perfil tuned custom que aplica todo de forma persistente
    local TUNED_DIR="/etc/tuned/profiles/max-performance"
    mkdir -p "$TUNED_DIR"
    cat > "$TUNED_DIR/tuned.conf" <<'EOF'
[main]
summary=Max performance for Ryzen 9 5950X workstation
include=throughput-performance

[cpu]
governor=performance
energy_perf_bias=performance
energy_performance_preference=performance
min_perf_pct=100

[sysctl]
kernel.nmi_watchdog=0
EOF

    # C-states profundos desactivados via tmpfiles (persistente)
    local cstate_conf="/etc/tmpfiles.d/cpu-cstates.conf"
    echo "# Desactivar C-states profundos" > "$cstate_conf"
    for i in $(seq 0 31); do
        echo "w /sys/devices/system/cpu/cpu${i}/cpuidle/state2/disable - - - - 1" >> "$cstate_conf"
    done

    # Aplicar ahora
    for state in /sys/devices/system/cpu/cpu*/cpuidle/state[2-9]/disable; do
        echo 1 > "$state" 2>/dev/null || true
    done

    systemctl restart tuned
    tuned-adm profile max-performance

    info "CPU en modo max performance"
}

# =============================================================================
# TRANSPARENT HUGEPAGES
# =============================================================================
optimize_hugepages() {
    info "Configurando Transparent HugePages..."

    # madvise: solo aplicaciones que lo pidan (mejor que always para workloads mixtos)
    echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
    echo madvise > /sys/kernel/mm/transparent_hugepage/defrag

    # Persistir
    cat > /etc/tmpfiles.d/thp.conf <<'EOF'
w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise
w /sys/kernel/mm/transparent_hugepage/defrag - - - - madvise
EOF

    info "THP en modo madvise"
}

# =============================================================================
# BTRFS OPTIMIZATIONS
# =============================================================================
optimize_btrfs() {
    info "Optimizando btrfs..."

    # Remount con noatime (elimina writes de access time)
    local fstab="/etc/fstab"
    if grep -q "relatime" "$fstab"; then
        sed -i 's/relatime/noatime/g' "$fstab"
        mount -o remount,noatime /
        mount -o remount,noatime /home
        info "Cambiado relatime -> noatime en fstab"
    else
        info "fstab ya tiene noatime o custom mount options"
    fi

    # Desactivar autodefrag para SSDs (contraproducente)
    # commit=120 para reducir frecuencia de journal flush
    # Estas se aplican en el proximo mount o reboot via fstab

    info "btrfs optimizado (noatime)"
}

# =============================================================================
# DISABLE UNNECESSARY SERVICES
# =============================================================================
optimize_services() {
    info "Desactivando servicios innecesarios..."

    local services=(
        ModemManager          # No hay modem
        cups                  # No hay impresora
        avahi-daemon          # mDNS discovery innecesario
        abrtd                 # Auto bug reporting
        abrt-journal-core     # ABRT journal
        abrt-oops             # ABRT kernel oops
        fwupd                 # Firmware updates (hacer manual)
        switcheroo-control    # GPU switching (no aplicable, 2 GPUs dedicadas)
        power-profiles-daemon # Conflicto con tuned
        thermald              # Intel only
    )

    for svc in "${services[@]}"; do
        if systemctl is-enabled "$svc" &>/dev/null 2>&1; then
            systemctl disable --now "$svc" 2>/dev/null && info "  Desactivado: $svc" || true
        fi
    done
}

# =============================================================================
# LIMITS — file descriptors, memlock
# =============================================================================
optimize_limits() {
    info "Configurando limits..."

    cat > /etc/security/limits.d/99-performance.conf <<EOF
*    soft    nofile    1048576
*    hard    nofile    1048576
*    soft    memlock   unlimited
*    hard    memlock   unlimited
*    soft    nproc     unlimited
*    hard    nproc     unlimited
EOF

    info "Limits configurados"
}

# =============================================================================
# ZRAM OPTIMIZATION
# =============================================================================
optimize_zram() {
    info "Optimizando zram..."

    # Con 128GB RAM, zram de 8GB es suficiente pero usar zstd en vez de lzo
    if [ -f /etc/systemd/zram-generator.conf ]; then
        sed -i 's/compression-algorithm.*/compression-algorithm = zstd/' /etc/systemd/zram-generator.conf 2>/dev/null || true
        info "zram compresion: zstd"
    fi
}

# =============================================================================
# MAIN
# =============================================================================
info "Optimizando Fedora 44 para maximo rendimiento..."
echo ""

optimize_kernel_params
optimize_sysctl
optimize_io
optimize_cpu
optimize_hugepages
optimize_btrfs
optimize_services
optimize_limits
optimize_zram

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  OPTIMIZACION COMPLETADA${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "Cambios aplicados:"
echo "  - Kernel: mitigations=off, nowatchdog, nohz_full, audit=0, split_lock_detect=off"
echo "  - CPU: governor performance, C-states profundos desactivados"
echo "  - Memory: swappiness=1, dirty pages optimizados, THP=madvise"
echo "  - I/O: NVMe=none scheduler, SATA=mq-deadline, read-ahead optimizado"
echo "  - Network: TCP BBR, buffers ampliados, fastopen"
echo "  - Btrfs: noatime"
echo "  - Servicios innecesarios desactivados"
echo "  - Limits: nofile/memlock/nproc ampliados"
echo ""
echo -e "${YELLOW}REQUIERE REBOOT para aplicar parametros del kernel${NC}"
