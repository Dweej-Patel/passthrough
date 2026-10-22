# Passthrough for Android

The phone side of Passthrough, for Android 8.0 and later (the remote shell, including its built-in iroh connection, needs Android 10). It serves the Mac over
USB exactly like the iPhone app: same SOCKS5 server (with the UDP-in-TCP
extension), same pairing codes and tokens, same control channel, same design.

## Layout

```
app/src/main/java/dev/dpatel/passthrough/
  core/      Pure Kotlin, no Android imports: SOCKS5 server, control channel,
             pairing registry, stats. Unit tested on the JVM.
  service/   Foreground service, cellular-only egress, device facts, usage, settings
  ui/        Jetpack Compose screens, theme, flow map, chart
app/src/test Protocol tests (handshake, auth, CONNECT, UDP framing, pairing, control, JSON)
```

## Build

Needs JDK 25 (Gradle 9.8.2 and AGP 9.4.1 build with it) and the Android SDK (platform 35). With Homebrew:

```
brew install openjdk@25
brew install --cask android-commandlinetools android-platform-tools
export JAVA_HOME=/opt/homebrew/opt/openjdk@25/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
sdkmanager "platforms;android-35" "build-tools;35.0.0"
```

Or open the `android/` folder in Android Studio.

```
./gradlew testDebugUnitTest lintDebug   # tests and lint
./gradlew installDebug                  # build and install on the attached phone
```

### Native libraries

The built-in remote-shell connection comes from `computer.iroh:iroh-android` (pinned in `app/build.gradle.kts` and `gradle/verification-metadata.xml`), which ships `libiroh_ffi.so`. Release builds include arm64-v8a and armeabi-v7a; debug builds add x86_64 for the emulator. The release APK is about 27 MB. The library is loaded lazily, and the app falls back to local-only shell connections if it cannot load. iroh-android 1.1.0's library is not 16 KB page-aligned, which Google Play requires for apps targeting Android 15+; CI reports this as a warning, and the fix is to move to 1.1.1 or later when it is verified.

### Dependency verification

`gradle/verification-metadata.xml` pins a SHA-256 for every artifact in the
build (including the Termux terminal libraries from JitPack, which are
published without signatures). Gradle fails the build if a download doesn't
match. After changing a dependency or plugin version, regenerate it and review
the diff before committing:

```
./gradlew --refresh-dependencies --write-verification-metadata sha256 \
  testDebugUnitTest lintDebug assembleDebug assembleRelease lintVitalRelease
```

`--refresh-dependencies` makes Gradle re-fetch (and so record) everything,
including plugin and build-script artifacts that are normally cached.

Release builds are minified and left unsigned. Sign them with your own key
(`apksigner`, or a `signingConfigs` block in `app/build.gradle.kts` that reads
from a keystore outside the repository). Keystores are gitignored.

## Using it

1. Turn on USB debugging (Settings ▸ About phone ▸ tap *Build number* seven
   times, then Settings ▸ System ▸ Developer options ▸ *USB debugging*).
2. Plug the phone into the Mac and allow the Mac's USB debugging key.
3. Open Passthrough, tap the power button, then *Pair your Mac* and type the
   code into Passthrough in the Mac's menu bar.

The Mac needs `adb` (`brew install android-platform-tools`); the Mac app finds
it and starts the adb server by itself.

## Permissions

| Permission | Why |
|---|---|
| Internet, network state | Open the Mac's connections |
| Change network state | Keep cellular up while on Wi-Fi ("Cellular only") |
| Foreground service (connected device) | Keep serving with the screen off |
| Notifications | The ongoing notification that shows the service is on |
| Wake lock | Keep the CPU awake while serving; renewed every minute, released on stop |
| Phone state (optional) | Label the radio 5G / LTE. Asked only from Settings |

Paired-Mac data is excluded from cloud backup and device transfer.
