# Passthrough for Android

The phone side of Passthrough, for Android 8.0 and later. It serves the Mac over
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

Needs JDK 17 and the Android SDK (platform 35). With Homebrew:

```
brew install openjdk@17
brew install --cask android-commandlinetools android-platform-tools
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
sdkmanager "platforms;android-35" "build-tools;35.0.0"
```

Or open the `android/` folder in Android Studio.

```
./gradlew testDebugUnitTest lintDebug   # tests and lint
./gradlew installDebug                  # build and install on the attached phone
```

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
