# Contributing to Passthrough

Thanks for your interest. This is a small project with one maintainer, so the
process is deliberately light.

## Ground rules

* `main` and `dev` are protected. Contributors cannot push to them directly;
  all changes land through pull requests reviewed by the maintainer.
* Open pull requests against **`dev`**. `main` only receives merges from `dev`
  when a release is cut.
* Keep pull requests focused. One fix or one feature per PR is much easier to
  review than a grab-bag.
* For anything larger than a bug fix, open an issue first so we can agree on
  the approach before you spend time on it.

## Setting up

You need Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and an
Apple Developer account (the Network Extension and keychain entitlements need
a real Team ID).

```
brew install xcodegen
cp Config/Signing.xcconfig.example Config/Signing.xcconfig   # then set DEVELOPMENT_TEAM
xcodegen generate
open Passthrough.xcodeproj
```

The Mac and iPhone apps use SwiftTerm, which compiles a Metal shader. Newer Xcodes ship the Metal Toolchain separately, so install it once with `xcodebuild -downloadComponent MetalToolchain` (CI does this).

The apps need iOS 17.5 and macOS 14.5 or later (iroh-ffi's floors), and the Mac app builds for Apple Silicon only (arm64), like its helper, because iroh-ffi's prebuilt library has no Intel slice. The built-in connection (iroh) adds noticeable size: the iOS zip went from about 2.8 MB to 8.9 MB (+6.1 MB), the Mac zip from about 10.2 MB to 14.2 MB (+4.0 MB) and the Android release APK from about 2.7 MB to 26.9 MB (+24.2 MB), so mind new dependencies.

The app's Swift package versions (SwiftTerm, iroh-ffi and their dependencies) are pinned
in `Config/Package.resolved`; `xcodegen generate` copies it into the project,
and CI builds with `-onlyUsePackageVersionsFromResolvedFile`, so a dependency
cannot change underneath a build. To move to a new version, change it in
`project.yml`, regenerate, resolve in Xcode (File > Packages > Update to
Latest Package Versions, or `xcodebuild -resolvePackageDependencies`), and
copy `Passthrough.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
back to `Config/Package.resolved` in the same PR. `Packages/PassthroughCore` also
depends on iroh-ffi and has its own `Package.resolved`; if you change that pin,
run `swift package resolve` there and commit both files.

`Config/Signing.xcconfig` and the generated `.xcodeproj` are gitignored. Never
commit your Team ID, provisioning profiles or device identifiers.

The protocol core has no Apple-framework dependencies beyond Foundation and
Network, so it can be tested from the command line:

```
cd Packages/PassthroughCore
swift test
```

If `swift test` hangs on the Keychain from a terminal, use `swift test --disable-keychain`.

Please run the tests before opening a PR, and add tests for anything in
`PassthroughCore` that you change.

The Android app lives in `android/` and needs JDK 25 and the Android SDK
(see [android/README.md](android/README.md)):

```
cd android
./gradlew testDebugUnitTest lintDebug assembleDebug
```

The Swift and Kotlin sides speak the same wire protocol, described in
[protocol/README.md](protocol/README.md). Both test suites check themselves
against `protocol/fixtures.json`: if you change a message, a port or the
pairing rules, update the fixtures first, then make both suites pass.

## Things to keep in mind

* **Security posture matters here.** The Mac helper runs as root and the phone
  app terminates every connection the Mac makes. Read the *Security model* section of
  [docs/GUIDE.md](docs/GUIDE.md#security-model) before touching pairing, the SOCKS5 server, the OpenVPN profile
  sanitiser or the helper's XPC surface. Changes that widen what the helper
  will execute, or what a profile can contain, will get extra scrutiny.
* **Vendored binaries.** `Vendor/HevSocks5Tunnel` and `Vendor/VPNEngines` are
  prebuilt. If you need to change them, change the build script
  (`scripts/build-hev.sh`, `scripts/build-vpn-engines.sh`) and say in the PR
  which upstream commit you built from.
* **No secrets, ever.** Do not commit API keys, VPN credentials, `.ovpn` files
  with embedded keys, screenshots with your device name, or anything from your
  keychain. The repository is scanned, but please do not make us rely on that.

## Pull request checklist

* [ ] Branch is based on `dev`
* [ ] `swift test` passes in `Packages/PassthroughCore`
* [ ] `./gradlew testDebugUnitTest lintDebug` passes in `android/` (if you touched it)
* [ ] Both apps build (`xcodegen generate`, then build the `Passthrough` and
      `PassthroughMac` schemes)
* [ ] README and docs/GUIDE.md updated if behaviour or setup changed
* [ ] No personal identifiers or credentials in the diff

## Reporting security issues

Please do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).

## Licence

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE) that covers the project.
