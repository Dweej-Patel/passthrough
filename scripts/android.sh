#!/bin/bash
# The Android app: check, set up, build, install, update and remove, over adb.
# Run ./passthrough android --help. Bash 3.2.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./passthrough android <verb> [flags]

Verbs
  doctor              JDK 25, the Android SDK, adb, and a connected phone with USB debugging allowed.
  deps [--yes]        Installs adb (android-platform-tools), JDK 25 and the SDK's
                      platform 35 with Homebrew, and points android/local.properties at the SDK.
  build               ./gradlew assembleDebug in android/.
  install [--device SERIAL] [--no-build] [--force]
                      ./gradlew installDebug on the phone, then opens the app. With one
                      phone it's used; with several, name one. Pairings stay.
  update [--pull] [--device SERIAL] [--force]
                      --pull runs git pull --ff-only first; then as install.
  remove [--device SERIAL] [--yes]
                      adb uninstall: deletes the app with its pairings and keys.

Flags
  --dry-run           Prints each action instead of doing it.
  --force             Installs even when the Mac is online through a phone right now.
  --yes, -y           Answers yes to every question.
  --help, -h          This text.
EOF
}

VERB="${1:-}"
case "$VERB" in ""|-h|--help|help) usage; exit 0 ;; esac
shift

DEVICE_ARG="" PULL=0 NO_BUILD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) YES=1 ;;
    --device) [ $# -ge 2 ] || die "--device needs a serial (see adb devices)"; DEVICE_ARG="$2"; shift ;;
    --pull) PULL=1 ;;
    --no-build) NO_BUILD=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown flag $1 (see ./passthrough android --help)" ;;
  esac
  shift
done

ANDROID_DIR="$PT_ROOT/android"
APP_ID="$(sed -n 's/^[[:space:]]*applicationId[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ANDROID_DIR/app/build.gradle.kts" | head -1)"
APP_ID="${APP_ID:-dev.dpatel.passthrough.android}"
APK="$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk"
JDK_MAJOR=25
SDK_PLATFORM="$(sed -n 's/^[[:space:]]*compileSdk[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "$ANDROID_DIR/app/build.gradle.kts" | head -1)"
SDK_PLATFORM="${SDK_PLATFORM:-35}"

java_major() { "$1/bin/java" -version 2>&1 | awk -F'"' '/version/ {print $2; exit}' | cut -d. -f1; }

# find_jdk: a JDK 25 (or later) home: $JAVA_HOME, java_home, or Homebrew's
# openjdk@25, which isn't linked where /usr/libexec/java_home looks.
find_jdk() {
  local h m
  for h in "${JAVA_HOME:-}" "$(/usr/libexec/java_home -v "$JDK_MAJOR" 2>/dev/null || true)" \
           "/opt/homebrew/opt/openjdk@$JDK_MAJOR/libexec/openjdk.jdk/Contents/Home" \
           "/usr/local/opt/openjdk@$JDK_MAJOR/libexec/openjdk.jdk/Contents/Home"; do
    [ -n "$h" ] && [ -x "$h/bin/java" ] || continue
    m="$(java_major "$h")"
    if [ -n "$m" ] && [ "$m" -ge "$JDK_MAJOR" ] 2>/dev/null; then printf '%s' "$h"; return; fi
  done
}

local_sdk_dir() { [ -f "$ANDROID_DIR/local.properties" ] && sed -n 's/^sdk\.dir=//p' "$ANDROID_DIR/local.properties" | tail -1 || true; }

# find_sdk: what Gradle would use (local.properties, then the environment),
# then the usual places.
find_sdk() {
  local d
  for d in "$(local_sdk_dir)" "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "/opt/homebrew/share/android-commandlinetools"; do
    if [ -n "$d" ] && [ -d "$d/platforms" -o -d "$d/cmdline-tools" ]; then printf '%s' "$d"; return; fi
  done
}

find_adb() {
  if have adb; then command -v adb; return; fi
  local sdk; sdk="$(find_sdk)"
  if [ -n "$sdk" ] && [ -x "$sdk/platform-tools/adb" ]; then printf '%s' "$sdk/platform-tools/adb"; fi
}

# phones: "serial<TAB>state<TAB>model" from adb devices -l (state: device,
# unauthorized, offline…). Lists only; nothing is sent to the phone.
phones() {
  local adb; adb="$(find_adb)"
  [ -n "$adb" ] || return 0
  "$adb" devices -l 2>/dev/null | awk 'NR > 1 && NF >= 2 {
    model = ""; for (i = 3; i <= NF; i++) if ($i ~ /^model:/) model = substr($i, 7)
    printf "%s\t%s\t%s\n", $1, $2, model }'
}

pick_phone() {
  local ready n
  ready="$(phones | awk -F'\t' '$2 == "device"')"
  n="$(printf '%s' "$ready" | grep -c . || true)"
  if [ -n "$DEVICE_ARG" ]; then
    if printf '%s\n' "$ready" | awk -F'\t' -v d="$DEVICE_ARG" '$1 == d {f=1} END {exit !f}'; then printf '%s' "$DEVICE_ARG"; return; fi
    if [ "$DRY_RUN" = 1 ]; then warn "$DEVICE_ARG isn't connected; showing the plan anyway (--dry-run)." >&2; printf '%s' "$DEVICE_ARG"; return; fi
    die "$DEVICE_ARG isn't connected with USB debugging allowed (adb devices)."
  fi
  if [ "$n" = 0 ] && [ "$DRY_RUN" = 1 ]; then warn "No Android phone connected; showing the plan for one anyway (--dry-run)." >&2; printf '<serial>'; return; fi
  case "$n" in
    0) if phones | grep -q $'\tunauthorized'; then die "The phone hasn't allowed this Mac yet: unlock it and accept the USB debugging prompt."; fi
       die "No Android phone connected. Turn on USB debugging (Settings ▸ About phone ▸ tap Build number seven times, then Developer options), and plug it in." ;;
    1) printf '%s' "$ready" | cut -f1 ;;
    *) printf '%s\n' "$ready" | awk -F'\t' '{printf "    %s  %s\n", $1, $3}' >&2
       die "Several phones are connected; choose one with --device <serial>." ;;
  esac
}

# gradle <tasks…>: with JDK 25 and the SDK in the environment.
gradle() {
  local jdk sdk
  jdk="$(find_jdk)"; sdk="$(find_sdk)"
  if [ -z "$jdk" ]; then
    [ "$DRY_RUN" = 1 ] || die "JDK $JDK_MAJOR is missing: ./passthrough android deps (or brew install openjdk@$JDK_MAJOR)."
    jdk="<JDK $JDK_MAJOR>"
  fi
  [ -n "$sdk" ] || [ "$DRY_RUN" = 1 ] || die "The Android SDK is missing: ./passthrough android deps"
  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[dry-run]%s (cd android && JAVA_HOME=%s%s%s ./gradlew %s)\n' "$C_WARN" "$C_0" "$jdk" \
      "${sdk:+ ANDROID_HOME=$sdk}" "${ANDROID_SERIAL:+ ANDROID_SERIAL=$ANDROID_SERIAL}" "$*"
    return 0
  fi
  printf '  %s$ (cd android && ./gradlew %s)%s\n' "$C_DIM" "$*" "$C_0"
  (cd "$ANDROID_DIR" && JAVA_HOME="$jdk" ANDROID_HOME="${sdk:-}" ./gradlew --console=plain -q "$@")
}

do_doctor() {
  step "Build tools"
  local jdk sdk adb
  jdk="$(find_jdk)"
  if [ -n "$jdk" ]; then ok "JDK $(java_major "$jdk") at $jdk"
  else bad "JDK $JDK_MAJOR isn't installed (Gradle and the Android plugin need it)." "./passthrough android deps (or brew install openjdk@$JDK_MAJOR)"; fi
  sdk="$(find_sdk)"
  if [ -z "$sdk" ]; then bad "The Android SDK isn't installed." "./passthrough android deps, or install Android Studio"
  else
    ok "Android SDK at $sdk"
    if [ -d "$sdk/platforms/android-$SDK_PLATFORM" ]; then ok "Platform android-$SDK_PLATFORM"
    else bad "The SDK has no platform android-$SDK_PLATFORM." "sdkmanager \"platforms;android-$SDK_PLATFORM\" \"build-tools;$SDK_PLATFORM.0.0\" (deps does this)"; fi
    if [ -z "$(local_sdk_dir)" ] && [ -z "${ANDROID_HOME:-}" ]; then warn "Gradle won't find the SDK by itself (no android/local.properties, no ANDROID_HOME); these scripts pass it." "./passthrough android deps writes android/local.properties"; fi
  fi

  step "adb"
  adb="$(find_adb)"
  if [ -n "$adb" ]; then ok "adb at $adb"
  else bad "adb isn't installed (the Mac app needs it too)." "./passthrough android deps (or brew install --cask android-platform-tools)"; fi

  step "Phones"
  local list
  list="$(phones || true)"
  if [ -z "$list" ]; then bad "No Android phone connected." "Turn on USB debugging (Settings ▸ About phone ▸ tap Build number seven times, then Developer options), and plug it in."
  else
    printf '%s\n' "$list" | while IFS="$(printf '\t')" read -r serial state model; do
      case "$state" in
        device) ok "$serial ${model:+($model)}" ;;
        unauthorized) warn "$serial: hasn't allowed this Mac. Unlock it and accept the USB debugging prompt." ;;
        *) warn "$serial: $state" ;;
      esac
    done
  fi
  if [ "$PT_FAILS" -gt 0 ]; then printf '\n%s✗ %d problem(s) above.%s\n' "$C_BAD" "$PT_FAILS" "$C_0"; exit 1; fi
  done_ok "Ready."
}

do_deps() {
  local missing_casks="" missing_formulae="" sdk
  have brew || die "Homebrew is missing. Install it from https://brew.sh (or install Android Studio, which brings a JDK and the SDK)."
  step "Packages"
  [ -n "$(find_adb)" ] || missing_casks="$missing_casks android-platform-tools"
  [ -n "$(find_jdk)" ] || missing_formulae="$missing_formulae openjdk@$JDK_MAJOR"
  [ -n "$(find_sdk)" ] || missing_casks="$missing_casks android-commandlinetools"
  if [ -z "$missing_casks$missing_formulae" ]; then ok "adb, JDK $JDK_MAJOR and the Android SDK are installed."
  else
    if confirm "Install with Homebrew:$missing_formulae$missing_casks?"; then
      # shellcheck disable=SC2086
      [ -z "$missing_formulae" ] || run brew install $missing_formulae
      # shellcheck disable=SC2086
      [ -z "$missing_casks" ] || run brew install --cask $missing_casks
    else die "Nothing installed."; fi
  fi
  info "Gradle needs JDK $JDK_MAJOR; these scripts find Homebrew's by themselves. For Android Studio or your shell:"
  info "  export JAVA_HOME=\"\$(brew --prefix openjdk@$JDK_MAJOR)/libexec/openjdk.jdk/Contents/Home\""

  step "SDK packages"
  sdk="$(find_sdk)"
  [ -n "$sdk" ] || sdk="/opt/homebrew/share/android-commandlinetools"
  if [ -d "$sdk/platforms/android-$SDK_PLATFORM" ]; then ok "Platform android-$SDK_PLATFORM is installed."
  else
    local sdkmanager="$sdk/cmdline-tools/latest/bin/sdkmanager"
    [ -x "$sdkmanager" ] || sdkmanager="$(command -v sdkmanager || true)"
    [ -n "$sdkmanager" ] || [ "$DRY_RUN" = 1 ] || die "sdkmanager isn't installed: brew install --cask android-commandlinetools"
    if confirm "Install platform android-$SDK_PLATFORM and build-tools $SDK_PLATFORM.0.0, accepting their licences?"; then
      if [ "$DRY_RUN" = 1 ]; then run sh -c "yes | sdkmanager --sdk_root=$sdk --licenses"
      else yes | JAVA_HOME="$(find_jdk)" "$sdkmanager" --sdk_root="$sdk" --licenses >/dev/null || true; fi
      run env JAVA_HOME="$(find_jdk)" "${sdkmanager:-sdkmanager}" --sdk_root="$sdk" "platforms;android-$SDK_PLATFORM" "build-tools;$SDK_PLATFORM.0.0"
    else die "The build needs platform android-$SDK_PLATFORM."; fi
  fi
  if [ -z "$(local_sdk_dir)" ]; then
    if [ "$DRY_RUN" = 1 ]; then run sh -c "echo sdk.dir=$sdk >> android/local.properties"
    else printf 'sdk.dir=%s\n' "$sdk" >> "$ANDROID_DIR/local.properties"; ok "android/local.properties points at $sdk (gitignored)."; fi
  fi
  info "On the phone: Settings ▸ About phone ▸ tap Build number seven times, then turn on USB debugging in Developer options."
  done_ok "Dependencies are in place. Next: ./passthrough android install"
}

do_build() {
  step "Building the Android app (debug)"
  gradle assembleDebug
  [ "$DRY_RUN" = 1 ] || { [ -f "$APK" ] && ok "Built ${APK#"$PT_ROOT"/}"; }
}

do_install() {
  local serial adb
  step "Phone"
  serial="$(pick_phone)"
  ok "$serial"
  adb="$(find_adb)"; [ -n "$adb" ] || adb=adb
  export ANDROID_SERIAL="$serial"
  # Build first, then check the route (the build takes minutes), then install: replacing the app stops what
  # serves the Mac.
  if [ "$NO_BUILD" = 0 ]; then gradle assembleDebug; fi
  [ "$DRY_RUN" = 1 ] || [ -f "$APK" ] || die "No build at ${APK#"$PT_ROOT"/}; run without --no-build."
  check_phone_route
  step "Installing"
  run "$adb" -s "$serial" install -r "$APK"
  run "$adb" -s "$serial" shell monkey -p "$APP_ID" -c android.intent.category.LAUNCHER 1
  if [ "$DRY_RUN" = 1 ]; then done_ok "Dry run finished; nothing was changed."; return; fi
  done_ok "Installed on $serial. Tap the power button, then flip the switch in the Mac's menu bar and type the code from Pair your Mac."
  info "Install the Mac app from the same commit too: ./passthrough mac update"
}

do_update() {
  [ "$PULL" = 0 ] || git_pull
  do_install
}

do_remove() {
  local serial adb
  serial="$(pick_phone)"
  check_phone_route
  adb="$(find_adb)"; [ -n "$adb" ] || adb=adb
  warn "This deletes Passthrough from $serial with everything it saved: its pairings with your computers and its shell keys. Pairing again needs the cable."
  confirm "Delete Passthrough ($APP_ID) from $serial?" || die "Nothing removed."
  run "$adb" -s "$serial" uninstall "$APP_ID"
  if [ "$DRY_RUN" = 1 ]; then done_ok "Dry run finished; nothing was changed."; return; fi
  done_ok "Removed from $serial. On the Mac, Settings ▸ Remote Shell ▸ Phones with access still lists it until you remove it there."
}

case "$VERB" in
  doctor) do_doctor ;;
  deps) do_deps ;;
  build) do_build; [ "$DRY_RUN" = 1 ] || done_ok "Built: $APK" ;;
  install|reinstall) do_install ;;
  update) do_update ;;
  remove|uninstall) do_remove ;;
  *) die "Unknown verb \"$VERB\" (see ./passthrough android --help)" ;;
esac
