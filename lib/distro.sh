# shellcheck shell=bash disable=SC2034
# (SC2034 is off: some variables set here are used by the other scripts.)
# Distribution specific pieces: packages, NVIDIA driver, initramfs, kernel command line,
# libvirt daemons and the NVIDIA EGL vendor file.

# ------------------------------------------------------------- packages ---

pkg_refresh() {
  case $DISTRO_FAMILY in
    debian) run apt-get update ;;
    suse) run zypper --non-interactive refresh ;;
    # Arch: refreshing without upgrading causes partial upgrades; the user keeps the system current.
    # Fedora: dnf refreshes metadata by itself.
  esac
}

pkg_install() {
  (( $# )) || return 0
  case $DISTRO_FAMILY in
    debian) run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    arch) run pacman -S --needed --noconfirm "$@" ;;
    fedora) run dnf install -y "$@" ;;
    suse) run zypper --non-interactive install "$@" ;;
  esac
}

# Packages for QEMU/KVM, libvirt, UEFI firmware, TPM emulation and the helper tools we call.
packages_virt() {
  case $DISTRO_FAMILY in
    debian) echo qemu-system-x86 libvirt-daemon-system libvirt-clients virt-manager ovmf swtpm swtpm-tools \
                 acpica-tools psmisc pciutils curl python3 libxml2-utils ;;
    arch) echo qemu-desktop libvirt virt-manager edk2-ovmf swtpm dnsmasq acpica psmisc pciutils curl python \
               libxml2 ;;
    fedora) echo qemu-kvm libvirt virt-manager edk2-ovmf swtpm swtpm-tools acpica-tools psmisc pciutils curl \
                 python3 libxml2 policycoreutils-python-utils ;;
    suse) echo qemu-x86 libvirt virt-manager qemu-ovmf-x86_64 swtpm acpica psmisc pciutils curl python3 \
               libxml2-tools policycoreutils-python-utils ;;
  esac
}

# Build dependencies of the Looking Glass client (from its documentation, plus fuse3, which the
# current development builds require but the list does not mention).
packages_lg() {
  case $DISTRO_FAMILY in
    debian) echo binutils cmake make gcc g++ pkg-config fonts-dejavu-core libdw-dev libfontconfig-dev \
                 libgmp-dev libunwind-dev libegl-dev libgl-dev libgles-dev libspice-protocol-dev nettle-dev \
                 libx11-dev libxcursor-dev libxfixes-dev libxi-dev libxinerama-dev libxpresent-dev \
                 libxrandr-dev libxss-dev libxkbcommon-dev libwayland-bin libwayland-dev \
                 libpipewire-0.3-dev libpulse-dev libsamplerate0-dev libusbredirparser-dev libfuse3-dev ;;
    arch) echo base-devel cmake binutils ttf-dejavu libelf fontconfig gmp libunwind libglvnd mesa \
               spice-protocol nettle libx11 libxcursor libxfixes libxi libxinerama libxpresent libxrandr \
               libxss libxkbcommon wayland wayland-protocols pipewire libpulse libsamplerate usbredir fuse3 ;;
    fedora) echo gcc gcc-c++ cmake make pkgconf-pkg-config binutils dejavu-sans-mono-fonts elfutils-devel \
                 fontconfig-devel gmp-devel libunwind-devel mesa-libEGL-devel mesa-libGL-devel \
                 mesa-libGLES-devel spice-protocol nettle-devel libX11-devel libXcursor-devel libXfixes-devel \
                 libXi-devel libXinerama-devel libXpresent-devel libXrandr-devel libXScrnSaver-devel \
                 libxkbcommon-devel wayland-devel wayland-protocols-devel pipewire-devel \
                 pulseaudio-libs-devel libsamplerate-devel usbredir-devel fuse3-devel ;;
    suse) echo gcc gcc-c++ cmake make pkg-config binutils dejavu-fonts libdw-devel fontconfig-devel \
               gmp-devel libunwind-devel Mesa-libEGL-devel Mesa-libGL-devel Mesa-libGLESv2-devel \
               spice-protocol-devel libnettle-devel libX11-devel libXcursor-devel libXfixes-devel \
               libXi-devel libXinerama-devel libXpresent-devel libXrandr-devel libXss-devel \
               libxkbcommon-devel wayland-devel wayland-protocols-devel pipewire-devel libpulse-devel \
               libsamplerate-devel libusbredirparser-devel fuse3-devel ;;
  esac
}

# --------------------------------------------------------------- NVIDIA ---

nvidia_install() {
  local open_note="NVIDIA's open kernel modules"
  [[ $NVIDIA_TURING_PLUS == 1 ]] || open_note="the proprietary NVIDIA driver (GPU older than Turing)"
  info "Installing $open_note"
  case $DISTRO_FAMILY in
    debian)
      if command -v ubuntu-drivers > /dev/null; then
        run ubuntu-drivers install
      elif [[ $NVIDIA_TURING_PLUS == 1 ]]; then
        pkg_install nvidia-open-kernel-dkms nvidia-driver firmware-misc-nonfree
      else
        pkg_install nvidia-kernel-dkms nvidia-driver firmware-misc-nonfree
      fi ;;
    arch)
      local kernel headers=()
      for kernel in $(pacman -Qq | grep -E '^linux(-lts|-zen|-hardened|-rt)?$'); do headers+=("$kernel-headers"); done
      if [[ $NVIDIA_TURING_PLUS == 1 ]]; then
        pkg_install "${headers[@]}" nvidia-open-dkms nvidia-utils
      else
        die "Arch no longer packages drivers for GPUs older than Turing; install one from the AUR, then run again."
      fi ;;
    fedora)
      rpm -q rpmfusion-nonfree-release > /dev/null 2>&1 ||
        die "Enable the RPM Fusion nonfree repository first (https://rpmfusion.org/Configuration), then run again."
      pkg_install akmod-nvidia xorg-x11-drv-nvidia-cuda
      info "Building the kernel module with akmods (this can take several minutes)"
      run akmods --force ;;
    suse)
      local path=tumbleweed
      [[ $DISTRO_ID == opensuse-leap ]] && path=leap/$DISTRO_VERSION
      if ! zypper lr -u 2>/dev/null | grep -q download.nvidia.com; then
        warn "Adding NVIDIA's repository. When zypper asks, check the key fingerprint:"
        warn "2FB0 3195 DECD 4949 2BD1 C17A B1D0 D788 DB27 FD5A"
        run zypper addrepo --refresh "https://download.nvidia.com/opensuse/$path" NVIDIA
        run zypper refresh
      fi
      pkg_install nvidia-open-driver-G06-signed-kmp-default nvidia-video-G06 nvidia-gl-G06 nvidia-compute-utils-G06 ;;
  esac
  [[ $SECURE_BOOT == enabled ]] &&
    warn "Secure Boot is on. If the driver was built locally (DKMS/akmods), you may have to enroll its key (MOK) at the next boot."
  return 0
}

initramfs_regen() {
  if command -v update-initramfs > /dev/null; then run update-initramfs -u -k all
  elif command -v mkinitcpio > /dev/null; then run mkinitcpio -P
  elif command -v dracut > /dev/null; then run dracut -f --regenerate-all
  else warn "No initramfs tool found; skipping."
  fi
}

# ------------------------------------------------------- kernel cmdline ---

kernel_params() {   # kernel_params add|remove "param1 param2"
  local action=$1 params=$2 p
  case $BOOTLOADER in
    grub)
      local f=/etc/default/grub
      backup_file "$f" > /dev/null
      for p in $params; do
        if [[ $action == add ]]; then
          grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=.*\b$p\b" "$f" ||
            run sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=)([\"'])(.*)\2$/\1\2\3 $p\2/" "$f"
        else
          run sed -i -E "/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/ ?\b$p\b//" "$f"
        fi
      done
      if command -v update-grub > /dev/null; then run update-grub
      elif [[ -d /boot/grub2 ]]; then run grub2-mkconfig -o /boot/grub2/grub.cfg
      else run grub-mkconfig -o /boot/grub/grub.cfg
      fi ;;
    grubby)
      if [[ $action == add ]]; then run grubby --update-kernel=ALL --args="$params"
      else run grubby --update-kernel=ALL --remove-args="$params"; fi ;;
    sdbootutil | kernel-cmdline)
      local f=/etc/kernel/cmdline
      backup_file "$f" > /dev/null
      [[ -f $f || $DRY_RUN == 1 ]] || cut -d' ' -f2- /proc/cmdline > "$f"
      for p in $params; do
        if [[ $action == add ]]; then grep -q "\b$p\b" "$f" || run sed -i "s/\$/ $p/" "$f"
        else run sed -i -E "s/ ?\b$p\b//" "$f"; fi
      done
      if [[ $BOOTLOADER == sdbootutil ]]; then run sdbootutil update-all-entries
      else initramfs_regen   # unified kernel images embed the command line
      fi ;;
    systemd-boot)
      local entry
      for entry in /boot/loader/entries/*.conf /efi/loader/entries/*.conf /boot/efi/loader/entries/*.conf; do
        [[ -f $entry ]] || continue
        backup_file "$entry" > /dev/null
        for p in $params; do
          if [[ $action == add ]]; then grep -q "^options.*\b$p\b" "$entry" || run sed -i "/^options/ s/\$/ $p/" "$entry"
          else run sed -i -E "/^options/ s/ ?\b$p\b//" "$entry"; fi
        done
      done ;;
    *)
      die "Unknown boot loader. Add these kernel parameters by hand, reboot and run again: $params" ;;
  esac
}

# --------------------------------------------------------------- libvirt ---

libvirt_daemon() {   # prints the unit that runs the QEMU driver
  if systemctl list-unit-files virtqemud.socket > /dev/null 2>&1 && systemctl is-enabled virtqemud.socket > /dev/null 2>&1; then
    echo virtqemud
  else
    echo libvirtd
  fi
}

unit_exists() { systemctl list-unit-files "$1" 2>/dev/null | grep -q "^$1"; }

# Keep whatever daemon layout the distribution set up; only choose one when nothing is enabled.
libvirt_enable() {
  if systemctl is-enabled libvirtd.socket libvirtd.service 2>/dev/null | grep -q -x enabled; then
    try systemctl start libvirtd.socket 2>/dev/null || run systemctl start libvirtd.service
  elif unit_exists virtqemud.socket; then
    local u
    for u in virtqemud virtnetworkd virtstoraged virtnodedevd virtsecretd virtlogd; do
      unit_exists "$u.socket" && run systemctl enable --now "$u.socket"
    done
  else
    try systemctl enable --now libvirtd.socket || run systemctl enable --now libvirtd.service
  fi
}

# The group QEMU runs as (it differs between distributions); the shared memory file must be
# readable and writable by both QEMU and the desktop user.
qemu_identity() {
  local conf=/etc/libvirt/qemu.conf u="" g="" ids
  # libvirt reports the uid:gid QEMU runs as (build defaults plus qemu.conf), e.g. +64055:+991.
  ids=$(virsh -c qemu:///system capabilities 2> /dev/null | sed -n "s|.*<baselabel type='kvm'>+\([0-9]*\):+\([0-9]*\)</baselabel>.*|\1 \2|p" | head -n 1)
  if [[ -n $ids ]]; then
    g=$(getent group "${ids#* }" | cut -d: -f1)
    if [[ -n $g ]]; then
      QEMU_GROUP=$g
      return 0
    fi
  fi
  u=$(sed -n 's/^[[:space:]]*user[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$conf" 2>/dev/null | tail -n 1)
  g=$(sed -n 's/^[[:space:]]*group[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$conf" 2>/dev/null | tail -n 1)
  if [[ -z $u ]]; then
    for u in libvirt-qemu qemu; do getent passwd "$u" > /dev/null && break; done
  fi
  [[ -n $g ]] || g=$(id -gn "$u" 2>/dev/null || echo kvm)
  QEMU_GROUP=$g
}

# ------------------------------------------------------ NVIDIA EGL file ---
# Programs that enumerate EGL devices (Hyprland, hyprpaper, hyprlauncher, Electron apps…) load
# NVIDIA's EGL library, which keeps /dev/nvidiactl open and blocks the hand-over to the VM.
# The fix keeps NVIDIA's EGL vendor file out of the default search path; nvrun adds it back.

EGL_NV=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
EGL_NV_AWAY=/usr/share/glvnd/10_nvidia.json.$HGP_NAME

egl_nvidia_path() {   # where the moved file lives (an existing dpkg diversion wins)
  if command -v dpkg-divert > /dev/null && dpkg-divert --list "$EGL_NV" 2>/dev/null | grep -q .; then
    dpkg-divert --truename "$EGL_NV"
  else
    echo "$EGL_NV_AWAY"
  fi
}

egl_nvidia_disable() {
  if command -v dpkg-divert > /dev/null && dpkg -S "$EGL_NV" > /dev/null 2>&1; then
    if dpkg-divert --list "$EGL_NV" | grep -q .; then
      ok "NVIDIA EGL file already diverted to $(dpkg-divert --truename "$EGL_NV")"
    else
      run dpkg-divert --local --rename --divert "$EGL_NV_AWAY" --add "$EGL_NV"
      manifest_add "divert $EGL_NV"
    fi
    return 0
  fi
  # rpm and pacman have no diversions: move the file, and a systemd path unit moves it again
  # whenever a driver update puts it back.
  write_file "/etc/systemd/system/$HGP_NAME-egl.service" 644 <<EOF
[Unit]
Description=Keep NVIDIA's EGL vendor file out of the default search path ($HGP_NAME)

[Service]
Type=oneshot
ExecStart=/usr/bin/mv -f $EGL_NV $EGL_NV_AWAY
EOF
  write_file "/etc/systemd/system/$HGP_NAME-egl.path" 644 <<EOF
[Unit]
Description=Watch for NVIDIA's EGL vendor file ($HGP_NAME)

[Path]
PathExists=$EGL_NV

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
  run systemctl enable --now "$HGP_NAME-egl.path"
  [[ -e $EGL_NV ]] && run mv -f "$EGL_NV" "$EGL_NV_AWAY"
  manifest_add "eglmove $EGL_NV $EGL_NV_AWAY"
}
