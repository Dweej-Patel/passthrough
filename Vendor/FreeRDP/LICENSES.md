# Licences for the Remote Desktop engine

`FreeRDP.xcframework` (iOS device, iOS simulator and Apple Silicon macOS) is one
static library per slice, `libfreerdp-vendor.a`, built by
`scripts/build-freerdp.sh` from the archives pinned in `SOURCES.lock`, with the
patches in `patches/`:

| Component | Upstream | Licence |
|---|---|---|
| FreeRDP (libfreerdp, libfreerdp-client, the cliprdr, disp, drdynvc and rdpgfx channels) | https://github.com/FreeRDP/FreeRDP | Apache-2.0 |
| WinPR (part of FreeRDP) | https://github.com/FreeRDP/FreeRDP | Apache-2.0 |
| OpenSSL 3.5 (libssl, libcrypto) | https://github.com/openssl/openssl | Apache-2.0 |
| Passthrough's shim (`shim/`) | this repository | the repository's licence |

The Apache License 2.0 text is in each upstream archive (`LICENSE` in FreeRDP,
`LICENSE.txt` in OpenSSL) and at https://www.apache.org/licenses/LICENSE-2.0.
FreeRDP's copyright and attribution notices are in its archive's `LICENSE`,
`README.md` and source file headers; OpenSSL's in its `LICENSE.txt` and
`NOTICE` where present. `patches/0001-no-dynamic-addins.patch` is a
modification of FreeRDP's `libfreerdp/common/addin.c`, marked as such in its
header.
