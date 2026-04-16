# Windows 11 KVM + GPU Passthrough (AMD RDNA 4)

Turn a Linux workstation into a high-performance Windows gaming VM with near-native GPU performance using PCI passthrough. This setup achieves **RTX 5090-class performance** with an AMD RX 9070 XT (~700€ GPU) thanks to FSR 4, AFMF, and zero-overhead passthrough.

**Benchmarks (1440p, all maxed out):**

| Game | Settings | FPS |
|---|---|---|
| Cyberpunk 2077 | Ray Tracing Overdrive + FSR 4 Quality + AFMF | 150-200 |
| Cyberpunk 2077 | Ray Tracing Ultra + FSR Quality | 200-300 |
| Monster Hunter Wilds | Max settings + FSR Quality | 220-250 |
| Overwatch 2 | Max settings + Reduce Buffering | 260 (base) / 520 (AFMF, 3ms latency) |
| Overwatch 2 | Min settings | 400 (base) / 800 (AFMF) |

## Hardware

| Component | Detail |
|---|---|
| CPU | AMD Ryzen 9 5950X (16C/32T) — AM4 |
| RAM | 128 GB DDR4 |
| Motherboard | ASRock X570 Taichi Razer Edition |
| Host GPU | AMD RX 7700 XT (handles Linux desktop — any cheap GPU works, it just needs to run a desktop) |
| Passthrough GPU | AMD RX 9070 XT Sapphire Nitro+ (dedicated to VM) |
| USB Controller | AMD xHCI (11:00.3) — dedicated IOMMU group |
| Storage | 2x NVMe 1TB + 8x SATA SSD 1TB (btrfs, 10 devices) |
| Monitor | 2K 165Hz FreeSync (DisplayPort) |
| OS | Fedora 44 (host) / Windows 11 Pro (VM) |

## VM Specs

| Resource | Config |
|---|---|
| vCPUs | 32 (pinned 1:1 to all 32 threads) |
| RAM | 64 GB (hugepages 2MB) |
| Disk | 5 TB raw (VirtIO, O_DIRECT) |
| Firmware | OVMF UEFI + Secure Boot + TPM 2.0 |
| Chipset | Q35 |
| Network | VirtIO |

## About This Project

This is **not** a step-by-step guide to follow blindly. Every GPU passthrough setup is different depending on your hardware — IOMMU groups, PCI layout, GPU generation, and motherboard all affect what works and what doesn't. **Depending on your hardware, this can be a smooth ride or a complete nightmare — or simply impossible.**

This repository is a **reference implementation** — a working example of a setup that achieves near-native gaming performance in a KVM VM. Use it to understand the moving parts, adapt what applies to your hardware, and avoid the pitfalls we hit along the way.

### What's included

| Script | Purpose |
|---|---|
| `install.sh` | Host setup: packages, IOMMU, vfio-pci binding, VM definition |
| `optimize.sh` | Host performance tuning (kernel params, CPU governor, I/O, network, btrfs) |
| `domain.xml` | Libvirt VM definition with all passthrough config |
| `autounattend.xml` | Unattended Windows 11 installation with VirtIO drivers |
| `optimize-gaming.ps1` | Windows gaming optimization (safe, no boot modifications) |

### Tips

- **Snapshot your disk before experimenting.** The disk is raw for max I/O performance (no qcow2 snapshots), but a simple `cp` saves hours of reinstallation:
  ```bash
  cp /var/lib/libvirt/images/win11.raw /var/lib/libvirt/images/win11-base.raw
  ```
- **Use a QXL display during initial setup** until your passthrough is fully working. It gives you a fallback display via SPICE while you troubleshoot GPU issues. Remove it once everything is stable.
  ```xml
  <graphics type='spice' autoport='yes'>
    <listen type='address' address='127.0.0.1'/>
  </graphics>
  <video>
    <model type='qxl' ram='65536' vram='65536' vgamem='16384' heads='1' primary='yes'/>
  </video>
  ```
- **Install AMD drivers before running optimize-gaming.ps1** — GPU scheduling (`HwSchMode=2`) requires the driver to be present.

## Critical Points (Lessons Learned the Hard Way)

### 1. SMBIOS Spoofing — AMD drivers require real hardware identity

AMD Adrenalin drivers (RDNA 2+) detect when they're running inside a VM. When they do, they fail to read the monitor's EDID (the display's identity and capabilities), and instead activate **AMD vDisplay** — a virtual display that replaces your physical monitor outputs. This means:
- The driver can't detect your monitor's native resolution or refresh rate
- FreeSync/VRR won't work
- You're stuck at 60Hz on a 165Hz monitor
- Games stutter or refuse to run properly

**Solution:** Spoof real hardware so the AMD driver thinks it's on a physical machine:

```xml
<!-- Hide hypervisor -->
<hyperv>
  <vendor_id state='on' value='AuthenticAMD'/>
</hyperv>
<kvm>
  <hidden state='on'/>
</kvm>

<!-- Spoof real motherboard in SMBIOS -->
<sysinfo type='smbios'>
  <system>
    <entry name='manufacturer'>ASRock</entry>
    <entry name='product'>X570 Taichi Razer Edition</entry>
  </system>
  <baseBoard>
    <entry name='manufacturer'>ASRock</entry>
    <entry name='product'>X570 Taichi Razer Edition</entry>
  </baseBoard>
</sysinfo>
<os firmware='efi' smbios='sysinfo'>
```

Get your real SMBIOS data with:
```bash
sudo dmidecode -t system
sudo dmidecode -t baseboard
```

### 2. GPU Scheduling — Enable it or games stutter

After installing AMD drivers, you **must** enable Hardware-accelerated GPU Scheduling in Windows. Without it, every frame goes through an extra Windows kernel scheduling layer that adds latency and causes micro-stuttering.

The `optimize-gaming.ps1` script does this automatically:
```powershell
# HwSchMode=2 enables hardware GPU scheduling
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value 2 -Type DWord -Force
```

You can also enable it manually: Settings > Display > Graphics > Change default graphics settings > Hardware-accelerated GPU scheduling: ON.

### 3. VFIO-PCI binding at boot

The passthrough GPU must be claimed by `vfio-pci` before `amdgpu` loads. This is done via:

- **Kernel cmdline:** `vfio-pci.ids=1002:7550,1002:ab40` (your GPU's vendor:device IDs)
- **Modprobe:** softdep to load `vfio-pci` before `amdgpu`
- **initramfs:** vfio modules baked into the early boot image

`install.sh` configures all of this automatically.

> **Note:** Only put GPU-unique device IDs in `vfio-pci.ids`. If your USB controller shares its device ID with other host controllers (common on AMD), let libvirt handle it with `managed='yes'` instead.

### 4. ROM BAR must be enabled

```xml
<rom bar='on'/>
```

Required on GPU VGA, GPU Audio, and xHCI controller (This is just a PCI lane on my hardware holding 4 USB 3.0). Without it, OVMF can't initialize the GPU and you get no display output.

### 5. USB Controller passthrough — you need a dedicated IOMMU group

Passing individual USB devices is laggy and unreliable for gaming peripherals. Passing an entire USB controller gives native USB performance, but it only works if the controller is in its own IOMMU group.

Check your IOMMU groups:
```bash
for d in /sys/kernel/iommu_groups/*/devices/*; do
  n=$(basename $(dirname $(dirname $d)))
  echo "IOMMU Group $n: $(lspci -nns $(basename $d))"
done
```

If your controller shares a group with other devices, you're out of luck (ACS override patches exist but are not recommended).

### 6. VirtIO drivers during installation

The `autounattend.xml` automatically loads VirtIO drivers during Windows PE so the installer can see the VirtIO disk. Drivers loaded:

| Driver | Purpose |
|---|---|
| viostor | VirtIO block storage |
| vioscsi | VirtIO SCSI |
| NetKVM | VirtIO network |
| viorng | VirtIO RNG |
| vioser | VirtIO serial |

**Not included:** `Balloon` (disabled in this setup), `vioinput` (USB controller handles input natively).

### Parameters that don't work with RDNA 4

| Parameter | Problem |
|---|---|
| `x-vga=on` | Causes `Bad address` with 16GB BAR. Legacy for SeaBIOS. |
| `display='on'` / `ramfb='on'` | Only works with virtual GPUs (mdev/vGPU), not physical. |
| `fw_cfg X-PciMmio64Mb` | Changes OVMF MMIO map, causes video signal glitches. |

## Windows Optimization (optimize-gaming.ps1)

A safe PowerShell script that optimizes Windows for gaming. **No bcdedit, no boot modifications.** Only registry tweaks, service management, and power settings — all reversible.

What it does:
- High performance power plan, hibernate off
- Game Bar / Game DVR disabled
- Nagle algorithm disabled (lower network latency)
- Unnecessary services disabled (telemetry, Superfetch, Search indexer, etc.)
- Visual effects set to performance mode
- Transparency disabled
- Notifications disabled
- Windows Update paused
- Hardware GPU scheduling enabled (`HwSchMode=2`)
- Fullscreen optimizations disabled
- DirectX optimized for performance + VRR
- USB selective suspend and PCIe power management off

**Run after installing AMD drivers:**
```powershell
# From admin PowerShell
powershell -ExecutionPolicy Bypass -File optimize-gaming.ps1
```

## Host Optimization (optimize.sh)

Optimizes the Fedora host for maximum VM performance:
- `mitigations=off` — disables Spectre/Meltdown mitigations
- CPU governor set to `performance`, deep C-states disabled
- I/O schedulers: `none` for NVMe, `mq-deadline` for SATA SSDs
- TCP BBR congestion control, enlarged network buffers
- `vm.swappiness=1`, optimized dirty page settings
- btrfs `noatime`
- Transparent HugePages in `madvise` mode
- Unnecessary services disabled (ModemManager, CUPS, Avahi, etc.)
- Custom `tuned` profile `max-performance`

## Project Structure

```
WindowsKVM/
├── install.sh                       # Full setup: packages, IOMMU, vfio, VM
├── domain.xml                       # Libvirt VM definition
├── autounattend.xml                 # Unattended Windows installation
├── optimize.sh                      # Host (Fedora) performance tuning
├── optimize-gaming.ps1              # Guest (Windows) gaming optimization
├── configs/
│   ├── vfio-modules.conf            # vfio modules loaded at boot
│   └── vfio-modprobe.conf.template  # modprobe template for vfio-pci
├── repair/
│   ├── autounattend.xml             # Recovery autounattend
│   └── repair-bcd.bat               # BCD repair script (emergency)
└── README.md
```

## Adapting to Your Hardware

This setup is specific to our hardware, but the principles apply to any AMD GPU passthrough setup:

1. **Find your GPU's PCI IDs:** `lspci -nn | grep VGA`
2. **Find your GPU's IOMMU group** and verify it's isolated
3. **Get your SMBIOS data:** `sudo dmidecode -t system && sudo dmidecode -t baseboard`
4. **Update `install.sh`** with your GPU vendor:device IDs
5. **Update `domain.xml`** with your PCI addresses, SMBIOS data, CPU topology, and RAM
6. **Update `autounattend.xml`** with your preferred user/password and locale

Key requirements:
- AMD or Intel CPU with IOMMU support (AMD-Vi / VT-d)
- Two GPUs (one for host, one for VM — the host GPU only needs to run a Linux desktop, even a 30€ used GPU works)
- A USB controller in its own IOMMU group (optional but recommended for native input)
- Enough RAM to split between host and VM

## Troubleshooting

| Symptom | Cause | Solution |
|---|---|---|
| Monitor shows "AMD vDisplay" | Driver detects VM | Add `vendor_id` + `kvm hidden` + SMBIOS spoof |
| `Bad address` on VM start | `x-vga=on` or `fw_cfg MMIO` | Remove both parameters |
| No disks visible in Windows installer | VirtIO drivers not loaded | Check `PnpCustomizationsWinPE` paths in autounattend |
| UEFI boot shows nothing | ROM BAR disabled | Add `<rom bar='on'/>` to GPU |
| Keyboard unresponsive in UEFI | xHCI slow to initialize | Wait a few seconds, retry |
| Only 60-75Hz available | AMD vDisplay active | Spoof hypervisor (see point 1) |
| Games stutter | GPU scheduling disabled | Enable HwSchMode=2 or run optimize-gaming.ps1 |

## License

Do whatever you want with this. If it saves you the hours of pain it cost us, it was worth it.
