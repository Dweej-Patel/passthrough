#!/bin/bash
# The iPhone and iPad app over USB: list devices, check, build, install,
# update and remove. Run ./passthrough iphone --help. Bash 3.2.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./passthrough iphone <verb> [flags]      (iPad too: the app is universal)

Verbs
  devices             The iPhones and iPads this Mac can reach (no simulators).
  doctor              Xcode, signing, the engine, and a connected, unlocked device.
  build               Builds the Passthrough scheme (Debug, as you install it) into build/dd-ios.
  install [--device ID|NAME] [--pc-screen] [--no-build] [--force]
                      Builds, installs on the device and opens the app. With one device
                      it's used; with several, name one. Pairings and keys stay.
                      --pc-screen opens it with -PTWindowsScreen YES (a PC's screen),
                      for that launch only.
  update [--pull] [--device …] [--pc-screen] [--force] [--no-engine]
                      --pull runs git pull --ff-only first; then as install.
  remove --device ID|NAME [--yes]
                      Deletes the app from the device, with its saved keys and pairings.

Flags
  --dry-run           Prints each action instead of doing it.
  --force             Installs even when the Mac is online through a phone right now.
  --yes, -y           Answers yes to every question.
  --help, -h          This text.

The Mac and the phones update together: install the Mac app from the same commit.
EOF
}

VERB="${1:-}"
case "$VERB" in ""|-h|--help|help) usage; exit 0 ;; esac
shift

DEVICE_ARG="" PC_SCREEN=0 PULL=0 NO_BUILD=0 FORCE=0 NO_ENGINE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) YES=1 ;;
    --device) [ $# -ge 2 ] || die "--device needs a UDID or a name (see ./passthrough iphone devices)"; DEVICE_ARG="$2"; shift ;;
    --pc-screen) PC_SCREEN=1 ;;
    --pull) PULL=1 ;;
    --no-build) NO_BUILD=1 ;;
    --no-engine) NO_ENGINE=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown flag $1 (see ./passthrough iphone --help)" ;;
  esac
  shift
done

DERIVED="build/dd-ios"
BUILT_APP="$PT_ROOT/$DERIVED/Build/Products/Debug-iphoneos/Passthrough.app"

bundle_id() {
  local id=""
  [ -f "$BUILT_APP/Info.plist" ] && id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILT_APP/Info.plist" 2>/dev/null || true)"
  printf '%s' "${id:-$(pt_identifier).ios}"
}

# devices: "udid<TAB>name<TAB>model<TAB>state" for each iPhone and iPad that
# isn't a simulator; state is "available" when the Mac can reach it now.
DEVICES_JSON=""
DEV_I=0
get() { plutil -extract "result.devices.$DEV_I.$1" raw "$DEVICES_JSON" 2>/dev/null || true; }
devices() {
  if [ -z "$DEVICES_JSON" ]; then
    DEVICES_JSON="$(mktemp -t passthrough-devices)"
    trap 'rm -f "$DEVICES_JSON"' EXIT
    xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null 2>&1 || { : > "$DEVICES_JSON"; }
  fi
  local n platform reality tunnel name udid model
  n="$(plutil -extract result.devices raw "$DEVICES_JSON" 2>/dev/null || echo 0)"
  DEV_I=0
  while [ "$DEV_I" -lt "$n" ]; do
    platform="$(get hardwareProperties.platform)"; reality="$(get hardwareProperties.reality)"
    if [ "$platform" = iOS ] && [ "$reality" != simulated ]; then
      name="$(get deviceProperties.name)"; udid="$(get hardwareProperties.udid)"
      model="$(get hardwareProperties.marketingName)"; [ -n "$model" ] || model="$(get hardwareProperties.productType)"
      tunnel="$(get connectionProperties.tunnelState)"
      if [ "$tunnel" = unavailable ] || [ -z "$tunnel" ]; then tunnel="not connected"; else tunnel="available"; fi
      printf '%s\t%s\t%s\t%s\n' "$udid" "$name" "$model" "$tunnel"
    fi
    DEV_I=$((DEV_I + 1))
  done
}
# device_locked <udid>: true, false or unknown (devicectl's passcodeRequired).
device_locked() {
  local j v
  j="$(mktemp -t passthrough-lock)"
  xcrun devicectl device info lockState --device "$1" --quiet --json-output "$j" >/dev/null 2>&1 || true
  v="$(plutil -extract result.passcodeRequired raw "$j" 2>/dev/null || echo unknown)"
  rm -f "$j"
  printf '%s' "$v"
}
available_devices() { devices | awk -F'\t' '$4 == "available"'; }

# pick_device: the UDID to use, from --device or the only one connected.
pick_device() {
  local avail n match
  avail="$(available_devices)"; n="$(printf '%s' "$avail" | grep -c . || true)"
  if [ -n "$DEVICE_ARG" ]; then
    if [ "$(devices | awk -F'\t' -v d="$DEVICE_ARG" '$2 == d' | grep -c . || true)" -gt 1 ]; then
      devices | awk -F'\t' -v d="$DEVICE_ARG" '$2 == d {printf "    %s  %s (%s), %s\n", $1, $2, $3, $4}' >&2
      die "More than one device is called $DEVICE_ARG; use its UDID."
    fi
    match="$(printf '%s\n' "$avail" | awk -F'\t' -v d="$DEVICE_ARG" '$1 == d || $2 == d' | head -1)"
    if [ -z "$match" ] && [ "$DRY_RUN" = 1 ]; then
      match="$(devices | awk -F'\t' -v d="$DEVICE_ARG" '$1 == d || $2 == d' | head -1)"
      if [ -n "$match" ]; then warn "$DEVICE_ARG isn't connected; showing the plan anyway (--dry-run)." >&2; printf '%s' "$match"; return; fi
    fi
    if [ -z "$match" ]; then
      devices | awk -F'\t' -v d="$DEVICE_ARG" '$1 == d || $2 == d {found=1} END {exit !found}' \
        && die "$DEVICE_ARG isn't reachable: plug it in, unlock it and trust this Mac."
      die "No device called $DEVICE_ARG (see ./passthrough iphone devices)."
    fi
    printf '%s' "$match"; return
  fi
  if [ "$n" = 0 ] && [ "$DRY_RUN" = 1 ]; then
    warn "No iPhone or iPad connected; showing the plan for one anyway (--dry-run)." >&2
    printf '<device>\t<device>\t\tavailable'; return
  fi
  case "$n" in
    0) die "No iPhone or iPad connected. Plug one in, unlock it and trust this Mac (./passthrough iphone devices)." ;;
    1) printf '%s' "$avail" ;;
    *) printf '%s\n' "$avail" | awk -F'\t' '{printf "    %s  %s (%s)\n", $1, $2, $3}' >&2
       die "Several devices are connected; choose one with --device <UDID or name>." ;;
  esac
}

do_devices() {
  local all
  all="$(devices)"
  if [ -z "$all" ]; then info "No iPhone or iPad known to this Mac."; return; fi
  printf '%s\n' "$all" | while IFS="$(printf '\t')" read -r udid name model state; do
    if [ "$state" = available ]; then ok "$name ($model)  $udid"; else printf '  - %s (%s)  %s  not connected\n' "$name" "$model" "$udid"; fi
  done
}

do_doctor() {
  step "Tools"
  if xcodebuild -version >/dev/null 2>&1; then ok "$(xcodebuild -version | head -1)"; else bad "Xcode isn't installed or selected." "Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"; fi
  if have xcodegen; then ok "xcodegen"; else bad "xcodegen is missing." "./passthrough mac deps"; fi
  if xcrun metal --version >/dev/null 2>&1; then ok "Metal toolchain"; else bad "The Metal toolchain is missing." "xcodebuild -downloadComponent MetalToolchain"; fi

  step "Signing"
  if [ ! -f "$SIGNING" ]; then bad "Config/Signing.xcconfig is missing." "./passthrough mac deps"
  elif [ -z "$(team_id)" ]; then bad "DEVELOPMENT_TEAM is empty in Config/Signing.xcconfig." "./passthrough mac deps"
  else
    local phone_team
    phone_team="$(grep -E '^[[:space:]]*DEVELOPMENT_TEAM\[sdk=iphoneos\*\][[:space:]]*=' "$SIGNING" | tail -1 | sed -e 's/^[^=]*=//' -e 's/[[:space:]]//g' || true)"
    ok "DEVELOPMENT_TEAM = $(team_id)${phone_team:+; the iPhone signs with $phone_team}"
    info "The iPhone's VPN extension needs a paid team."
  fi

  step "Remote Desktop engine (optional: a PC's screen)"
  case "$(engine_state)" in
    current) ok "Built and current." ;;
    stale) warn "Out of date with its sources." "./passthrough iphone update rebuilds it." ;;
    unknown) warn "Built, without a SOURCES.lock to check." ;;
    missing) warn "Not built: a PC's screen is left out." "./passthrough mac deps" ;;
  esac

  step "Devices"
  local avail udid name
  avail="$(available_devices)"
  if [ -z "$avail" ]; then
    bad "No iPhone or iPad connected." "Plug one in, unlock it and trust this Mac; turn on Developer Mode (Settings ▸ Privacy & Security) the first time."
  else
    printf '%s\n' "$avail" | while IFS="$(printf '\t')" read -r udid name model state; do
      case "$(device_locked "$udid")" in
        true) warn "$name ($model)  $udid: locked. Unlock it before installing." ;;
        *) ok "$name ($model)  $udid" ;;
      esac
    done
  fi
  if [ -d "$BUILT_APP" ]; then info "Last build: ${BUILT_APP#"$PT_ROOT"/} ($(bundle_id))"; fi
  if [ "$PT_FAILS" -gt 0 ]; then printf '\n%s✗ %d problem(s) above.%s\n' "$C_BAD" "$PT_FAILS" "$C_0"; exit 1; fi
  done_ok "Ready."
}

do_build() {
  step "Building Passthrough for iPhone and iPad (Debug)"
  require_signing
  case "$(engine_state)" in
    missing) warn "No Remote Desktop engine: building without a PC's screen." ;;
    stale) warn "The Remote Desktop engine is out of date (./passthrough iphone update rebuilds it)." ;;
  esac
  xcodegen_generate
  xcode_build ios-debug \
    -project Passthrough.xcodeproj -scheme Passthrough -configuration Debug \
    -destination generic/platform=iOS -derivedDataPath "$DERIVED" \
    -onlyUsePackageVersionsFromResolvedFile -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
  if [ "$DRY_RUN" = 1 ]; then info "[dry-run] the app would be at ${BUILT_APP#"$PT_ROOT"/}"; return 0; fi
  [ -d "$BUILT_APP" ] || die "The build finished but $BUILT_APP isn't there."
  did "Built ${BUILT_APP#"$PT_ROOT"/} ($(bundle_id))"
}

do_install() {
  local dev udid name
  step "Device"
  dev="$(pick_device)"
  udid="$(printf '%s' "$dev" | cut -f1)"; name="$(printf '%s' "$dev" | cut -f2)"
  ok "$name  $udid"
  if [ "$(device_locked "$udid")" = true ]; then warn "$name is locked: unlock it, or opening the app at the end fails."; fi
  check_phone_route
  if [ "$NO_BUILD" = 0 ]; then do_build; else info "Not building (--no-build)."; fi
  [ "$DRY_RUN" = 1 ] || [ -d "$BUILT_APP" ] || die "No build at ${BUILT_APP#"$PT_ROOT"/}; run without --no-build."
  step "Installing on $name"
  run xcrun devicectl device install app --device "$udid" "$BUILT_APP"
  if [ "$PC_SCREEN" = 1 ]; then
    run xcrun devicectl device process launch --device "$udid" --terminate-existing "$(bundle_id)" -- -PTWindowsScreen YES
    info "A PC's screen is on for this launch only: opening the app from the home screen later starts it without -PTWindowsScreen."
  else
    run xcrun devicectl device process launch --device "$udid" --terminate-existing "$(bundle_id)"
  fi
  if [ "$DRY_RUN" = 1 ]; then done_ok "Dry run finished; nothing was changed."; return; fi
  done_ok "Installed on $name. The first time, tap the power button; iOS asks once to add the VPN configuration."
  info "Install the Mac app from the same commit too: ./passthrough mac update"
}

do_update() {
  [ "$PULL" = 0 ] || git_pull
  if [ "$NO_ENGINE" = 0 ] && [ "$(engine_state)" = stale ]; then step "The Remote Desktop engine's sources changed"; build_engine; fi
  do_install
}

do_remove() {
  [ -n "$DEVICE_ARG" ] || die "Name the device to remove it from: --device <UDID or name> (see ./passthrough iphone devices)."
  local dev udid name
  dev="$(pick_device)"
  udid="$(printf '%s' "$dev" | cut -f1)"; name="$(printf '%s' "$dev" | cut -f2)"
  check_phone_route
  warn "This deletes Passthrough from $name with everything it saved there: its shell keys, its pairings with your computers, the iPad's link to its iPhone and its VPN configuration. Pairing again needs the cable."
  confirm "Delete Passthrough from $name?" || die "Nothing removed."
  run xcrun devicectl device uninstall app --device "$udid" "$(bundle_id)"
  if [ "$DRY_RUN" = 1 ]; then done_ok "Dry run finished; nothing was changed."; return; fi
  done_ok "Removed from $name. On the Mac, Settings ▸ Remote Shell ▸ Phones with access still lists it until you remove it there."
}

case "$VERB" in
  devices) do_devices ;;
  doctor) do_doctor ;;
  build) do_build; [ "$DRY_RUN" = 1 ] || done_ok "Built: $BUILT_APP" ;;
  install|reinstall) do_install ;;
  update) do_update ;;
  remove|uninstall) do_remove ;;
  *) die "Unknown verb \"$VERB\" (see ./passthrough iphone --help)" ;;
esac
