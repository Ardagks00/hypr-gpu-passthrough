# shellcheck shell=bash
# Stage "virt": libvirt, the GPU's vBIOS, the fake battery, security policy, shared memory, the
# configuration file and the libvirt hook (tested without a VM).

FIRMWARE_DIR=/var/lib/libvirt/$HGP_NAME   # vBIOS copy and battery table for the VM
ROM_FILE=$FIRMWARE_DIR/vbios.rom
BATTERY_AML=$FIRMWARE_DIR/battery.aml
HOOK_PATH=/etc/libvirt/hooks/qemu.d/$HGP_NAME
TMPFILES_CONF=/etc/tmpfiles.d/$HGP_NAME.conf
AA_LOCAL=/etc/apparmor.d/local/abstractions/libvirt-qemu
NV_MODULES=(nvidia_drm nvidia_modeset nvidia_uvm nvidia)
VIRSH=(env LC_ALL=C virsh -c qemu:///system)

nvidia_services() {   # NVIDIA services that exist here; the hook stops them while the VM runs
  local s out=()
  for s in nvidia-persistenced nvidia-powerd; do unit_exists "$s.service" && out+=("$s"); done
  echo "${out[*]}"
}

dgpu_holders() {   # "PID USER COMMAND" of every process that has the NVIDIA GPU open
  local n p pids nodes=()
  for n in /dev/nvidia* "/dev/dri/by-path/pci-$DGPU-card" "/dev/dri/by-path/pci-$DGPU-render"; do
    [[ -e $n ]] && nodes+=("$(readlink -f "$n")")
  done
  (( ${#nodes[@]} )) || return 0
  pids=$(fuser "${nodes[@]}" 2> /dev/null | tr -cs '0-9' ' ')
  for p in $pids; do ps -o pid=,user=,comm= -p "$p"; done | sort -u
}

die_holders() {
  die "These programs use the NVIDIA GPU; close them and run the installer again:
$1
If your compositor (Hyprland, kwin_wayland, Xorg…) is listed, log out and back in, or reboot,
so that the display settings from the host stage take effect."
}

virt_precheck() {
  local fail=die
  [[ $DRY_RUN == 1 ]] && fail=warn   # a dry run also shows the stages after the reboot
  [[ $IOMMU_ENABLED == 1 ]] ||
    $fail "The IOMMU is still off. Enable VT-d (Intel) or AMD-Vi/IOMMU (AMD) in the firmware setup, then run again."
  [[ $DGPU_DRIVER == nvidia ]] ||
    $fail "The NVIDIA driver is not bound to $DGPU (driver: ${DGPU_DRIVER:-none}). With Secure Boot on, its key may have to be enrolled (MOK) first. Check with: lspci -k -s $DGPU"
  [[ -e /dev/dri/igpu ]] || $fail "/dev/dri/igpu is missing. Run the host stage and reboot first."
  [[ $IOMMU_ENABLED == 1 && $DGPU_DRIVER == nvidia && -e /dev/dri/igpu ]] &&
    ok "IOMMU on, NVIDIA driver loaded, /dev/dri/igpu present"
  return 0
}

virt_libvirt() {
  libvirt_enable
  if ! "${VIRSH[@]}" net-info default > /dev/null 2>&1; then
    local xml
    for xml in /usr/share/libvirt/networks/default.xml /etc/libvirt/qemu/networks/default.xml; do
      [[ -f $xml ]] && break
    done
    [[ -f $xml ]] || die "libvirt's default network is missing and no default.xml was found."
    run "${VIRSH[@]}" net-define "$xml"
  fi
  "${VIRSH[@]}" net-info default 2> /dev/null | grep -q -i '^autostart:.*yes' || run "${VIRSH[@]}" net-autostart default
  "${VIRSH[@]}" net-list --name 2> /dev/null | grep -q -x default || run "${VIRSH[@]}" net-start default
  if [[ $IMAGES_FS == btrfs ]] && ! lsattr -d "$IMAGES_DIR" 2> /dev/null | cut -d' ' -f1 | grep -q C; then
    info "Disabling copy-on-write for new disk images in $IMAGES_DIR (btrfs)"
    [[ -d $IMAGES_DIR ]] || run install -d -m 711 "$IMAGES_DIR"
    run chattr +C "$IMAGES_DIR"
  fi
  run install -d -m 755 "$FIRMWARE_DIR"
  manifest_add "created $FIRMWARE_DIR/"
}

# Puts the NVIDIA driver back after virt_vbios unloaded it (also called on errors).
vbios_restore() {
  rm -f "/run/modprobe.d/$HGP_NAME-vbios.conf"
  echo 0 > "/sys/bus/pci/devices/$DGPU/rom" 2> /dev/null
  [[ -n ${VBIOS_PM:-} ]] && echo "$VBIOS_PM" > "/sys/bus/pci/devices/$DGPU/power/control"
  modprobe nvidia_drm || warn "Could not load nvidia_drm"
  udevadm settle --timeout=10
  local s
  for s in "${VBIOS_SERVICES[@]}"; do systemctl reset-failed "$s" 2> /dev/null; systemctl start "$s"; done
  VBIOS_SERVICES=() VBIOS_PM=""
}

# The VM gets a copy of the GPU's vBIOS: laptop GPUs have no readable ROM of their own in a VM.
virt_vbios() {
  local sys=/sys/bus/pci/devices/$DGPU vendor
  vendor=$(pci_attr "$DGPU" vendor)
  ROM_OK=0
  if [[ -s $ROM_FILE ]] && python3 "$HGP_DIR/files/romcheck.py" "$ROM_FILE" "$vendor" "$DGPU_DEVICE_ID" > /dev/null; then
    ok "vBIOS already saved: $ROM_FILE"
    ROM_OK=1
    return 0
  fi
  info "Reading the GPU's vBIOS (the NVIDIA driver is unloaded for a few seconds)"
  if [[ $DRY_RUN == 1 ]]; then
    run "stop NVIDIA services; unload ${NV_MODULES[*]}; cat $sys/rom > $ROM_FILE; reload the driver"
    ROM_OK=1
    return 0
  fi
  local s m holders tmp
  VBIOS_SERVICES=() VBIOS_PM=""
  for s in $(nvidia_services); do systemctl is-active --quiet "$s" && VBIOS_SERVICES+=("$s"); done
  (( ${#VBIOS_SERVICES[@]} )) && systemctl stop "${VBIOS_SERVICES[@]}"
  holders=$(dgpu_holders)
  if [[ -n $holders ]]; then
    vbios_restore
    die_holders "$holders"
  fi
  trap vbios_restore EXIT
  # While the driver is out, nothing may load it again (NVIDIA's udev rules would try).
  mkdir -p /run/modprobe.d
  printf 'install %s /bin/false\n' "${NV_MODULES[@]}" > "/run/modprobe.d/$HGP_NAME-vbios.conf"
  for m in "${NV_MODULES[@]}"; do
    [[ -d /sys/module/$m ]] || continue
    modprobe -r "$m" || die "Could not unload $m."
  done
  VBIOS_PM=$(cat "$sys/power/control")
  echo on > "$sys/power/control"
  tmp=$(mktemp)
  if echo 1 > "$sys/rom" && cat "$sys/rom" > "$tmp" 2> /dev/null && [[ -s $tmp ]]; then
    install -m 644 "$tmp" "$ROM_FILE"
  fi
  rm -f "$tmp"
  trap - EXIT
  vbios_restore
  [[ $(pci_driver "$DGPU") == nvidia ]] || die "The NVIDIA driver did not come back. Reboot, then run again."
  if [[ -s $ROM_FILE ]] && python3 "$HGP_DIR/files/romcheck.py" "$ROM_FILE" "$vendor" "$DGPU_DEVICE_ID" | sed 's/^/    /'; then
    ok "vBIOS saved: $ROM_FILE ($(stat -c %s "$ROM_FILE") bytes)"
    ROM_OK=1
  else
    rm -f "$ROM_FILE"
    warn "The vBIOS could not be read. The VM is set up without it; desktop GPUs usually work anyway."
  fi
}

virt_battery() {
  [[ $IS_LAPTOP == 1 ]] || return 0
  info "Building the fake battery ACPI table (laptop GPUs need a battery in the VM, or Code 43)"
  run iasl -vs -p "${BATTERY_AML%.aml}" "$HGP_DIR/files/battery-ssdt.asl"
  [[ $DRY_RUN == 1 || -s $BATTERY_AML ]] || die "iasl did not produce $BATTERY_AML."
}

# QEMU reads the vBIOS and the battery table (passed on its command line, which libvirt's security
# drivers do not know about) and the shared memory file.
virt_mac() {
  case $MAC in
    apparmor)
      if [[ ! -e /etc/apparmor.d/abstractions/libvirt-qemu ]]; then
        warn "AppArmor is on but libvirt's AppArmor profiles are not installed; skipping."
        return 0
      fi
      set_block "$AA_LOCAL" files <<EOF
$FIRMWARE_DIR/ r,
$FIRMWARE_DIR/* r,
/dev/shm/looking-glass rw,
EOF
      if [[ $DRY_RUN != 1 && -f /etc/apparmor.d/libvirt/TEMPLATE.qemu ]]; then
        apparmor_parser -Q -K /etc/apparmor.d/libvirt/TEMPLATE.qemu > /dev/null ||
          die "AppArmor rejected $AA_LOCAL."
        ok "AppArmor rules accepted"
      fi ;;
    selinux)
      selinux_label "$FIRMWARE_DIR(/.*)?" virt_content_t
      selinux_label /dev/shm/looking-glass svirt_tmpfs_t
      run restorecon -R "$FIRMWARE_DIR" ;;
    *) ok "No security module active" ;;
  esac
}

selinux_label() {   # selinux_label PATTERN TYPE
  if semanage fcontext -l 2> /dev/null | grep -q -F "$1 "; then
    run semanage fcontext -m -t "$2" "$1"
  else
    run semanage fcontext -a -t "$2" "$1"
  fi
  manifest_add "fcontext $1"
}

virt_shm() {
  qemu_identity
  write_file "$TMPFILES_CONF" 644 <<EOF
# $HGP_NAME: Looking Glass shared memory. QEMU writes it (group $QEMU_GROUP), the client
# reads it as $TARGET_USER.
f /dev/shm/looking-glass 0660 $TARGET_USER $QEMU_GROUP -
EOF
  run systemd-tmpfiles --create "$TMPFILES_CONF"
  [[ $MAC == selinux ]] && run restorecon /dev/shm/looking-glass
  return 0
}

conf_line() {
  [[ $2 != *"'"* ]] || die "Unexpected quote in $1."
  printf "%s='%s'\n" "$1" "$2"
}

# Settings shared by the hook, nvrun and winvm. Also rewritten by the vm-passthrough stage.
write_config() {
  {
    echo "# $HGP_NAME settings, written by install.sh. The libvirt hook, nvrun and winvm read them."
    echo "# Run the installer again instead of editing: the VM definition uses the same values."
    conf_line VM_NAME "$VM_NAME"
    conf_line DGPU "$DGPU"
    conf_line DGPU_PASS "$DGPU_PASS"
    conf_line IGPU "$IGPU"
    conf_line HOST_CPUS "$HOST_CPUS"
    conf_line VM_CPUS "$VM_CPUS"
    conf_line EMULATOR_CPUS "$EMULATOR_CPUS"
    conf_line NVIDIA_SERVICES "$(nvidia_services)"
    conf_line NVIDIA_EGL_JSON "$(egl_nvidia_path)"
    conf_line SHMEM_MIB "$SHMEM_MIB"
    conf_line LG_BUILD "$LG_BUILD"
  } | write_file "$HGP_CONF" 644
}

virt_hook() {
  write_file "$HOOK_PATH" 755 < "$HGP_DIR/files/qemu-hook"
  # libvirt looks for hooks only when the daemon starts.
  run systemctl restart "$(libvirt_daemon).service"
}

# Runs the hook like libvirt would, without a VM: the driver must leave and come back.
virt_selftest() {
  local xml="<domain><memory unit='KiB'>1048576</memory></domain>" out mods m drv s
  info "Testing the hook without a VM (the NVIDIA driver is unloaded and loaded again)"
  if [[ $DRY_RUN == 1 ]]; then
    run "$HOOK_PATH $VM_NAME prepare begin -; $HOOK_PATH $VM_NAME release end -"
    return 0
  fi
  "$HOOK_PATH" "$VM_NAME-other" prepare begin - <<< "$xml" || die "Hook test: failed for another VM name."
  [[ $(pci_driver "$DGPU") == nvidia ]] || die "Hook test: the hook acted on another VM."
  ok "Ignores other VMs"
  trap '"$HOOK_PATH" "$VM_NAME" release end - < /dev/null' EXIT
  if ! out=$("$HOOK_PATH" "$VM_NAME" prepare begin - <<< "$xml" 2>&1); then
    trap - EXIT
    "$HOOK_PATH" "$VM_NAME" release end - < /dev/null
    die "Hook test: prepare refused:
$out"
  fi
  mods=""
  for m in "${NV_MODULES[@]}"; do [[ -d /sys/module/$m ]] && mods+="$m "; done
  drv=$(pci_driver "$DGPU")
  "$HOOK_PATH" "$VM_NAME" release end - < /dev/null
  trap - EXIT
  [[ -z $mods && -z $drv ]] || die "Hook test: modules still loaded after prepare: ${mods:-none}, driver: ${drv:-none}"
  ok "prepare: NVIDIA driver unloaded"
  sleep 2
  [[ $(pci_driver "$DGPU") == nvidia ]] || die "Hook test: release did not bring the NVIDIA driver back."
  for s in $(nvidia_services); do
    systemctl is-enabled --quiet "$s" 2> /dev/null || continue
    systemctl is-active --quiet "$s" || warn "$s is not running after release"
  done
  ok "release: NVIDIA driver back"
}

stage_virt() {
  step "Stage 2/5: virt (libvirt, vBIOS, hook)"
  virt_precheck
  virt_libvirt
  write_config
  virt_vbios
  state_set rom_ok "$ROM_OK"
  virt_battery
  virt_mac
  virt_shm
  virt_hook
  virt_selftest

  checks
  if [[ $DRY_RUN != 1 ]]; then
    ok "Passed to the VM: $DGPU_PASS (IOMMU group $DGPU_GROUP)"
    [[ $ROM_OK == 1 ]] && ok "vBIOS: $ROM_FILE"
    [[ $IS_LAPTOP == 1 ]] && ok "Fake battery: $BATTERY_AML"
    ok "Hook: $HOOK_PATH (log: journalctl -t $HGP_NAME)"
  fi
  stage_mark virt
}
