#!/bin/bash
# The Mac app: check, set up, build, install, update, roll back and remove.
# Run ./passthrough mac --help (or scripts/mac.sh --help). Works from any
# directory; Bash 3.2.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./passthrough mac <verb> [flags]

Verbs
  doctor              What's installed and what's missing, each with its fix. Changes nothing.
  deps [--yes] [--team ID] [--no-engine]
                      Installs what building needs: xcodegen (and cmake, ninja for the
                      PC-screen engine) with Homebrew, the Metal toolchain, a
                      Config/Signing.xcconfig, and the Remote Desktop engine if it's missing.
  build [--debug]     xcodegen generate, then builds PassthroughMac (Release) into build/dd-rel.
  install [--force] [--no-build]
                      Fresh install, or reinstall over the top: builds, checks, quits the
                      running app, keeps it as build/Passthrough.app.previous, copies the new
                      one into /Applications and opens it.
  update [--pull] [--force] [--no-engine]
                      --pull runs git pull --ff-only first. Rebuilds the engine if its
                      sources changed, then installs.
  rollback [--force]  Puts build/Passthrough.app.previous back (the current app becomes the previous).
  remove [--purge] [--yes] [--force]
                      Quits the app, stops its root helper, removes the app, the microphone
                      driver and its login item. --purge also deletes its settings and data.

Flags
  --dry-run           Prints each action instead of doing it (checks still run; they only read).
  --force             Goes ahead even when a safety check refuses.
  --yes, -y           Answers yes to every question.
  --help, -h          This text.
EOF
}

VERB="${1:-}"
case "$VERB" in ""|-h|--help|help) usage; exit 0 ;; esac
shift

FORCE=0 DEBUG=0 PULL=0 PURGE=0 NO_ENGINE=0 NO_BUILD=0 TEAM_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) YES=1 ;;
    --force) FORCE=1 ;;
    --debug) DEBUG=1 ;;
    --pull) PULL=1 ;;
    --purge) PURGE=1 ;;
    --no-engine) NO_ENGINE=1 ;;
    --no-build) NO_BUILD=1 ;;
    --team) [ $# -ge 2 ] || die "--team needs a Team ID"; TEAM_ARG="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown flag $1 (see ./passthrough mac --help)" ;;
  esac
  shift
done

APP_DEST="/Applications/Passthrough.app"
PREV="$PT_ROOT/build/Passthrough.app.previous"
DERIVED="build/dd-rel"
CONFIG="Release"; [ "$DEBUG" = 1 ] && CONFIG="Debug"
BUILT_APP="$PT_ROOT/$DERIVED/Build/Products/$CONFIG/Passthrough.app"
DRIVER="/Library/Audio/Plug-Ins/HAL/PassthroughMicrophone.driver"
DRIVER_STAGING="/Library/Audio/Plug-Ins/.PassthroughMicrophone.staging"
HELPER_STATE="/var/run/passthrough"

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

# PASSTHROUGH_ID of the installed app if there is one (it may have been built
# with another), else the tree's. The Mac bundle ID, the helper's launchd
# label and the defaults domain derive from it (project.yml, HelperConstants).
installed_id() {
  local id=""
  [ -f "$APP_DEST/Contents/Info.plist" ] && id="$(plist_get "$APP_DEST/Contents/Info.plist" PassthroughID)"
  printf '%s' "${id:-$(pt_identifier)}"
}
ID="$(installed_id)"
BUNDLE_ID="$ID.mac"
HELPER_LABEL="$ID.helper"

# signing_state <binary or bundle>: release, debug or unsigned. Debug means it
# carries com.apple.security.get-task-allow, which every development-signed
# Debug build does and which the Release root helper refuses.
signing_state() {
  local xml
  xml="$(codesign -d --entitlements - --xml "$1" 2>/dev/null)" || { echo unsigned; return; }
  if printf '%s' "$xml" | grep -q 'com.apple.security.get-task-allow</key><true/>'; then echo debug; else echo release; fi
}
# app_kind <app>: release only when the app and its embedded helper both are.
app_kind() {
  local a h
  a="$(signing_state "$1")"
  h="$(signing_state "$1/Contents/MacOS/PassthroughHelper")"
  if [ "$a" = release ] && [ "$h" = release ]; then echo release
  elif [ "$a" = unsigned ] || [ "$h" = unsigned ]; then echo "unsigned (app: $a, helper: $h)"
  else echo "debug (app: $a, helper: $h)"; fi
}
# The APNs key the build embeds as Resources/AuthKey_<Key ID>.p8 (project.yml, "Bundle push key").
push_key_of() { (cd "$1/Contents/Resources" 2>/dev/null && ls AuthKey_*.p8 2>/dev/null | head -1) || true; }

# The Mac app's processes only: an iOS simulator's Passthrough is also named
# Passthrough, but runs from …/Passthrough.app/Passthrough, not Contents/MacOS.
app_pids() {
  local p
  for p in $(pgrep -x Passthrough 2>/dev/null || true); do
    case "$(ps -o comm= -p "$p" 2>/dev/null)" in */Contents/MacOS/Passthrough) echo "$p" ;; esac
  done
}
helper_pid() { pgrep -x PassthroughHelper 2>/dev/null | head -1 || true; }

# Hosted shell sessions. The app forks each one straight onto a pty
# (CPTY's pt_spawn_on_pty: fork, setsid, TIOCSCTTY, exec the login shell with
# -l), so every live session is a direct child of the app's process with a
# controlling terminal, whatever it now runs (a shell can exec claude, vim…).
# Anything else the app might start has no terminal ("??"), and a Terminal
# window showing a session runs passthrough-term under Terminal, not under the
# app. So: children of the app that have a tty. Prints "pid tty command".
shell_sessions() {
  local pid
  for pid in $(app_pids); do
    ps -axo pid=,ppid=,tty=,comm= | awk -v p="$pid" '$2 == p && $3 != "??" { print $1, $3, $4 }'
  done
}

default_iface() { route -n get default 2>/dev/null | awk '/interface:/ {print $2}'; }

helper_registered() { launchctl print "system/$HELPER_LABEL" >/dev/null 2>&1; }

# --- The safety checks before quitting or swapping the app ---------------------

check_release() {  # <new app>
  local kind; kind="$(app_kind "$1")"
  if [ "$kind" = release ]; then ok "The new app is a Release build (no get-task-allow in the app or its helper)."
  else bad "The new app is a $kind build. The installed Release helper refuses an app that carries get-task-allow, so the tunnel and keep-awake would stop working." \
           "Build Release: ./passthrough mac build (without --debug)."; fi
}

check_push() {  # <new app>
  local old new
  [ -d "$APP_DEST" ] || { ok "Nothing installed yet, so no push key to keep."; return; }
  old="$(push_key_of "$APP_DEST")"; new="$(push_key_of "$1")"
  if [ -z "$old" ]; then ok "The installed app has no push key, so none is lost${new:+ (the new one has $new)}."
  elif [ -n "$new" ]; then ok "Push key kept ($new)."
  else bad "The installed app has a push key ($old) and the new one has none: phone notifications would stop." \
           "Put the .p8 back in Config/ and set PASSTHROUGH_PUSH_KEY_FILE in Config/Signing.xcconfig, then rebuild."; fi
}

check_writable() {
  local foreign
  [ -d "$APP_DEST" ] || { [ -w /Applications ] && ok "/Applications is writable." && return; bad "You can't write to /Applications." "Use an administrator account."; return; }
  foreign="$(find "$APP_DEST" ! -user "$(id -u)" -print 2>/dev/null | head -1)"
  if [ -z "$foreign" ]; then ok "$APP_DEST is yours to replace."
  else bad "$APP_DEST has files you don't own ($foreign), so replacing it would stop halfway." "sudo chown -R \"$(id -un)\" $APP_DEST"; fi
}

check_route() {
  local iface; iface="$(default_iface)"
  case "$iface" in
    utun*) bad "This Mac's default route is $iface: it's online through a tunnel (the phone's, or a VPN). Quitting Passthrough would cut this Mac's internet, and this session with it." \
               "Turn off Internet through the phone (and the VPN) in the menu bar first, so the Mac is on Wi-Fi or Ethernet." ;;
    "") ok "No default route (offline), so there's no connection to cut." ;;
    *) ok "Default route is $iface, not the phone's tunnel." ;;
  esac
}

check_one_process() {
  local pids n
  pids="$(app_pids)"; n="$(printf '%s' "$pids" | grep -c . || true)"
  if [ "$n" -le 1 ]; then ok "${n} Passthrough app process running."
  else
    bad "$n Passthrough app processes are running; quitting by bundle ID would pick one of them." \
        "Quit the extra copy (usually a Debug build run from Xcode), then run this again."
    for p in $pids; do info "$p $(ps -o command= -p "$p" 2>/dev/null)"; done
  fi
}

check_no_shells() {
  local s n
  s="$(shell_sessions)"; n="$(printf '%s' "$s" | grep -c . || true)"
  if [ "$n" = 0 ]; then ok "No hosted shell sessions running."
  else
    bad "$n shell session(s) hosted by Passthrough are running. Quitting ends them for every phone using them." \
        "Finish or close them (from the phone, or Terminals on this Mac), then run this again."
    printf '%s\n' "$s" | while read -r pid tty cmd; do info "pid $pid on $tty: $cmd"; done
  fi
}

# gate <what>: stops when a check above failed, unless --force or --dry-run.
DRY_REFUSED=0
gate() {
  if [ "$PT_FAILS" = 0 ]; then return 0; fi
  if [ "$FORCE" = 1 ]; then warn "Going ahead anyway (--force)."; PT_FAILS=0; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then
    warn "Without --dry-run this would stop here. Showing the rest of the plan."
    DRY_REFUSED=1; PT_FAILS=0; return 0
  fi
  die "Not going to $1: a check above refused. Fix it and run this again (after a build, add --no-build to skip rebuilding), or pass --force if you're sure."
}

# --- Quitting, swapping, verifying -------------------------------------------

quit_app() {
  local pids i
  pids="$(app_pids)"
  if [ -z "$pids" ]; then ok "Passthrough isn't running."; return; fi
  # Only when it runs: "tell application id" would launch it otherwise.
  run osascript -e "tell application id \"$BUNDLE_ID\" to quit"
  [ "$DRY_RUN" = 1 ] && { info "[dry-run] would wait up to 10 s for it to exit"; return; }
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -z "$(app_pids)" ] && { ok "Passthrough quit."; return; }
    sleep 1
  done
  die "Passthrough didn't quit within 10 s (a dialog may be waiting). Quit it from the menu bar's power button, then run this again."
}

# swap <new app>: the running app's copy becomes build/Passthrough.app.previous.
swap() {
  step "Swapping the app"
  info "A Release build ignores --diagnostics and PASSTHROUGH_NO_AUTOCONNECT: when it opens, it connects"
  info "through a phone if one is plugged in and set to connect."
  quit_app
  if [ -d "$APP_DEST" ]; then
    run rm -rf "$PREV"
    run ditto "$APP_DEST" "$PREV"
    run rm -rf "$APP_DEST"
  fi
  run ditto "$1" "$APP_DEST" || die "Copying the new app failed. The old one is in build/Passthrough.app.previous: ./passthrough mac rollback"
  run open "$APP_DEST"
}

verify_running() {
  step "Checking the new app"
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] would wait 15 s, then look for refusals in: log show --last 30s --predicate 'process == \"PassthroughHelper\"'"
    return 0
  fi
  info "Waiting 15 s for the app to reach its helper…"
  sleep 15
  local pids lines
  pids="$(app_pids)"
  if [ -n "$pids" ]; then ok "Passthrough is running (pid $(printf '%s' "$pids" | tr '\n' ' '))."
  else bad "Passthrough isn't running after opening it." "Open /Applications/Passthrough.app and check ~/Library/Logs/DiagnosticReports."; fi
  # The helper's process is PassthroughHelper (its PRODUCT_NAME). A Release
  # helper sets a code-signing requirement on each connection; libxpc then
  # logs the refusal of a client that doesn't meet it.
  lines="$(/usr/bin/log show --last 30s --style compact --predicate 'process == "PassthroughHelper"' 2>/dev/null \
           | grep -iE 'forbidden|code signing requirement|refusing all clients' || true)"
  if [ -z "$lines" ]; then ok "The helper refused nothing in the last 30 s."
  else
    printf '%s\n' "$lines" | tail -5 | sed 's/^/      /'
    bad "The helper is refusing the app." \
        "Usually a Debug build: check with ./passthrough mac doctor, then ./passthrough mac rollback, or rebuild Release and install again."
  fi
  if [ "$PT_FAILS" -gt 0 ]; then die "Installed, but something is wrong (above)."; fi
  if helper_registered; then ok "The helper is registered."; else
    warn "The helper isn't registered yet." "It registers on first connect; macOS may ask you to allow it under System Settings ▸ General ▸ Login Items & Extensions."; fi
}

# --- Verbs --------------------------------------------------------------------

do_doctor() {
  step "Tools"
  if xcodebuild -version >/dev/null 2>&1; then ok "$(xcodebuild -version | tr '\n' ' ')($(xcode-select -p))"
  else bad "Xcode isn't installed or selected." "Install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app"; fi
  if have xcodegen; then ok "xcodegen $(xcodegen --version 2>/dev/null | awk '{print $NF}')"
  else bad "xcodegen is missing." "./passthrough mac deps (or brew install xcodegen)"; fi
  if xcrun metal --version >/dev/null 2>&1; then ok "Metal toolchain (SwiftTerm's shader)"
  else bad "The Metal toolchain is missing; SwiftTerm's shader won't compile." "xcodebuild -downloadComponent MetalToolchain (deps does this)"; fi
  if have cmake && have ninja; then ok "cmake $(cmake --version | head -1 | awk '{print $3}') and ninja $(ninja --version) (for the PC-screen engine)"
  else warn "cmake or ninja is missing (only needed to build the PC-screen engine)." "brew install cmake ninja"; fi

  step "Signing"
  if [ -f "$SIGNING" ]; then
    if [ -n "$(team_id)" ]; then ok "Config/Signing.xcconfig: DEVELOPMENT_TEAM = $(team_id)"
    else bad "DEVELOPMENT_TEAM is empty in Config/Signing.xcconfig." "./passthrough mac deps offers the team it finds, or set it by hand (Xcode ▸ Settings ▸ Accounts)."; fi
  else bad "Config/Signing.xcconfig is missing." "./passthrough mac deps copies the example; then set DEVELOPMENT_TEAM."; fi
  local teams; teams="$(signing_teams)"
  if [ -n "$teams" ]; then info "Teams with a signing certificate in your keychain:"; printf '%s\n' "$teams" | sed 's/^/      /'
  else warn "No Apple Development certificate in your keychain." "Sign in to your account in Xcode ▸ Settings ▸ Accounts; Xcode makes one on the first build."; fi
  [ "$(pt_identifier)" = "dev.dpatel.passthrough" ] || info "PASSTHROUGH_ID = $(pt_identifier)"

  step "Push key (optional)"
  local key keypath
  key="$(xc_value "$SIGNING" PASSTHROUGH_PUSH_KEY_FILE)"
  if [ -z "$key" ]; then
    warn "PASSTHROUGH_PUSH_KEY_FILE isn't set: the Mac builds without phone notifications." "See README ▸ Install: put AuthKey_<Key ID>.p8 in Config/ and name it in Config/Signing.xcconfig."
  else
    case "$key" in /*) keypath="$key" ;; "~/"*) keypath="$HOME/${key#\~/}" ;; *) keypath="$PT_ROOT/$key" ;; esac
    if [ -f "$keypath" ]; then ok "Push key $key is there."
    else bad "PASSTHROUGH_PUSH_KEY_FILE names $key, which isn't there; the build will fail." "Put the .p8 back, or remove the line to build without notifications."; fi
  fi

  step "Remote Desktop engine (optional: a PC's screen)"
  case "$(engine_state)" in
    current) ok "Vendor/FreeRDP/FreeRDP.xcframework is built and matches its sources." ;;
    stale) warn "The engine is out of date with its sources." "./passthrough mac update rebuilds it (or bash scripts/build-freerdp.sh)." ;;
    unknown) warn "The engine is there but has no SOURCES.lock, so its sources can't be checked." "bash scripts/build-freerdp.sh" ;;
    missing) warn "Not built: everything else works, and a PC's screen is left out." "./passthrough mac deps (needs cmake and ninja; takes a while)" ;;
  esac

  step "Installed app"
  if [ -d "$APP_DEST" ]; then
    local plist="$APP_DEST/Contents/Info.plist" kind pk signed
    signed="$(codesign -dvv "$APP_DEST" 2>&1 | sed -n 's/^Signed Time=//p')"
    ok "$APP_DEST: version $(plist_get "$plist" CFBundleShortVersionString) ($(plist_get "$plist" CFBundleVersion)), $(plist_get "$plist" CFBundleIdentifier)${signed:+, signed $signed}"
    kind="$(app_kind "$APP_DEST")"
    if [ "$kind" = release ]; then ok "Release build (no get-task-allow in the app or its helper)."
    else bad "It's a $kind build; the Release helper refuses it." "./passthrough mac install"; fi
    pk="$(push_key_of "$APP_DEST")"
    if [ -n "$pk" ]; then ok "Has a push key ($pk): notifications on."; else warn "No push key: it sends no phone notifications."; fi
  else
    warn "Not installed in /Applications." "./passthrough mac install"
  fi
  if [ -d "$PREV" ]; then info "Previous copy for rollback: build/Passthrough.app.previous"; fi
  if [ -d "$DRIVER" ]; then ok "Microphone driver installed ($DRIVER)."; else info "Microphone driver not installed (the app offers it when a phone views the screen)."; fi

  step "Running"
  local pids hp sessions
  pids="$(app_pids)"
  if [ -n "$pids" ]; then
    for p in $pids; do ok "Passthrough pid $p: $(ps -o command= -p "$p" 2>/dev/null)"; done
  else info "Passthrough isn't running."; fi
  hp="$(helper_pid)"
  if helper_registered; then
    ok "Helper $HELPER_LABEL is registered$(launchctl print "system/$HELPER_LABEL" 2>/dev/null | awk -F' = ' '/^\tstate = / {print " (" $2 ")"; exit}')${hp:+, pid $hp}."
  else info "Helper $HELPER_LABEL isn't registered (it registers on first connect)."; fi
  sessions="$(shell_sessions)"
  if [ -n "$sessions" ]; then warn "$(printf '%s\n' "$sessions" | grep -c .) hosted shell session(s) running; installing or removing ends them."
  elif [ -n "$pids" ]; then ok "No hosted shell sessions."; fi
  local iface; iface="$(default_iface)"
  case "$iface" in
    utun*) warn "Default route is $iface: online through a tunnel (the phone or a VPN). install and remove refuse until it's off." ;;
    "") warn "No default route: this Mac is offline." ;;
    *) ok "Default route is $iface (a physical interface)." ;;
  esac

  if [ "$PT_FAILS" -gt 0 ]; then printf '\n%s✗ %d problem(s) above.%s\n' "$C_BAD" "$PT_FAILS" "$C_0"; exit 1; fi
  done_ok "Ready."
}

set_team() {  # <TEAM>
  printf '%s' "$1" | grep -Eq '^[A-Z0-9]{10}$' || die "\"$1\" isn't a Team ID (ten capital letters and digits)."
  if grep -Eq '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=' "$SIGNING"; then
    run sed -i '' -E "s/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=.*/DEVELOPMENT_TEAM = $1/" "$SIGNING"
  elif [ "$DRY_RUN" = 1 ]; then
    run sh -c "echo 'DEVELOPMENT_TEAM = $1' >> Config/Signing.xcconfig"
  else
    printf 'DEVELOPMENT_TEAM = %s\n' "$1" >> "$SIGNING"
  fi
  did "DEVELOPMENT_TEAM = $1"
}

do_deps() {
  step "Homebrew packages"
  local pkgs="xcodegen" missing="" p
  [ "$NO_ENGINE" = 1 ] || pkgs="$pkgs cmake ninja"
  for p in $pkgs; do have "$p" || missing="$missing $p"; done
  if [ -z "$missing" ]; then ok "Installed:$(printf ' %s' $pkgs)"
  else
    have brew || die "Homebrew is missing. Install it from https://brew.sh, then run this again."
    if confirm "Install$missing with Homebrew?"; then
      # shellcheck disable=SC2086
      run brew install $missing
    else die "Not installing$missing."; fi
  fi

  step "Metal toolchain"
  if xcrun metal --version >/dev/null 2>&1; then ok "Installed."
  elif confirm "Download Xcode's Metal toolchain (SwiftTerm needs it)?"; then run xcodebuild -downloadComponent MetalToolchain
  else die "SwiftTerm's shader needs the Metal toolchain: xcodebuild -downloadComponent MetalToolchain"; fi

  step "Signing"
  if [ ! -f "$SIGNING" ]; then
    run cp "$PT_ROOT/Config/Signing.xcconfig.example" "$SIGNING"
    did "Copied Config/Signing.xcconfig.example to Config/Signing.xcconfig (gitignored)."
  fi
  if [ -n "$TEAM_ARG" ]; then set_team "$TEAM_ARG"
  elif [ -n "$(team_id)" ]; then ok "DEVELOPMENT_TEAM = $(team_id)"
  else
    local teams n
    teams="$(signing_teams)"; n="$(printf '%s' "$teams" | grep -c . || true)"
    if [ "$n" = 1 ] && confirm "Use team $(printf '%s' "$teams" | awk '{print $1}') ($(printf '%s' "$teams" | cut -c13-)), the only one with a certificate in your keychain?"; then
      set_team "$(printf '%s' "$teams" | awk '{print $1}')"
    else
      bad "DEVELOPMENT_TEAM must be set in Config/Signing.xcconfig."
      info "Find your Team ID in Xcode ▸ Settings ▸ Accounts (select the team), or developer.apple.com ▸ Account ▸ Membership."
      if [ -n "$teams" ]; then info "Teams with a certificate in your keychain:"; printf '%s\n' "$teams" | sed 's/^/      /'; fi
      info "Then: ./passthrough mac deps --team <TEAMID>   (or edit the file)."
      info "The iPhone's VPN extension needs a paid team; with a free Mac team, also set DEVELOPMENT_TEAM[sdk=iphoneos*]."
      die "Set DEVELOPMENT_TEAM, then run this again."
    fi
  fi
  if [ -z "$(xc_value "$SIGNING" PASSTHROUGH_PUSH_KEY_FILE)" ]; then
    warn "No push key: the Mac will send no phone notifications (optional)." "Put AuthKey_<Key ID>.p8 in Config/ and set PASSTHROUGH_PUSH_KEY_FILE in Config/Signing.xcconfig (README ▸ Install)."
  fi

  step "Remote Desktop engine"
  if [ "$NO_ENGINE" = 1 ]; then info "Skipped (--no-engine); a PC's screen is left out."
  else
    case "$(engine_state)" in
      current) ok "Built and current." ;;
      unknown) warn "Built, without a SOURCES.lock to check it against; leaving it." ;;
      missing|stale) build_engine ;;
    esac
  fi
  done_ok "Dependencies are in place. Next: ./passthrough mac install"
}

do_build() {
  step "Building PassthroughMac ($CONFIG)"
  require_signing
  case "$(engine_state)" in
    missing) warn "No Remote Desktop engine: building without a PC's screen (./passthrough mac deps builds it)." ;;
    stale) warn "The Remote Desktop engine is out of date with its sources (./passthrough mac update rebuilds it)." ;;
  esac
  xcodegen_generate
  xcode_build "mac-$(printf '%s' "$CONFIG" | tr '[:upper:]' '[:lower:]')" \
    -project Passthrough.xcodeproj -scheme PassthroughMac -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" -onlyUsePackageVersionsFromResolvedFile \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
  if [ "$DRY_RUN" = 1 ]; then info "[dry-run] the app would be at ${BUILT_APP#"$PT_ROOT"/}"; return 0; fi
  [ -d "$BUILT_APP" ] || die "The build finished but $BUILT_APP isn't there."
  ok "Built ${BUILT_APP#"$PT_ROOT"/} ($(app_kind "$BUILT_APP"))."
  local pk; pk="$(push_key_of "$BUILT_APP")"
  if [ -n "$pk" ]; then ok "Push key bundled ($pk)."; else warn "No push key bundled: this build sends no phone notifications."; fi
  if [ "$DEBUG" = 1 ]; then warn "This is a Debug build: it can't be installed (the Release helper refuses it). It's for running from Xcode."; fi
}

# install_from <app> [<app to check>]: the checks, the swap, the verification.
# The second is for --dry-run, where a staged copy was never made.
install_from() {
  local check="${2:-$1}"
  step "Checking before swapping"
  if [ -d "$check" ]; then
    check_release "$check"
    check_push "$check"
  elif [ "$DRY_RUN" = 1 ]; then
    warn "No built app at ${check#"$PT_ROOT"/} yet, so the Release and push-key checks would run after the build."
  else die "No app at $1."; fi
  check_writable
  check_route
  check_one_process
  check_no_shells
  gate "swap the app"
  swap "$1"
  verify_running
}

finish() {
  if [ "$DRY_REFUSED" = 1 ]; then die "Dry run finished; a check would have stopped the real run (above)."; fi
  if [ "$DRY_RUN" = 1 ]; then done_ok "Dry run finished; nothing was changed."; else done_ok "$1"; fi
}

do_install() {
  [ "$DEBUG" = 0 ] || die "install takes a Release build only: the Release helper refuses a Debug app. Use build --debug for Xcode work."
  if [ "$NO_BUILD" = 0 ]; then do_build; else info "Not building (--no-build): installing ${BUILT_APP#"$PT_ROOT"/}"; fi
  install_from "$BUILT_APP"
  finish "Passthrough is installed in /Applications. On first connect macOS may ask you to allow its helper in System Settings ▸ General ▸ Login Items & Extensions."
}

do_update() {
  [ "$PULL" = 0 ] || git_pull
  if [ "$NO_ENGINE" = 0 ]; then
    case "$(engine_state)" in
      stale) step "The Remote Desktop engine's sources changed"; build_engine ;;
      missing) info "No Remote Desktop engine built; leaving it out (./passthrough mac deps builds it)." ;;
    esac
  fi
  do_install
}

do_rollback() {
  [ -d "$PREV" ] || die "There's no build/Passthrough.app.previous to roll back to."
  local staged="$PT_ROOT/build/Passthrough.app.rollback"
  run rm -rf "$staged"
  run ditto "$PREV" "$staged"
  install_from "$staged" "$PREV"
  [ "$DRY_RUN" = 1 ] || run rm -rf "$PT_ROOT/build/Passthrough.app.rollback"
  finish "Rolled back. The app that was installed is now build/Passthrough.app.previous."
}

do_remove() {
  step "Checking before removing"
  check_route
  check_one_process
  check_no_shells
  gate "remove Passthrough"

  local registered=0 sleep_off=0
  helper_registered && registered=1
  pmset -g 2>/dev/null | grep -Eq 'SleepDisabled[[:space:]]+1' && sleep_off=1

  step "What happens"
  info "1. Quit Passthrough (it turns the tunnel and the VPN off on the way out)."
  [ "$registered" = 1 ] && info "2. sudo launchctl bootout system/$HELPER_LABEL: stop and unload the root helper."
  [ "$sleep_off" = 1 ] && info "   sudo pmset -a disablesleep 0: sleep is disabled (keep-awake), turn it back on."
  [ -d "$HELPER_STATE" ] && info "   sudo rm -rf $HELPER_STATE: the helper's run-time files."
  info "3. Delete $APP_DEST."
  [ -d "$DRIVER" ] && info "4. sudo rm -rf $DRIVER, then sudo killall coreaudiod (audio drops for a second)."
  info "5. Remove its Start at login item, and check what macOS still lists for it."
  [ "$PURGE" = 1 ] && info "6. --purge: delete its settings ($ID.mac) and ~/Library/Application Support/$ID (shell history, activity)."
  if [ "$registered" = 1 ] || [ "$sleep_off" = 1 ] || [ -d "$DRIVER" ] || [ -d "$HELPER_STATE" ]; then
    info "sudo asks for your password once, before step 2."
  fi
  confirm "Remove Passthrough from this Mac?" || die "Nothing removed."

  step "Removing"
  quit_app
  if [ "$registered" = 1 ] || [ "$sleep_off" = 1 ] || [ -d "$DRIVER" ] || [ -d "$HELPER_STATE" ]; then
    [ "$DRY_RUN" = 1 ] || sudo -v || die "sudo is needed to stop the helper and remove the driver."
  fi
  if [ "$registered" = 1 ]; then
    # The helper is an SMAppService daemon: only the app itself can call
    # SMAppService.unregister(), and the app is about to be deleted. bootout
    # stops the daemon and unloads it from launchd now; with the bundle gone,
    # launchd has nothing to start at the next boot. The Background Task
    # Management record (Login Items ▸ Allow in the Background) can outlive
    # the bundle; it's inert, and is checked (read-only) with sfltool below.
    # Not `sfltool resetbtm`: that resets every app's login items and
    # background permissions and needs a restart.
    run sudo launchctl bootout "system/$HELPER_LABEL" || true
    if [ "$DRY_RUN" = 0 ]; then
      if helper_registered; then bad "launchd still has system/$HELPER_LABEL." "sudo launchctl bootout system/$HELPER_LABEL, or restart the Mac once the app is gone."
      else ok "Helper stopped and unloaded."; fi
    fi
  else ok "The helper isn't loaded."; fi
  # Keep-awake sets pmset disablesleep; quitting usually turns it back, so look again.
  if [ "$DRY_RUN" = 1 ]; then [ "$sleep_off" = 0 ] || run sudo pmset -a disablesleep 0
  elif pmset -g 2>/dev/null | grep -Eq 'SleepDisabled[[:space:]]+1'; then run sudo pmset -a disablesleep 0; fi
  if [ -d "$HELPER_STATE" ]; then run sudo rm -rf "$HELPER_STATE"; fi

  if [ -d "$APP_DEST" ]; then run rm -rf "$APP_DEST"; did "Deleted $APP_DEST."
  else ok "$APP_DEST isn't there."; fi

  if [ -d "$DRIVER" ] || [ -d "$DRIVER_STAGING" ]; then
    [ -d "$DRIVER" ] && run sudo rm -rf "$DRIVER"
    [ -d "$DRIVER_STAGING" ] && run sudo rm -rf "$DRIVER_STAGING"
    run sudo killall coreaudiod || true
    did "Microphone driver removed."
  else ok "No microphone driver installed."; fi

  step "Login items"
  # Start at login is SMAppService.mainApp, which only the app can unregister.
  # System Events lists the same "Open at Login" items on recent macOS and can
  # delete one; macOS may ask once whether Terminal may control System Events.
  if [ "$DRY_RUN" = 1 ]; then
    run osascript -e 'tell application "System Events" to delete (every login item whose name is "Passthrough")'
  elif osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -q 'Passthrough'; then
    run osascript -e 'tell application "System Events" to delete (every login item whose name is "Passthrough")' >/dev/null || true
  fi
  local btm=""
  # Read-only, and only with sudo's cached password (-n): no prompt of its own.
  if [ "$DRY_RUN" = 0 ]; then btm="$(sudo -n sfltool dumpbtm 2>/dev/null | grep -c "$ID" || true)"; fi
  if [ -n "$btm" ] && [ "$btm" != 0 ]; then
    warn "macOS still remembers Passthrough's background items ($btm mention(s) in sfltool dumpbtm). They're inert without the app."
    info "To tidy them: System Settings ▸ General ▸ Login Items & Extensions; remove Passthrough under Open at Login, and turn it off under Allow in the Background if it's listed."
  else
    info "Check System Settings ▸ General ▸ Login Items & Extensions: Passthrough shouldn't be under Open at Login or Allow in the Background."
  fi

  if [ "$PURGE" = 1 ]; then
    step "Purging settings and data"
    local d
    if defaults read "$ID.mac" >/dev/null 2>&1; then run defaults delete "$ID.mac"; fi
    for d in "$HOME/Library/Application Support/$ID" "$HOME/Library/Caches/$ID.mac" \
             "$HOME/Library/HTTPStorages/$ID.mac" "$HOME/Library/HTTPStorages/$ID.mac.binarycookies" \
             "$HOME/Library/Saved Application State/$ID.mac.savedState" "${TMPDIR:-/tmp}/$ID.terminals.sock"; do
      if [ -e "$d" ]; then run rm -rf "$d"; fi
    done
    did "Settings, shell history, activity and caches deleted."
    warn "Keychain items stay: the phones' pairing tokens, Remote shell's keys and identity, and saved Windows sign-ins." \
      "They're in the data-protection keychain under the services $ID and $ID.windows-login, which only an app signed by your team can read or delete (the security command can't), so a reinstall picks them up again. To start clean, delete them from the app before removing it (Settings ▸ General ▸ Forget Pairing, Settings ▸ Remote Shell ▸ Reset Identity, Forget Saved Sign-In)."
  fi
  if [ "$PT_FAILS" -gt 0 ]; then die "Removed, with problems (above)."; fi
  [ "$PURGE" = 1 ] || info "Your settings and data in ~/Library stay; remove --purge deletes them too."
  finish "Passthrough is removed from this Mac."
}

case "$VERB" in
  doctor) do_doctor ;;
  deps) do_deps ;;
  build) do_build; [ "$DRY_RUN" = 1 ] && done_ok "Dry run finished; nothing was built." || done_ok "Built: ${BUILT_APP}" ;;
  install|reinstall) do_install ;;
  update) do_update ;;
  rollback) do_rollback ;;
  remove|uninstall) do_remove ;;
  *) die "Unknown verb \"$VERB\" (see ./passthrough mac --help)" ;;
esac
