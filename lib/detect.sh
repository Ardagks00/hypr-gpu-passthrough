# shellcheck shell=bash disable=SC2034
# System and hardware detection. Everything here only reads.
# (SC2034 is off: the variables set here are used by the other scripts.)

pci_attr() { cat "/sys/bus/pci/devices/$1/$2" 2>/dev/null; }
have_any() { local c; for c; do command -v "$c" > /dev/null && return 0; done; return 1; }
pci_name() { lspci -s "$1" 2>/dev/null | sed 's/^[^ ]* //; s/^[^:]*: //'; }
pci_driver() { local d; d=$(readlink -f "/sys/bus/pci/devices/$1/driver" 2>/dev/null) && basename "$d"; }

detect_distro() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
  local ID="" ID_LIKE="" PRETTY_NAME="" VERSION_ID=""
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID=$ID
  DISTRO_NAME=${PRETTY_NAME:-$ID}
  DISTRO_VERSION=$VERSION_ID
  case " $ID $ID_LIKE " in
    *" debian "* | *" ubuntu "*) DISTRO_FAMILY=debian ;;
    *" arch "*) DISTRO_FAMILY=arch ;;
    *" fedora "* | *" rhel "*) DISTRO_FAMILY=fedora ;;
    *suse*) DISTRO_FAMILY=suse ;;
    *) DISTRO_FAMILY=unknown ;;
  esac
  # Only Ubuntu-family installs have been tested end to end.
  DISTRO_TESTED=0
  [[ $DISTRO_FAMILY == debian ]] && DISTRO_TESTED=1
}

detect_user() {
  if [[ $EUID == 0 ]]; then
    TARGET_USER=${HGP_USER:-${SUDO_USER:-}}
  else
    TARGET_USER=$(id -un)   # dry run without sudo
  fi
  [[ -n $TARGET_USER && $TARGET_USER != root ]] ||
    die "Run the installer from your normal user account with sudo: sudo ./install.sh"
  TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
  [[ -d $TARGET_HOME ]] || die "Home directory of $TARGET_USER not found."
}

detect_gpus() {
  local dev cls ven nvidia=() others=()
  IGPU="" DGPU=""
  for dev in /sys/bus/pci/devices/*; do
    dev=${dev##*/}
    cls=$(pci_attr "$dev" class)
    [[ $cls == 0x0300* || $cls == 0x0302* || $cls == 0x0380* ]] || continue
    ven=$(pci_attr "$dev" vendor)
    if [[ $ven == 0x10de ]]; then
      nvidia+=("$dev")
    elif [[ $ven == 0x8086 || $ven == 0x1002 ]]; then
      if [[ -z $IGPU || $(pci_attr "$dev" boot_vga) == 1 ]]; then IGPU=$dev; fi
    fi
  done
  DGPU=${nvidia[0]:-}
  if [[ -n ${HGP_DGPU:-} ]]; then   # --gpu
    [[ $(pci_attr "$HGP_DGPU" vendor) == 0x10de && $(pci_attr "$HGP_DGPU" class) == 0x03* ]] ||
      die "$HGP_DGPU is not an NVIDIA GPU (see: lspci -D -d 10de:)."
    DGPU=$HGP_DGPU
  fi
  for dev in "${nvidia[@]}"; do [[ $dev == "$DGPU" ]] || others+=("$dev"); done
  DGPU_EXTRA=${others[*]}
  [[ -n $DGPU ]] || die "No NVIDIA GPU found. This project passes an NVIDIA card to the VM."
  [[ -n $IGPU ]] || die "No Intel or AMD integrated GPU found. The Linux desktop needs its own GPU while the NVIDIA card is in the VM."
  DGPU_DEVICE_ID=$(pci_attr "$DGPU" device)
  DGPU_SUB_VENDOR=$(pci_attr "$DGPU" subsystem_vendor)
  DGPU_SUB_DEVICE=$(pci_attr "$DGPU" subsystem_device)
  DGPU_SUB_VENDOR_DEC=$((DGPU_SUB_VENDOR))
  DGPU_SUB_DEVICE_DEC=$((DGPU_SUB_DEVICE))
  DGPU_NAME=$(pci_name "$DGPU")
  IGPU_NAME=$(pci_name "$IGPU")
  DGPU_DRIVER=$(pci_driver "$DGPU")
  DGPU_BOOT_VGA=$(pci_attr "$DGPU" boot_vga)
}

# IOMMU groups: every non-bridge device in the dGPU's group must go to the VM with it.
detect_iommu() {
  local dev
  IOMMU_ENABLED=0 DGPU_GROUP="" DGPU_GROUP_OK=0 DGPU_PASS="" DGPU_GROUP_FOREIGN=""
  compgen -G '/sys/kernel/iommu_groups/*' > /dev/null && IOMMU_ENABLED=1
  [[ $IOMMU_ENABLED == 1 ]] || return 0
  DGPU_GROUP=$(basename "$(readlink -f "/sys/bus/pci/devices/$DGPU/iommu_group")")
  for dev in /sys/kernel/iommu_groups/"$DGPU_GROUP"/devices/*; do
    dev=${dev##*/}
    if [[ $(pci_attr "$dev" vendor) == 0x10de ]]; then
      DGPU_PASS+="$dev "
    elif [[ $(pci_attr "$dev" class) != 0x0604* ]]; then
      DGPU_GROUP_FOREIGN+="$dev "
    fi
  done
  DGPU_PASS=${DGPU_PASS% }
  [[ -z $DGPU_GROUP_FOREIGN ]] && DGPU_GROUP_OK=1
}

detect_cpu() {
  CPU_VENDOR=intel
  grep -q AuthenticAMD /proc/cpuinfo && CPU_VENDOR=amd
  CPU_VIRT=0
  grep -q -w -E 'vmx|svm' /proc/cpuinfo && CPU_VIRT=1
  CPU_ERROR=""
  VM_CPUS=""
  eval "$(python3 "$HGP_DIR/lib/cpusel.py" "${HGP_VM_CORES:-0}")"
  [[ -z $CPU_ERROR ]] || die "$CPU_ERROR"
  [[ -n $VM_CPUS ]] || die "CPU topology detection failed."
}

detect_memory() {
  local total_kib swap_kib
  total_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  swap_kib=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
  # Firmware and the iGPU reserve some RAM, so round the visible size up to whole GiB.
  MEM_GIB=$(( (total_kib + 1048575) / 1048576 ))
  SWAP_GIB=$(( (swap_kib + 524288) / 1048576 ))   # an 8 GiB swap file shows as 8 GiB minus a page
  local vm=$(( MEM_GIB / 2 ))
  (( vm < 4 )) && vm=4
  (( vm > 32 )) && vm=32
  VM_RAM_GIB=${HGP_VM_RAM:-$vm}
  # VFIO pins all guest RAM. Without enough swap the host runs out of memory when the VM starts.
  SWAP_NEEDED_GIB=0
  if (( MEM_GIB - VM_RAM_GIB < 12 && SWAP_GIB < VM_RAM_GIB )); then
    SWAP_NEEDED_GIB=$VM_RAM_GIB
  fi
}

# Largest preferred mode on the iGPU's connected outputs → Looking Glass IDD shared memory size.
detect_display() {
  local conn card mode w=0 h=0 cw ch
  for conn in /sys/class/drm/card*-*; do
    [[ $(cat "$conn/status" 2>/dev/null) == connected ]] || continue
    card=${conn##*/}; card=${card%%-*}
    [[ $(basename "$(readlink -f "/sys/class/drm/$card/device")") == "$IGPU" ]] || continue
    mode=$(head -n 1 "$conn/modes" 2>/dev/null)
    [[ $mode =~ ^([0-9]+)x([0-9]+) ]] || continue
    cw=${BASH_REMATCH[1]} ch=${BASH_REMATCH[2]}
    (( cw * ch > w * h )) && w=$cw h=$ch
  done
  (( w == 0 )) && w=1920 h=1080
  DISPLAY_RES=${w}x${h}
  # Outputs wired to the NVIDIA GPU cannot be used by the Linux desktop (only inside the VM).
  DGPU_OUTPUTS=""
  for conn in /sys/class/drm/card*-*; do
    card=${conn##*/}; card=${card%%-*}
    [[ $(basename "$(readlink -f "/sys/class/drm/$card/device")") == "$DGPU" ]] || continue
    conn=${conn##*/}
    DGPU_OUTPUTS+="${conn#*-} "
  done
  DGPU_OUTPUTS=${DGPU_OUTPUTS% }
  # Formula from the Looking Glass IDD documentation, rounded up to a power of two (min 32 MiB).
  local bytes=$(( (w * 4 + 255) / 256 * 256 * h * 3 + 4 * 1024 * 1024 ))
  local mib=$(( (bytes + 1048575) / 1048576 )) size=32
  while (( size < mib )); do size=$(( size * 2 )); done
  SHMEM_MIB=${HGP_SHMEM_MIB:-$size}
}

detect_bootloader() {
  BOOTLOADER=unknown
  if [[ $DISTRO_FAMILY == suse && -r /etc/sysconfig/bootloader ]]; then
    case $(sed -n 's/^LOADER_TYPE="\?\([^"]*\)"\?/\1/p' /etc/sysconfig/bootloader) in
      grub2-bls | systemd-boot) BOOTLOADER=sdbootutil ;;
      grub2*) BOOTLOADER=grub ;;
    esac
  elif [[ $DISTRO_FAMILY == fedora ]] && command -v grubby > /dev/null; then
    BOOTLOADER=grubby
  elif [[ -f /etc/default/grub ]] && have_any update-grub grub-mkconfig grub2-mkconfig; then
    BOOTLOADER=grub
  elif [[ -f /etc/kernel/cmdline ]]; then
    BOOTLOADER=kernel-cmdline
  elif command -v bootctl > /dev/null && bootctl is-installed > /dev/null 2>&1; then
    BOOTLOADER=systemd-boot
  fi
}

detect_mac() {
  MAC=none
  if [[ $(cat /sys/fs/selinux/enforce 2>/dev/null) =~ ^[01]$ ]]; then
    MAC=selinux
  elif [[ $(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) == Y ]]; then
    MAC=apparmor
  fi
}

detect_secureboot() {
  SECURE_BOOT=unknown
  local var
  var=$(compgen -G '/sys/firmware/efi/efivars/SecureBoot-*' | head -n 1)
  if [[ -n $var ]]; then
    # The fifth byte of the variable is the state.
    if [[ $(od -An -t u1 -j 4 -N 1 "$var" 2>/dev/null | tr -d ' ') == 1 ]]; then SECURE_BOOT=enabled; else SECURE_BOOT=disabled; fi
  fi
}

detect_nvidia_driver() {
  NVIDIA_INSTALLED=0
  modinfo nvidia > /dev/null 2>&1 && NVIDIA_INSTALLED=1
  NVIDIA_OPEN=0
  [[ $(modinfo -F license nvidia 2>/dev/null) == "Dual MIT/GPL" ]] && NVIDIA_OPEN=1
  # Turing (2018) and newer GPUs can use NVIDIA's open kernel modules.
  local id=$((DGPU_DEVICE_ID))
  NVIDIA_TURING_PLUS=0
  (( id >= 0x1e00 )) && NVIDIA_TURING_PLUS=1
}

detect_misc() {
  IS_LAPTOP=0
  compgen -G '/sys/class/power_supply/BAT*' > /dev/null && IS_LAPTOP=1
  HYPRLAND=0
  command -v Hyprland > /dev/null && HYPRLAND=1
  IMAGES_DIR=/var/lib/libvirt/images
  IMAGES_FS=$(findmnt -n -o FSTYPE --target "$IMAGES_DIR" 2>/dev/null || findmnt -n -o FSTYPE --target /var/lib)
  ROOT_FS=$(findmnt -n -o FSTYPE --target / )
}

detect_all() {
  detect_distro
  detect_user
  detect_gpus
  detect_iommu
  detect_cpu
  detect_memory
  detect_display
  detect_bootloader
  detect_mac
  detect_secureboot
  detect_nvidia_driver
  detect_misc
}

print_summary() {
  local tested=" (tested)"
  [[ $DISTRO_TESTED == 1 ]] || tested=" (${C_YEL}experimental: not tested yet${C_RST})"
  step "Detected system"
  printf '  %-22s %s\n' \
    "Distribution" "$DISTRO_NAME [$DISTRO_FAMILY]$tested" \
    "User" "$TARGET_USER ($TARGET_HOME)" \
    "Integrated GPU" "$IGPU ($IGPU_NAME)" \
    "NVIDIA GPU" "$DGPU ($DGPU_NAME), driver: ${DGPU_DRIVER:-none}" \
    "  subsystem ID" "$DGPU_SUB_VENDOR:$DGPU_SUB_DEVICE (decimal $DGPU_SUB_VENDOR_DEC / $DGPU_SUB_DEVICE_DEC)" \
    "IOMMU" "$( [[ $IOMMU_ENABLED == 1 ]] && echo "on, dGPU group $DGPU_GROUP: $DGPU_PASS" || echo "off (will be enabled)")" \
    "CPU" "$CPU_VENDOR, $CPU_TOTAL_CORES cores$( [[ $CPU_HYBRID == 1 ]] && echo " ($CPU_PCORES P + $CPU_ECORES E)")" \
    "VM CPUs" "$VM_CPUS ($VM_CORES cores x $VM_THREADS threads), host keeps $HOST_CPUS, emulator $EMULATOR_CPUS" \
    "Memory" "$MEM_GIB GiB RAM, $SWAP_GIB GiB swap; VM gets $VM_RAM_GIB GiB$( (( SWAP_NEEDED_GIB > 0 )) && echo "; a $SWAP_NEEDED_GIB GiB swap file will be added")" \
    "Display" "$DISPLAY_RES → Looking Glass shared memory $SHMEM_MIB MiB" \
    "NVIDIA outputs" "${DGPU_OUTPUTS:-none}$( [[ -n $DGPU_OUTPUTS ]] && echo " (usable only inside the VM)")" \
    "Boot loader" "$BOOTLOADER" \
    "Security module" "$MAC" \
    "Secure Boot" "$SECURE_BOOT" \
    "Laptop" "$( [[ $IS_LAPTOP == 1 ]] && echo "yes (fake battery ACPI table will be added)" || echo no)" \
    "Hyprland" "$( [[ $HYPRLAND == 1 ]] && echo installed || echo "not found")"
}

# Hard requirements; stops with an explanation when something cannot work.
preflight() {
  [[ $(uname -m) == x86_64 ]] || die "Only x86_64 is supported."
  [[ $DISTRO_FAMILY != unknown ]] || die "Unsupported distribution ($DISTRO_NAME). Supported families: Debian/Ubuntu, Arch, Fedora, openSUSE."
  [[ $CPU_VIRT == 1 ]] || die "Hardware virtualization (VT-x / AMD-V) is off. Enable it in the firmware setup."
  if [[ $IOMMU_ENABLED == 1 && $DGPU_GROUP_OK != 1 ]]; then
    die "The NVIDIA GPU shares its IOMMU group ($DGPU_GROUP) with other devices: $DGPU_GROUP_FOREIGN. Passing it through safely is not possible on this board (ACS override is deliberately not offered)."
  fi
  if [[ -n $DGPU_EXTRA ]]; then
    warn "More than one NVIDIA GPU found. Using $DGPU; the others ($DGPU_EXTRA) stay with Linux."
    warn "To pass another one to the VM, run the installer with --gpu ADDRESS."
  fi
  if [[ $DGPU_BOOT_VGA == 1 ]]; then
    warn "The firmware uses the NVIDIA GPU as the primary display. Your screen must be driven by the integrated GPU:"
    warn "laptops with a MUX switch: select hybrid/Optimus mode; desktops: connect the monitor to the motherboard."
    confirm "Continue anyway?" || exit 1
  fi
  (( VM_RAM_GIB >= 4 && VM_RAM_GIB <= MEM_GIB - 4 )) ||
    die "The VM needs at least 4 GiB and Linux keeps at least 4 GiB: --vm-ram must be between 4 and $(( MEM_GIB - 4 ))."
  if [[ $DISTRO_TESTED != 1 ]]; then
    warn "$DISTRO_NAME support is experimental and has not been tested yet. Read every step before confirming."
  fi
  [[ $HYPRLAND == 1 ]] || warn "Hyprland was not found. Everything still works, but the desktop integration was written for Hyprland."
}
