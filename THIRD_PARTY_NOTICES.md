# Third-party notices

Third-party components distributed with this repository keep their own licences:

* Vendor/HevSocks5Tunnel — hev-socks5-tunnel (MIT), lwIP (BSD-3-Clause),
  hev-task-system (MIT), libyaml (MIT). See Vendor/HevSocks5Tunnel/LICENSES.md.
* Vendor/VPNEngines/bin/wireguard-go — MIT. See Vendor/VPNEngines/licenses/WIREGUARD-GO-LICENSE.
* Vendor/VPNEngines/bin/openvpn — GPL-2.0 with the OpenSSL linking exception.
  See Vendor/VPNEngines/licenses/OPENVPN-COPYING. Source is fetched and rebuilt by
  scripts/build-vpn-engines.sh.
* SwiftTerm (https://github.com/migueldeicaza/SwiftTerm), 1.18.0 — MIT. Fetched by
  Swift Package Manager (project.yml) and linked into the Mac and iPhone apps. See its LICENSE.
* iroh-ffi (https://github.com/n0-computer/iroh-ffi), 1.1.0 — MIT OR Apache-2.0 (used here
  under MIT). Its prebuilt, checksum-pinned IrohLib.xcframework statically links iroh and its
  Rust dependencies (MIT and/or Apache-2.0 licensed crates). Fetched by Swift Package Manager
  (Packages/PassthroughCore) and linked into the Mac and iPhone apps, not the tunnel extension.
  See its LICENSE-MIT and LICENSE-APACHE.
  On Android, computer.iroh:iroh-android 1.1.0 (same project and licences; Maven Central,
  pinned in android/gradle/verification-metadata.xml) ships the same library as
  libiroh_ffi.so for arm64-v8a and armeabi-v7a (plus x86_64 in debug builds), and brings JNA 5.15.0
  (https://github.com/java-native-access/jna) — LGPL-2.1 OR Apache-2.0, used here under
  Apache-2.0 (android/licenses/APACHE-2.0.txt).
* android/app/src/main/res/font/nunito.ttf — Nunito, SIL Open Font License 1.1.
  See android/licenses/NUNITO-OFL.txt.
* Termux terminal-view and terminal-emulator (https://github.com/termux/termux-app),
  release v0.118.3, fetched from JitPack (com.github.termux.termux-app:terminal-view) and
  linked into the Android app — Apache-2.0 (derived from Terminal Emulator for Android).
  Only these two library modules are used; the Termux app itself is GPLv3 and is not used.
  Its process-spawning native library (libtermux.so) is excluded from the APK.
  See android/licenses/APACHE-2.0.txt and the exceptions in termux-app's LICENSE.md.
