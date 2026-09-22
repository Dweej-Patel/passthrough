#!/bin/bash
# Builds the two VPN engines the Mac helper bundles for the "VPN layer":
#   * wireguard-go  (MIT)    -> Vendor/VPNEngines/bin/wireguard-go
#   * openvpn 2.6   (GPLv2)  -> Vendor/VPNEngines/bin/openvpn  (static OpenSSL/LZO/LZ4)
# Both are standalone arm64 executables the root helper spawns as separate processes.
# Requires: Homebrew go, openssl@3, lzo, lz4 (brew install go openssl@3 lzo lz4).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Vendor/vpn-engines-src"
OUT="$ROOT/Vendor/VPNEngines/bin"
OPENVPN_VERSION="${OPENVPN_VERSION:-2.6.14}"
MINOS="-mmacosx-version-min=14.0"
BREW="$(brew --prefix)"
mkdir -p "$SRC" "$OUT"

echo "== wireguard-go"
if [ ! -d "$SRC/wireguard-go" ]; then
  git clone --depth 1 https://git.zx2c4.com/wireguard-go "$SRC/wireguard-go"
fi
( cd "$SRC/wireguard-go"
  CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 GOFLAGS=-mod=mod \
    go build -trimpath -ldflags "-s -w" -o "$OUT/wireguard-go" . )
echo "   -> $OUT/wireguard-go"

echo "== openvpn $OPENVPN_VERSION"
TARBALL="$SRC/openvpn-$OPENVPN_VERSION.tar.gz"
if [ ! -f "$TARBALL" ]; then
  curl -fsSL -o "$TARBALL" "https://swupdate.openvpn.org/community/releases/openvpn-$OPENVPN_VERSION.tar.gz"
fi
rm -rf "$SRC/openvpn-$OPENVPN_VERSION"
tar -xzf "$TARBALL" -C "$SRC"
( cd "$SRC/openvpn-$OPENVPN_VERSION"
  SSL="$BREW/opt/openssl@3"; LZO="$BREW/opt/lzo"; LZ4="$BREW/opt/lz4"
  # A directory holding only the static archives, so "-llzo2"/"-llz4" cannot
  # resolve to Homebrew dylibs and the result runs on any Mac.
  STATIC="$SRC/staticlibs"; rm -rf "$STATIC"; mkdir -p "$STATIC"
  ln -s "$LZO/lib/liblzo2.a" "$STATIC/liblzo2.a"
  ln -s "$LZ4/lib/liblz4.a" "$STATIC/liblz4.a"
  ./configure \
    --disable-debug --disable-plugins --disable-pkcs11 --disable-dco \
    CC="xcrun --sdk macosx clang" \
    CFLAGS="-arch arm64 $MINOS -O2" LDFLAGS="-arch arm64 $MINOS -L$STATIC" \
    OPENSSL_CFLAGS="-I$SSL/include" OPENSSL_LIBS="$SSL/lib/libssl.a $SSL/lib/libcrypto.a" \
    LZO_CFLAGS="-I$LZO/include" LZO_LIBS="-llzo2" \
    LZ4_CFLAGS="-I$LZ4/include" LZ4_LIBS="-llz4"
  make -j"$(sysctl -n hw.ncpu)" >/dev/null
  cp src/openvpn/openvpn "$OUT/openvpn"
  strip "$OUT/openvpn" )
echo "   -> $OUT/openvpn"
echo "== dynamic deps (should only be system libs):"
otool -L "$OUT/openvpn" | grep -v "^$OUT"
mkdir -p "$ROOT/Vendor/VPNEngines/licenses"
cp "$SRC/openvpn-$OPENVPN_VERSION/COPYING" "$ROOT/Vendor/VPNEngines/licenses/OPENVPN-COPYING"
cp "$SRC/wireguard-go/LICENSE" "$ROOT/Vendor/VPNEngines/licenses/WIREGUARD-GO-LICENSE"
echo "done"
