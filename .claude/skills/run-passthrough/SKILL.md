---
description: Build, install and launch Passthrough - the macOS menu bar app plus the iOS app on a USB-attached iPhone - and confirm they see each other. Use when asked to run, start, or try the app on real devices.
---

# Run Passthrough (Mac + iPhone)

Run from the repo root. Everything below was verified on Xcode 27, macOS, an
iPhone 16 over USB.

## 1. Signing config (once per clone)

`Config/Signing.xcconfig` is gitignored and holds the personal bits. It is
optionally included by the committed `Config/Identity.xcconfig`. If it is
missing, create it:

```
DEVELOPMENT_TEAM = <team for the Mac app>
DEVELOPMENT_TEAM[sdk=iphoneos*] = <paid team for the iPhone app>
PASSTHROUGH_ID = <your reverse-DNS base, e.g. dev.yourname.passthrough>
```

- Team IDs are the `OU=` of the signing certificates:
  `security find-identity -v -p codesigning`, then
  `security find-certificate -a -c "<cert name>" -p | openssl x509 -noout -subject`.
  Ask the user which team to use when there are several.
- **A free (personal) team cannot sign the iOS Network Extension** (the packet
  tunnel). The iPhone build fails with "Personal development teams ... do not
  support the Network Extensions capability". Use a paid team for
  `[sdk=iphoneos*]`, which is why the per-SDK override exists. The Mac app
  builds fine on a free team.
- `PASSTHROUGH_ID` must be one your teams can own; the upstream default
  `dev.dpatel.passthrough` belongs to the original author and will not
  provision. Every bundle ID, App Group, keychain service and launchd label
  derives from it (Swift reads it via `PassthroughProtocol.identifier` /
  `HelperConstants.identifier`), so never hand-edit the IDs in source.

## 2. Generate and build

```bash
xcodegen generate
UDID=$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /iPhone/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)

xcodebuild -project Passthrough.xcodeproj -scheme PassthroughMac -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/dd \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > build/mac.log 2>&1
xcodebuild -project Passthrough.xcodeproj -scheme Passthrough -configuration Debug \
  -destination "id=$UDID" -derivedDataPath build/dd-ios \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > build/ios.log 2>&1
grep -E "error:|BUILD" build/mac.log build/ios.log
```

The iPhone must show as `available (paired)` in `xcrun devicectl list devices`
(unlocked, "Trust this computer" accepted). `build/` is gitignored.

## 3. Install and launch

```bash
ID=$(awk -F' *= *' '/^PASSTHROUGH_ID/ {print $2}' Config/Signing.xcconfig)
xcrun devicectl device install app --device "$UDID" build/dd-ios/Build/Products/Debug-iphoneos/Passthrough.app
xcrun devicectl device process launch --device "$UDID" "$ID.ios"
open build/dd/Build/Products/Debug/Passthrough.app
```

## 4. Confirm it is running

```bash
/usr/bin/log show --last 1m --info --predicate "subsystem == \"$ID\"" | tail -20
```

Expect `iPhone attached over USB (...)` from the Mac app. On a first run you will
also see `Helper registration failed: ... Operation not permitted` and
`Helper XPC error`: normal until the helper is approved (step 5).

To verify the IDs resolved in the build:
`plutil -p build/dd/Build/Products/Debug/Passthrough.app/Contents/Library/LaunchDaemons/*.plist`
should show `Label => <ID>.helper`.

## 5. Hand-off: steps only the user can do

Tell the user to:

1. **Mac:** System Settings ▸ General ▸ Login Items & Extensions ▸ *Allow in
   the Background* ▸ enable Passthrough (approves the root helper).
2. **iPhone:** tap the power button in Passthrough and allow the VPN
   configuration. If iOS says the developer is untrusted: Settings ▸ General ▸
   VPN & Device Management ▸ trust it.
3. **Pair:** flip the switch in the Mac's menu bar panel, enter the six-digit
   code shown by *Pair* on the phone.

## Without a phone

`cd Packages/PassthroughCore && swift test` (all pass; one skipped), or
`swift run passthrough-devserver` and
`curl --socks5-hostname 127.0.0.1:7890 --proxy-user dev:dev-token https://example.com`.
