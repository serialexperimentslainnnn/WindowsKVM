# Windows 11 KVM + GPU Passthrough (AMD RDNA 4)

Linux workstation → Windows gaming VM with **near-native GPU performance** via PCI passthrough. This reference build delivers **RTX 5090-class FPS** on an AMD RX 9070 XT (~700€) thanks to FSR 4, AFMF and a heavily tuned host + VM + guest stack. In most AAA titles the VM actually *outperforms* bare-metal Windows on the same hardware — see the [three optimization layers](#why-the-vm-outperforms-bare-metal-windows) below.

> [!CAUTION]
> ### THIS IS NOT A GUIDE — IT IS A REFERENCE IMPLEMENTATION
>
> **Do not copy `domain.xml`, `install.sh` or the kernel parameters blindly.** Every passthrough host is different. IOMMU groups, PCI layout, motherboard firmware, BIOS version, GPU generation, reset-bug behaviour and chipset ACS support all determine what works. Configurations that run flawlessly on this build **can brick the boot** on another even with identical CPU and GPU models.
>
> Read every file, understand *why* each decision was made, then adapt to your own hardware. If your hardware fundamentally doesn't support passthrough — shared IOMMU groups, reset bug with no workaround, BIOS without IOMMU support, single-GPU system, etc. — no amount of config tuning will fix that.
>
> **Use the scripts and XML in this repo as examples, not as recipes. You have been warned.**

## Benchmarks

**GPU** — RX 9070 XT Sapphire Nitro+, custom tune:

| Setting            | Value                                           |
|--------------------|-------------------------------------------------|
| Clock offset       | +250 MHz                                        |
| Undervolt          | -60 mV                                          |
| Memory clock       | 2700 MHz                                        |
| Power limit        | Maximum                                         |
| Fan curve          | 100% @ 60°C (GPU 48°C / memory 58°C sustained)  |

**Adrenalin advanced options:** every setting is forced via *Override application settings* at its maximum value, and every setting that exposes a quality tier is set to *Quality*.

**Results (1440p, FSR Sharpness 1 across all titles):**

| Game                 | Preset                          | FSR                     | AFMF (added latency)     | FPS     |
|----------------------|---------------------------------|-------------------------|--------------------------|---------|
| Cyberpunk 2077       | RT Overdrive                    | FSR 4 Quality           | Quality (~7 ms)          | 120-140 |
| Cyberpunk 2077       | RT Overdrive                    | FSR 4 Ultra Performance | Quality (4-5 ms)         | 250-300 |
| Cyberpunk 2077       | RT Ultra                        | FSR 4 Quality           | Quality (4-5 ms)         | 250-300 |
| Borderlands 4        | Badass                          | FSR Quality             | Quality (4-5 ms)         | 210-220 |
| Monster Hunter Wilds | Max + RT Max                    | FSR Quality             | Quality (4-5 ms)         | 240-280 |
| Doom: The Dark Ages  | UltraNightmare                  | FSR Quality             | Quality (4-5 ms)         | 370-400 |
| Doom: The Dark Ages  | UltraNightmare + Path Tracing   | FSR Ultra Performance   | Quality (4-5 ms)         | 230-270 |
| Overwatch 2          | Epic + Reduced Buffering        | FSR 2.0                 | Disabled                 | 260-280 |
| Overwatch 2          | Epic + Reduced Buffering        | FSR 2.0                 | Quality (2-3 ms)         | 400-420 |

AFMF + Anti-Lag 2 adds only **2-7 ms of input latency** depending on title — roughly an order of magnitude below Nvidia Frame Generation (~50 ms). These are real frames in real gameplay, not a statistical trick.

## System

| Component | Host                                              | VM                                                               |
|-----------|---------------------------------------------------|------------------------------------------------------------------|
| CPU       | Ryzen 9 5950X (16C/32T, AM4)                      | 32 vCPUs pinned 1:1, `host-passthrough`, CCDs respected          |
| RAM       | 128 GB DDR4                                       | 64 GB backed by 2 MB hugepages                                   |
| GPU       | RX 7800 XT (host desktop)                         | RX 9070 XT Sapphire Nitro+ (VFIO passthrough)                    |
| Storage   | 2× NVMe 1 TB + 8× SATA SSD 1 TB (btrfs RAID 10)   | 5 TB raw, VirtIO + O_DIRECT                                      |
| USB       | —                                                 | AMD xHCI 11:00.3, dedicated IOMMU group, VFIO passthrough        |
| Network   | —                                                 | VirtIO                                                           |
| Firmware  | ASRock X570 Taichi Razer Edition                  | OVMF UEFI + Secure Boot + TPM 2.0 (Q35)                          |
| OS        | Fedora 45 Rawhide, kernel 7.0.0-62.fc45.x86_64    | Windows 11 Pro                                                   |
| Display   | 2K 165 Hz FreeSync (DisplayPort)                  | —                                                                |

## VM Configuration

Full breakdown of the live `virsh dumpxml win11` (what the `domain.xml` actually defines, without the "why" — that comes in the next section).

| Area | Value |
|---|---|
| Machine type | Q35 (`pc-q35-9.2`), x86_64 |
| Firmware | OVMF with enrolled Secure Boot keys (`OVMF_CODE_4M.secboot.qcow2`) + per-VM NVRAM copy |
| Memory | 64 GiB (67 108 864 KiB), backed by `<hugepages/>` + `memfd` source + `shared` access |
| vCPUs | 32 — `placement='static'`, mode `host-passthrough`, `migratable='off'` |
| CPU topology | `sockets=1 dies=1 clusters=1 cores=16 threads=2` |
| CPU features | `topoext` (AMD SMT ID), `invtsc` (invariant TSC), `cache mode='passthrough'` |
| CPU pinning (CCD0) | vCPU 0-15 ↔ host threads `0,16,1,17,2,18,3,19,4,20,5,21,6,22,7,23` |
| CPU pinning (CCD1) | vCPU 16-31 ↔ host threads `8,24,9,25,10,26,11,27,12,28,13,29,14,30,15,31` |
| Emulator pin | CPUs 0, 16 |
| iothread pin | Both iothreads (1 + 2) on CPUs 0, 16 |
| Hyper-V enlightenments | `relaxed`, `vapic`, `spinlocks retries=8191`, `vpindex`, `runtime`, `synic`, `stimer + direct`, `vendor_id=AuthenticAMD`, `frequencies`, `tlbflush`, `ipi` |
| KVM feature flag | `<hidden state='on'/>` — hides KVM CPUID leaf from the guest |
| SMM | Enabled (required for Secure Boot) |
| Clock | `localtime`; timers: `rtc=catchup`, `pit=delay`, **`hpet=off`**, `hypervclock=on`, `tsc=native` |
| Power management | `suspend-to-mem` + `suspend-to-disk` both disabled |
| Disk | `vda` VirtIO, raw, `cache=none`, `io=native`, `discard=unmap`, spoofed WD serial |
| Controllers | virtio-scsi (iothread=1), qemu-xhci, SATA, 7× pcie-root-ports |
| Network | VirtIO on default NAT network |
| Input | PS/2 mouse + PS/2 keyboard (real input comes through the passed-through xHCI) |
| TPM | `tpm-crb`, emulator backend, version 2.0, SHA-256 PCR bank |
| Memory balloon | `<memballoon model='none'/>` — disabled (pointless with hugepage-backed RAM) |
| Watchdog | `itco`, action `reset` |
| Audio | `type='none'` on QEMU side — audio is carried by the GPU's HDMI/DP passthrough |
| PCI passthrough | `0000:0f:00.0` GPU VGA, `0000:0f:00.1` GPU audio, `0000:11:00.3` xHCI — all `managed='yes'` with `<rom bar='on'/>` |
| SMBIOS | Spoofed ASRock X570 Taichi Razer Edition (system + baseboard + BIOS vendor), real motherboard serial preserved |

## Why the VM outperforms bare-metal Windows

Three optimization layers stack on top of each other: the host gives the VM a clean, deterministic substrate; the VM exposes bare-metal-like hardware to Windows; the guest strips the bloat Windows can't remove on its own.

### 1. Host — `optimize.sh`

Fedora runs as a minimal hypervisor: the less it does, the better.

| Area            | Setting                                                                                                           | Why                                                                                                                                                   |
|-----------------|-------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------|
| Kernel cmdline  | `mitigations=off`, `nohz_full=1-31`, `nowatchdog`, `nmi_watchdog=0`, `audit=0`, `split_lock_detect=off`, `preempt=full` | Trusted single-user host — Spectre mitigations (~10-25% syscall loss) gone, tickless on all cores except 0, no periodic interrupts preempting pinned vCPUs, no split-lock penalty on VMs, full preemption for latency. |
| CPU             | `tuned` profile `max-performance`, governor `performance`, deep C-states disabled                                 | Cores stay at max frequency. No wake-up latency from C6/C7 on every context switch into the VM.                                                       |
| Memory          | **HugeTLB: 32768 × 2 MB = 64 GiB reserved**                                                                       | Backs the entire VM RAM with 2 MB pages. Guest RAM access resolves in one pagetable walk instead of four. Measurable 3-8% FPS gain in CPU-bound sections. |
| Memory          | THP `madvise`, `swappiness=1`                                                                                     | Transparent hugepages only where asked; swap is emergency-only.                                                                                       |
| I/O             | NVMe scheduler `none`, SATA `mq-deadline`, read-ahead tuned                                                       | No software reordering on NVMe — hardware queues handle it better.                                                                                    |
| Services        | ModemManager, CUPS, Avahi, ABRT, fwupd, thermald, power-profiles-daemon disabled                                  | One less daemon = one less source of CPU wake-ups.                                                                                                    |
| Limits          | `memlock=unlimited`, `nofile=1048576`                                                                             | Required so QEMU can mlock the VM RAM and open all passthrough FDs.                                                                                   |

### 2. VM — `domain.xml`

Where most of the "better than bare metal" effect comes from. Windows sees dedicated hardware, not a virtualized environment.

| Area              | Setting                                                                                                | Why                                                                                                                                                                |
|-------------------|--------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| CPU pinning       | 32 vCPUs pinned 1:1 to host threads, CCDs respected                                                    | vCPU 0-15 → CCD0, vCPU 16-31 → CCD1. The host scheduler never moves threads across CCDs (huge L3 miss penalty on Zen 3). SMT pairs stay coherent.                  |
| CPU topology      | `sockets=1 dies=1 cores=16 threads=2` exposed to guest                                                 | Windows sees the real 5950X topology — it places game threads correctly instead of treating the CPU as 32 independent cores.                                       |
| CPU mode          | `host-passthrough`                                                                                     | Every real-CPU flag exposed (AVX2, AES-NI, SVM, etc.). No emulated CPU model hiding instructions.                                                                  |
| emulatorpin       | QEMU threads pinned to CPUs 0,16                                                                       | Isolates QEMU's own I/O and device-emulation overhead from the vCPUs. Game threads never get preempted by bookkeeping.                                             |
| Memory            | `<hugepages/>` + `memfd` + `shared` access                                                             | Guest RAM lives in the host's HugeTLB reserve — lower memory access latency inside the guest.                                                                      |
| iothreads         | 2 dedicated                                                                                            | Disk I/O handled on separate threads outside the vCPU pool. Windows never stalls a game thread waiting for virtio.                                                 |
| Disk              | VirtIO raw, `cache=none`, `io=native`, `discard=unmap`                                                 | O_DIRECT straight to NVMe (VM has its own page cache), Linux AIO instead of threadpool, TRIM pass-through keeps the raw image thin.                                |
| Network, GPU, USB | VirtIO net + VFIO PCI passthrough with `<rom bar='on'/>` for GPU VGA + GPU audio + full xHCI controller| Native drivers, native performance, zero emulation. xHCI passthrough also means peripherals get their controller's IRQs without sharing with the host.             |
| Hypervisor hiding | `<kvm hidden='yes'/>`, `vendor_id=AuthenticAMD`, Hyper-V enlightenments enabled                        | AMD Adrenalin stops spawning vDisplay. Windows uses real Hyper-V calls (spinlocks, TLB flush, synthetic timer) for scheduler efficiency.                           |
| SMBIOS            | Spoofed to real ASRock X570 Taichi                                                                     | DMI looks physical → driver reads real EDID → native refresh + FreeSync work.                                                                                      |

### 3. Guest — `optimize-gaming.ps1` + Win11Debloat

Runtime tweaks the VM layer can't apply from outside.

| Area            | Setting                                                                                  | Why                                                                                                            |
|-----------------|------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| Power           | High-performance plan, hibernate off, USB selective suspend off, PCIe ASPM off           | No core parking, no PCIe sleeping. USB selective suspend specifically causes peripheral dropouts in passthrough.|
| GPU scheduling  | `HwSchMode=2`                                                                            | Hardware-accelerated GPU scheduling. Without it, every frame passes through an extra Windows kernel layer.      |
| DirectX         | `SwapEffectUpgradeEnable=1`, `VRROptimizeEnable=1`                                       | Modern flip-model + VRR-friendly pipeline — better FreeSync behavior in borderless windowed.                   |
| Fullscreen      | `GameDVR_FSEBehavior=2`                                                                  | Exclusive fullscreen actually works (no DWM composition wrapping).                                             |
| Services off    | `DiagTrack`, `SysMain`, `WSearch`, `MapsBroker`, `lfsvc`, `WMPNetworkSvc`, `wisvc`, …    | Telemetry, Superfetch (useless with hugepages), Search indexer (kills SSD I/O), geolocation, Insider.          |
| Network         | Nagle off on all interfaces (`TcpAckFrequency=1`, `TCPNoDelay=1`)                        | Lower TCP latency — noticeable in online games.                                                                |
| UI              | Visual effects → performance, transparency off, notifications off, Windows Update paused | Every DWM effect is a GPU draw; every notification is a context switch.                                        |

Run after installing AMD drivers:
```powershell
powershell -ExecutionPolicy Bypass -File optimize-gaming.ps1
```

Then add [**Win11Debloat**](https://github.com/Raphire/Win11Debloat) to strip the pre-installed Microsoft bloat the `.ps1` can't touch — Edge, Copilot, Cortana, Widgets, OneDrive, Teams, Xbox apps, lockscreen ads, suggested apps, telemetry endpoints. Combined, you get a Windows 11 that's a fraction of the install footprint and with far fewer background processes than a default install.

## Critical Gotchas

### SMBIOS spoofing — or your monitor is dead to AMD

AMD Adrenalin (RDNA 2+) detects the hypervisor, fails to read monitor EDID, and activates **AMD vDisplay** — a virtual display replacing the physical outputs. FreeSync/VRR stops working and you're stuck at 60 Hz on a 165 Hz panel on a monitor which is probably sending a glitched or incorrect output.

Spoof the motherboard identity so the driver thinks it's bare metal:

```xml
<hyperv>
  <vendor_id state='on' value='AuthenticAMD'/>
</hyperv>
<kvm>
  <hidden state='on'/>
</kvm>
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

Get real values with `sudo dmidecode -t system && sudo dmidecode -t baseboard`.

### VFIO-PCI binding at boot

The passthrough GPU must be claimed by `vfio-pci` **before** `amdgpu`. Three moving parts, all handled by `install.sh`:

- **Kernel cmdline:** `vfio-pci.ids=1002:7550,1002:ab40` (your GPU IDs)
- **Modprobe:** `softdep amdgpu pre: vfio-pci`
- **initramfs:** vfio modules baked in via `dracut`

> Only put GPU-unique IDs in `vfio-pci.ids`. If the USB controller shares its ID with other host controllers (common on AMD), let libvirt handle it with `managed='yes'`.
>
> Note: `amd_iommu=on` is **not** a valid option (the kernel logs `AMD-Vi: Unknown option - 'on'` and ignores it). It's noise, not a bug — `iommu=pt` is what you actually want. If AMD-Vi is not initializing, check the BIOS: IOMMU / SVM must be enabled there first.

### SELinux policy for swtpm + VFIO on Fedora

Fedora ships SELinux in enforcing mode by default, and the stock `targeted` policy doesn't cover every interaction between `libvirtd`, `swtpm`, and VFIO when the VM is pinned, uses hugepages, and has a TPM. The symptoms are nasty and misleading:

- vTPM manufacturing fails with `swtpm process terminated unexpectedly` / `Could not start the TPM 2` — actually caused by `swtpm_t` being denied `unlink`/`read` on its own pidfile in the `virtqemud_tmp_t` directory.
- QEMU fails to `mlock` guest RAM pages needed by VFIO — `svirt_t` is denied the `ipc_lock` capability.
- Audit log fills with `svirt_t` denials trying to stat the `pcscd` socket (harmless but noisy).

The fix ships in this repo as a small SELinux module (`selinux/windowskvm.te`). It grants exactly four things:

```
allow swtpm_t virtqemud_tmp_t:file { read unlink open getattr };
allow swtpm_t svirt_image_t:file   { read write open getattr };
allow svirt_t self:capability      ipc_lock;
allow svirt_t pcscd_var_run_t:sock_file getattr;
```

No blanket `permissive` mode, no disabling SELinux. Build and load:

```bash
cd selinux
checkmodule -M -m -o windowskvm.mod windowskvm.te
semodule_package -o windowskvm.pp -m windowskvm.mod
sudo semodule -i windowskvm.pp
```

What was deliberately **not** granted: `sys_admin`, `dac_override` and `dac_read_search` on `svirt_t`. These get logged during certain passthrough paths but are too broad to hand out blindly — skipping them has caused zero problems in practice.

### USB controller needs its own IOMMU group

Individual USB device passthrough is laggy and unreliable for gaming peripherals. Full-controller passthrough is native — but only if the controller is alone in its IOMMU group:

```bash
for d in /sys/kernel/iommu_groups/*/devices/*; do
  n=$(basename $(dirname $(dirname $d)))
  echo "IOMMU Group $n: $(lspci -nns $(basename $d))"
done
```

If it shares a group, you're out of luck (ACS override patches exist but aren't recommended).

**What "xHCI controller" actually means in this build:** on the X570 Taichi the device at `0000:11:00.3` isn't a separate card — it's an xHCI controller wired to a dedicated PCI lane of the motherboard that exposes **4 physical USB 3.0 ports** on the back I/O panel. The entire controller (and therefore all 4 ports) gets handed to the VM at boot. Plugged into those 4 ports: the keyboard, the mouse, a USB audio interface, and a powered USB hub — so *anything* plugged into that hub automatically belongs to the VM without extra configuration. Want to add a flight stick, a MIDI controller, a webcam? Just plug it into the hub. No per-device USB redirection, no hotplug libvirt calls.

### `<rom bar='on'/>` on every passthrough device

Required on GPU VGA, GPU audio and the xHCI controller. Without it, OVMF can't initialize the GPU — no display output.

### VirtIO drivers during Windows install

`autounattend.xml` preloads these into Windows PE so the installer sees the VirtIO disk:

| Driver   | Purpose               |
|----------|-----------------------|
| viostor  | VirtIO block storage  |
| vioscsi  | VirtIO SCSI           |
| NetKVM   | VirtIO network        |
| viorng   | VirtIO RNG            |
| vioser   | VirtIO serial         |

*Not included:* `Balloon` (disabled here), `vioinput` (xHCI handles input natively).

### Parameters that break RDNA 4

| Parameter                         | Problem                                                        |
|-----------------------------------|----------------------------------------------------------------|
| `x-vga=on`                        | `Bad address` with 16 GB BAR. Legacy for SeaBIOS only.         |
| `display='on'` / `ramfb='on'`     | Only work with virtual GPUs (mdev/vGPU), not physical.         |
| `fw_cfg X-PciMmio64Mb`            | Changes OVMF MMIO map → video signal glitches.                 |

## Quick Start

1. **Snapshot before experimenting.** The disk is raw (no qcow2 snapshots), but `cp` works:
   ```bash
   cp /var/lib/libvirt/images/win11.raw /var/lib/libvirt/images/win11-base.raw
   ```
2. **Use a QXL display during initial setup** so you have a SPICE fallback while troubleshooting GPU issues — remove it once passthrough is stable:
   ```xml
   <graphics type='spice' autoport='yes'>
     <listen type='address' address='127.0.0.1'/>
   </graphics>
   <video>
     <model type='qxl' ram='65536' vram='65536' vgamem='16384' heads='1' primary='yes'/>
   </video>
   ```
3. **Install AMD drivers first, then run `optimize-gaming.ps1`** — hardware GPU scheduling needs the driver present.

## Adapting to Your Hardware

The principles port to any AMD or Intel passthrough setup:

1. Find GPU PCI IDs: `lspci -nn | grep VGA`
2. Verify the GPU's IOMMU group is isolated
3. Get SMBIOS data: `sudo dmidecode -t system && sudo dmidecode -t baseboard`
4. Update `install.sh` with your GPU vendor:device IDs
5. Update `domain.xml` with your PCI addresses, SMBIOS, CPU topology, RAM
6. Update `autounattend.xml` with user/password/locale

**Requirements:** CPU + motherboard with IOMMU support (AMD-Vi / VT-d), two GPUs (the host one can be any cheap card that runs a desktop), ideally a USB controller alone in its IOMMU group, enough RAM to split between host and VM.

## Project Structure

| File                                      | Purpose                                                                 |
|-------------------------------------------|-------------------------------------------------------------------------|
| `install.sh`                              | Host setup: packages, IOMMU, vfio-pci binding, VM definition            |
| `optimize.sh`                             | Host performance tuning (kernel, CPU, I/O, network, hugepages)          |
| `domain.xml`                              | Libvirt VM definition with all passthrough config                       |
| `autounattend.xml`                        | Unattended Windows 11 install with VirtIO drivers preloaded             |
| `optimize-gaming.ps1`                     | Windows gaming tweaks (registry, services, power)                       |
| `configs/vfio-modules.conf`               | vfio modules loaded at boot                                             |
| `configs/vfio-modprobe.conf.template`     | modprobe template for vfio-pci                                          |
| `selinux/windowskvm.{te,pp}`              | SELinux module allowing swtpm + VFIO under enforcing mode               |
| `repair/`                                 | Recovery autounattend + BCD repair script (emergency)                   |

## Troubleshooting

| Symptom                                            | Cause                                       | Fix                                                                     |
|----------------------------------------------------|---------------------------------------------|-------------------------------------------------------------------------|
| Monitor shows "AMD vDisplay"                       | Driver detects VM                           | `vendor_id` + `kvm hidden` + SMBIOS spoof                               |
| `Bad address` on VM start                          | `x-vga=on` or `fw_cfg MMIO`                 | Remove both parameters                                                  |
| No disks in Windows installer                      | VirtIO drivers not loaded                   | Check `PnpCustomizationsWinPE` paths in `autounattend.xml`              |
| UEFI boot shows nothing                            | ROM BAR disabled                            | Add `<rom bar='on'/>` to GPU                                            |
| Keyboard unresponsive in UEFI                      | xHCI slow to init                           | Wait a few seconds, retry                                               |
| Stuck at 60-75 Hz                                  | AMD vDisplay active                         | Spoof hypervisor (see *Critical Gotchas → SMBIOS*)                      |
| Games stutter                                      | GPU scheduling disabled                     | Enable `HwSchMode=2` or run `optimize-gaming.ps1`                       |
| `VFIO PCI device assignment is not supported`      | IOMMU not initialised — usually disabled in BIOS | Enable IOMMU / SVM in the BIOS; verify with `ls /sys/kernel/iommu_groups/` (empty = off) |
| `swtpm` fails on boot ("Could not start the TPM 2")| SELinux blocking swtpm                      | Load `selinux/windowskvm.pp`                                            |

## License

Do whatever you want with this. If it saves you the hours of pain it cost us, it was worth it.
