#!/usr/bin/env bash
# hypr-gpu-passthrough installer: dynamic NVIDIA GPU passthrough to a Windows VM with Looking Glass.
# See README.md. Run from your normal account:  sudo ./install.sh
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
# shellcheck source=lib/stage_host.sh
. "$HGP_DIR/lib/stage_host.sh"
# shellcheck source=lib/stage_virt.sh
. "$HGP_DIR/lib/stage_virt.sh"
# shellcheck source=lib/stage_desktop.sh
. "$HGP_DIR/lib/stage_desktop.sh"
# shellcheck source=lib/stage_vm.sh
. "$HGP_DIR/lib/stage_vm.sh"

STAGES=(host virt desktop vm-create vm-passthrough)

usage() {
  cat <<EOF
Usage: sudo ./install.sh [options]

Runs the next unfinished stage, and the ones after it until a reboot or a step inside Windows is
needed. Run it again afterwards; it continues where it stopped.

Stages: host → (reboot) → virt → desktop → vm-create → (install Windows) → vm-passthrough

Options:
  --dry-run            show what would be done, change nothing (works without sudo)
  --yes                answer every question with yes (downloads included)
  --stage NAME         run only this stage again (${STAGES[*]})
  --status             show the detected system and the stages, change nothing
  --windows-iso PATH   Windows 11 ISO (default: the only Win11*.iso in your Downloads folder)
  --virtio-iso PATH    use a local virtio-win ISO instead of downloading it
  --vm-name NAME       name of the VM (default: win11)
  --vm-ram GIB         memory for the VM (default: half of the RAM, 4 to 32 GiB)
  --vm-cores N         CPU cores for the VM (default: automatic)
  --vm-disk GIB        size of the VM's disk, grows on demand (default: 150)
  --lg-build BUILD     Looking Glass build (default: $LG_DEFAULT_BUILD); the IDD in Windows must match
  --gpu ADDRESS        NVIDIA GPU to pass through when there are several (e.g. 0000:01:00.0)
  -h, --help           this help
EOF
}

ONLY_STAGE="" STATUS=0 WINDOWS_ISO="" VIRTIO_ISO="" OPT_VM_NAME="" VM_DISK_GIB=150 OPT_LG_BUILD=""
LG_ESCAPE_KEY=${LG_ESCAPE_KEY:-KEY_RIGHTCTRL}
while (( $# )); do
  case $1 in
    --dry-run) DRY_RUN=1 ;;
    --yes | -y) ASSUME_YES=1 ;;
    --stage) ONLY_STAGE=${2:?--stage needs a name}; shift ;;
    --status) STATUS=1 ;;
    --windows-iso) WINDOWS_ISO=$(realpath -e "${2:?}") || die "$2 not found"; shift ;;
    --virtio-iso) VIRTIO_ISO=$(realpath -e "${2:?}") || die "$2 not found"; shift ;;
    --vm-name) OPT_VM_NAME=${2:?}; shift ;;
    --vm-ram) HGP_VM_RAM=${2:?}; shift ;;
    --vm-cores) HGP_VM_CORES=${2:?}; shift ;;
    --vm-disk) VM_DISK_GIB=${2:?}; shift ;;
    --lg-build) OPT_LG_BUILD=${2:?}; shift ;;
    --gpu)
      HGP_DGPU=${2:?}; shift
      [[ $HGP_DGPU == ????:* ]] || HGP_DGPU=0000:$HGP_DGPU ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done

if [[ -n $ONLY_STAGE ]]; then
  printf '%s\n' "${STAGES[@]}" | grep -q -x -- "$ONLY_STAGE" || die "Unknown stage: $ONLY_STAGE (stages: ${STAGES[*]})"
fi
[[ ${HGP_VM_RAM:-1} =~ ^[0-9]+$ && ${HGP_VM_CORES:-1} =~ ^[0-9]+$ && $VM_DISK_GIB =~ ^[0-9]+$ ]] ||
  die "--vm-ram, --vm-cores and --vm-disk take whole numbers."
[[ $EUID == 0 || $DRY_RUN == 1 || $STATUS == 1 ]] || die "Run with sudo: sudo ./install.sh"

# Settings chosen on an earlier run stay unless given again.
HGP_DGPU=${HGP_DGPU:-$(state_get gpu)}
VM_NAME=${OPT_VM_NAME:-$(state_get vm_name)}
VM_NAME=${VM_NAME:-win11}
[[ $VM_NAME =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "VM names may contain letters, digits, '.', '_' and '-'."
LG_BUILD=${OPT_LG_BUILD:-$(state_get lg_build)}
LG_BUILD=${LG_BUILD:-$LG_DEFAULT_BUILD}
[[ $LG_BUILD =~ ^B[0-9][A-Za-z0-9.-]*$ ]] || die "Unexpected Looking Glass build name: $LG_BUILD"

detect_all

if [[ $STATUS == 1 ]]; then
  print_summary
  step "Stages"
  for s in "${STAGES[@]}"; do
    if stage_done "$s"; then ok "$s"; else printf '  - %s\n' "$s"; fi
  done
  exit 0
fi

print_summary
preflight
if [[ $DRY_RUN == 1 ]]; then
  warn "Dry run: nothing is changed."
  [[ $EUID == 0 ]] || warn "Without sudo some checks see less (for example programs of other users)."
fi

state_set vm_name "$VM_NAME"
state_set lg_build "$LG_BUILD"
[[ -n $HGP_DGPU ]] && state_set gpu "$HGP_DGPU"

run_stage() {
  case $1 in
    host) stage_host ;;
    virt) stage_virt ;;
    desktop) stage_desktop ;;
    vm-create) stage_vm_create ;;
    vm-passthrough) stage_vm_passthrough ;;
  esac
}

reboot_pending() {
  local id
  id=$(state_get reboot_boot_id)
  [[ -n $id && $id == "$(cat /proc/sys/kernel/random/boot_id)" ]]
}

if [[ -n $ONLY_STAGE ]]; then
  if [[ $ONLY_STAGE != host && $DRY_RUN != 1 ]] && reboot_pending; then
    die "Reboot first: the host stage needs it."
  fi
  run_stage "$ONLY_STAGE"
  [[ $ONLY_STAGE == host && $DRY_RUN != 1 ]] && step "Reboot now, then run: sudo ./install.sh"
  exit 0
fi

if [[ $DRY_RUN != 1 ]] && reboot_pending; then
  die "Reboot first: the settings from the host stage take effect after a reboot. Then run sudo ./install.sh again."
fi

for s in "${STAGES[@]}"; do
  if stage_done "$s" && [[ $DRY_RUN != 1 ]]; then continue; fi
  run_stage "$s"
  case $s in
    host)
      if [[ $DRY_RUN == 1 ]]; then
        step "(A real run stops here: reboot, then run the installer again.)"
      else
        step "Done with the host stage. Reboot now, then run: sudo ./install.sh"
        exit 0
      fi ;;
    vm-create)
      if [[ $DRY_RUN == 1 ]]; then
        step "(A real run stops here: install Windows, shut it down, run the installer again.)"
      else
        exit 0
      fi ;;
  esac
done

if [[ $DRY_RUN == 1 ]]; then
  step "Dry run finished. Nothing was changed."
  exit 0
fi
step "All stages are done."
cat <<EOF
  Start Windows: "Windows VM" in your app menu, or run: winvm
  Run a Linux program on the NVIDIA GPU: nvrun <program>   (CUDA programs need nothing)
  Hook log: journalctl -t $HGP_NAME
EOF
