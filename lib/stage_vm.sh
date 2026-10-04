# shellcheck shell=bash
# Stages "vm-create" (a VM without the GPU, for installing Windows) and "vm-passthrough" (adds the
# GPU, Looking Glass and the tuning once Windows is installed).

# virtio-win drivers. The server publishes no checksum for the ISO; this one was downloaded over
# HTTPS and has been in use since.
VIRTIO_VERSION=0.1.302
VIRTIO_URL=https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-$VIRTIO_VERSION-1/virtio-win-$VIRTIO_VERSION.iso
VIRTIO_SHA256=303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d
VIRTIO_SIZE=877373440

vm_state() { "${VIRSH[@]}" domstate "$VM_NAME" 2> /dev/null; }

# The storage pool that holds $IMAGES_DIR; virt-manager may have created one already.
vm_pool() {
  local p
  for p in $("${VIRSH[@]}" pool-list --all --name 2> /dev/null); do
    if "${VIRSH[@]}" pool-dumpxml "$p" 2> /dev/null | grep -q "<path>$IMAGES_DIR/\?</path>"; then
      VM_POOL=$p
      break
    fi
  done
  if [[ -z ${VM_POOL:-} ]]; then
    VM_POOL=default
    "${VIRSH[@]}" pool-info "$VM_POOL" > /dev/null 2>&1 && VM_POOL=$HGP_NAME
    run "${VIRSH[@]}" pool-define-as "$VM_POOL" dir --target "$IMAGES_DIR"
    run "${VIRSH[@]}" pool-autostart "$VM_POOL"
  fi
  "${VIRSH[@]}" pool-list --name 2> /dev/null | grep -q -x "$VM_POOL" || run "${VIRSH[@]}" pool-start "$VM_POOL"
  ok "Storage pool: $VM_POOL ($IMAGES_DIR)"
}

vm_find_windows_iso() {
  if [[ -n $WINDOWS_ISO ]]; then
    [[ -s $WINDOWS_ISO ]] || die "$WINDOWS_ISO not found."
    return 0
  fi
  local downloads found=()
  downloads=$(as_user xdg-user-dir DOWNLOAD 2> /dev/null || echo "$TARGET_HOME/Downloads")
  mapfile -t found < <(find "$downloads" "$TARGET_HOME" -maxdepth 1 -iname 'Win11*.iso' 2> /dev/null | sort -u)
  if (( ${#found[@]} != 1 )); then
    local msg="Windows 11 ISO not found (or more than one in $downloads). Download it from
https://www.microsoft.com/software-download/windows11 and run: sudo ./install.sh --windows-iso PATH"
    [[ $DRY_RUN == 1 ]] || die "$msg"
    warn "$msg"
    found=("$downloads/Win11.iso")
  fi
  WINDOWS_ISO=${found[0]}
}

vm_virtio_iso() {
  VIRTIO_DEST=$IMAGES_DIR/virtio-win-$VIRTIO_VERSION.iso
  if [[ -n $VIRTIO_ISO ]]; then
    [[ -s $VIRTIO_ISO ]] || die "$VIRTIO_ISO not found."
    run cp --reflink=auto "$VIRTIO_ISO" "$VIRTIO_DEST"
  elif [[ -s $VIRTIO_DEST ]] && echo "$VIRTIO_SHA256  $VIRTIO_DEST" | sha256sum -c --status 2> /dev/null; then
    ok "virtio-win drivers already downloaded: $VIRTIO_DEST"
    return 0
  else
    info "Windows needs the virtio-win drivers for the VM's disk and network:"
    info "  $VIRTIO_URL"
    info "  file virtio-win-$VIRTIO_VERSION.iso, $(human_size "$VIRTIO_SIZE"), SHA-256 $VIRTIO_SHA256"
    confirm "Download it?" || die "The drivers are required. Or pass a local copy with --virtio-iso PATH."
    run curl -fL --proto '=https' --tlsv1.2 -o "$VIRTIO_DEST.part" "$VIRTIO_URL"
    if [[ $DRY_RUN != 1 ]]; then
      echo "$VIRTIO_SHA256  $VIRTIO_DEST.part" | sha256sum -c --status ||
        { rm -f "$VIRTIO_DEST.part"; die "Checksum mismatch for the downloaded virtio-win ISO."; }
      mv "$VIRTIO_DEST.part" "$VIRTIO_DEST"
      ok "Checksum verified"
    fi
  fi
  run chmod 644 "$VIRTIO_DEST"
  manifest_add "vmfile $VIRTIO_DEST"
}

stage_vm_create() {
  step "Stage 4/5: vm-create (Windows VM without the GPU, for installing Windows)"
  local disk=$IMAGES_DIR/$VM_NAME.qcow2 win_dest=$IMAGES_DIR/$VM_NAME-windows.iso out
  local xml=$HGP_VAR/$VM_NAME-install.xml
  if "${VIRSH[@]}" dominfo "$VM_NAME" > /dev/null 2>&1; then
    if [[ $(state_get vm_created) != "$VM_NAME" ]]; then
      [[ $DRY_RUN == 1 ]] || die "A VM named $VM_NAME already exists. Pick another name with --vm-name NAME."
      warn "A VM named $VM_NAME already exists; a real run stops here (use --vm-name NAME)."
    fi
    ok "VM $VM_NAME exists"
  else
    if [[ -e $disk ]] && ! grep -q -x -F "vmfile $disk" "$HGP_MANIFEST" 2> /dev/null; then
      die "$disk already exists."
    fi
    vm_find_windows_iso
    info "Windows ISO: $WINDOWS_ISO"
    vm_virtio_iso
    vm_pool
    if [[ ! -e $disk ]]; then
      # Grows as Windows writes to it (--allocation 0; without it libvirt reserves the full size).
      run "${VIRSH[@]}" vol-create-as "$VM_POOL" "$VM_NAME.qcow2" "${VM_DISK_GIB}G" --format qcow2 --allocation 0
      manifest_add "vmfile $disk"
    fi
    if [[ $(stat -c %s "$WINDOWS_ISO" 2> /dev/null) != "$(stat -c %s "$win_dest" 2> /dev/null)" ]]; then
      info "Copying the Windows ISO to $IMAGES_DIR (QEMU cannot read files in home directories)"
      run cp --reflink=auto "$WINDOWS_ISO" "$win_dest"
      run chmod 644 "$win_dest"
      manifest_add "vmfile $win_dest"
    fi
    run "${VIRSH[@]}" pool-refresh "$VM_POOL"

    run install -d -m 755 "$HGP_VAR"
    run python3 "$HGP_DIR/lib/vmxml.py" create "$xml" name="$VM_NAME" ram_mib=$(( VM_RAM_GIB * 1024 )) \
      cores="$VM_CORES" threads="$VM_THREADS" cpu_vendor="$CPU_VENDOR" disk="$disk" win_iso="$win_dest" \
      virtio_iso="$VIRTIO_DEST"
    if [[ $DRY_RUN == 1 ]]; then
      # Preview: build the definition in a temporary file and let libvirt check it.
      local tmp
      tmp=$(mktemp -d)
      python3 "$HGP_DIR/lib/vmxml.py" create "$tmp/vm.xml" name="$VM_NAME" ram_mib=$(( VM_RAM_GIB * 1024 )) \
        cores="$VM_CORES" threads="$VM_THREADS" cpu_vendor="$CPU_VENDOR" disk="$disk" win_iso="$win_dest" \
        virtio_iso="$VIRTIO_DEST" &&
        { ! command -v virt-xml-validate > /dev/null || virt-xml-validate "$tmp/vm.xml" domain &> /dev/null; } &&
        ok "The VM definition would be valid (Q35, UEFI Secure Boot, TPM 2.0, $VM_VCPUS vCPUs, $VM_RAM_GIB GiB)"
      rm -rf "$tmp"
    elif command -v virt-xml-validate > /dev/null; then
      out=$(virt-xml-validate "$xml" domain 2>&1) || die "The generated VM definition is not valid ($xml):
$out"
    fi
    run "${VIRSH[@]}" define "$xml"
    state_set vm_created "$VM_NAME"
    manifest_add "vm $VM_NAME"
  fi

  checks
  if [[ $DRY_RUN != 1 ]]; then
    "${VIRSH[@]}" dominfo "$VM_NAME" | grep -E '^(Name|State|CPU\(s\)|Max memory):' | sed 's/^/  /'
    "${VIRSH[@]}" domblklist "$VM_NAME" | sed -n '3,$p' | sed '/^$/d; s/^/  /'
    "${VIRSH[@]}" dumpxml "$VM_NAME" | grep -q "<tpm model='tpm-crb'>" && ok "TPM 2.0"
    "${VIRSH[@]}" dumpxml "$VM_NAME" | grep -q "secure='yes'" && ok "UEFI Secure Boot"
  fi
  stage_mark vm-create
  cat <<EOF

${C_BLD}Next: install Windows${C_RST} (step by step: docs/windows.md, part 1)
  1. Open virt-manager, start "$VM_NAME" and open its console. Press a key to boot from the CD.
  2. Where Windows Setup finds no disk: "Load driver" → virtio-win CD → viostor\\w11\\amd64.
  3. On the network screen: "Install driver" → virtio-win CD → NetKVM\\w11\\amd64.
  4. On the Windows desktop: run virtio-win-guest-tools.exe from the virtio-win CD.
  5. Shut Windows down, then run:  sudo ./install.sh
EOF
}

stage_vm_passthrough() {
  step "Stage 5/5: vm-passthrough (NVIDIA GPU, Looking Glass, CPU pinning)"
  local before after state out rom="" battery=""
  "${VIRSH[@]}" dominfo "$VM_NAME" > /dev/null 2>&1 || [[ $DRY_RUN == 1 ]] ||
    die "VM $VM_NAME not found. Run the vm-create stage first."
  state=$(vm_state)
  if [[ -n $state && $state != "shut off" ]]; then
    die "$VM_NAME is $state. Shut Windows down first."
  fi
  confirm "Is Windows installed in $VM_NAME (with virtio-win-guest-tools)?" ||
    die "Install Windows first (docs/windows.md, part 1), then run again."

  local rom_ok=${ROM_OK:-$(state_get rom_ok)}
  [[ $rom_ok == 1 && ( -s $ROM_FILE || $DRY_RUN == 1 ) ]] && rom=$ROM_FILE
  [[ $IS_LAPTOP == 1 ]] && battery=$BATTERY_AML
  [[ -n $BACKUP_DIR ]] || BACKUP_DIR=$HGP_BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)
  before=$BACKUP_DIR/$VM_NAME-before-passthrough.xml
  after=$HGP_VAR/$VM_NAME-passthrough.xml
  if [[ $DRY_RUN == 1 ]]; then
    run "virsh dumpxml --inactive $VM_NAME > $before"
  else
    mkdir -p "$BACKUP_DIR"
    "${VIRSH[@]}" dumpxml --inactive "$VM_NAME" > "$before" || die "Could not save the VM definition."
    ok "Saved the current definition: $before"
    manifest_add "vmxml $VM_NAME $before"
  fi
  local vmargs=(pass="$DGPU_PASS" rom="$rom" sub_vendor="$DGPU_SUB_VENDOR_DEC" sub_device="$DGPU_SUB_DEVICE_DEC"
    cores="$VM_CORES" threads="$VM_THREADS" vcpu_pin="$VCPU_PIN" emulator_cpus="$EMULATOR_CPUS"
    shmem_mib="$SHMEM_MIB" battery_aml="$battery")
  run python3 "$HGP_DIR/lib/vmxml.py" passthrough "$before" "$after" "${vmargs[@]}"
  if [[ $DRY_RUN == 1 ]] && "${VIRSH[@]}" dominfo "$VM_NAME" > /dev/null 2>&1; then
    # Preview: the changes this stage would make to the current definition.
    local tmp
    tmp=$(mktemp -d)
    if "${VIRSH[@]}" dumpxml --inactive "$VM_NAME" > "$tmp/before.xml" 2> /dev/null &&
       python3 "$HGP_DIR/lib/vmxml.py" passthrough "$tmp/before.xml" "$tmp/after.xml" "${vmargs[@]}"; then
      python3 - "$tmp/before.xml" > "$tmp/a.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
ET.register_namespace("qemu", "http://libvirt.org/schemas/domain/qemu/1.0")
ET.register_namespace("libosinfo", "http://libosinfo.org/xmlns/libvirt/domain/1.0")
root = ET.parse(sys.argv[1]).getroot()
ET.indent(root, space="  ")
print(ET.tostring(root, encoding="unicode"))
PY
      info "Changes to the definition of $VM_NAME:"
      diff -u "$tmp/a.xml" "$tmp/after.xml" | tail -n +3 | grep '^[-+]' | sed 's/^/      /'
      command -v virt-xml-validate > /dev/null && virt-xml-validate "$tmp/after.xml" domain &> /dev/null &&
        ok "The new definition passes virt-xml-validate"
    fi
    rm -rf "$tmp"
  fi
  if [[ $DRY_RUN != 1 ]] && command -v virt-xml-validate > /dev/null; then
    out=$(virt-xml-validate "$after" domain 2>&1) || die "The generated VM definition is not valid ($after):
$out"
  fi
  run "${VIRSH[@]}" define "$after"
  write_config   # CPU split and VM name may have changed since the virt stage

  checks
  if [[ $DRY_RUN != 1 ]]; then
    local x n=0 bdf
    x=$("${VIRSH[@]}" dumpxml --inactive "$VM_NAME")
    for bdf in $DGPU_PASS; do   # host addresses: <address domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
      grep -q "<address domain='0x${bdf:0:4}' bus='0x${bdf:5:2}' slot='0x${bdf:8:2}' function='0x${bdf:11:1}'/>" <<< "$x" &&
        n=$(( n + 1 ))
    done
    (( n == $(wc -w <<< "$DGPU_PASS") )) || die "Not every GPU function is in the VM definition."
    ok "GPU functions passed through: $DGPU_PASS"
    [[ -z $rom ]] || grep -q "<rom file='$rom'/>" <<< "$x" || die "vBIOS missing from the definition."
    [[ -z $rom ]] || ok "vBIOS: $rom"
    grep -q "<shmem name='looking-glass'>" <<< "$x" || die "Looking Glass shared memory missing."
    ok "Looking Glass shared memory: $SHMEM_MIB MiB"
    grep -c "<vcpupin " <<< "$x" | grep -q -x "$VM_VCPUS" || die "CPU pinning missing."
    ok "vCPUs pinned to $VM_CPUS, emulator on $EMULATOR_CPUS; Linux keeps $HOST_CPUS while the VM runs"
    if [[ -n $battery ]]; then
      grep -q "file=$battery" <<< "$x" || die "Fake battery table missing."
      ok "Fake battery table"
    fi
    grep -q "x-pci-sub-vendor-id" <<< "$x" && ok "GPU subsystem ID $DGPU_SUB_VENDOR:$DGPU_SUB_DEVICE"
  fi
  stage_mark vm-passthrough
  cat <<EOF

${C_BLD}Next: drivers inside Windows${C_RST} (step by step: docs/windows.md, part 2)
  1. Start "$VM_NAME" from virt-manager and open its console (Looking Glass works after step 3).
  2. Install the NVIDIA driver from nvidia.com.
  3. Download the Looking Glass IDD of exactly this build and run looking-glass-idd-setup.exe:
     https://looking-glass.io/artifact/$LG_BUILD/idd
  4. Close the virt-manager console. From now on start Windows with "Windows VM" in your app menu,
     or run: winvm
EOF
}
