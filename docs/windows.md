# Inside Windows

The installer prepares Linux and the VM. The steps inside Windows are yours. There are two parts:
part 1 after the `vm-create` stage, part 2 after `vm-passthrough`.

The VM is called `win11` below; use your name if you chose another one with `--vm-name`.

## Part 1: install Windows (VM without the GPU)

The VM has the Windows ISO in its first CD drive and the virtio-win drivers in the second. It
starts without the NVIDIA GPU, so this works like any other VM.

1. **Start the VM.** Open virt-manager. If it asks, connect to "QEMU/KVM" (the system connection).
   Double-click `win11` and click **Start** (▶). Press a key when "Press any key to boot from CD
   or DVD" appears.
2. **Windows Setup.** Choose your language and edition and accept the license.
3. **The disk is not listed.** The VM uses a VirtIO disk, which Windows does not know yet.
   1. Click **Load driver** → **Browse**.
   2. Open the virtio-win CD → `viostor` → `w11` → `amd64` → **OK**.
   3. Select the "Red Hat VirtIO SCSI controller" driver → **Next**.

   The disk appears; install Windows on it.
4. **No network on the "Let's connect you to a network" screen.**
   1. Click **Install driver**.
   2. Open the virtio-win CD → `NetKVM` → `w11` → `amd64`.

   The network appears and setup continues as on a normal PC.
5. **Guest tools.** On the Windows desktop, open the virtio-win CD in File Explorer and run
   `virtio-win-guest-tools.exe`. It installs the remaining VirtIO drivers and the SPICE and QEMU
   guest agents.
6. Let Windows Update finish its first round, then **shut Windows down** (Start → Power → Shut
   down).
7. Back on Linux, run `sudo ./install.sh`. It adds the GPU.

## Part 2: NVIDIA driver and Looking Glass (VM with the GPU)

From now on, starting the VM moves the NVIDIA GPU into it. Close programs that use the GPU on
Linux first; if something still uses it, the start fails and lists the programs.

1. **Start the VM from virt-manager** and open its console. Windows shows its desktop on the basic
   display adapter. Looking Glass cannot show anything yet.
2. **NVIDIA driver.** In Device Manager, under "Display adapters", the NVIDIA GPU is listed,
   possibly with a warning sign until its driver is installed. Download the driver for your GPU
   from [nvidia.com/drivers](https://www.nvidia.com/drivers) and install it. Game Ready and Studio
   drivers both work. Afterwards, the GPU is listed without a warning sign.
   On laptops, a "Batteries" category also appears: that is the fake battery that keeps the
   driver happy.
3. **Looking Glass IDD.** In Windows, download the IDD of exactly the build the installer used
   (`B7-826-236efcb1` unless you chose another with `--lg-build`):
   `https://looking-glass.io/artifact/B7-826-236efcb1/idd`
   1. Unzip it and run `looking-glass-idd-setup.exe` as administrator.
   2. Keep "IVSHMEM Driver" selected.

   The IDD creates a virtual monitor, so no dummy HDMI plug is needed.
4. **Close the virt-manager console window.** Looking Glass also uses the VM's SPICE connection,
   and only one client can use it at a time.
5. **Start Looking Glass** with "Windows VM" in your app menu or `winvm` in a terminal. The Windows
   desktop appears in the window.
6. **Check the IDD settings.** Right-click the Looking Glass (IDD) icon in the Windows notification
   area → **Open configuration**.
   - **Make LG the only monitor** should be enabled (the default). Otherwise Windows may keep its
     desktop on the basic display, and Looking Glass shows an empty desktop.
   - **Default refresh:** set it to your screen's refresh rate for smooth motion, for example
     `144.003` on a 144 Hz panel (three decimals are allowed).
   - Then click **Load default** → **Save & reload driver**, and press Right Ctrl + = in Looking
     Glass so Windows matches the window size.

Done. When you close the Looking Glass window, `winvm` asks whether Windows should shut down;
shutting it down gives the GPU back to Linux.

## Tips

- **USB devices** (a USB stick, a license dongle):
  - virt-manager → the VM → Add Hardware → USB Host Device, or
  - with the VM running, `virsh attach-device win11 --live usb.xml`.

  Unmount USB storage on Linux first.
- **The virt-manager console after installing the IDD** stays black when "Make LG the only monitor"
  is on. That is expected: Windows draws only to the Looking Glass display.
- **Windows updates** that reset display settings can bring the two-monitor problem back; enable
  **Make LG the only monitor** again.
