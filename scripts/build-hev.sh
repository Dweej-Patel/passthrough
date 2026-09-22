#!/bin/bash
# Rebuilds the vendored tun2socks engine (hev-socks5-tunnel + lwIP) as a static
# library for Apple Silicon macOS. Run after updating Vendor/hev-socks5-tunnel.
set -euo pipefail
VENDOR="$(dirname "$0")/../Vendor/hev-socks5-tunnel"
if [ ! -d "$VENDOR" ]; then
  echo "Fetching hev-socks5-tunnel source..."
  git clone --depth 1 --recursive https://github.com/heiher/hev-socks5-tunnel.git "$VENDOR"
fi
cd "$VENDOR"
git submodule update --init --recursive 2>/dev/null || true
make clean >/dev/null 2>&1 || true
make PP="xcrun --sdk macosx clang" CC="xcrun --sdk macosx clang" \
     CFLAGS="-arch arm64 -mmacosx-version-min=14.0" \
     LFLAGS="-arch arm64 -mmacosx-version-min=14.0 -Wl,-Bsymbolic-functions" static -j"$(sysctl -n hw.ncpu)"
mkdir -p ../HevSocks5Tunnel/lib ../HevSocks5Tunnel/include
libtool -static -o ../HevSocks5Tunnel/lib/libhev-socks5-tunnel.a \
    bin/libhev-socks5-tunnel.a third-part/lwip/bin/liblwip.a \
    third-part/yaml/bin/libyaml.a third-part/hev-task-system/bin/libhev-task-system.a 2>/dev/null
cp src/hev-main.h module.modulemap ../HevSocks5Tunnel/include/
echo "built Vendor/HevSocks5Tunnel/lib/libhev-socks5-tunnel.a"
