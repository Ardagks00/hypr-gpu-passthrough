# shellcheck shell=bash disable=SC2034
# (SC2034 is off: the paths below are used by the other scripts.)
# Shared helpers: output, dry-run aware execution, file writes with backups, state and manifest.

HGP_NAME=hypr-gpu-passthrough
HGP_ETC=/etc/$HGP_NAME
HGP_CONF=$HGP_ETC/config
HGP_VAR=/var/lib/$HGP_NAME
HGP_STATE=$HGP_VAR/state
HGP_MANIFEST=$HGP_VAR/manifest
HGP_BACKUP_ROOT=$HGP_VAR/backup
HGP_LOG_DIR=/var/log/$HGP_NAME
HGP_LOG=$HGP_LOG_DIR/install.log

DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}
BACKUP_DIR=""

if [[ -t 1 ]]; then
  C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YEL=$'\e[33m' C_BLU=$'\e[34m' C_BLD=$'\e[1m' C_RST=$'\e[0m'
else
  C_RED="" C_GRN="" C_YEL="" C_BLU="" C_BLD="" C_RST=""
fi

_log() {
  [[ $DRY_RUN == 1 ]] && return 0
  [[ -d $HGP_LOG_DIR ]] || mkdir -p "$HGP_LOG_DIR" 2>/dev/null || return 0
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$HGP_LOG" 2>/dev/null || true
}
step() { printf '\n%s== %s%s\n' "$C_BLD" "$*" "$C_RST"; _log "STEP $*"; }
checks() { step "Checks"; [[ $DRY_RUN == 1 ]] && printf '  (skipped in a dry run)\n'; return 0; }
info() { printf '%s->%s %s\n' "$C_BLU" "$C_RST" "$*"; _log "INFO $*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GRN" "$C_RST" "$*"; _log "OK $*"; }
warn() { printf '  %s!%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; _log "WARN $*"; }
die()  { printf '%sError:%s %s\n' "$C_RED" "$C_RST" "$*" >&2; _log "ERROR $*"; exit 1; }

# run CMD... — execute as root and stop the installer if it fails; dry-run mode only prints it.
run() {
  if [[ $DRY_RUN == 1 ]]; then
    printf '  %s[dry-run]%s %s\n' "$C_YEL" "$C_RST" "$*"
    return 0
  fi
  _log "RUN $*"
  "$@" || die "Command failed (exit $?): $*"
}

# try CMD... — like run, but a failure is returned to the caller instead of stopping.
try() {
  if [[ $DRY_RUN == 1 ]]; then
    printf '  %s[dry-run]%s %s\n' "$C_YEL" "$C_RST" "$*"
    return 0
  fi
  _log "TRY $*"
  "$@"
}

# as_user CMD... — run a read-only command as the desktop user (also during a dry run).
as_user() {
  if [[ $(id -un) == "$TARGET_USER" ]]; then "$@"; else sudo -n -u "$TARGET_USER" -H -- "$@"; fi
}

# run_user CMD... — execute as the desktop user (with that user's HOME); stops on failure.
run_user() {
  if [[ $DRY_RUN == 1 ]]; then
    printf '  %s[dry-run as %s]%s %s\n' "$C_YEL" "$TARGET_USER" "$C_RST" "$*"
    return 0
  fi
  _log "RUN(user) $*"
  sudo -u "$TARGET_USER" -H -- "$@" || die "Command failed (exit $?): $*"
}

# confirm "Question?" — yes/no prompt; --yes answers yes, and a dry run assumes yes.
confirm() {
  if [[ $DRY_RUN == 1 ]]; then printf '  %s[dry-run]%s %s yes\n' "$C_YEL" "$C_RST" "$1"; return 0; fi
  [[ $ASSUME_YES == 1 ]] && return 0
  local answer
  read -r -p "$1 [y/N] " answer < /dev/tty || return 1
  [[ $answer == [yY]* ]]
}

# ask "Question" DEFAULT — free-text prompt; --yes takes the default.
ask() {
  local answer
  if [[ $ASSUME_YES == 1 || $DRY_RUN == 1 ]]; then printf '%s\n' "$2"; return 0; fi
  read -r -p "$1 [$2] " answer < /dev/tty || true
  printf '%s\n' "${answer:-$2}"
}

# ---------------------------------------------------------------- state ---

state_get() { [[ -f $HGP_STATE ]] && sed -n "s/^$1=//p" "$HGP_STATE" | tail -n 1; return 0; }

state_set() {
  [[ $DRY_RUN == 1 ]] && return 0
  mkdir -p "$HGP_VAR"
  { grep -v "^$1=" "$HGP_STATE" 2>/dev/null || true; printf '%s=%s\n' "$1" "$2"; } > "$HGP_STATE.tmp"
  mv "$HGP_STATE.tmp" "$HGP_STATE"
}

stage_done() { [[ $(state_get "stage_$1") == "done" ]]; }
stage_mark() { state_set "stage_$1" "done"; }

# ------------------------------------------------------------- manifest ---
# The manifest lets uninstall.sh undo our changes:
#   created PATH            — a file we created; uninstall deletes it
#   modified PATH BACKUP    — a file that existed; uninstall restores BACKUP
#   block PATH NAME         — a marked block we added to someone else's file

manifest_has() { awk -v p="$1" '$2 == p {found = 1} END {exit !found}' "$HGP_MANIFEST" 2>/dev/null; }

manifest_add() {
  [[ $DRY_RUN == 1 ]] && return 0
  mkdir -p "$HGP_VAR"
  grep -q -x -F -- "$*" "$HGP_MANIFEST" 2>/dev/null || printf '%s\n' "$*" >> "$HGP_MANIFEST"
}

backup_file() {
  local f=$1
  [[ -e $f ]] || return 0
  [[ -n $BACKUP_DIR ]] || BACKUP_DIR=$HGP_BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)
  if [[ $DRY_RUN == 1 ]]; then
    printf '  %s[dry-run]%s backup %s\n' "$C_YEL" "$C_RST" "$f"
    return 0
  fi
  mkdir -p "$BACKUP_DIR$(dirname "$f")"
  cp -a "$f" "$BACKUP_DIR$f"
  printf '%s\n' "$BACKUP_DIR$f"
}

# track_file PATH — record a file before we create or change it (first time only).
track_file() {
  local f=$1 b
  manifest_has "$f" && return 0
  if [[ -e $f ]]; then
    b=$(backup_file "$f")
    manifest_add "modified $f $b"
  else
    manifest_add "created $f"
  fi
}

# write_file PATH MODE [USER:GROUP] < CONTENT — write a whole file (backed up, idempotent).
write_file() {
  local path=$1 mode=$2 owner=${3:-root:root} tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if [[ $DRY_RUN == 1 ]]; then
    printf '  %s[dry-run]%s write %s (%s, %s)\n' "$C_YEL" "$C_RST" "$path" "$mode" "$owner"
    sed 's/^/      | /' "$tmp" | head -n 25
    rm -f "$tmp"
    return 0
  fi
  if [[ -e $path ]] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; return 0; fi
  track_file "$path"
  # Directories in a user's home must belong to that user, not to root.
  if [[ $owner != root:root ]]; then
    if [[ $(id -un) == "${owner%%:*}" ]]; then mkdir -p "$(dirname "$path")"
    else sudo -u "${owner%%:*}" mkdir -p "$(dirname "$path")"; fi
  fi
  install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$path" || die "Could not write $path."
  rm -f "$tmp"
  _log "WROTE $path"
}

# set_block PATH NAME < CONTENT — add or replace a marked block in a file someone else owns.
set_block() {
  local path=$1 name=$2 content
  content=$(cat)
  if [[ $DRY_RUN == 1 ]]; then
    printf '  %s[dry-run]%s block "%s" in %s:\n' "$C_YEL" "$C_RST" "$name" "$path"
    printf '%s\n' "$content" | sed 's/^/      | /'
    return 0
  fi
  [[ -e $path ]] || { install -D -m 644 /dev/null "$path"; manifest_add "created $path"; }
  manifest_has "$path" || backup_file "$path" > /dev/null
  manifest_add "block $path $name"
  local tmp
  tmp=$(mktemp)
  awk -v b="# >>> $HGP_NAME $name" -v e="# <<< $HGP_NAME $name" '
    $0 == b {skip = 1; next} $0 == e {skip = 0; next} !skip' "$path" > "$tmp"
  { printf '# >>> %s %s\n' "$HGP_NAME" "$name"; printf '%s\n' "$content"; printf '# <<< %s %s\n' "$HGP_NAME" "$name"; } >> "$tmp"
  cat "$tmp" > "$path"
  rm -f "$tmp"
  _log "BLOCK $name in $path"
}

remove_block() {
  local path=$1 name=$2 tmp
  [[ -e $path ]] || return 0
  if [[ $DRY_RUN == 1 ]]; then
    printf '  %s[dry-run]%s remove block "%s" from %s\n' "$C_YEL" "$C_RST" "$name" "$path"
    return 0
  fi
  tmp=$(mktemp)
  awk -v b="# >>> $HGP_NAME $name" -v e="# <<< $HGP_NAME $name" '
    $0 == b {skip = 1; next} $0 == e {skip = 0; next} !skip' "$path" > "$tmp"
  cat "$tmp" > "$path"
  rm -f "$tmp"
}
