#!/bin/bash
# Rebuilds the vendored tun2socks engine (hev-socks5-tunnel + lwIP):
#  - lib/libhev-socks5-tunnel.a: Apple Silicon macOS, for the Mac's root helper;
#  - HevSocks5Tunnel.xcframework: iOS (device and Apple Silicon simulator), for
#    the iPad's tunnel extension (the simulator slice only lets the app build
#    for the simulator; packet tunnels don't run there).
# Run after updating Vendor/hev-socks5-tunnel.
set -euo pipefail
VENDOR="$(dirname "$0")/../Vendor/hev-socks5-tunnel"
if [ ! -d "$VENDOR" ]; then
  echo "Fetching hev-socks5-tunnel source..."
  git clone --depth 1 --recursive https://github.com/heiher/hev-socks5-tunnel.git "$VENDOR"
fi
cd "$VENDOR"
git submodule update --init --recursive 2>/dev/null || true
# Local fixes (see each patch's header); skipped when already applied.
for p in ../HevSocks5Tunnel/patches/*.patch; do
  if patch -p1 -R --dry-run -s -f < "$p" >/dev/null 2>&1; then continue; fi
  patch -p1 -N -s < "$p" || { echo "failed to apply $p" >&2; exit 1; }
done

OUT=../HevSocks5Tunnel
SLICES="$(mktemp -d)"
trap 'rm -rf "$SLICES"' EXIT

# build <sdk> <min-version flag> <output .a>
build() {
  make clean >/dev/null 2>&1 || true
  make PP="xcrun --sdk $1 clang" CC="xcrun --sdk $1 clang" \
       CFLAGS="-arch arm64 $2" \
       LFLAGS="-arch arm64 $2 -Wl,-Bsymbolic-functions" static -j"$(sysctl -n hw.ncpu)"
  mkdir -p "$(dirname "$3")"
  libtool -static -o "$3" \
      bin/libhev-socks5-tunnel.a third-part/lwip/bin/liblwip.a \
      third-part/yaml/bin/libyaml.a third-part/hev-task-system/bin/libhev-task-system.a 2>/dev/null
}

build macosx "-mmacosx-version-min=14.0" "$OUT/lib/libhev-socks5-tunnel.a"
build iphoneos "-miphoneos-version-min=17.5" "$SLICES/ios/libhev-socks5-tunnel.a"
build iphonesimulator "-mios-simulator-version-min=17.5" "$SLICES/ios-simulator/libhev-socks5-tunnel.a"
make clean >/dev/null 2>&1 || true

mkdir -p "$OUT/include"
cp src/hev-main.h module.modulemap "$OUT/include/"
rm -rf "$OUT/HevSocks5Tunnel.xcframework"
xcodebuild -create-xcframework \
    -library "$SLICES/ios/libhev-socks5-tunnel.a" \
    -library "$SLICES/ios-simulator/libhev-socks5-tunnel.a" \
    -output "$OUT/HevSocks5Tunnel.xcframework" >/dev/null
echo "built $OUT/lib/libhev-socks5-tunnel.a and $OUT/HevSocks5Tunnel.xcframework"
