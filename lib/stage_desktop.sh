# shellcheck shell=bash
# Stage "desktop": the Looking Glass client (built from source), nvrun, the winvm launcher and its
# application menu entry.

# The client and the Windows side (Looking Glass IDD) must come from the same build. This build
# ships the IDD virtual display, so no dummy HDMI plug is needed.
LG_DEFAULT_BUILD=B7-826-236efcb1
LG_DEFAULT_SHA256=e396d923172ff3e6e88a1c6906a0e5e87a298ddb5a18aa4d8cb4da37e78ce250
LG_DEFAULT_SIZE=5066711

human_size() { numfmt --to=iec-i --suffix=B "${1:-0}" 2> /dev/null || echo "$1 bytes"; }

desktop_lg() {
  local build=$LG_BUILD
  local work=$TARGET_HOME/.local/share/$HGP_NAME
  local tarball=$work/looking-glass-$build.tar.gz
  local src=$work/looking-glass-$build
  local bin=$TARGET_HOME/.local/bin/looking-glass-client
  local icon=$TARGET_HOME/.local/share/icons/hicolor/scalable/apps/looking-glass.svg
  local url=https://looking-glass.io/artifact/$build/source sha size

  if [[ -x $bin && $(state_get lg_installed) == "$build" ]]; then
    ok "Looking Glass client $build is installed"
    return 0
  fi
  info "Installing the build dependencies of the Looking Glass client"
  # shellcheck disable=SC2046
  pkg_install $(packages_lg)

  if [[ $build == "$LG_DEFAULT_BUILD" ]]; then
    sha=$LG_DEFAULT_SHA256 size=$LG_DEFAULT_SIZE
  elif [[ $DRY_RUN == 1 ]]; then
    sha="(looked up when installing)" size=0
  else
    # The download link redirects to a path that contains the file's SHA-256.
    sha=$(curl -fsSI --proto '=https' "$url" | sed -n 's|^location:.*/\([0-9a-f]\{64\}\)/.*|\1|Ip' | head -n 1)
    [[ -n $sha ]] || die "Looking Glass build $build was not found ($url)."
    size=$(curl -fsSIL --proto '=https' "$url" | sed -n 's/^content-length: *\([0-9]*\).*/\1/Ip' | tail -n 1)
  fi

  if [[ -s $tarball ]] && echo "$sha  $tarball" | sha256sum -c --status 2> /dev/null; then
    ok "Source already downloaded: $tarball"
  else
    info "Looking Glass $build source: $url"
    info "  file looking-glass-$build.tar.gz, $(human_size "$size"), SHA-256 $sha"
    confirm "Download it?" || die "The Looking Glass client is required; run again when you are ready."
    [[ -d $work ]] || manifest_add "created $work/"
    run_user mkdir -p "$work"
    run_user curl -fL --proto '=https' --tlsv1.2 -o "$tarball.part" "$url"
    if [[ $DRY_RUN != 1 ]]; then
      echo "$sha  $tarball.part" | sha256sum -c --status || { rm -f "$tarball.part"; die "Checksum mismatch for the downloaded file."; }
      run_user mv "$tarball.part" "$tarball"
      ok "Checksum verified"
    fi
  fi

  info "Building the client (a few minutes)"
  run_user rm -rf "$src"
  run_user tar -xzf "$tarball" -C "$work"
  run_user cmake -S "$src/client" -B "$src/client/build" -Wno-dev
  run_user cmake --build "$src/client/build" -j "$(nproc)"
  track_file "$bin"
  track_file "$icon"
  run_user install -D -m 755 "$src/client/build/looking-glass-client" "$bin"
  run_user install -D -m 644 "$src/resources/lg-logo.svg" "$icon"
  state_set lg_installed "$build"
}

desktop_files() {
  local grp ini=$TARGET_HOME/.looking-glass-client.ini
  grp=$(id -gn "$TARGET_USER")
  write_file /usr/local/bin/nvrun 755 < "$HGP_DIR/files/nvrun"
  write_file /usr/local/bin/winvm 755 < "$HGP_DIR/files/vm-launch"
  # The client's own settings are left alone if they exist.
  if [[ ! -e $ini && ! -e $TARGET_HOME/.config/looking-glass/client.ini ]]; then
    write_file "$ini" 644 "$TARGET_USER:$grp" <<EOF
[input]
escapeKey=$LG_ESCAPE_KEY
EOF
  fi
  write_file "$TARGET_HOME/.local/share/applications/$HGP_NAME.desktop" 644 "$TARGET_USER:$grp" <<EOF
[Desktop Entry]
Type=Application
Name=Windows VM
GenericName=Windows virtual machine
Comment=Starts the Windows VM ($VM_NAME) with the NVIDIA GPU and shows it in Looking Glass
Exec=winvm
Icon=looking-glass
Terminal=false
Categories=System;Emulator;
Keywords=windows;vm;looking glass;gpu;passthrough;
StartupWMClass=looking-glass-client
EOF
}

stage_desktop() {
  step "Stage 3/5: desktop (Looking Glass client, nvrun, winvm)"
  desktop_lg
  desktop_files

  checks
  if [[ $DRY_RUN != 1 ]]; then
    local bin=$TARGET_HOME/.local/bin/looking-glass-client missing
    # Do not start the client to check it: it has no --version and ignores unknown options.
    missing=$(ldd "$bin" 2> /dev/null | grep 'not found')
    [[ -z $missing ]] || die "The Looking Glass client is missing libraries:
$missing"
    ok "Looking Glass client $LG_BUILD: $bin"
    ok "nvrun and winvm in /usr/local/bin; menu entry \"Windows VM\""
    command -v desktop-file-validate > /dev/null &&
      desktop-file-validate "$TARGET_HOME/.local/share/applications/$HGP_NAME.desktop" && ok "Menu entry is valid"
  fi
  stage_mark desktop
}
