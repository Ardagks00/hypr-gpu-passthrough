# hypr-gpu-passthrough

One installer that sets up **dynamic NVIDIA GPU passthrough** to a Windows 11 VM on a Linux machine
that also has an integrated GPU (most gaming laptops, many desktops). It was built for Hyprland.

- **VM off:** the NVIDIA GPU belongs to Linux. CUDA, PyTorch and MATLAB use it directly; games and
  other graphics programs run on it with `nvrun`.
- **VM on:** the GPU moves to Windows at native speed (for CAD, games, anything that needs a real
  GPU). Linux keeps running on the integrated GPU.
- **VM off again:** the GPU comes back to Linux. No reboot, no logout.
- [Looking Glass](https://looking-glass.io) shows Windows in a window on your Linux desktop, with
  almost no added latency. Its virtual display driver (IDD) means **no dummy HDMI plug** is needed.

```
VM stopped                              VM running
┌────────────────────────────────┐      ┌───────────────────────────────────────────────┐
│ Linux desktop → Intel/AMD iGPU │      │ Linux desktop → Intel/AMD iGPU                │
│ CUDA, nvrun   → NVIDIA GPU     │ ───▶ │ Looking Glass ← shared memory ← Windows 11 VM │
└────────────────────────────────┘      │ Windows 11 VM → NVIDIA GPU (vfio-pci)         │
                                        └───────────────────────────────────────────────┘
```

## Status

| Distribution | State |
|---|---|
| Ubuntu / Kubuntu (Debian family) | **Tested** end to end on Kubuntu 26.04 with Hyprland 0.56, MSI Cyborg 15 A13VF (i7-13620H, RTX 4060 Laptop) |
| Arch, Fedora, openSUSE | **Experimental**: written from the distributions' documentation, not tested yet. Reports and fixes are welcome. |

Always start with `./install.sh --dry-run` (no sudo needed): it shows what was detected and every
command and file it would write, without changing anything. On a machine that already has a VM, it
also shows the exact changes the last stage would make to that VM's definition.

## Requirements

- x86_64 CPU with hardware virtualization (VT-x / AMD-V) and an IOMMU (VT-d / AMD-Vi), both
  enabled in the firmware setup.
- An Intel or AMD integrated GPU that drives your screen, plus an NVIDIA GPU (Turing / RTX 20 or
  newer recommended).
  Laptops with a MUX switch must be in hybrid (Optimus) mode, not "discrete only".
- The NVIDIA GPU in an IOMMU group of its own (only its own functions and PCIe bridges). The
  installer checks this. It does **not** offer the ACS override patch, which breaks the isolation
  that makes passthrough safe.
- 16 GiB of RAM or more is recommended. The VM gets half of it. VFIO locks all VM memory, so the
  installer adds a swap file when RAM is tight.
- A Windows 11 ISO from [Microsoft](https://www.microsoft.com/software-download/windows11) and a
  Windows license.
- About 150 GiB of free disk space (the VM disk grows as Windows uses it).

## Quick start

```bash
git clone https://github.com/<you>/hypr-gpu-passthrough.git
cd hypr-gpu-passthrough
./install.sh --dry-run        # look first (changes nothing)
sudo ./install.sh             # stage 1, then reboot
sudo ./install.sh             # stages 2-4; ends with a VM for installing Windows
```

Install Windows in the VM as described in [docs/windows.md](docs/windows.md) (part 1), shut it
down, then:

```bash
sudo ./install.sh             # stage 5: GPU, Looking Glass, CPU pinning
```

Finish inside Windows ([docs/windows.md](docs/windows.md), part 2: NVIDIA driver and the Looking
Glass IDD). From then on, start Windows from your app menu ("Windows VM") or with `winvm`.

The installer stops whenever you have to do something (reboot, install Windows) and continues
where it stopped when you run it again. `sudo ./install.sh --status` shows where you are.

## What each stage does

| Stage | Changes |
|---|---|
| **host** | Installs QEMU/KVM, libvirt, UEFI firmware and TPM emulation; adds you to the `libvirt` and `kvm` groups. Turns the IOMMU on if needed. Installs the NVIDIA driver if missing. Writes the udev rules, `/etc/environment` entries and the EGL change described below. Adds a swap file if needed. **Ends with a reboot.** |
| **virt** | Enables libvirt and its default network. Saves a copy of the GPU's vBIOS and, on laptops, builds a fake battery ACPI table. Allows QEMU to read them (AppArmor or SELinux). Creates the Looking Glass shared memory file. Installs the libvirt hook and tests it without a VM. |
| **desktop** | Downloads (after asking) and builds the Looking Glass client. Installs `nvrun`, `winvm` and the "Windows VM" menu entry. |
| **vm-create** | Downloads (after asking) the virtio-win drivers and creates the VM: Q35, UEFI Secure Boot, TPM 2.0, VirtIO disk and network, no GPU yet. |
| **vm-passthrough** | After Windows is installed: adds the NVIDIA GPU (all functions of its IOMMU group), the vBIOS, Looking Glass shared memory, CPU pinning and the Code 43 countermeasures. Backs up the old definition first. |

Every file it changes is backed up under `/var/lib/hypr-gpu-passthrough/backup/` and recorded in a
manifest, which `uninstall.sh` uses.

## How it works

**The hand-over.** libvirt binds the GPU to `vfio-pci` itself when the VM starts (managed
`hostdev`) and gives it back when the VM stops. A libvirt hook
(`/etc/libvirt/hooks/qemu.d/hypr-gpu-passthrough`) does the rest:

- *Before the VM starts:*
  1. Refuses to start when RAM plus swap is too small for the VM, with a clear message instead of
     the kernel's OOM killer ending QEMU.
  2. Refuses to start while programs use the GPU, and lists them.
  3. Stops `nvidia-persistenced` and `nvidia-powerd`.
  4. Blocks NVIDIA module loading for the VM's lifetime. Otherwise a failed load (for example from
     `nvidia-smi`) makes NVIDIA's udev rules retry endlessly.
  5. Unloads the NVIDIA modules.
  6. Restricts Linux to the host's CPU cores and selects the `performance` power profile.
- *After the VM stops:* unblocks and reloads the driver, restarts the services, and restores the
  CPU limits and the power profile.

**Keeping the desktop off the NVIDIA GPU.** The GPU can only leave when no program has it open.
Three settings make sure the desktop never does:

1. `AQ_DRM_DEVICES=/dev/dri/igpu` (Hyprland) and `KWIN_DRM_DEVICES=/dev/dri/igpu` (KDE Plasma),
   where `/dev/dri/igpu` is a stable udev symlink to the integrated GPU.
2. The NVIDIA GPU's display node belongs to no seat (udev rule). When the driver comes back after the
   VM, compositors see it as a hot-plugged GPU and would open it; logind does not give them a
   device without a seat. Render nodes and `/dev/nvidia*` are not affected.
3. Programs that list EGL devices (Hyprland, hyprpaper, Electron apps…) and GTK 4 programs (through
   Vulkan) open the NVIDIA GPU just by starting. The installer moves NVIDIA's EGL vendor file out of
   the default search path (`dpkg-divert` on Debian/Ubuntu, a systemd path unit elsewhere) and sets
   `GDK_DISABLE=vulkan`. `nvrun` puts both back for the programs you start with it.

**Code 43 countermeasures** (NVIDIA's Windows driver refusing to start in a VM, mostly on laptop
GPUs): the VM gets a copy of the vBIOS, a fake battery, the GPU's real subsystem ID, a hidden
hypervisor signature and a Hyper-V vendor ID.

**Performance:** vCPUs are pinned to whole cores (P-cores on hybrid Intel CPUs), QEMU's own threads
run on separate cores, Hyper-V enlightenments are on, and the disk uses VirtIO with `cache=none`.

## Daily use

- **Start Windows:** "Windows VM" in your app menu, or `winvm`. When you close the Looking Glass
  window, it asks whether Windows should shut down too, which gives the GPU back.
- **Looking Glass keys** (the escape key is Right Ctrl; change `escapeKey` in
  `~/.looking-glass-client.ini`):
  - Tap Right Ctrl: capture or release the mouse and keyboard.
  - Right Ctrl + F: full screen.
  - Right Ctrl + =: make Windows match the window size.
  - Right Ctrl + Q: quit.
- **NVIDIA GPU on Linux** (VM off):
  - CUDA, PyTorch and MATLAB need nothing.
  - Graphics programs: `nvrun <program>`. For Steam games, set the launch option
    `nvrun %command%`.
- **Before starting the VM**, close programs that use the NVIDIA GPU (games, CUDA jobs). If you
  forget, the start fails and lists them.
- **While the VM runs**, Linux cannot use the NVIDIA GPU, and loading its driver is blocked on
  purpose.
- **Display outputs wired to the NVIDIA GPU** (on many laptops the HDMI or USB-C port) work only in
  Windows. The installer lists them.

## Configuration

- `/etc/hypr-gpu-passthrough/config` holds the detected values (GPU addresses, CPU split…). It is
  generated; run the installer again rather than editing it.
- Different VM memory or CPU cores:
  ```bash
  sudo ./install.sh --stage vm-passthrough --vm-ram 12 --vm-cores 4
  ```
- `sudo ./install.sh --help` lists all options (VM name, disk size, Looking Glass build, local ISOs).
- The Looking Glass client and the IDD in Windows must be the **same build**. The default is
  `B7-826-236efcb1`. With `--lg-build` you can choose another one; then install the matching IDD
  in Windows.

## Troubleshooting

**"The NVIDIA GPU is in use, … was not started"**
Close the listed programs. If Hyprland, kwin_wayland or Xorg is listed, the display settings are not
active: log out and back in, and check that `echo $AQ_DRM_DEVICES` prints `/dev/dri/igpu`.

**A Flatpak app is listed as using the NVIDIA GPU**
Flatpak apps bring their own copy of NVIDIA's libraries, so the system-wide EGL change does not
reach them. Close the app before starting the VM.

**"Not enough memory to start …"**
Close large programs, or give the VM less memory (see Configuration).

**Looking Glass stays black right after installing the IDD**
Windows may still be on a setup or update screen on its basic display. Close Looking Glass, finish
that screen in virt-manager's console, close the console, and start `winvm` again.

**Looking Glass shows an empty desktop, or input does nothing**
Windows spread the desktop over two monitors (the IDD display and the basic display).
- Right-click the Looking Glass (IDD) icon in the Windows notification area → **Open
  configuration**, and enable **Make LG the only monitor**.
- Or, in Windows Settings → Display, choose "Show only on 2".

**Only 60 Hz in Windows**
In the same IDD configuration window, set **Default refresh** to your screen's rate (for example
`144.003`; three decimals are allowed). Then click **Load default** and **Save & reload driver**,
and press Right Ctrl + = in Looking Glass.

**Code 43 in Windows' Device Manager**
- Check `journalctl -t hypr-gpu-passthrough` and the installer's output for the vBIOS step.
- On laptops, Device Manager should show a "Batteries" category: that is the fake battery.

**The GPU does not come back to Linux after the VM** (very rare)
Reboot. Then send `journalctl -t hypr-gpu-passthrough -b -1` with your bug report.

**Logs**
- Hook: `journalctl -t hypr-gpu-passthrough`
- Installer: `/var/log/hypr-gpu-passthrough/install.log`
- QEMU: `/var/log/libvirt/qemu/<vm>.log`

## Uninstall

```bash
sudo ./uninstall.sh             # asks whether to delete the VM too
sudo ./uninstall.sh --keep-vm   # keep the VM (without the GPU)
```

It removes the hook, rules, configuration, swap file and Looking Glass client, restores changed
files, and puts NVIDIA's EGL file back. Packages, the NVIDIA driver and group memberships stay.
Reboot afterwards.

## Contributing

Reports from Arch, Fedora and openSUSE are especially welcome: the output of
`./install.sh --dry-run` already helps. Before sending changes, run:

```bash
shellcheck install.sh uninstall.sh lib/*.sh files/qemu-hook files/vm-launch files/nvrun
```

## Credits

- [Looking Glass](https://looking-glass.io) by Geoffrey McRae (gnif) and contributors.
- [virtio-win](https://github.com/virtio-win/virtio-win-pkg-scripts) drivers.
- [libvirt](https://libvirt.org) and [QEMU](https://www.qemu.org).
- The Arch Wiki article [PCI passthrough via OVMF](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF),
  where much of this knowledge is collected.

This project is not affiliated with NVIDIA, Microsoft or the Looking Glass project.

## License

MIT, see [LICENSE](LICENSE).
