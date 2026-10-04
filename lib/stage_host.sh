# shellcheck shell=bash
# Stage "host": packages, IOMMU, the NVIDIA driver and the Linux side of the GPU hand-over.
# Ends with a reboot.

UDEV_IGPU=/etc/udev/rules.d/61-$HGP_NAME-igpu.rules
UDEV_NOSEAT=/etc/udev/rules.d/72-$HGP_NAME-noseat.rules
MODPROBE_CONF=/etc/modprobe.d/zz-$HGP_NAME.conf

# Setups that would fight with this one.
host_conflicts() {
  if [[ $DGPU_DRIVER == vfio-pci ]]; then
    die "The NVIDIA GPU is bound to vfio-pci at boot (static passthrough, e.g. vfio-pci.ids=… on the kernel command line or in /etc/modprobe.d). This project moves the card between Linux and the VM on demand; remove that setting, reboot and run again."
  fi
  local hook=/etc/libvirt/hooks/qemu
  if [[ -x $hook ]] && ! manifest_has "$hook" && grep -q -i -E 'nvidia|vfio|modprobe' "$hook"; then
    warn "Another libvirt hook that manages GPUs is installed: $hook"
    warn "Both would run when the VM starts and stops."
    if confirm "Disable it? (it is backed up and restored if you uninstall)"; then
      track_file "$hook"
      run chmod a-x "$hook"   # libvirt only runs executable hooks
    else
      die "Remove or adapt $hook, then run again."
    fi
  fi
}

host_packages() {
  info "Installing QEMU/KVM, libvirt, UEFI firmware and TPM emulation"
  pkg_refresh
  # shellcheck disable=SC2046
  pkg_install $(packages_virt)
  local g groups=()
  for g in libvirt kvm; do
    if getent group "$g" > /dev/null || [[ $DRY_RUN == 1 ]]; then
      id -nG "$TARGET_USER" | tr ' ' '\n' | grep -q -x "$g" || groups+=("$g")
    fi
  done
  if (( ${#groups[@]} )); then
    run usermod -a -G "$(IFS=,; echo "${groups[*]}")" "$TARGET_USER"
    manifest_add "groups $TARGET_USER ${groups[*]}"
  fi
}

host_iommu() {
  if [[ $IOMMU_ENABLED == 1 ]]; then
    ok "IOMMU is already on"
    return 0
  fi
  local params="iommu=pt"
  [[ $CPU_VENDOR == intel ]] && params="intel_iommu=on iommu=pt"
  info "Enabling the IOMMU on the kernel command line: $params"
  kernel_params add "$params"
  manifest_add "kparams $params"
}

host_nvidia() {
  if [[ $NVIDIA_INSTALLED == 1 ]]; then
    ok "NVIDIA driver is installed ($( [[ $NVIDIA_OPEN == 1 ]] && echo "open kernel modules" || echo "proprietary kernel modules"))"
  else
    nvidia_install
  fi
  # KMS on, but no framebuffer console on the NVIDIA GPU: it would keep nvidia_drm loaded.
  write_file "$MODPROBE_CONF" 644 <<EOF
# $HGP_NAME: kernel mode setting on, no fbdev console on the NVIDIA GPU (it would block unloading
# the driver before the VM starts).
options nvidia-drm modeset=1 fbdev=0
EOF
}

host_udev() {
  write_file "$UDEV_IGPU" 644 <<EOF
# $HGP_NAME: stable path /dev/dri/igpu for the integrated GPU. Compositors are told to use only
# this GPU (AQ_DRM_DEVICES, KWIN_DRM_DEVICES); the path must not contain ':' for AQ_DRM_DEVICES.
SUBSYSTEM=="drm", KERNEL=="card[0-9]*", KERNELS=="$IGPU", SYMLINK+="dri/igpu"
EOF
  write_file "$UDEV_NOSEAT" 644 <<EOF
# $HGP_NAME: the NVIDIA GPU's display node belongs to no seat. When the driver comes back after
# the VM, compositors treat the card as hot-plugged and would open it, ignoring AQ_DRM_DEVICES;
# logind does not hand out devices without a seat. Render nodes and /dev/nvidia* are not affected:
# PRIME offload (nvrun) and CUDA keep working. Runs after 71-seat.rules.
SUBSYSTEM=="drm", KERNEL=="card[0-9]*", KERNELS=="$DGPU", TAG-="seat", TAG-="master-of-seat"
EOF
  run udevadm control --reload
  run udevadm trigger --action=change --subsystem-match=drm
  run udevadm settle --timeout=10
  if [[ $DRY_RUN == 1 ]]; then return 0; fi
  if [[ -e /dev/dri/igpu ]]; then
    ok "/dev/dri/igpu → $(readlink -f /dev/dri/igpu)"
  else
    die "/dev/dri/igpu was not created. Check $UDEV_IGPU (integrated GPU: $IGPU)."
  fi
}

host_environment() {
  # Compositors use only the integrated GPU; GTK 4 does not open the NVIDIA GPU through Vulkan.
  set_block /etc/environment display <<EOF
AQ_DRM_DEVICES=/dev/dri/igpu
KWIN_DRM_DEVICES=/dev/dri/igpu
GDK_DISABLE=vulkan
EOF
}

host_swap() {
  local file
  # A swap file from an earlier, interrupted run is kept.
  file=$(awk '$1 == "swapfile" {print $2}' "$HGP_MANIFEST" 2> /dev/null | tail -n 1)
  if [[ -n $file && -e $file ]]; then
    grep -q "^$file " /proc/swaps || run swapon "$file"
    set_block /etc/fstab swap <<< "$file none swap defaults 0 0"
    ok "Swap file: $file"
    return 0
  fi
  (( SWAP_NEEDED_GIB > 0 )) || { ok "Swap: $SWAP_GIB GiB is enough"; return 0; }
  info "Adding a $SWAP_NEEDED_GIB GiB swap file (VFIO pins all VM memory; without swap Linux can run out of memory)"
  if [[ $ROOT_FS == btrfs ]]; then
    # A swap file on btrfs must live in a subvolume that is never snapshotted.
    if [[ ! -e /swap ]]; then
      run btrfs subvolume create /swap
      manifest_add "subvolume /swap"
    fi
    file=/swap/$HGP_NAME.swap
    [[ -e $file ]] && die "$file already exists."
    run btrfs filesystem mkswapfile --size "${SWAP_NEEDED_GIB}g" "$file"
  else
    file=$HGP_VAR/swapfile
    [[ -e $file ]] && die "$file already exists."
    run install -d -m 700 "$HGP_VAR"
    run fallocate -l "${SWAP_NEEDED_GIB}G" "$file"
    run chmod 600 "$file"
    run mkswap "$file"
  fi
  manifest_add "swapfile $file"
  run swapon "$file"
  set_block /etc/fstab swap <<< "$file none swap defaults 0 0"
}

stage_host() {
  step "Stage 1/5: host (packages, IOMMU, NVIDIA driver, display setup)"
  host_conflicts
  host_packages
  host_iommu
  host_nvidia
  host_udev
  host_environment
  egl_nvidia_disable
  host_swap
  initramfs_regen

  checks
  if [[ $DRY_RUN != 1 ]]; then
    local f
    for f in "$MODPROBE_CONF" "$UDEV_IGPU" "$UDEV_NOSEAT"; do [[ -s $f ]] && ok "$f"; done
    grep -q '^AQ_DRM_DEVICES=/dev/dri/igpu$' /etc/environment && ok "/etc/environment: AQ_DRM_DEVICES, KWIN_DRM_DEVICES, GDK_DISABLE"
    [[ -e $EGL_NV ]] && die "$EGL_NV is still in place."
    ok "NVIDIA EGL vendor file moved to $(egl_nvidia_path)"
    swapon --show=NAME,SIZE --noheadings | sed 's/^/  swap: /'
  fi
  state_set reboot_boot_id "$(cat /proc/sys/kernel/random/boot_id)"
  stage_mark host
}
