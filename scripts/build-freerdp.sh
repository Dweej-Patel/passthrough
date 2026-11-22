#!/bin/bash
# Builds the Remote Desktop engine the iPhone and iPad (and later the Mac's
# helper) use to show a PC's screen:
#   Vendor/FreeRDP/FreeRDP.xcframework  ios-arm64, ios-arm64-simulator, macos-arm64
# Each slice is one static library, libfreerdp-vendor.a: FreeRDP 3 (client
# library, WinPR, the four channels Passthrough uses), OpenSSL 3 (the LTS
# line), and Passthrough's shim (Vendor/FreeRDP/shim), whose header is the
# only thing the module "FreeRDP" exports.
#
# Sources are pinned by version and archive SHA-256 (no clone of a moving
# branch); Vendor/FreeRDP/patches are applied on top. Hardened per
# docs/plans/windows-remote/stage-6-ios-rdp.md: NLA only (in the shim's
# settings), channels compiled in and nothing loaded from a file (patch 0001),
# no drive, printer, smartcard, serial, USB, sound, RemoteApp or other channel,
# no RemoteFX, NSCodec or legacy caches (shim), no FFmpeg, OpenH264, JSON,
# Kerberos, AAD, PKCS#11 or zlib. H.264 decodes through Apple's VideoToolbox.
#
# Needs: Xcode, cmake (3.24 or later), ninja, perl (brew install cmake ninja).
# Writes the xcframework, Vendor/FreeRDP/SOURCES.lock and SIZE.md; sources and
# build trees go to the gitignored Vendor/freerdp-src.
set -euo pipefail

FREERDP_VERSION=3.33.1
FREERDP_COMMIT=65bcca1913a28cbdd7eb913599f692bd2b707991
FREERDP_URL="https://pub.freerdp.com/releases/freerdp-$FREERDP_VERSION.tar.gz"
FREERDP_SHA256=4431bbf04d370545cfe2924b9d9f116b95c90c64ff156b2550bbaf82d34e7124

OPENSSL_VERSION=3.5.9
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a

IOS_MIN=17.5
MAC_MIN=14.5

# The channels compiled in, and every other folder under channels/ at the tag,
# switched off. A folder in neither list stops the script: a channel added
# upstream can't slip in.
CHANNELS_ON="cliprdr disp drdynvc rdpgfx"
CHANNELS_OFF="ainput audin drive echo encomsp geometry gfxredir location parallel printer rail rdp2tcp rdpdr rdpear rdpecam rdpei rdpemsc rdpewa rdpsnd remdesk serial smartcard sshagent telemetry tsmf urbdrc video"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/FreeRDP"
WORK="$ROOT/Vendor/freerdp-src"
JOBS="$(sysctl -n hw.ncpu)"

need() { command -v "$1" >/dev/null 2>&1 || { echo "build-freerdp: needs $1" >&2; exit 1; }; }
for tool in xcodebuild xcrun cmake ninja perl shasum libtool nm curl tar patch; do need "$tool"; done
CMAKE_VERSION="$(cmake --version | head -1 | awk '{print $3}')"
CMAKE_MAJOR="${CMAKE_VERSION%%.*}"; CMAKE_MINOR="${CMAKE_VERSION#*.}"; CMAKE_MINOR="${CMAKE_MINOR%%.*}"
if [ "$CMAKE_MAJOR" -lt 3 ] || { [ "$CMAKE_MAJOR" -eq 3 ] && [ "$CMAKE_MINOR" -lt 24 ]; }; then
  echo "build-freerdp: cmake 3.24 or later is needed (found $CMAKE_VERSION)" >&2
  exit 1
fi
XCODE_VERSION="$(xcodebuild -version | tr '\n' ' ')"
echo "== $XCODE_VERSION; cmake $CMAKE_VERSION; ninja $(ninja --version)"

upper() { echo "$1" | tr '[:lower:]' '[:upper:]'; }

# fetch <url> <file> <sha256>
fetch() {
  if [ ! -f "$2" ]; then
    echo "== fetching $1"
    curl -fsSL --retry 3 -o "$2.part" "$1"
    mv "$2.part" "$2"
  fi
  local got
  got="$(shasum -a 256 "$2" | awk '{print $1}')"
  if [ "$got" != "$3" ]; then
    echo "build-freerdp: $2 has SHA-256 $got, expected $3" >&2
    rm -f "$2"
    exit 1
  fi
}

mkdir -p "$WORK"
fetch "$FREERDP_URL" "$WORK/freerdp-$FREERDP_VERSION.tar.gz" "$FREERDP_SHA256"
fetch "$OPENSSL_URL" "$WORK/openssl-$OPENSSL_VERSION.tar.gz" "$OPENSSL_SHA256"

FREERDP_SRC="$WORK/freerdp-$FREERDP_VERSION"
OPENSSL_SRC="$WORK/openssl-$OPENSSL_VERSION"
BUILD="$WORK/build"
rm -rf "$FREERDP_SRC" "$OPENSSL_SRC" "$BUILD"
tar -xzf "$WORK/freerdp-$FREERDP_VERSION.tar.gz" -C "$WORK"
tar -xzf "$WORK/openssl-$OPENSSL_VERSION.tar.gz" -C "$WORK"
mkdir -p "$BUILD/no-pkgconfig"

echo "== patches"
for p in "$VENDOR"/patches/*.patch; do
  [ -e "$p" ] || continue
  echo "   $(basename "$p")"
  (cd "$FREERDP_SRC" && patch -p1 -N -s < "$p") || { echo "build-freerdp: $p does not apply" >&2; exit 1; }
done

echo "== channels"
CHANNEL_FLAGS=()
for dir in "$FREERDP_SRC"/channels/*/; do
  name="$(basename "$dir")"
  case "$name" in client | server) continue ;; esac
  if [[ " $CHANNELS_ON " == *" $name "* ]]; then
    CHANNEL_FLAGS+=("-DCHANNEL_$(upper "$name")=ON")
  elif [[ " $CHANNELS_OFF " == *" $name "* ]]; then
    CHANNEL_FLAGS+=("-DCHANNEL_$(upper "$name")=OFF")
  else
    echo "build-freerdp: channels/$name is new upstream; add it to CHANNELS_ON or CHANNELS_OFF" >&2
    exit 1
  fi
done
for name in $CHANNELS_ON; do
  [ -d "$FREERDP_SRC/channels/$name" ] || { echo "build-freerdp: channels/$name is gone upstream" >&2; exit 1; }
done
echo "   on: $CHANNELS_ON"

OPENSSL_OPTIONS=(no-shared no-tests no-apps no-docs no-engine no-dso no-module no-legacy no-ui-console no-comp
  no-ssl3 no-dtls no-srp no-psk no-sm2 no-sm3 no-sm4 no-idea no-seed no-camellia no-aria no-bf no-cast
  no-whirlpool no-rmd160 no-mdc2 no-ocb no-siv no-cms no-ts no-ct no-ocsp)

FREERDP_OPTIONS=(
  -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_SHARED_LIBS=OFF -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF
  -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT=OFF -DWITH_CLIENT_SDL=OFF -DWITH_SERVER=OFF -DWITH_SAMPLE=OFF
  -DWITH_PROXY=OFF -DWITH_SHADOW=OFF -DWITH_PLATFORM_SERVER=OFF
  -DWITH_CHANNELS=ON -DWITH_CLIENT_CHANNELS=ON -DWITH_SERVER_CHANNELS=OFF
  -DWITH_MANPAGES=OFF -DWITH_WINPR_TOOLS=OFF -DBUILD_TESTING=OFF
  -DWITH_APPLE_VIDEOTOOLBOX=ON -DWITH_FFMPEG=OFF -DWITH_VIDEO_FFMPEG=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_SWSCALE=OFF
  -DWITH_CAIRO=OFF -DWITH_OPENH264=OFF -DWITH_JPEG=OFF -DWITH_OPUS=OFF -DWITH_FDK_AAC=OFF -DWITH_GFX_AV1=OFF
  -DWITH_RDPEUDP=OFF -DWITH_OPENCL=OFF -DWITH_AAD=OFF -DWITH_KRB5=OFF -DWITH_PKCS11=OFF
  -DWITH_SMARTCARD_EMULATE=OFF -DWITH_PCSC=OFF -DWITH_FUSE=OFF -DWITH_CLIPRDR_FILE_APPLE=OFF -DWITH_MACAUDIO=OFF
  -DWITH_THIRD_PARTY=OFF -DWITH_CCACHE=OFF -DWITH_JSON_DISABLED=ON -DWITH_URIPARSER=OFF -DWITH_LODEPNG=OFF
  -DWITH_TIMEZONE_ICU=OFF -DWITH_SSO_MIB=OFF
  -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_MD5=ON -DWITH_INTERNAL_RC4=ON
  -DWITH_VERBOSE_WINPR_ASSERT=OFF -DWITH_DEBUG_ALL=OFF -DWITHOUT_FREERDP_3x_DEPRECATED=ON
  "${CHANNEL_FLAGS[@]}"
)

# Symbols that would mean a channel or loader that must not be there.
FORBIDDEN_ENTRY='_(ainput|audin|drive|echo|encomsp|geometry|gfxredir|location|parallel|printer|rail|rdp2tcp|rdpdr|rdpear|rdpecam|rdpei|rdpemsc|rdpewa|rdpsnd|remdesk|serial|smartcard|sshagent|telemetry|tsmf|urbdrc|video)_(VirtualChannelEntry|VirtualChannelEntryEx|DVCPluginEntry|DeviceServiceEntry)$'

# build_slice <name> <sdk> <openssl target> <min-version flag>
build_slice() {
  local name="$1" sdk="$2" ossl_target="$3" min_flag="$4"
  local dir="$BUILD/$name"
  echo "== $name: OpenSSL $OPENSSL_VERSION"
  mkdir -p "$dir"
  cp -R "$OPENSSL_SRC" "$dir/openssl"
  (
    cd "$dir/openssl"
    ./Configure "$ossl_target" "${OPENSSL_OPTIONS[@]}" "$min_flag" -Os --prefix="$dir/ossl" --libdir=lib >"$dir/openssl-configure.log"
    make -j"$JOBS" build_libs >"$dir/openssl-build.log"
    make install_dev >"$dir/openssl-install.log"
  )

  echo "== $name: FreeRDP $FREERDP_VERSION"
  local platform_flags=()
  case "$sdk" in
    iphoneos) platform_flags=(-DCMAKE_TOOLCHAIN_FILE="$FREERDP_SRC/cmake/ios.toolchain.cmake" -DPLATFORM=OS64 -DDEPLOYMENT_TARGET="$IOS_MIN") ;;
    iphonesimulator) platform_flags=(-DCMAKE_TOOLCHAIN_FILE="$FREERDP_SRC/cmake/ios.toolchain.cmake" -DPLATFORM=SIMULATORARM64 -DDEPLOYMENT_TARGET="$IOS_MIN") ;;
    macosx) platform_flags=(-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MAC_MIN") ;;
  esac
  # Nothing from Homebrew or pkg-config may be found: everything is in this build or the SDK.
  PKG_CONFIG_LIBDIR="$BUILD/no-pkgconfig" PKG_CONFIG_PATH="" cmake -S "$FREERDP_SRC" -B "$dir/freerdp" -G Ninja \
    "${platform_flags[@]}" \
    -DCMAKE_INSTALL_PREFIX="$dir/out" \
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
    -DOPENSSL_ROOT_DIR="$dir/ossl" -DOPENSSL_USE_STATIC_LIBS=ON -DCMAKE_FIND_ROOT_PATH="$dir/ossl" \
    "${FREERDP_OPTIONS[@]}" >"$dir/freerdp-configure.log"
  cmake --build "$dir/freerdp" -j "$JOBS" >"$dir/freerdp-build.log"
  cmake --install "$dir/freerdp" >"$dir/freerdp-install.log"

  local lib="$dir/out/lib"
  for a in libfreerdp-client3.a libfreerdp3.a libwinpr3.a; do
    [ -f "$lib/$a" ] || { echo "build-freerdp: $name has no $a (built: $(ls "$lib"))" >&2; exit 1; }
  done

  # The VideoToolbox H.264 decoder is in; the add-in loader opens nothing.
  local vt=0
  if nm -g "$lib/libfreerdp3.a" 2>/dev/null | grep -E ' [DST] _g_Subsystem_VideoToolbox$' >/dev/null; then vt=1; fi
  [ "$vt" = 1 ] || { echo "build-freerdp: $name has no VideoToolbox H.264 decoder" >&2; exit 1; }
  if nm -A "$lib/libfreerdp3.a" 2>/dev/null | grep -E 'addin\.c\.o:? .* U _(LoadLibrary[AWX]?|dlopen)$'; then
    echo "build-freerdp: $name: the add-in loader still opens libraries" >&2
    exit 1
  fi

  echo "== $name: shim"
  local includes=(-I"$dir/out/include/freerdp3" -I"$dir/out/include/winpr3" -I"$dir/ossl/include" -I"$VENDOR/shim/include")
  mkdir -p "$dir/shim"
  for c in pt_rdp pt_bridge; do
    xcrun --sdk "$sdk" clang -arch arm64 "$min_flag" -Os -std=c11 -DPT_HAS_VIDEOTOOLBOX=1 \
      -Wall -Wextra -Wno-unused-parameter -Werror=implicit-function-declaration -Werror=incompatible-pointer-types \
      "${includes[@]}" -c "$VENDOR/shim/$c.c" -o "$dir/shim/$c.o"
  done
  # Everything of the shim's own is static; only pt_rdp.h's functions are global.
  libtool -static -o "$dir/shim/libpt_rdp.a" "$dir/shim/pt_rdp.o" "$dir/shim/pt_bridge.o"

  mkdir -p "$dir/vendor"
  libtool -static -o "$dir/vendor/libfreerdp-vendor.a" "$dir/shim/libpt_rdp.a" \
    "$lib/libfreerdp-client3.a" "$lib/libfreerdp3.a" "$lib/libwinpr3.a" "$dir/ossl/lib/libssl.a" "$dir/ossl/lib/libcrypto.a" 2>"$dir/libtool.log"
  strip -S "$dir/vendor/libfreerdp-vendor.a"

  if nm -g "$dir/vendor/libfreerdp-vendor.a" 2>/dev/null | awk '$2 ~ /^[DST]$/ {print $3}' | grep -E "$FORBIDDEN_ENTRY"; then
    echo "build-freerdp: $name has a channel that must not be there" >&2
    exit 1
  fi
  for symbol in _pt_rdp_new _pt_rdp_run _pt_rdp_feed _pt_rdp_take; do
    # grep reads everything (no -q): with pipefail, nm cut off early would fail the check.
    nm -g "$dir/vendor/libfreerdp-vendor.a" | grep -E " T $symbol\$" >/dev/null || { echo "build-freerdp: $name lacks $symbol" >&2; exit 1; }
  done
  nm -g "$dir/vendor/libfreerdp-vendor.a" | awk '$2 ~ /^[DST]$/ {print $3}' | sort -u >"$dir/vendor/exports.txt"
}

build_slice ios iphoneos ios64-xcrun "-miphoneos-version-min=$IOS_MIN"
build_slice ios-simulator iphonesimulator iossimulator-arm64-xcrun "-mios-simulator-version-min=$IOS_MIN"
build_slice macos macosx darwin64-arm64 "-mmacosx-version-min=$MAC_MIN"

echo "== xcframework"
HEADERS="$BUILD/headers"
mkdir -p "$HEADERS/FreeRDP"
cp "$VENDOR/shim/include/pt_rdp.h" "$VENDOR/shim/module.modulemap" "$HEADERS/FreeRDP/"
rm -rf "$VENDOR/FreeRDP.xcframework"
xcodebuild -create-xcframework \
  -library "$BUILD/ios/vendor/libfreerdp-vendor.a" -headers "$HEADERS" \
  -library "$BUILD/ios-simulator/vendor/libfreerdp-vendor.a" -headers "$HEADERS" \
  -library "$BUILD/macos/vendor/libfreerdp-vendor.a" -headers "$HEADERS" \
  -output "$VENDOR/FreeRDP.xcframework" >/dev/null

size() { stat -f %z "$1"; }
{
  echo "# What Vendor/FreeRDP/FreeRDP.xcframework was built from (scripts/build-freerdp.sh)."
  echo "freerdp $FREERDP_VERSION commit $FREERDP_COMMIT"
  echo "freerdp-archive $FREERDP_URL sha256 $FREERDP_SHA256"
  echo "openssl $OPENSSL_VERSION"
  echo "openssl-archive $OPENSSL_URL sha256 $OPENSSL_SHA256"
  for p in "$VENDOR"/patches/*.patch; do [ -e "$p" ] && echo "patch $(basename "$p") sha256 $(shasum -a 256 "$p" | awk '{print $1}')"; done
  echo "shim pt_rdp.c sha256 $(shasum -a 256 "$VENDOR/shim/pt_rdp.c" | awk '{print $1}')"
  echo "shim pt_bridge.c sha256 $(shasum -a 256 "$VENDOR/shim/pt_bridge.c" | awk '{print $1}')"
  echo "xcode $XCODE_VERSION"
  echo "cmake $CMAKE_VERSION"
  echo "minimums ios $IOS_MIN macos $MAC_MIN"
  echo "openssl-options ${OPENSSL_OPTIONS[*]}"
  echo "freerdp-options ${FREERDP_OPTIONS[*]}"
} >"$VENDOR/SOURCES.lock"

{
  echo "# Library sizes (bytes), per slice, as built by scripts/build-freerdp.sh"
  echo
  echo "| Slice | libfreerdp-vendor.a |"
  echo "|---|---|"
  for s in ios ios-simulator macos; do echo "| $s | $(size "$BUILD/$s/vendor/libfreerdp-vendor.a") |"; done
  echo
  echo "The app's own growth is measured separately (an unsigned Release build, zipped, before and after)."
} >"$VENDOR/SIZE.md"

for s in ios ios-simulator macos; do
  cp "$BUILD/$s/vendor/exports.txt" "$VENDOR/exports-$s.txt"
  echo "   $s: $(size "$BUILD/$s/vendor/libfreerdp-vendor.a") bytes"
done
echo "built Vendor/FreeRDP/FreeRDP.xcframework"
