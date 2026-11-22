# shellcheck shell=bash
# Shared by scripts/mac.sh, scripts/iphone.sh and scripts/android.sh.
# Bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile, no ${x,,},
# and never "${empty[@]}" under set -u.

PT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Never as root: `open` from a root shell would start the Mac app as root (it then can't reach its own
# helper, Keychain or login items), and files it builds would be root's. The scripts ask for sudo
# themselves for the few steps that need it (removing the helper and the driver).
if [ "$(id -u)" = 0 ] && [ "${PT_ALLOW_ROOT:-0}" != 1 ]; then
  printf 'passthrough: run this as yourself, not with sudo or as root; it asks for your password where it needs it.\n' >&2
  exit 1
fi
cd "$PT_ROOT"

DRY_RUN=0
YES=0
FORCE=0
PT_FAILS=0

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_OK=''; C_BAD=''; C_WARN=''; C_DIM=''; C_B=''; C_0=''
fi

step() { printf '\n%s== %s%s\n' "$C_B" "$*" "$C_0"; }
ok()   { printf '  %s✓%s %s\n' "$C_OK" "$C_0" "$*"; }
# bad <what> [fix]: a failed check; counts toward PT_FAILS.
bad()  {
  PT_FAILS=$((PT_FAILS + 1))
  printf '  %s✗%s %s\n' "$C_BAD" "$C_0" "$1"
  if [ -n "${2:-}" ]; then printf '      %sfix:%s %s\n' "$C_DIM" "$C_0" "$2"; fi
}
warn() { printf '  %s!%s %s\n' "$C_WARN" "$C_0" "$1"; if [ -n "${2:-}" ]; then printf '      %s%s%s\n' "$C_DIM" "$2" "$C_0"; fi; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n%s✗ %s%s\n' "$C_BAD" "$*" "$C_0" >&2; exit 1; }
# did <msg>: an ok after an action, which a dry run didn't take.
did() { if [ "$DRY_RUN" = 1 ]; then return 0; fi; ok "$@"; }
done_ok() { printf '\n%s✓ %s%s\n' "$C_OK" "$*" "$C_0"; }

# shell_words <args…>: the command as you'd type it (single quotes where needed).
shell_words() {
  local a out=""
  for a in "$@"; do
    case "$a" in
      *[!A-Za-z0-9_./:=@%+,-]*|"") a="'$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'" ;;
    esac
    out="$out $a"
  done
  printf '%s' "$out"
}

# run <cmd> [args…]: runs it, or with --dry-run prints it.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[dry-run]%s%s\n' "$C_WARN" "$C_0" "$(shell_words "$@")"
    return 0
  fi
  printf '  %s$%s%s\n' "$C_DIM" "$(shell_words "$@")" "$C_0"
  "$@"
}

# confirm <question>: yes with --yes; no when there is no terminal to ask on.
confirm() {
  if [ "$YES" = 1 ]; then return 0; fi
  if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] would ask: %s (answering yes)\n' "$1"; return 0; fi
  if [ ! -t 0 ]; then
    printf '  %s (no terminal to ask on; pass --yes to agree)\n' "$1"
    return 1
  fi
  local answer
  printf '  %s [y/N] ' "$1"
  read -r answer || return 1
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

have() { command -v "$1" >/dev/null 2>&1; }

# xc_value <file> <key>: the last uncommented "KEY = value" in an xcconfig
# (KEY[sdk=…] variants don't match), without a trailing // comment.
xc_value() {
  [ -f "$1" ] || return 0
  # grep finds nothing when the key isn't set: that's an empty value, not a failure (pipefail).
  { grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" || true; } | tail -1 \
    | sed -e 's#[[:space:]]//.*##' -e 's/^[^=]*=//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

SIGNING="$PT_ROOT/Config/Signing.xcconfig"

# PASSTHROUGH_ID: Signing.xcconfig may override Identity.xcconfig's.
pt_identifier() {
  local id
  id="$(xc_value "$SIGNING" PASSTHROUGH_ID)"
  [ -n "$id" ] || id="$(xc_value "$PT_ROOT/Config/Identity.xcconfig" PASSTHROUGH_ID)"
  id="${id:-dev.dpatel.passthrough}"
  # It names folders --purge deletes: a reverse-DNS id only, never "..", a slash or a space.
  printf '%s' "$id" | grep -Eq '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' \
    || { printf 'passthrough: PASSTHROUGH_ID "%s" in Config/*.xcconfig isn'"'"'t a bundle id like com.example.passthrough.\n' "$id" >&2; exit 1; }
  printf '%s' "$id"
}

team_id() { xc_value "$SIGNING" DEVELOPMENT_TEAM; }

# The teams of the code-signing certificates in the keychain, one "TEAMID  Org"
# a line. The "(XXXXXXXXXX)" in an identity's name is the person's ID, not the
# team's; the team is the certificate's OU.
signing_teams() {
  local hashes tmp f subject ou org
  hashes="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development|"Apple Distribution/ {print $2}' | tr '\n' ' ')"
  [ -n "$hashes" ] || return 0
  tmp="$(mktemp -d)"
  # One PEM file for each of those identities' certificates (matched by SHA-1).
  security find-certificate -a -Z -p 2>/dev/null | awk -v want="$hashes" -v dir="$tmp" '
    BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) keep[w[i]] = 1 }
    /^SHA-1 hash:/ { take = ($3 in keep); count++; next }
    /BEGIN CERTIFICATE/ { if (take) { file = dir "/" count ".pem"; writing = 1 } }
    writing { print > file }
    /END CERTIFICATE/ { if (writing) { close(file); writing = 0 } }'
  for f in "$tmp"/*.pem; do
    [ -f "$f" ] || continue
    subject="$(openssl x509 -in "$f" -noout -subject 2>/dev/null)"
    ou="$(printf '%s' "$subject" | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p')"
    org="$(printf '%s' "$subject" | sed -n 's/.*[,/] *O=\([^,/]*\).*/\1/p')"
    if [ -n "$ou" ]; then printf '%s  %s\n' "$ou" "$org"; fi
  done | sort -u
  rm -rf "$tmp"
}

# Remote Desktop engine (Vendor/FreeRDP/FreeRDP.xcframework, untracked).
ENGINE="$PT_ROOT/Vendor/FreeRDP/FreeRDP.xcframework"
ENGINE_LOCK="$PT_ROOT/Vendor/FreeRDP/SOURCES.lock"
# The build script's SHA-256 when this script last built the engine.
ENGINE_STAMP="$PT_ROOT/build/freerdp-script.sha256"

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

# engine_state: missing, current, stale or unknown (no SOURCES.lock).
# Stale is decided by content, not mtimes (a checkout or merge touches files
# without changing them): SOURCES.lock, which build-freerdp.sh writes, names
# the FreeRDP and OpenSSL versions and the SHA-256 of every patch and shim
# source it built from, so any of those differing from the tree means a
# rebuild. A change to the script's own options is caught by ENGINE_STAMP,
# which exists only once this script has built the engine.
engine_state() {
  if [ ! -f "$ENGINE/Info.plist" ]; then echo missing; return; fi
  if [ ! -f "$ENGINE_LOCK" ]; then echo unknown; return; fi
  local script="$PT_ROOT/scripts/build-freerdp.sh" v p f listed=0 present=0
  v="$(sed -n 's/^FREERDP_VERSION=//p' "$script")"
  grep -q "^freerdp $v " "$ENGINE_LOCK" || { echo stale; return; }
  v="$(sed -n 's/^OPENSSL_VERSION=//p' "$script")"
  grep -qx "openssl $v" "$ENGINE_LOCK" || { echo stale; return; }
  for p in "$PT_ROOT"/Vendor/FreeRDP/patches/*.patch; do
    [ -e "$p" ] || continue
    present=$((present + 1))
    grep -qx "patch $(basename "$p") sha256 $(sha256 "$p")" "$ENGINE_LOCK" || { echo stale; return; }
  done
  listed="$(grep -c '^patch ' "$ENGINE_LOCK" || true)"
  [ "$listed" = "$present" ] || { echo stale; return; }
  for f in pt_rdp.c pt_bridge.c; do
    grep -qx "shim $f sha256 $(sha256 "$PT_ROOT/Vendor/FreeRDP/shim/$f")" "$ENGINE_LOCK" || { echo stale; return; }
  done
  if [ -f "$ENGINE_STAMP" ] && [ "$(cat "$ENGINE_STAMP")" != "$(sha256 "$script")" ]; then echo stale; return; fi
  echo current
}

engine_stamp() {
  [ "$DRY_RUN" = 1 ] && return 0
  mkdir -p "$PT_ROOT/build"
  sha256 "$PT_ROOT/scripts/build-freerdp.sh" > "$ENGINE_STAMP"
}

build_engine() {
  local missing="" t
  for t in cmake ninja; do have "$t" || missing="$missing $t"; done
  if [ -n "$missing" ]; then
    die "The Remote Desktop engine needs$missing: brew install$missing (or run deps), or pass --no-engine."
  fi
  step "Building the Remote Desktop engine (FreeRDP + OpenSSL; takes a while)"
  run bash "$PT_ROOT/scripts/build-freerdp.sh"
  engine_stamp
}

# git_pull: --pull for update. Untracked files (the engine) don't count as dirty.
git_pull() {
  step "Pulling"
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    git status --short --untracked-files=no | sed 's/^/    /'
    if [ "$DRY_RUN" = 1 ]; then warn "The working tree has changes: without --dry-run this would stop here."
    else die "The working tree has changes; commit or stash them first (git pull --ff-only won't run on a dirty tree)."; fi
  fi
  run git pull --ff-only
}

# xcodegen_generate: the .xcodeproj is generated and gitignored.
xcodegen_generate() {
  have xcodegen || die "xcodegen is missing: brew install xcodegen (or run ./passthrough mac deps)."
  run xcodegen generate --quiet
}

require_signing() {
  [ -f "$SIGNING" ] || die "Config/Signing.xcconfig is missing. Run ./passthrough mac deps (it copies the example), then set DEVELOPMENT_TEAM."
  [ -n "$(team_id)" ] || die "DEVELOPMENT_TEAM is empty in Config/Signing.xcconfig. Set it to your Team ID (./passthrough mac deps lists the teams in your keychain)."
}

# xcode_build <log name> <xcodebuild args…>: quiet build, full log in build/logs.
xcode_build() {
  local name="$1"; shift
  local log="$PT_ROOT/build/logs/$name.log"
  if [ "$DRY_RUN" = 1 ]; then run xcodebuild "$@"; return 0; fi
  mkdir -p "$PT_ROOT/build/logs"
  printf '  %s$ xcodebuild%s%s\n' "$C_DIM" "$(shell_words "$@")" "$C_0"
  info "full log: build/logs/$name.log"
  if ! xcodebuild "$@" > "$log" 2>&1; then
    grep -E 'error:|\*\* BUILD FAILED|Signing|provisioning' "$log" | sort -u | tail -25 >&2 || true
    die "The build failed; see build/logs/$name.log."
  fi
}

# check_phone_route: replacing or deleting a phone's app stops what serves the
# Mac (the iPhone's tunnel extension, Android's foreground service), which cuts
# this Mac's internet when it's online through that phone. Uses FORCE.
check_phone_route() {
  local iface; iface="$( { /sbin/route -n get default 2>/dev/null || true; } | awk '/interface:/ {print $2}')"
  case "$iface" in
    utun*)
      if [ "$FORCE" = 1 ]; then warn "This Mac is online through a tunnel ($iface); going ahead (--force)."
      elif [ "$DRY_RUN" = 1 ]; then warn "This Mac is online through a tunnel ($iface): without --dry-run this would stop here."
      else die "This Mac's default route is $iface: it may be online through this phone, and replacing the app stops its tunnel. Turn Internet through the phone off in the Mac's menu bar first, or pass --force."; fi ;;
    *) ok "This Mac isn't online through a tunnel (default route ${iface:-none})." ;;
  esac
}
