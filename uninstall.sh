#!/usr/bin/env bash
# Undo what install.sh did, using its manifest (/var/lib/hypr-gpu-passthrough/manifest).
# Packages, the NVIDIA driver and group memberships stay. The VM stays unless you ask for its removal;
# a kept VM gets its definition from before the GPU passthrough back.
set -uo pipefail
# Predictable tool output and regular expressions (in tr_TR, for example, [a-z] does not match "i").
if locale -a 2> /dev/null | grep -q -i -x 'c\.utf-\?8'; then export LC_ALL=C.UTF-8; else export LC_ALL=C; fi

HGP_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$HGP_DIR/lib/common.sh"
# shellcheck source=lib/detect.sh
. "$HGP_DIR/lib/detect.sh"
# shellcheck source=lib/distro.sh
. "$HGP_DIR/lib/distro.sh"

REMOVE_VM=ask
while (( $# )); do
  case $1 in
    --dry-run) DRY_RUN=1 ;;
    --yes | -y) ASSUME_YES=1 ;;
    --remove-vm) REMOVE_VM=yes ;;
    --keep-vm) REMOVE_VM=no ;;
    -h | --help)
      cat <<EOF
Usage: sudo ./uninstall.sh [--dry-run] [--yes] [--remove-vm | --keep-vm]
  --remove-vm   also delete the VM, its disk and its ISOs (Windows and your files in it are lost)
  --keep-vm     keep the VM; it gets its definition from before the GPU passthrough back
EOF
      exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

[[ $EUID == 0 || $DRY_RUN == 1 ]] || die "Run with sudo: sudo ./uninstall.sh"
[[ -s $HGP_MANIFEST ]] || die "Nothing to undo: $HGP_MANIFEST not found."
detect_distro
detect_bootloader

VIRSH=(env LC_ALL=C virsh -c qemu:///system)
VM_NAME=$(state_get vm_name)
if [[ -n $VM_NAME ]]; then
  vm_state=$("${VIRSH[@]}" domstate "$VM_NAME" 2> /dev/null)
  [[ -z $vm_state || $vm_state == "shut off" ]] ||
    die "$VM_NAME is $vm_state. Shut Windows down first: without the hook the GPU would not return to Linux."
fi

# What to do with the VM.
vm_ours=0
grep -q -x "vm $VM_NAME" "$HGP_MANIFEST" && vm_ours=1
if [[ $vm_ours == 1 && $REMOVE_VM == ask ]]; then
  REMOVE_VM=no
  if [[ $ASSUME_YES != 1 && $DRY_RUN != 1 ]]; then
    read -r -p "Also delete the VM $VM_NAME with its disk (Windows and everything in it)? [y/N] " a < /dev/tty
    [[ $a == [yY]* ]] && REMOVE_VM=yes
  fi
fi
[[ $vm_ours == 1 ]] || REMOVE_VM=no

step "Undoing the changes of $HGP_NAME"
need_initramfs=0 need_udev=0 need_daemon=0

if [[ -n $VM_NAME ]] && "${VIRSH[@]}" dominfo "$VM_NAME" > /dev/null 2>&1; then
  if [[ $REMOVE_VM == yes ]]; then
    info "Deleting the VM $VM_NAME"
    try "${VIRSH[@]}" undefine "$VM_NAME" --nvram --tpm 2> /dev/null ||
      run "${VIRSH[@]}" undefine "$VM_NAME" --nvram
  else
    # The earliest saved definition is the one without passthrough.
    before=$(awk -v vm="$VM_NAME" '$1 == "vmxml" && $2 == vm {print $3; exit}' "$HGP_MANIFEST")
    if [[ -n $before && -s $before ]]; then
      info "Keeping $VM_NAME; restoring its definition from before the GPU passthrough"
      run "${VIRSH[@]}" define "$before"
    fi
  fi
fi

# Undo in reverse order.
dirs=()
while read -r kind a b; do
  case $kind in
    created)
      if [[ $a == */ ]]; then dirs+=("$a"); continue; fi
      [[ -e $a || -L $a ]] || continue
      case $a in
        /etc/udev/*) need_udev=1 ;;
        /etc/modprobe.d/*) need_initramfs=1 ;;
        /etc/libvirt/*) need_daemon=1 ;;
      esac
      run rm -f "$a" ;;
    modified)
      if [[ -n $b && -e $b ]]; then run cp -a "$b" "$a"; else warn "No backup for $a"; fi
      [[ $a == /etc/libvirt/* ]] && need_daemon=1 ;;
    block)
      remove_block "$a" "$b" ;;
    divert)
      run dpkg-divert --local --rename --remove "$a" ;;
    eglmove)
      try systemctl disable --now "$HGP_NAME-egl.path" 2> /dev/null
      [[ -e $b && ! -e $a ]] && run mv "$b" "$a" ;;
    swapfile)
      grep -q "^$a " /proc/swaps && run swapoff "$a"
      run rm -f "$a" ;;
    subvolume)
      if [[ -d $a && -z $(ls -A "$a" 2> /dev/null) ]]; then run btrfs subvolume delete "$a"; fi ;;
    fcontext)
      try semanage fcontext -d "$a" ;;
    kparams)
      info "Removing kernel parameters: $a $b"
      kernel_params remove "$a${b:+ $b}" ;;
    vmfile)
      [[ $REMOVE_VM == yes && -e $a ]] && run rm -f "$a" ;;
    groups)
      info "Group membership stays: $a in $b (remove with: sudo gpasswd -d $a GROUP)" ;;
  esac
done < <(tac "$HGP_MANIFEST")

for d in "${dirs[@]}"; do
  [[ -d $d && $d == */$HGP_NAME/ ]] && run rm -rf "$d"
done

if [[ $need_udev == 1 ]]; then
  run udevadm control --reload
  run udevadm trigger --action=change --subsystem-match=drm
fi
try systemctl daemon-reload
[[ $need_daemon == 1 ]] && try systemctl restart "$(libvirt_daemon).service"
[[ $need_initramfs == 1 ]] && initramfs_regen

if [[ $DRY_RUN != 1 ]]; then
  rm -rf "$HGP_ETC" "$HGP_STATE" "$HGP_MANIFEST"
  ok "Removed $HGP_ETC and the installer state. Backups stay in $HGP_BACKUP_ROOT."
fi
step "Done. Reboot so that the driver, display and kernel settings are back to normal."
