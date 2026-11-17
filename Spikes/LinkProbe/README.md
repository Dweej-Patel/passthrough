# Link Probe (throwaway spike)

Question: for an iPad on the iPhone's Personal Hotspot, with both running
packet-tunnel extensions, **who can reach whom**, and does it survive the
iPhone being locked? With the Mac the iPhone dials out because iOS gives the
iPhone's background extension no incoming connections. If the iPad's extension
can't accept either, the real iPad client needs another design.

Each device runs the same probe. It listens on TCP and UDP, advertises them
over Bonjour (`_ptprobe._tcp` / `_ptprobe._udp`), dials every peer it finds
(plus fixed addresses: the iPad dials `172.20.10.1`, the iPhone's address on
its own hotspot), and sends a heartbeat once a second on every connection.
Each row on screen is one path; its dot shows when it was last heard (green
under 3 s, orange under 10 s, red after that, grey for never). The timeline
records every connect, failure, silence and recovery, plus the extension's
sleep and wake.

| Probe | TCP | UDP |
|---|---|---|
| in the tunnel extension (`ext`) | 47100 | 47101 |
| in the app (`app`, fallback) | 47200 | 47201 |

## Build and install

Needs Xcode signed in to the team (Xcode ▸ Settings ▸ Accounts) so it can make
the new app IDs, the app group and a profile that includes the iPad. Plug the
iPad in once (Developer Mode on) so it gets registered.

```sh
cd Spikes/LinkProbe
xcodegen generate
xcodebuild -project LinkProbe.xcodeproj -scheme LinkProbe -destination generic/platform=iOS \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration -derivedDataPath build build
xcrun devicectl device install app --device <iPhone or iPad id> build/Build/Products/Debug-iphoneos/LinkProbe.app
```

## Run

**Before you start:** turn Passthrough **off** in the iPhone app. Its tunnel
reconnects on demand and would take the VPN slot back from the probe, and
iOS runs one VPN at a time. (The Mac loses the phone's internet meanwhile.)

1. iPhone: Personal Hotspot on. iPad: join it.
2. Open Link Probe on both and allow Local Network.
3. **A. Light.** On both: Start the tunnel probe (guard off). Wait 30 s.
   Then lock the **iPhone** for 3 minutes while the iPad stays unlocked
   (turn on "Keep this screen on"). Then lock the iPad too for 3 minutes.
   Unlock both.
4. **B. Guard** (the iPad's real setting). On the iPad: Stop, turn Guard mode
   on, Start. Check the iPad has no internet (Safari fails) and the paths
   still work. Lock the iPhone for 3 minutes again.
5. **C. App fallback**, only if the iPad's extension never got an incoming
   path in A: on the iPad, also Start the app probe and repeat the iPhone lock.

Then turn Passthrough back on on the iPhone.

## Reading it

| Row (on the iPhone) | Means |
|---|---|
| `tcp out → ipad-ext` green | The current design works for the iPad: the phone dials, the iPad's extension accepts |
| `tcp in ← ipad-ext` green | The iPad's extension can dial the phone's extension (expected to fail) |
| `udp …` rows | Fallbacks if TCP into an extension doesn't work |

What matters most is the iPhone-locked stretch: how long `tcp out → ipad-ext`
stays silent (longest gap), or whether it drops and how fast it comes back.

## Getting the logs to Claude

Plug the device into the Mac and say so; the logs are in the app group:

```sh
xcrun devicectl device copy from --device <id> --domain-type appGroupDataContainer \
  --domain-identifier group.dev.dpatel.passthrough.linkprobe --source probe-phone-ext.log --destination .
```

(`probe-ipad-ext.log`, `probe-ipad-app.log` and `probe-phone-app.log` too.) Or use
"Share full log" in the app.
