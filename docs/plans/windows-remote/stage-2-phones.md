# Stage 2: Phones know a PC

Master plan: `docs/plans/windows-remote/MASTER.md` (cited below as *MP*, with its section). Paths are relative to `D:\projects\passthrough`. `iOS/App/...` lines were read on branch `windows-remote-spikes`.

## Goal and done-when

The iPhone/iPad app (with its widget, Live Activity, notification extension and App Intents) and the Android app stop assuming that every paired computer is a Mac. A Windows PC shows as a PC: the right noun in every sentence, only the rows a PC has, the shell working against it (shell chooser, `signed_out` states, going-away reasons), its own setup steps, and "Your computers" in place of "Your Macs". There is no screen viewer for a PC in this stage (stage 6): the page shows a dimmed Screen row that says so, and nothing in the app can reach the Mac Screen Sharing login for a PC.

No PC can grant a shell until stage 3, so this stage is verified against fixtures, fakes, the debug demo, and today's Mac.

Done when:

1. A Mac and a PC sit side by side in the switcher ("Your computers"), each with its own words, on iPhone, iPad and Android. Verified with the demo data (a PC added to `-PTDemoShell`) and with the fixture-driven tests.
2. Every state in MP §1 "The phone's page for a PC" is produced by one pure function per platform, with a test per row.
3. New shell is a split control when the host lists more than one shell; a plain button otherwise. The chosen shell goes out as `open.shell`; the last choice is kept per computer.
4. With a PC selected, tapping Screen, a widget, a notification, a Live Activity link or an App Intent never shows `Phase.login` or `Phase.confirmScreenSharing` (`iOS/App/Screen/ScreenModel.swift:25-36`).
5. Against today's Mac (no `host`, no `hostKind`) every screen reads exactly as it does today; a test compares the Mac variant of each catalog sentence with the sentence in today's source.
6. `swift test` in `Packages/PassthroughCore`, `./gradlew testDebugUnitTest lintDebug`, and both Apple schemes build.

## What exists today (verified, with path:line)

### Wire and storage (Swift)

* A paired computer is a `PairedClient` (`Packages/PassthroughCore/Sources/PassthroughCore/Pairing.swift:54-72`). Its `kind` is a `ClientKind` with `mac` and `ipad` only (`Pairing.swift:47-51`); "records without `kind` are Macs". It says what the *client's role* is (an iPad is dialed over the hotspot, `Pairing.swift:214-221`), not what kind of host it is.
* The shell grant as stored is `ShellGrant` (`Pairing.swift:29-44`): `certSHA256`, `port`, `addresses`, `macName`, `irohID`, `irohRelay`. No host kind.
* The list is JSON in the App Group defaults under `pairing.clients` (`Pairing.swift:77`, `279-288`), written by the tunnel extension and read by the app. Unknown JSON keys are ignored by `Codable`, so a new optional field survives an older build reading it (and is dropped when that build rewrites the list).
* The phone's control server takes the computer's name from `hello.name`, default `"Mac"` (`ControlServer.swift:169`), stores a grant from `shellGrant` with `macName` (`ControlServer.swift:232-263`), and logs "Paired Mac …" (`Pairing.swift:379`), "A Mac with an older Passthrough…" (`ControlServer.swift:154-155`), "A Mac could not prove its pairing" (`ControlServer.swift:185`). Those lines show in the app's log view.
* A computer on the cable is a `ConnectedMac` (`ControlServer.swift:24-35`); `ProviderStats.connectedMacs` is every connected client that is not an iPad (`Protocol.swift:174`). A PC on the cable is therefore counted as "a Mac online through this iPhone" today (`iOS/App/ThisPhoneView.swift:147`, `iOS/App/Home/MacHomeView.swift:32,270-272`).
* `ShellCredential` (`ShellClient.swift:6-28`) is built from client + grant + key by `ShellCredentials.build` (`ShellCredentials.swift:11-22`). It is also the wire shape of `screenPass.pass` (`ShellProtocol.swift:81`).
* `ShellEnvelope` (`ShellProtocol.swift:42-159`) has no `host`, no `shell`, no `message`. `ShellError` (`ShellProtocol.swift:277-300`) has no `signed_out`.
* `ShellClient` (`ShellClient.swift:89-867`): before `ready`, any message other than `challenge`, `ready`, `error` ends the attempt as a protocol violation (`ShellClient.swift:668-697`), which is why MP says `host` comes only after `ready`. After `ready`, an unknown `t` is dropped (`ShellClient.swift:786-787`) and an unknown error reason becomes `.badRequest` (`ShellClient.swift:758`). `open(cols:rows:)` sends `cols`, `rows`, `ref` (`ShellClient.swift:310-323`). A line that fails to decode is dropped whole (`ShellClient.swift:667`).
* No typed "relay did not answer" error exists: `IrohShellDialer.connect` throws whatever iroh throws (`Sources/IrohTransport/IrohShellDialer.swift:24-39`).

### iOS app

* `ShellModel` (`iOS/App/Shell/ShellModel.swift`) holds `macs: [ShellCredential]`, the selection, `reach` (`Reach`, `:13-39`, whose `message` is Mac-worded), `sessions`, `macState`, `path`, `lastHeard` per Mac in `UserDefaults` (`:335-345`), tab memory, hidden sessions. `handle(_:generation:)` (`:721-855`) is the one place events land. `.failed(.notAuthorized)` sets `reach = .noAccess` (`:827`), the same state as "never granted". Redials after a drop run on `redialDelays = [0,1,2,4,8,15]` (`:164`), then `.unreachable`.
* `newSession(cols:rows:)` (`:529-540`) calls `client.open`; when still connecting it sets `openWhenReady` (`:177`, `:732-737`).
* `selectedMacName` falls back to `"Your Mac"` (`:315-317`).
* `MacWatcher` (`iOS/App/Shell/MacWatcher.swift`) keeps `Seen { sessions, state, reachable, lastHeard }` per watched Mac (`:15-21`) and ignores every other event (`:137-140`).
* `ShellKeyVault` (`iOS/App/Shell/ShellKeyVault.swift`) stores only keys, by client id (`:32-43`). It needs no change.
* Mac page: `MacHomeView` (`iOS/App/Home/MacHomeView.swift`): `narrowLayout` (`:113-122`) = hero, needs-you cards, switches card, setup card, shells card. The switches card (`:224-265`) always shows the Internet row on iPhone, then for a paired Mac: Keep awake, VPN, Screen lock (only when `state.locked != nil`), Screen, Share screen. `controlBlock` (`:566-575`) disables Keep awake, VPN **and Lock** when `macState.control != true`.
* New shell is a plain button in four places: `MacHomeView.swift:597` and `:607-614` ("New shell"), `RemoteShellCard.swift:77-80` ("New session"), `RootView.swift:371-372` (Shells tab `+`), `TerminalScreen.swift:290-302` and `:388-389` (inside the terminal). All go through `router.terminal = .new` → `TerminalIntent.new` (`TerminalScreen.swift:7-13`, `:139`) or `controller.newSession()` (`TerminalScreen.swift:146`).
* Session rows are captioned by `RemoteShellCard.status(_:now:)` (`RemoteShellCard.swift:181-197`): "running · 4m", prefixed "on the Mac · " for `origin == "mac"`.
* Setup steps: `ShellSetupSteps` (`RemoteShellCard.swift:255-290`): "Pair this iPhone with your Mac", "Turn on Remote shell on your Mac", "Connect over USB once" ("With sharing on, plug this iPhone into the Mac…").
* Switcher: `MacSwitcherSheet` (`iOS/App/Home/MacSwitcher.swift:44-159`), title "Your Macs", action "Add a Mac"; row text from `MacProfiles.statusText` (`MacProfiles.swift:109-125`).
* Share screen: offered when `shell.macs.count >= 2` (`MacHomeView.swift:465`); the sheet lists every other credential (`ShareScreenSheet.swift:14`). A PC among `macs` would be offered as a viewer and sent `screenGrant`/`screenPass`.
* Screen: `router.showScreen = true` (`MacHomeView.swift:444`, `:143`, `RemoteShellCard.swift:95`) presents `ScreenView`, which calls `ScreenModel.begin` (`ScreenModel.swift:194-212`). `begin` asks for `screenVideo`; on `screen_video_unavailable` or `bad_request` it calls `fallBackToScreenSharing()` (`:394-395`, `:294-307`), which shows `Phase.confirmScreenSharing` or sends a saved Mac login. This is the path that must never run for a PC.
* Pairing: `PairSheet` (`iOS/App/PairSheet.swift`) is already titled "Pair a Mac or PC" (`:20-21`). When the service is not running it says "This iPhone's internet sharing is off, so the computer can't reach it to pair." with **Turn on sharing** (`:25-37`).
* How "sharing" starts the cable link: `AppModel.start()` (`iOS/App/AppModel.swift:167-189`) picks `ExtensionHost` when hosting is `background` and the extension is available, else `InProcessHost`. `ExtensionHost.start` → `TunnelController.configure` saves a `NETunnelProviderManager` (this is what makes iOS ask to add a VPN configuration) with on-demand "always connect" (`iOS/App/TunnelController.swift:30-50`) and starts it. `PacketTunnelProvider.startTunnel` (`iOS/Tunnel/PacketTunnelProvider.swift:27-61`) sets a tunnel that routes one unreachable /32 (`:38-42`) and starts `PassthroughService`, which always starts **both** the SOCKS5 server and the control server (`PassthroughService.swift:45-87`). The extension does nothing host-specific: a PC's control channel gets the same `hello`/`auth`/`pair`/`shellGrant` handling and a `status` every second (`ControlServer.swift:362-374`); the SOCKS server simply has no client.
* The same service also runs inside the app with no VPN configuration: `InProcessHost` (`iOS/App/ProxyHost.swift:56-94`). An iPad already works this way for Macs: "What a Mac reaches over the cable (pairing, the shell key) is served by the app whenever it's open" (`AppModel.swift:146-153`). `InProcessHost` keeps an iPhone awake while serving (`ProxyHost.swift:76-79`). A refused VPN configuration is reported as "iOS did not allow the VPN configuration. Approve it in Settings, or switch to foreground hosting." (`AppModel.swift:348-354`).
* Widget and Live Activity: `MacSnapshot` (`iOS/Shared/MacSnapshot.swift:9-48`) has no kind; `MacWidget` shows "Sleeps as usual" / "Awake" / "Plugged in" (`iOS/Widgets/MacWidget.swift:77`) and "Open Passthrough to see your Mac here." (`:91`). The Live Activity starts only from Keep awake (`iOS/App/Home/MacActivityController.swift:92-117`).
* Notification extension: `NotificationService` (`iOS/Notifications/NotificationService.swift`) has no Mac wording of its own; the placeholder text "Something on your Mac needs a look." is written by the **host** into the APNs payload (`PushNotice.swift:77-78`, `protocol/README.md:510`).
* App Intents and links: `KeepMacAwakeIntent`, `MacVPNOnIntent` (`iOS/App/Home/AppIntents.swift:40-69`) open `AppLink.keepAwake` / `.vpnOn`, which target the selected computer (`AppLink.swift:54-62`) and wait for `macState.control == true` (`RootView.swift:269-283`).
* Localisation: none. No `.strings`, `.xcstrings` or `.lproj` anywhere in the repo, and `project.yml` sets none. Every sentence is a Swift literal, most with interpolation (`"…\(macName)…"`, `"this \(ThisDevice.name)"`). `ThisDevice.name` is "iPhone" or "iPad" (`iOS/App/ThisDevice.swift:9`).

### Android app

* Same shapes in Kotlin: `PairedClient`, `ShellGrant` (`android/.../core/Pairing.kt:52-73`), `ShellCredential` (`core/ShellCredentials.kt:10-34`), `ShellEnvelope`, `ShellError`, `MacState` (`core/ShellProtocol.kt`), events in `ShellEvent` (`core/ShellConnection.kt:118-161`), `open(cols, rows)` (`ShellConnection.kt:269-273`). JSON is decoded with `ignoreUnknownKeys = true` (`core/Protocol.kt:96-97`). Unknown error reasons become `BAD_REQUEST` (`ShellConnection.kt:452`).
* Strings are Kotlin literals; `res/values/strings.xml` is 3 lines (app name). Copy lives in plain-Kotlin objects where it can be tested: `ShellReach` (`ui/shell/ShellLogic.kt:14-53`), `MacSwitches` (`ui/mac/MacSwitches.kt`), `MacProfiles.statusText` (`ui/shell/MacProfiles.kt:108-121`), `SHELL_SETUP_STEPS` (`ui/shell/RemoteShellCard.kt:66-70`).
* Page: `MacScreen` (`ui/mac/MacScreen.kt:103-262`): header, needs-you cards, `StatusCard` (`:391-448`), a card with Internet, Keep Mac awake, VPN, lock; `ShellsPreview`; `ThisPhoneRow`. The "New" pill is in `RemoteShellCard.kt:103-107`. Android has no screen viewer at all.
* Tab title "Mac" (`ui/MainTabs.kt:75`); switcher "Your Macs", "Add a Mac" (`ui/mac/MacSwitcher.kt:147,172`).
* Per-computer preferences live in `AppSettings` (`service/AppSettings.kt:50-115`).

### Protocol today

`protocol/README.md` documents none of `host`, `hostKind`, `open.shell`, `signed_out`, or a going-away message on the shell connection; `protocol/fixtures.json` has none either. Stage 1 adds them. The control channel has a `goodbye` with no fields, from the phone (`protocol/README.md:43`).

## Design

### 1. What a host is (types)

All new portable types go in `Packages/PassthroughCore/Sources/PassthroughCore/Host.swift` (new file) and `android/app/src/main/java/dev/dpatel/passthrough/core/Host.kt` (new file). Stage 1 owns the wire structs; where it has already added one under another name, use it and keep only the derived types here.

```swift
/// What kind of computer a host is. Raw values are the wire's.
public enum HostKind: String, Codable, Sendable { case mac, windows }

/// The `host` message, cleaned for showing and keeping (below, "Limits").
public struct HostFacts: Codable, Equatable, Sendable {
    public var kind: HostKind?            // nil: the wire named a kind this build doesn't know
    public var os: String?                // "Windows 11 Pro"
    public var user: String?              // the granting account's sign-in name
    public var signedIn: Bool?            // the owning account's Passthrough is there to run shells
    public var console: Console?          // .active, .locked, .signedOut, .otherUser
    public var idleSeconds: Int?
    public var shells: [HostShell]        // [] when the host lists none
    public var screens: [String]          // "video", "rfb", "rdp"
    public var rdp: String?               // "ready", "off", "edition", "account", "service", "exposed"
    public var sleepAfterSeconds: Int?
    public var access: Access?            // see Corrections 2; nil when the host doesn't say
    public enum Console: String, Codable, Sendable { case active, locked, signedOut, otherUser }
    public struct Access: Codable, Equatable, Sendable { public var shell: Bool?; public var screen: Bool? }
    public var defaultShell: HostShell? { shells.first(where: \.isDefault) ?? shells.first }
}
public struct HostShell: Codable, Equatable, Sendable, Identifiable {
    public var id: String; public var name: String; public var isDefault: Bool
}
/// Why a host said it was leaving, and when this phone heard it.
public struct HostFarewell: Codable, Equatable, Sendable {
    public var reason: String             // "sleeping", "turned_off", "shutting_down"; others kept, shown as unknown
    public var at: Date
}
```

Kotlin mirrors: `enum class HostKind(val wire: String)`, `@Serializable data class HostFacts`, `HostShell`, `HostFarewell` (epoch millis).

**Effective kind** (one function, used everywhere a noun or a row is chosen):

```swift
public enum Hosts {
    /// live `host.kind` → the stored `PairedClient.hostKind` → `.mac`.
    public static func kind(live: HostFacts?, stored: HostKind?) -> HostKind
}
```

A host that never said is a Mac. That is exactly today's behaviour, and it is the compatibility rule for today's Mac (see §7). A third value, "kind unknown to this build", exists only when a `host` message names a kind that is not `mac` or `windows`: then `HostFacts.kind` is nil **and** a flag `unknownKind` is set on the facts; wording uses the neutral noun "computer" and the page shows only shells. It is not reachable with any host in this plan; it keeps a future host from being called a Mac.

### 2. Model changes

#### Storage

| What | Where (iOS) | Where (Android) | Written by |
|---|---|---|---|
| Host kind per paired computer | new optional `PairedClient.hostKind: HostKind?` in `pairing.clients` | new `PairedClient.hostKind: String? = null` | `ControlServer` on `auth`/`paired` (from `hello.hostKind`, see Corrections 1) and on `shellGrant` (`hostKind`); `PairingRegistry.noteHostKind(clientID:kind:)` when a live `host` says so |
| Last `host` per computer | `UserDefaults.standard` key `shell.hostFacts`: JSON `[clientID: HostFacts]` | `AppSettings` key `shell.hostFacts`, same JSON | `ShellModel` / `ShellViewModel` on every `host` event from the live connection or a watch |
| Last farewell per computer | key `shell.farewells`: JSON `[clientID: HostFarewell]` | same | on a going-away message; removed on the next `ready` from that computer |
| Last shell chosen per computer | key `shell.lastShell`: `[clientID: String]` (shell id) | same | on every open that named a shell |

All three per-computer maps are pruned where the others are: `ShellModel.forget(macID:)` (`ShellModel.swift:415-449`), `forgetAll()` (`:451-465`), `forgetUnpaired(keeping:)` (`:949-960`); Android `forgetUnpaired` (`ShellViewModel.kt:1008`) and its forget paths.

`ShellGrant` is unchanged. The kind sits on `PairedClient` so a computer that is paired but has granted nothing can still have one.

New registry method (both platforms):

```swift
/// Records what kind of computer `clientID` says it is. No-op for an unknown id, an iPad, or an unchanged value.
@discardableResult public func noteHostKind(clientID: String, kind: HostKind) -> Bool
```

It takes the registry lock, edits one field and saves (which posts the change notification, `Pairing.swift:284-288`). It is called only with a value from an authenticated peer: the control channel after `auth`/`paired`, or a shell connection after `ready`.

`ShellCredentials.build` copies `client.hostKind` into `ShellCredential.hostKind` (the field stage 1 adds). `ShellCredential` is `Equatable`, so the first time a kind is learned the watcher restarts that computer's watch once (`MacProfiles.watchChanges`, `MacProfiles.swift:192-198`) and a connection still in `.connecting` is redialed once (`ShellModel.swift:297-301`); a `.ready` connection is kept (`sameKey`, `:304-306`).

`ConnectedMac` gains `host: HostKind?` (set from the registry in `Peer.authenticate`, `ControlServer.swift:379-386`). `ProviderStats` gains:

```swift
public var connectedPCs: [ConnectedMac] { macs.filter { $0.kind != .ipad && $0.host == .windows } }
// connectedMacs now also excludes `.windows`
public var connectedComputers: [ConnectedMac] { macs.filter { $0.kind != .ipad } }
```

`AppModel.tick` uses `connectedComputers` for "a computer that just paired connects: the code is spent" (`AppModel.swift:249`). `connectedMacIDs` stays Macs only (it drives "online through this iPhone"); a new `connectedComputerIDs` drives "Connected now" in the paired list (`ThisPhoneView.swift:359-360`).

#### Migration

None is run. Every new field is optional and absent in old records:

* `PairedClient` without `hostKind` → Mac by `Hosts.kind`.
* `MacSnapshot` without `hostKind` → Mac.
* No `shell.hostFacts` entry → `host == nil`: the page uses only what it has today.

An older build that rewrites `pairing.clients` drops `hostKind`; the next control or shell connection puts it back. Until then a PC reads as a Mac in that older build, which cannot use a PC anyway.

#### A host that never sent `host`

`ShellModel.hostFacts` is nil. Then:

* Kind comes from `PairedClient.hostKind`, else Mac.
* New shell is the plain button; `open` carries no `shell` (the encoded line is byte-for-byte today's).
* No shell-availability sentence is shown before an `open`; a `signed_out` answer still produces one (it then reads "Passthrough isn't open on *X*. Open it there.", the least specific true sentence).
* For kind `windows` the Screen row is dimmed with the "not in this version" sentence (it does not depend on `host`).
* For kind `mac` everything is as today.

#### Live state

`ShellModel` gains (all `@MainActor`, published):

```swift
@Published private(set) var hostFacts: HostFacts?          // the selected computer's; restored from `shell.hostFacts` on select, replaced by each live `host`
@Published private(set) var farewell: HostFarewell?        // the selected computer's, while it can't be reached
@Published private(set) var accessRefused = false          // `not_authorized` arrived while a credential was held
@Published private(set) var connectingSince: Date?         // set when `reach` enters `.connecting`, cleared when it leaves
@Published private(set) var relayHealth: RelayHealth = .unknown   // .unknown, .answering, .silent
@Published private(set) var shellRefusal: ShellError?      // the last `open` refused with signed_out / shell_not_allowed
var selectedKind: HostKind { Hosts.kind(live: hostFacts, stored: paired.first { $0.id == selectedMacID }?.hostKind) }
var words: HostWords { HostWords(kind: selectedKind, name: selectedHostName, device: ThisDevice.name) }
func kind(of id: String) -> HostKind
func preferredShell(for id: String) -> HostShell?          // last chosen if the host still lists it, else its default
func newSession(cols: Int, rows: Int, shell: String? = nil)
```

`resetSessions()` (`ShellModel.swift:969-988`) clears `shellRefusal`; `switchSessions(to:)` (`:903-912`) loads the new computer's stored facts and farewell. `MacWatcher.Seen` gains `host: HostFacts?` (set on the new `.host` event at `MacWatcher.swift:137-140`), so the switcher and widget can name the kind and the shell state of a computer that is not selected. A watch never acts on a farewell beyond storing it.

Android: the same fields as `StateFlow`s on `ShellViewModel`, and `MacWatcher.Seen.host`.

`ShellClient` (Swift) changes, in PR 1:

```swift
public func open(cols: Int, rows: Int, shell: String? = nil)     // `shell` omitted from the line when nil
public enum Event { …
    case host(HostFacts)                    // after `ready`, and whenever it changes
    case goingAway(reason: String)          // the host says it is leaving; a disconnect follows
}
```

`.host` and `.goingAway` are emitted from the `ready` branch of `handle` (`ShellClient.swift:703-788`) only. `.openFailed(.signedOut)` and `.openFailed(.shellNotAllowed)` come through the existing `error`-with-`ref` path (`ShellClient.swift:761-766`). Kotlin: `ShellConnection.open(cols, rows, shell: String? = null)`, `ShellEvent.Host(facts)`, `ShellEvent.GoingAway(reason)`.

`openWhenReady` (`ShellModel.swift:177`) becomes `pendingOpen: PendingOpen?` where `struct PendingOpen { var shell: String? }`, so a shell chosen while connecting is the one opened on `.ready` (`:732-737`).

#### Limits (applied when a `host` is taken in, before it is shown or stored)

`HostFacts.cleaned(_:)`: `os` ≤ 64 characters, `user` ≤ 256, each one line with control characters removed (as `ScreenPass.cleanName` does, `ShellProtocol.swift:317-320`); at most 32 shells kept; a shell is kept only if its `id` is 1–64 characters of `A–Z a–z 0–9 . _ : -` and its `name`, cleaned, is 1–64 characters; duplicate ids dropped after the first; `screens` limited to 8 entries of ≤ 16 characters; `rdp` ≤ 16 characters; `idleSeconds` and `sleepAfterSeconds` clamped to 0…604800. A `host` line is bounded by the existing 262144-byte line limit (`ShellProtocol.swift:26`).

The phone sends in `open.shell` only an id taken from the cleaned list of the connection it is sending on. A remembered id that the host no longer lists is not sent; the default is.

### 3. Host-aware wording: one mechanism

Neither platform has localisation files, and most sentences already interpolate a name and `ThisDevice.name`. Adding string tables for one variable would be a larger change than the feature. The mechanism is two small portable types, the same on both platforms, plus a test that keeps new literals out.

**`HostWords`: the nouns** (for the ~80% of sentences where only the noun changes).

```swift
public struct HostWords: Equatable, Sendable {
    public init(kind: HostKind?, name: String?, device: String)   // kind nil → neutral
    public var noun: String        // "Mac" | "PC" | "computer"
    public var plural: String      // "Macs" | "PCs" | "computers"
    public var the: String         // "the Mac" | "the PC" | "the computer"
    public var The: String
    public var your: String        // "your Mac" | "your PC" | "your computer"
    public var Your: String
    public var this: String        // "this Mac" | "this PC" | "this computer"
    public var that: String        // "that Mac" | …
    public var name: String        // the host's name, else `Your`
    public var device: String      // "iPhone" | "iPad" | "phone"
    public var settingsPlace: String   // Mac: "Passthrough's Remote Shell settings on the Mac"; PC: "Passthrough's settings on the PC"
    public var feature: String     // Mac: "Remote shell"; PC: "Remote access"
    public var symbol: String      // SF Symbol / Material icon key: "laptopcomputer" | "pc" | "desktopcomputer"
    public static func generic(device: String) -> HostWords      // "computer"
}
```

Kotlin: `class HostWords(kind: HostKind?, name: String?, device: String = "phone")` with the same members (`symbol` maps to `Icons.Filled.Laptop` / `Icons.Filled.DesktopWindows`).

**`HostCopy`: the sentences that differ in more than the noun.** One function per sentence, each a `switch` on kind, returning a `String`. Every state sentence in MP §1's phone table lives here, and so does the Mac sentence it replaces, copied unchanged from today's source. Examples:

```swift
public enum HostCopy {
    public static func noAccess(_ w: HostWords) -> String
    // mac: "Turn on Remote shell in Passthrough on your Mac, then connect this iPhone with the cable once."   (ShellModel.swift:32)
    // pc:  "Paired. Turn on Remote access on Office-PC, then plug this iPhone in once."                      (MP §1)
    public static func unreachable(_ w: HostWords, fromAnywhere: Bool, lastHeard: String?) -> String
    public static func wentToSleep(_ w: HostWords, at: String, sleepsAfter: String?) -> String
    public static func setupSteps(_ w: HostWords, paired: Bool, cableLinkOn: Bool) -> [SetupStep]
    …
}
```

Times are passed in already formatted (the callers own `Date` formatting), so `HostCopy` is pure text and the same vectors work on both platforms.

**Where each lives:** `Packages/PassthroughCore/Sources/PassthroughCore/HostWords.swift` and `HostCopy.swift` (the widget and notification targets already import PassthroughCore); `android/.../core/HostWords.kt` and `android/.../ui/shell/HostCopy.kt` (plain Kotlin, like `ShellLogic.kt`).

**Keeping the two platforms and the two kinds honest:**

* `protocol/fixtures.json` gains a section `hostCopy`: a list of `{ "key": "wentToSleep", "kind": "windows", "name": "Office-PC", "device": "iPhone", "args": {"at":"14:02","sleepsAfter":"30 minutes"}, "text": "Office-PC went to sleep at 14:02. It sleeps after 30 minutes; turn on Stay awake in Passthrough on the PC." }`. Both suites produce each `text` from their own `HostCopy`. This follows the existing shared `rates`/`durations` vectors (`ProtocolFixtureTests.swift:88-99`). The C# suite does not read this section (the PC shows its own words).
* A source-scan test in each suite fails on a string literal containing the word `Mac`, `Macs` or `macOS` in the app's UI sources unless the line ends in `// mac-only` (a row or feature a PC never shows) or the file is in a short allowlist (the screen viewer until stage 6; debug demo data). Swift: `HostWordingTests.testNoStrayMacLiterals` reads `iOS/App`, `iOS/Widgets`, `iOS/Shared` relative to `#filePath`, as the fixture tests reach `protocol/fixtures.json`. Kotlin: `HostWordingTests` reads `src/main/java/.../ui` and `service`. This is what makes it one mechanism rather than a convention.

**Rules for choosing a variant** (they give the codes used in the table below):

* **N** the sentence is kept and its noun comes from `HostWords` ("your Mac" → `w.your`, "the Mac" → `w.the`, …). The PC variant is the same sentence with "PC".
* **S** a different sentence for a PC, written out in the table or in *UX states and strings*; lives in `HostCopy`.
* **X** not shown for a PC (the row, card or dialog is absent). The literal stays, marked `// mac-only`.
* **G** no one computer is meant (lists, pairing, settings, empty states): the generic word. "Your Macs" → "Your computers", "Add a Mac" → "Add a computer", "Pair your Mac" → "Pair a Mac or PC".
* **U** unchanged for both: it already names no kind, or it is about a Mac-only feature shown only in a Mac's context (internet sharing, wireless link, Keep awake, VPN, screen passes).

MP §1 "Names" governs: once the kind is known, never "computer"; "Remote access" is the PC's setting; "Screen" is the feature; "Remote Desktop" only where Windows itself is meant.

#### Table: every user-facing string that names the Mac

iOS and shared Swift. Line numbers are today's.

| File:line | Today | For a PC |
|---|---|---|
| **`iOS/App/Shell/ShellModel.swift`** | | |
| :31 | "Couldn't read the Remote shell key. Plug into the Mac again to renew access." | N |
| :32 | "Turn on Remote shell in Passthrough on your Mac, then connect this iPhone with the cable once." | S "Paired. Turn on Remote access on *X*, then plug this iPhone in once." |
| :34 | "Can't reach your Mac. Check that Remote shell is on and the Mac is awake." | S "Can't reach *X*. It may be asleep, off, or offline. Last heard 14:02." (and the farewell and relay sentences, §4) |
| :35 | "Can't reach your Mac. Use the same Wi-Fi, or turn on Tailscale on both devices." | S "Can't reach *X*. Use the same Wi-Fi, or turn on Tailscale on both devices." |
| :316 | "Your Mac" (name fallback) | N (`w.Your`) |
| :326 | "Your Mac isn't connected right now, so nothing changed. Try again once it shows as reachable." | N |
| :1071 | "Your Mac already has 8 sessions open. End one to start another." | N |
| :1072 | "That session is no longer open on your Mac." | N |
| :1073 | "Your Mac couldn't do that. Try again." | N |
| :1074 | "This iPhone isn't allowed to see your Mac's screen. Turn on Screen for it in Passthrough's Remote Shell settings on your Mac." | S "Screen is off for this iPhone. On *X*, open Passthrough's settings and turn on Screen for it." |
| :1076 | "Your Mac can't show its screen yet. …allow Screen Recording and Accessibility, or turn on Screen Sharing." | S the Screen row's sentence (§4); never the Mac text |
| :1077 | "Your Mac can't stream its screen itself yet. …" | X (never asked of a PC) |
| :1078 | "Your Mac is already showing its screen as often as it allows (…)." | N |
| :1079 | "Your Mac doesn't let this iPhone change Keep awake and the VPN. …" | X |
| :1080 | "Your Mac has no VPN set up yet. …" | X |
| :1081 | "That Mac only lets this device see its screen." | N |
| :1082 | "Your Mac couldn't save the screen pass. Try again." | U (Mac to Mac only until stage 7) |
| :1100-1195 | demo names ("MacBook Pro", "Office iMac") | U; the demo gains a PC, "Office-PC" |
| **`iOS/App/Shell/RemoteShellCard.swift`** | | |
| :13 | "your Mac" (name fallback) | N |
| :48 | "Open your Mac's shell right from this iPhone. To set it up:" | N |
| :55, :74 | "Connecting to *X*…", "No sessions open. Start one to run commands on *X*." | U (name only) |
| :184 | "on the Mac · " (session started at the computer) | N "on the PC · " (not sent by a PC in this plan) |
| :236 | "Can't reach Mac" | N "Can't reach PC" |
| :260 | "Pair this iPhone with your Mac" | S step 1 (§6) |
| :262-263 | "Turn on Remote shell on your Mac" / "On the Mac, open Passthrough's Settings, go to Remote Shell and turn on "Allow remote shell from paired phones"." | S step 2 (§6) |
| :264-265 | "Connect over USB once" / "With sharing on, plug this iPhone into the Mac. …" | S step 3 (§6) |
| **`iOS/App/Home/MacHomeView.swift`** | | |
| :64 | a11y "Your Macs" | G "Your computers" |
| :65 | a11y "*X*, another Mac needs you" | G "*X*, another computer needs you" |
| :73-76 | "Let *X* sleep?" dialog | X |
| :275, :279 | "Internet through this iPhone" and its hints | X (the row is absent on a PC's page) |
| :289-291 | "Mac online through this iPhone", "Sharing — waiting for the Mac", "Sharing with the Mac and …" | X |
| :305, :308, :311, :314 | "Turn this on, then pair your Mac. …", "Now pair your Mac: …", "…so the Mac gets Wi-Fi…", "Plug the Mac into this iPhone, then connect from Passthrough in the Mac's menu bar." | U (internet sharing is a Mac's; shown only with no PC selected) |
| :327 | "Keep Mac awake" | X |
| :359, :362, :372-378, :385, :387 | Keep awake reasons | X |
| :423, :430-436 | VPN reasons | X |
| :449 | "See and control the Mac's screen" | S the Screen row's sentence (§4) |
| :461 | a11y "Opens the Mac's screen" | N |
| :472-473, :483 | "Share screen with a Mac", "Let your other Mac see and control this one", hint | X (offered only between two Macs until stage 7) |
| :520-521 | a11y "Lock *X*'s screen" / "The Mac stays awake and its shells keep running" | S hint "Its shells keep running" |
| :559 | "To change these from this iPhone, set up Remote shell on the Mac. The steps are below." | S "To use *X* from this iPhone, turn on Remote access there. The steps are below." |
| :569 | "Update Passthrough on *X* to change Keep awake and the VPN from here." | X |
| :572 | "This iPhone isn't allowed to change Keep awake and the VPN, or lock the screen. … on the Mac open Passthrough's Settings, go to Remote Shell and turn on Awake & VPN…" | X (a PC's Lock does not depend on `control`, Decisions 6) |
| :593, :648-649 | "Nothing running. Start a shell to run commands on *X*.", "Reach it from anywhere", "Open its shell and see its screen from this iPhone, even away from home." | U |
| :718 | a11y value "Waiting for Mac" | N |
| :800, :803 | "Control *X*'s screen", "See and control the Mac. Touch, a trackpad and a keyboard all work." | N (iPad Screen card; dimmed with the row's sentence for a PC) |
| **`iOS/App/Home/MacHeroCard.swift`** | | |
| :23 | "Online through this iPhone" | X |
| :41 | "Set up your Mac" | G "Add a computer" |
| :46 | "Online through this iPhone" / "Paired" | "Paired" only |
| :61 | "Even with the lid closed" / "It won't sleep" | X |
| :84 | "Then it's online through this iPhone whenever they're connected, and you can reach its shell from anywhere." | G "A Mac is then online through this iPhone whenever they're connected, and you can reach either one's shell from anywhere." |
| :87 | "Pair your Mac" | G "Pair a Mac or PC" |
| :94-95 | "It most likely went to sleep" / battery-limit text | X (a PC says why itself, §4) |
| :98 | "It may be asleep, off, or offline" | U as the heading; body from §4 |
| :203 | a11y "Mac, not answering" / "Mac, staying awake" / "Mac" | N ("PC, not answering", "PC") |
| **`iOS/App/Home/MacSwitcher.swift`** | | |
| :74 | "Add a Mac" | G "Add a computer" |
| :85 | "Your Macs" | G "Your computers" |
| (row, :105) | status from `MacProfiles.statusText` | kind prefix "PC · " (Decisions 4) |
| **`Packages/.../PassthroughCore/MacProfiles.swift`** | | |
| :122 | "Paired, no Remote shell" | S "Paired, no access yet" |
| **`iOS/App/Home/ShareScreenSheet.swift`**, **`iOS/App/Shell/ScreenShareModel.swift`** | :37, :39; :42, :62, :135, :154 (all name Macs) | U; the sheet lists Macs only |
| **`iOS/App/PairSheet.swift`** | | |
| :20-21 | "Pair a Mac or PC", "Open Passthrough on your Mac or PC, plug in the cable, and enter this code." | U |
| :28 | "This iPhone's internet sharing is off, so the computer can't reach it to pair." | G "The cable link is off, so the computer can't reach this iPhone to pair." |
| :31 | "Turn on sharing" | G "Turn on the cable link" |
| :67 | "…Each Mac gets its own key you can revoke at any time." | G "…Each computer gets its own key…" |
| **`iOS/App/ThisPhoneView.swift`** | | |
| :46 | footer "A Mac reaches this iPhone over the USB cable (or its wireless link), an iPad over its Personal Hotspot. …" | G "A Mac or PC reaches this iPhone over the USB cable (a Mac also over its wireless link), an iPad over its Personal Hotspot. …" |
| :63 | "*n* Macs" / "Mac" (flow map) | U (Macs only: `connectedMacs` now excludes PCs) |
| :116 | "This iPhone is on Wi-Fi, so your Mac uses its Wi-Fi, not cellular. …" | U |
| :132 | "Pair your Mac" | G "Pair a Mac or PC" |
| :142 | "Off. Tap to share this iPhone's internet with your Mac" | S with only PCs paired: "Off. Turn on the cable link to pair a PC or renew its access." |
| :147 | "*X* is online through this iPhone" | U (Macs only) |
| :148 | "Sharing. Plug in your Mac and connect from its menu bar." | S with only PCs paired: "The cable link is on. A PC doesn't use this iPhone's internet." |
| :335 | "Paired Macs" (iPad) | G "Paired computers" |
| :338, :349, :354 | already "Mac or PC" / "Mac, PC or iPad" | U |
| :353 | "No Mac paired yet. Tap Pair and enter the code in Passthrough on your Mac, with the cable plugged in." | G "No computer paired yet. Tap Pair and enter the code in Passthrough on your Mac or PC, with the cable plugged in." |
| :363 | icon `laptopcomputer` | `w.symbol` |
| :374 | "Forget this Mac" | N |
| **`iOS/App/SettingsView.swift`** | | |
| :25 | "Shown on your Mac and iPads." / "…Mac and iPhone." | G "Shown on your computers and iPads." |
| :47, :61 | cellular-only and wireless-link footers | U |
| :73, :114 | "Forget all paired Macs" (+ "?") | G "Forget all paired computers" |
| :117 | "Every Mac loses access, including Remote shell, until you pair it again." | G "Every computer loses its pairing, and this iPhone its access to them, until you pair again." |
| :84 | "…Start the proxy and connect a Mac…" | G "…connect a computer…" |
| :105 | "The Mac connects through usbmuxd… Every Mac authenticates with a per-device key that only its own keychain holds." | G "A computer connects through usbmuxd… Every computer authenticates with its own key, which only it holds." |
| :146 | "Open your Mac's shell from this iPhone. Every session is recorded on the Mac." | G "Open a computer's shell from this iPhone. Every session is recorded on that computer." |
| :148 | "Every session is recorded on your Mac. To take access away, turn Remote shell off on the Mac, or forget the Mac on this iPhone." | G "Every session is recorded on the computer it runs on. To take access away, turn it off there, or forget the computer on this iPhone." |
| :163, :165 | "Mac address (optional)" and its footer | G "Address (optional)"; "Only needed when this iPhone can't find a computer by itself, for example over Tailscale. Enter its Tailscale name or IP address. Leave blank to use the addresses it shares." |
| :188 | "*X* can't send them: its Passthrough has no usable push key. See Settings › Remote Shell on the Mac, …" | S "*X* doesn't send notifications yet. A shell that needs you still shows in the app." |
| :195 | "…Your Mac sends them through Apple's push service… Each Mac starts sending once the app has connected to it." | G adds "A PC doesn't send them yet." |
| :200 | "Your Mac" | N |
| :214 | "…your Mac's screen…" | G "…a computer's screen…" |
| :233 | "…Locking the app never stops sharing: your Mac stays online." | U |
| :244 | "…when "Reach this Mac from anywhere" is on in the Mac's Remote Shell settings." | G "…when From anywhere is on in Passthrough on the computer." |
| **`iOS/App/Home/ActivityTab.swift`** | | |
| :35 | "Update Passthrough on your Mac to see what happened on it." | N (not reached for a PC: it answers an empty list) |
| :40 | "As of 14:02. Your Mac can't be reached right now." | N |
| :48 | "Your Mac's timeline shows up here once this iPhone can reach it." | S "A PC keeps no timeline yet." |
| :98 | "Nothing happened on your Mac in this time." | S "A PC keeps no timeline yet." |
| **`iOS/App/Home/AppIntents.swift`** | :25 "Couldn't reach your Mac in time. …"; :41-66 titles and phrases | U (Keep awake and the VPN are a Mac's; §8 says what they do with a PC selected) |
| **`iOS/App/Home/RootView.swift`** | :136 tab "Mac" | "Mac" / "PC" by the selected computer; "Computer" with none paired |
| **`iOS/App/Home/MacActivityController.swift`** | :156 "Your Mac" | N |
| **`iOS/App/Home/HotspotCard.swift`** | :115 "Pair a Mac to reach it from here." | G "Pair a Mac or PC to reach it from here." |
| **`iOS/App/Home/VPNOffSheet.swift`** :46, **`iOS/App/Home/PairWithPhoneSheet.swift`** :84, **`iOS/App/Lock/LockOverlay.swift`** :139 | VPN, iPad pairing, "Your Mac stays online while Passthrough is locked." | U / X |
| **`iOS/App/Shell/ShellHistoryView.swift`** | :28 "Connect to your Mac to see its session history."; :37 "…Every session opened on this Mac is recorded here…"; :142 "…Check that your Mac is reachable…" | N |
| **`iOS/App/Shell/TerminalScreen.swift`** | :420 "your Mac"; :302, :389 "New session" | N; the control of §5 |
| **`iOS/App/AppModel.swift`** | :296 "that code names a device already paired as a Mac" | G "…already paired as a computer" |
| **`iOS/App/Shell/ShellKeyVault.swift`** | :102 log "…the Mac grants again over the cable" | G "…the computer grants again…" |
| **`iOS/App/Screen/*`** | `ScreenModel.swift:56,201,284,406,548-552,1179`; `ScreenView.swift:613,626,653`; `ScreenCanvas.swift:1054,1062,1065` | U in this stage: never reached for a PC (§4 gate). `:201`, `:284` "Choose a Mac first." → G "Choose a computer first." Stage 6 does the rest. |
| **`iOS/Widgets/MacWidget.swift`** | :16 "Mac"; :17 "Your Mac's awake time and shells, as Passthrough last saw them."; :77 "Sleeps as usual"; :91 "Open Passthrough to see your Mac here." | §8 |
| **`iOS/Widgets/PassthroughWidgets.swift`** | :29-46 "Keep Mac awake", "Mac VPN on" and descriptions | U |
| **`iOS/Widgets/MacLiveActivity.swift`** | no literal names the Mac (it shows the name) | U; never started for a PC |
| **`iOS/App/Info.plist`** | :46 "…keep your Mac's shell and settings private."; :48 "…finds your linked Mac… and reaches your Mac's shell on the same network."; :50 "…sends your voice to your Mac…" | G :46 "…keep your computers' shells and settings private."; :48 "…and reaches your computers' shells on the same network."; :50 U |
| **`Packages/.../Pairing.swift`** | :379 log "Paired Mac *X*" | G "Paired *X*" |
| **`Packages/.../ControlServer.swift`** | :154-155 "A Mac with an older/newer Passthrough tried to connect: update Passthrough on the Mac / on this phone"; :169 default name "Mac"; :185 "A Mac could not prove its pairing…" | G "A computer with an older Passthrough…: update Passthrough on it"; default name "Computer"; "A computer could not prove its pairing…" |
| **`Packages/.../PushNotice.swift`** | :78 "Something on your Mac needs a look." | U: written by the host, and a PC sends none in this plan |

Android (`android/app/src/main/java/dev/dpatel/passthrough/`). "this phone" is the device noun.

| File:line | Today | For a PC |
|---|---|---|
| **`ui/shell/ShellLogic.kt`** | | |
| :18 | "Turn on Remote shell in Passthrough on your Mac, then connect this phone with the cable once." | S "Paired. Turn on Remote access on *X*, then plug this phone in once." |
| :26, :31 | "Can't reach your Mac. Use the same Wi-Fi, …" / "…Check that Remote shell is on and the Mac is awake." | S as iOS |
| :76 | "Your Mac already has 8 sessions open. End one to start another." | N |
| **`core/ShellCredentials.kt`** | :49 "Couldn't read the Remote shell key. Plug into the Mac again to renew access." | N |
| **`ui/shell/RemoteShellCard.kt`** | | |
| :67-69 | the three setup steps | S (§6, Android wording) |
| :120 | "Connecting to your Mac…" (fallback) | N |
| :124 | "No sessions open on this Mac. Tap New to start one." | N |
| :134 | "Open your Mac's shell from this phone. To set it up:" | N |
| :138-139 | "Can't reach this Mac" / "Can't reach your Mac" and the `removePrefix("Can't reach your Mac. ")` | N title; the detail comes whole from `HostCopy` (no prefix surgery) |
| :150 | "…Start the proxy and plug into the Mac again to renew access." | N |
| **`ui/shell/ShellHistoryScreen.kt`** | :114 "Sessions on this Mac"; :130 "Connect to your Mac to see its history."; :134 "…recorded on the Mac…"; :266 "The Mac didn't send its output. …" | N |
| **`ui/shell/ShellTerminalView.kt`** :68, **`ui/shell/TerminalScreen.kt`** :148 | "your Mac" | N |
| **`ui/mac/MacScreen.kt`** | | |
| :136 | "Your Mac" | N |
| :196 | "Keep Mac awake" | X |
| :376, :385 | "Set up your Mac", "Pair your Mac" | G "Add a computer", "Pair a Mac or PC" |
| :381-383 | "Plug this phone into your Mac with a USB cable." / "Open Passthrough in the Mac's menu bar." / "Tap Pair your Mac and type the code on the Mac." | G "…into your Mac or PC…" / "Open Passthrough on the computer." / "Tap Pair a Mac or PC and type the code there." |
| :440 | "…so Keep Mac awake let it sleep. …" | X |
| :472 | "1 Mac paired" / "*n* Macs paired" | G "1 computer paired" / "*n* computers paired" |
| **`ui/mac/MacSwitcher.kt`** | :89, :147 "Your Macs"; :90 "…another Mac needs you"; :172 "Add a Mac" | G as iOS |
| **`ui/shell/MacProfiles.kt`** | :120 "Paired, no Remote shell" | S "Paired, no access yet" |
| **`ui/mac/MacSwitches.kt`** | | |
| :18 | fix label "Pair your Mac" | G "Pair a Mac or PC" |
| :49, :57-59, :63-64, :78-79 | internet row statuses and notes | X on a PC's page; U elsewhere |
| :92, :96, :102-103, :151 | Keep awake / VPN blocks | X |
| **`ui/mac/ActivityScreen.kt`** | :103, :107, :109, :122 | as iOS `ActivityTab` |
| **`ui/mac/VpnOffDialog.kt`** :52 | VPN | X |
| **`ui/MainTabs.kt`** :75 | tab "Mac" | "Mac" / "PC" / "Computer" as iOS |
| **`ui/PairSheet.kt`** | :82-83 U; :115 "…Each Mac gets its own key…" | G |
| **`ui/PhoneScreen.kt`** | | |
| :95 | back label "Mac" | follows the tab |
| :112 | "Traffic between the Mac and this phone travels only over the USB cable. The Mac's connections are opened by this phone's own network stack." | U |
| :136 | "Waiting for a Mac on USB" / "Serving 1 Mac over USB" | G "Waiting for a computer on USB"; "Serving…" counts Macs only |
| :140 | "USB internet for your Mac" | U |
| :173 | "Ready. Plug in your Mac and connect from the menu bar." | G "Ready. Plug in your Mac or PC." |
| :196 | "The Mac reaches this phone through Android's USB debugging bridge. …" | G "A computer reaches…" |
| :210 | "Pair your Mac" | G |
| :227 | "*n* Macs" / "Mac" (flow map) | U |
| :320 | "Paired Macs" | G "Paired computers" |
| :333, :336 | already "Mac or PC" | U |
| :365 | "Forget this Mac" | N |
| **`ui/SettingsScreen.kt`** | :120 "Name shown on the Mac"; :137 cellular; :163, :165 Remote shell; :172, :183-184 connect and address; :205, :258-259 forget all; :219, :248 log and about | G as the iOS settings rows; :137 U |
| **`ui/lock/LockGate.kt`** | :311 "Locking doesn't stop sharing with your Mac."; :357-359, :408 "Your Macs and Remote shell stay private…", "A Mac just shared Remote shell with this phone. …" | :311 U; others G "Your computers and Remote shell…", "A computer just shared its shell with this phone. …" |
| **`service/ServingNotification.kt`** | :33 "Waiting for a Mac on USB"; :35 "Serving *n* Macs over USB"; :37 "Connect from Passthrough in the Mac's menu bar." | G "Waiting for a computer on USB"; counts Macs; "Plug in your Mac or PC." |
| **`service/PassthroughService.kt`** :108, **`service/ShellKeyVault.kt`** :293, **`core/ControlServer.kt`** :114-115, **`core/Pairing.kt`** :243 | log lines | G as the Swift logs |

### 4. The PC's page: state machine

One pure reducer per platform. Swift: `Packages/PassthroughCore/Sources/PassthroughCore/HostPage.swift`. Kotlin: `android/.../ui/shell/HostPage.kt`.

```swift
public enum HostReach: Equatable, Sendable {      // mirrors ShellModel.Reach / ShellReach
    case noAccess, locked, needsPasscode, keyUnavailable, connecting(redialing: Bool), unreachable, ready(ShellPath?)
}
public enum RelayHealth: Sendable { case unknown, answering, silent }

public struct HostPageInput: Sendable {
    public var kind: HostKind
    public var reach: HostReach
    public var paired: Bool                 // a PairedClient exists
    public var granted: Bool                // it has a shell grant
    public var accessRefused: Bool          // `not_authorized` while holding a credential
    public var host: HostFacts?             // live, else last stored
    public var farewell: HostFarewell?
    public var lastHeard: Date?
    public var connectingSince: Date?
    public var triedFromAnywhere: Bool      // this connect also dialed iroh
    public var relay: RelayHealth
    public var shellRefusal: ShellError?    // signed_out / shell_not_allowed from the last open
    public var viewerScreens: Set<String>   // screen backends this app has for this kind
    public var now: Date
}

public enum HostPageState: Equatable, Sendable {
    case connected(ShellPath?)
    case connecting, reconnecting           // `canRetry` below
    case unreachable                        // cause unknown
    case wentToSleep(at: Date), turnedOff(at: Date), shutDown(at: Date)
    case noRelay
    case revoked
    case pairedNoAccess
    case locked, needsPasscode, keyUnavailable     // the phone's own; wording as today with the noun swapped
}
public enum HostShellState: Equatable, Sendable { case available, nobodySignedIn, someoneElseSignedIn, appNotOpen, switchedOff }
public enum HostScreenState: Equatable, Sendable {
    case available            // a Mac, or a PC once stage 6 is in
    case notInThisVersion     // the host offers only backends this app lacks
    case switchedOff, remoteDesktopOff, windowsHome, noPassword, remoteDesktopProblem
    case none                 // nothing offered and no reason given: no row
}
public struct HostPage: Equatable, Sendable {
    public var state: HostPageState
    public var shell: HostShellState
    public var screen: HostScreenState
    public var canRetry: Bool
    public static func make(_ input: HostPageInput) -> HostPage
}
```

`ShellModel.page: HostPage` builds the input from its published fields; views read `page` and ask `HostCopy` for the sentence. For a Mac, `make` returns states whose `HostCopy` sentences are today's, so `MacHeroCard` and `RemoteShellCard` can read `page` for both kinds.

**Transitions for `state`**, first match wins:

1. `reach == .locked / .needsPasscode / .keyUnavailable` → the same-named state.
2. `reach == .noAccess`: `accessRefused` → `.revoked`; else `.pairedNoAccess`.
3. `reach == .ready(p)` → `.connected(p)`.
4. `reach == .connecting(redialing)` → `.reconnecting` if redialing else `.connecting`; `canRetry = now − connectingSince ≥ 30 s`.
5. `reach == .unreachable`: a `farewell` with reason `sleeping` → `.wentToSleep`, `turned_off` → `.turnedOff`, `shutting_down` → `.shutDown`; else `triedFromAnywhere && relay == .silent` → `.noRelay`; else `.unreachable`. `canRetry = true`.

**`shell`** (meaningful when `state == .connected`): `host.access?.shell == false` or `shellRefusal == .shellNotAllowed` → `.switchedOff`; `host.signedIn == false` or `shellRefusal == .signedOut` → by `host.console`: `.signedOut` → `.nobodySignedIn`, `.otherUser` → `.someoneElseSignedIn`, anything else (including no `host`) → `.appNotOpen`; else `.available`. A later `host` with `signedIn: true` clears `shellRefusal`.

**`screen`**: kind `mac` → `.available` (today's behaviour, the Mac's own refusals stay where they are). Kind `windows`: `host == nil` → `.notInThisVersion` if `viewerScreens` is empty, else `.none`; `host.screens ∩ viewerScreens` non-empty → `.available`; else if `viewerScreens` is empty and `host.screens` is non-empty → `.notInThisVersion`; else by `host.rdp`: `edition` → `.windowsHome`, `off` → `.remoteDesktopOff`, `account` → `.noPassword`, `service` or `exposed` → `.remoteDesktopProblem`; else `host.access?.screen == false` → `.switchedOff`; else `.none`. In this stage `viewerScreens` for `windows` is the empty set (one constant, `ScreenBackends.supported(for:)`, which stage 6 changes to `["rdp"]`), so a PC's row reads `.notInThisVersion` whenever the PC offers a screen, and `.windowsHome` etc. only when it offers none. All branches are implemented and tested now.

**Every row of MP §1 "The phone's page for a PC", and what produces it:**

| MP row | `HostPage` | Inputs, and the code that sets them | Shown by | Action |
|---|---|---|---|---|
| Connected | `.connected(path)` | `reach = .ready` at `ShellModel.swift:725`; `path` at `:728` | hero title "Reachable", detail by path (`MacHeroCard.swift:63-68`, unchanged strings) | shells card, **New shell**, Screen row |
| Connecting / redialling | `.connecting` / `.reconnecting` | `reach = .connecting` at `:500` and `:994`; `isRedialing` (`:382`); new `connectingSince` set in `reach.didSet` | hero + `RemoteShellCard.swift:52-58` | **Try again** when `canRetry` (new; calls `shell.connect()`) |
| Can't reach, cause unknown | `.unreachable` | `reach = .unreachable` at `:846`; `lastHeard` (`:330-333`) | hero's amber box (`MacHeroCard.swift:91-108`) with `HostCopy.unreachable` | **Try again** (exists) |
| The PC said it was going to sleep | `.wentToSleep(at:)` | new `.goingAway("sleeping")` event → `farewell` stored; then the drop → `.unreachable`. `host.sleepAfterSeconds` from the stored facts | same box, `HostCopy.wentToSleep` | **Try again** |
| The PC said Remote access was turned off | `.turnedOff(at:)` | `.goingAway("turned_off")` | same box, `HostCopy.turnedOff` | **Try again** |
| (not in MP's table) the PC said it was shutting down | `.shutDown(at:)` | `.goingAway("shutting_down")` | same box, `HostCopy.shutDown` | **Try again** |
| No relay, away | `.noRelay` | `clientTriesIroh` (`:140`, `:491`); new `relayHealth` from the relay check below | same box, `HostCopy.noRelay` | **Try again** |
| Access revoked | `.revoked` | `.failed(.notAuthorized)` at `:825-827` now also sets `accessRefused = true` (cleared by the next `ready` or a new grant in `refresh`) | hero title "No access"; `HostCopy.revoked`; no steps | none |
| Paired, no access yet | `.pairedNoAccess` | `reach = .noAccess` with the selection kept (`idleOnMacWithoutShell`, `:919-930`); kind from `PairedClient.hostKind` | hero "Paired" + setup card with the PC's steps (`MacHomeView.swift:118`, `:645-656`) | steps (§6) |
| Shell: nobody signed in | `shell == .nobodySignedIn` | `host.signedIn == false`, `host.console == .signedOut`; or `.openFailed(.signedOut)` at `:786-792` → `shellRefusal` | a notice in the shells card in place of the list and the New shell control | **Open the screen**: hidden in this stage (`screen != .available`) |
| Shell: someone else signed in | `.someoneElseSignedIn` | `host.console == .otherUser` | same | same |
| Shell: Passthrough closed there | `.appNotOpen` | `host.signedIn == false` with console `active`/`locked`, or `signed_out` with no `host` | same | same |
| Shell switch off | `.switchedOff` | `host.access.shell == false`, or an `open` refused `shell_not_allowed` (Corrections 2) | same | none |
| Screen switch off | `screen == .switchedOff` | `host.access.screen == false` (and, from stage 6, `screen_not_allowed` to `rdp`) | Screen row, dimmed, sentence under it | none |
| Remote Desktop off | `.remoteDesktopOff` | `host.rdp == "off"` | Screen row | none |
| Windows Home | `.windowsHome` | `host.rdp == "edition"` | Screen row, dimmed | none |
| Account has no password | `.noPassword` | `host.rdp == "account"` | Screen row | none |
| App too old | `.notInThisVersion` | `host.screens` has nothing in `ScreenBackends.supported(for: .windows)` | Screen row, dimmed | none |

**The relay check.** When a connect ends in `.unreachable`, `clientTriesIroh` was true and the credential has a custom `irohRelay`, `ShellModel` runs `RelayCheck.answers(url:)` once: a TLS connection (`NWConnection`, system trust, 3 s limit) to the relay URL's host and port (443 when none). Reaching `.ready` means `.answering`; failure or time-out means `.silent`. Nothing is sent after the handshake, and the relay token is never used. With n0's default relays (no `irohRelay`) the check is skipped and `relayHealth` stays `.unknown`. The result is cleared on the next `connect()`. Android: the same with `SSLSocket` on `Dispatchers.IO`. `RelayCheck` sits behind a one-method protocol so `HostPage` tests never touch the network.

**The page's layout for a PC** (iPhone; the iPad grid follows the same rules):

1. Hero: a desktop figure in place of the laptop (`HostFigure(kind:)` wraps `MacFigure`, `MacHeroCard.swift:183-269`, and draws SF Symbol `pc` in the same 104×76 frame, dimmed with a "z" when asleep; no Keep awake glow). Title and detail from `page.state`. The battery line shows when `macState.battery` is present, with the caption "64%, charging" or "64% on battery" only (no Keep awake limits).
2. Needs-you cards: unchanged.
3. One card: **Screen lock** row when `macState.locked != nil` (button **Lock**, enabled whenever reachable; `control` is not consulted for a PC), then the **Screen** row (title "Screen", sentence from `page.screen`, disabled and at 0.55 opacity unless `.available`). No Internet, Keep awake, VPN or Share screen rows. `controlBlock` is nil for a PC; `reachBlock` (`MacHomeView.swift:552-563`) shows with PC wording.
4. Setup card when `page.state == .pairedNoAccess`.
5. Shells card when connected: the notice for `page.shell != .available`, else the list and the control of §5.

`MacHomeView` keeps its name and file in this stage; its body branches once on `shell.selectedKind` into `macRows` (today's) and `pcRows`. Renaming files and types from `Mac…` to `Host…` is left out (it would bury the change in a rename).

**The screen gate (must-not-regress).** Three places, all keyed on the effective kind:

* `ShellModel.canOpenScreen: Bool { page.screen == .available }`. The Screen row, the iPad `ScreenCard` and `RemoteShellCard`'s "See and control the screen" row are disabled without it; `ShellRouter.showScreen` is set only through `router.openScreen(shell)` which checks it.
* `ScreenModel.begin` (`ScreenModel.swift:194`): first statement after the demo hook: if `shell.kind(of: selected) != .mac`, set `phase = .failed(HostCopy.screenSentence(…))` and return. No connection is made.
* `ScreenModel.fallBackToScreenSharing` (`:294`) and `useScreenSharing` (`:311`): the same guard, so even a kind learned late (a `host` arriving on the screen connection, which `ScreenModel.handle` now records) cannot reach `.confirmScreenSharing` or `.login`.

`ShareScreenSheet` and `canShareScreen` (`MacHomeView.swift:465`) count and list only credentials whose kind is `.mac`, on both sides.

### 5. The split New shell control

Shown as a split control when `host.shells.count > 1`; otherwise it is today's button, unchanged (so a Mac that lists one shell or none looks as it does now).

**iOS** (`iOS/App/Shell/NewShellControl.swift`, new):

```swift
struct NewShellControl: View {
    enum Style { case prominent, inline, toolbar }      // the three looks used today
    let shells: [HostShell]
    let preferred: HostShell?                           // ShellModel.preferredShell(for:)
    let hostName: String
    let style: Style
    let open: (String?) -> Void                         // nil: let the host choose
}
```

* Layout: one capsule holding two buttons separated by a hairline. Leading: `Button { open(preferred?.id) }` with the label "New shell" and, under it in `.caption`, the preferred shell's name ("PowerShell"). Trailing: `Menu { ForEach(shells) { Button($0.name) { open($0.id) } }; Section { Text("Shells open as you, never as administrator.") } } label: { Image(systemName: "chevron.down") }`. The checked item is the preferred one (`Label` with a checkmark). Each half is at least 44×44 pt. At accessibility text sizes the caption moves under the title and the capsule grows; nothing truncates before two lines.
* `.toolbar` style (Shells tab `+`, the terminal's `+`): a `Menu` with `primaryAction: { open(preferred?.id) }`, so a tap opens the preferred shell and a long press (or the menu action for assistive tech) shows the list.
* Accessibility (MP §1 "Accessibility": the chooser is an accessibility action on New shell):
  * Leading button: label "New shell", value the preferred shell's name, hint "Opens *PowerShell* on *Office-PC*", and `.accessibilityActions { ForEach(shells) { s in Button("New \(s.name) shell") { open(s.id) } } }`, so VoiceOver's actions rotor and Switch Control's menu reach every shell from the one element.
  * Trailing menu: label "Choose a shell", hint "*n* shells on *Office-PC*". It stays a separate element so Voice Control ("Tap Choose a shell") and pointer users have it.
  * The footnote is read as the last item of the menu.
  * After an open is refused with `signed_out`, the notice that replaces the control is posted with `AccessibilityNotification.Announcement`.
* Wiring: `TerminalIntent.new` becomes `.new(shell: String?)` with the same `id` "new" (`TerminalScreen.swift:7-13`); `TerminalController.start` passes it to `shell.newSession(cols:rows:shell:)` (`:139`); `controller.newSession()` (`:146`) takes a shell id. `ShellModel.newSession` records the id in `shell.lastShell` for the connected computer when it is non-nil.
* Replaces: `MacHomeView.swift:597`, `:607-614`; `RemoteShellCard.swift:77-80` (and its label becomes "New shell" for both kinds, see Decisions 8); `RootView.swift:371-372`; `TerminalScreen.swift:290-302`, `:388-389`.

**Android** (`ui/shell/NewShellControl.kt`, new):

```kotlin
@Composable fun NewShellControl(shells: List<HostShell>, preferred: HostShell?, hostName: String, enabled: Boolean, onOpen: (String?) -> Unit)
```

* A `Row` clipped to the pill shape of `ShellPillButton` (`RemoteShellCard.kt:221-232`): a leading clickable segment ("New" with the preferred shell's name beside it in the secondary colour) and a trailing `IconButton(Icons.Filled.ArrowDropDown)` that opens a `DropdownMenu` of `DropdownMenuItem`s, followed by a `Text("Shells open as you, never as administrator.")` in the menu's column (a real footer; not focusable as an action). Both segments use `Modifier.minimumInteractiveComponentSize()` (48 dp).
* Accessibility: the leading segment has `Role.Button`, `contentDescription = "New shell"`, `stateDescription = preferred.name`, and `customActions = shells.map { CustomAccessibilityAction("New ${it.name} shell") { onOpen(it.id); true } }` so TalkBack's actions menu holds the chooser. The trailing button has `contentDescription = "Choose a shell"`. The selected item sets `selected = true` in its semantics. A refusal notice uses `liveRegion = LiveRegionMode.Polite`.
* Wiring: `onOpen: (String?) -> Unit` in `RemoteShellCard` (`:79`, `:103-107`) becomes a pair, attach by id or open by shell; `ShellViewModel.newSession(cols, rows, shell: String? = null)` (`ShellViewModel.kt:560`).

**Session rows.** `RemoteShellCard.status` (Swift, `RemoteShellCard.swift:181-197`) and `ShellFormat.status` (Kotlin, `ShellLogic.kt:138-143`) gain a `shellName: String?` parameter and prefix it: "Ubuntu · running · 4m". The name is `host.shells.first { $0.id == session.shell }?.name` where `session.shell` is the field asked for in Corrections 3; with no such field, the phone uses what it remembers of the sessions it opened itself (`[sessionID: shellID]`, in memory, filled when `opened` answers an open that named a shell) and shows no prefix otherwise.

### 6. Pairing and the PC's setup steps

**What happens underneath** (unchanged): the PC reaches the phone's control port over the cable only while `PassthroughService` runs. On an iPhone that means the tunnel extension (background) or the app itself (foreground hosting); on Android the foreground service.

**The pairing sheet** cannot know what kind of computer will type the code, so it speaks of "the computer" and of the *cable link* (table above). When iOS has no VPN configuration saved yet (`ExtensionHost` loaded no manager: a new `AppModel.cableLinkNeedsVPNPrompt`, true when hosting is `background`, the extension is available and `TunnelController` holds no manager after `load()`, `TunnelController.swift:15-19`), the card under the button adds: "iOS asks to add a VPN configuration. That is how the cable link works in the background. Nothing is sent through it for a PC; a Mac's internet goes through it only while you share." Once a configuration exists the line is gone.

**The setup steps for a PC** (`HostCopy.setupSteps(w, paired:, cableLinkOn:)`, shown by `ShellSetupSteps` in the setup card, the Shells tab and Settings):

| # | Title | Detail | Done when |
|---|---|---|---|
| 1 | "Pair this iPhone with your PC" | "Done." / "In the iPhone tab, tap Pair under Paired devices, then Pair a Mac or PC." | a client is paired |
| 2 | "Turn on Remote access on your PC" | "On the PC, open Passthrough's Settings, go to Remote access and choose Turn on. Windows asks for an administrator once." | never ticked by the phone (it can't see it) |
| 3 | "Plug this iPhone in once" | cable link on: "Plug this iPhone into the PC with Passthrough open here. The PC then appears with its shells." Cable link off: "The cable link is off." with the button **Turn on the cable link** (calls `model.start()`), and under it, only while `cableLinkNeedsVPNPrompt`: "iOS asks to add a VPN configuration. That is how the cable link works; no traffic is sent through it for a PC." (MP §1 moment 6, verbatim) | a grant arrives (the card goes away) |

Android: step 3 reads "Start sharing with the power button on This phone, then plug this phone into the PC." (Android's switch is the foreground service; there is no VPN prompt). iPad: step 3 reads "With Passthrough open, plug this iPad into the PC." (an iPad already serves the cable from the app, `AppModel.swift:149-153`; no button, no prompt).

With nothing paired, the steps are the generic three ("Pair this iPhone with your Mac or PC", then "Turn on Remote shell (Mac) or Remote access (PC) there", then "Plug in once").

**Is "Turn on the cable link" feasible without the VPN configuration?** Yes, with a cost.

* How: `InProcessHost` runs the identical `PassthroughService` in the app (`ProxyHost.swift:56-94`). Hosting set to *Foreground only* (`AppModel.Hosting`, `AppModel.swift:10-14`) already does this, and an iPad always does.
* What it costs: the link exists only while Passthrough is on screen. Pairing and the first grant happen with the app open, so they work. What is lost is renewal while the app is closed: a PC grants a fresh key on each cable connection, and after stage 4 changes the PC's TLS key, phones are re-granted "on their next cable connection" (MP §3 stage 4); without the extension that needs the app open while plugged in. The old key keeps working until the new one is proved (`protocol/README.md:41`), so nothing breaks; a stale certificate pin after stage 4's hand-over is the one case that would, and its fix is "open Passthrough and plug in".
* Two more things to get right if it is used: `InProcessHost` must not hold the screen awake when no Mac is paired (`ProxyHost.swift:76-79` does so for every iPhone), and the two hosts must never run together (both bind 7890/7891).
* What this stage does: keeps MP's decision (the extension, with the prompt explained) as the default, and adds the in-app path only as the fix when iOS refuses the configuration. `AppModel.friendly` (`AppModel.swift:348-354`) today names "foreground hosting" in words; the failed state now carries a fix button **Use it only while Passthrough is open**, which sets hosting to foreground and starts. `InProcessHost.start` sets `isIdleTimerDisabled` only when a Mac is paired. Making the in-app path the default for a phone with no Mac paired is an open question for the owner (it removes the VPN prompt and the status-bar VPN badge for PC-only users).

**What the tunnel extension does when the host is a PC:** nothing different, by design. It answers the PC's control channel, stores the grant sealed for the app, records `hostKind`, and sends `status`. Its SOCKS5 server listens and is never used. The only code change in `iOS/Tunnel` is none; the change is in `ControlServer` (kind recorded, log wording).

### 7. Compatibility

| Phone (new build) against | What happens |
|---|---|
| Today's Mac: no `host`, no `hostKind` | Kind resolves to Mac. `hostFacts == nil`: plain New shell; `open` has no `shell` key (asserted byte-for-byte in a test); no farewell is ever received, so "can't reach" reads as today; Keep awake, VPN, Screen, Share screen, widget, Live Activity and intents unchanged. `HostCopy`'s Mac variants are today's sentences (test). The only visible differences for a Mac-only user: "Your computers" / "Add a computer" in the switcher, "Pair a Mac or PC" on buttons, the pairing sheet's "cable link" wording, generic settings footers, and "New shell" in place of "New session". |
| A Mac from stage 1 on: `host` with `kind: mac` | As above. If it lists more than one shell the split control appears; `access`, `signedIn`, `console` are honoured if sent. `rdp` is ignored for a Mac. |
| A PC that sends `hostKind` on the grant but no `host` (not expected) | PC wording from the stored kind; plain New shell; no shell-state sentence until an `open` is refused; Screen row "not in this version"; never the Mac screen path. |
| A computer that sends neither (a Windows build from before stage 1) | Read as a Mac. It cannot grant a shell, so the page stays at "Paired" with the Mac's steps. Fixed by rebuilding the PC after stage 1; Corrections 1 closes the paired-but-not-granted gap for builds from stage 1 on. |
| A `host` naming a kind this build doesn't know | Neutral "computer"; shells only. The envelope still decodes because `kind` is read as a string. |
| An older phone build against a new Mac or PC | Not this stage's code: stage 1 guarantees it (`host` only after `ready`; unknown messages dropped at `ShellClient.swift:786-787`; unknown errors become `bad_request`). Stage 2 re-runs the check by hand because MP's done-when for stage 2 names it. |
| Downgrading the phone app | Old builds ignore `hostKind`, `shell.hostFacts`, `shell.farewells`, `shell.lastShell`. |

### 8. Widget, Live Activity, notification text, App Intents

* **`MacSnapshot`** (`iOS/Shared/MacSnapshot.swift`): add `var hostKind: HostKind?` (absent = Mac) and `var note: String?` (one short line, set for a PC whose shell can't start: "Sign in needed"). `MacActivityController.Seen` gains `kind`; `writeSnapshot` (`MacActivityController.swift:194-211`) copies it; `RootView.seen(reachable:)` (`RootView.swift:240-244`) and the watched-computer path (`:339-345`) pass `shell.kind(of:)`. `looksSame` compares the new fields as part of `==`.
* **`MacWidget`**: the `kind` string "MacWidget" stays (changing it would remove placed widgets). Display name "Mac" → "Computer"; description → "Your computer's shells, and a Mac's awake time, as Passthrough last saw them." For a PC snapshot: icon `pc`; the large line is "Last heard 14:02" when stale, else "Reachable"; never "Awake", "Plugged in" or "Sleeps as usual"; the detail line is `note` if set, else battery (if any) · shells · time as today. Empty state: "Open Passthrough to see your computer here." Placeholder unchanged. The link stays `passthrough://mac?mac=<id>` (`AppLink.swift:24`), which already means "this paired computer".
* **Live Activity**: starts only from Keep awake, which a PC's page does not have, so none is ever started for a PC. No code change beyond `Seen.kind`. A running activity for a Mac keeps following that Mac when a PC is selected (existing behaviour, `MacActivityController.swift:119-148`).
* **Control Center controls** (`PassthroughWidgets.swift:24-48`): unchanged; they are a Mac's features.
* **Notification extension**: no change. The placeholder is the host's text and a PC sends no notices in this plan (`pushState on:false`). When a PC later sends them, it writes "Something on your PC needs a look." itself; `PushNotice.macName` stays the JSON key. The phone-side change is in Settings only (the :188 row above), keyed on kind rather than on `macSendsNotices == false` alone.
* **App Intents and their links** (`AppIntents.swift`, `RootView.swift:269-283`): Keep awake and VPN act on a Mac. New pure function in Core:

  ```swift
  extension AppLink {
      public enum ControlTarget: Equatable { case selected, switchTo(String), none }
      /// Where a keep-awake or VPN link runs: the selected computer if it is a Mac; else the only paired Mac with shell access; else nowhere.
      public static func controlTarget(selected: String?, kinds: [String: HostKind], withShell: [String]) -> ControlTarget
  }
  ```

  `.selected` → today's path. `.switchTo(id)` → `shell.select(id)`, then today's path (the link already waits for the Mac to be reachable, `RootView.swift:271`). `.none` → `links.done()` and `links.note = "Keep awake and the VPN are a Mac's. Choose a Mac under Your computers, then try again."` Intent titles, phrases and descriptions are unchanged.
* **Session and `mac` links** to a PC work as today: they select the computer and attach.

### Threading, errors, timeouts

* `ShellModel`, `MacWatcher`, `ScreenModel` stay `@MainActor`; `ShellClient` keeps its `work` queue and delivers the two new events on the callback queue like the rest.
* `PairingRegistry.noteHostKind` is called from the control server's queue (extension or app) and from the main actor; the registry lock covers both (`Pairing.swift:96`).
* Persisted maps are written only from the main actor (iOS) / the view model's scope (Android).
* A `host` line that fails to decode is dropped by the existing `try?` (`ShellClient.swift:667`); the page behaves as "never sent `host`". `HostFacts` decoding is lenient field by field (a wrong type in one optional field does not lose the rest): custom `init(from:)` using `try?` per field.
* Relay check: 3 s, one attempt per failed connect, cancelled by `connect()` and `dropConnection()`.
* "Try again after 30 s" while connecting: a `TimelineView(.periodic(by: 5))` around the button reads `page.canRetry`; no timer in the model.
* A farewell is trusted only from a connection that reached `ready` (it is an event of the winning attempt). It is displayed only while unreachable and dropped at the next `ready`.

## Pull requests, in order

All against `dev`. PRs 3 and 4 depend on 1 and are independent of each other and of 2.

### PR 1: Phones know a PC: the host's kind and what it says about itself (iOS core)

*Scope.* Portable Swift only, plus the smallest app wiring that keeps behaviour identical for a Mac. No visible change except log wording.

*Files added.* `Packages/PassthroughCore/Sources/PassthroughCore/Host.swift` (`HostKind` if stage 1 has not added it, `HostFacts`, `HostShell`, `HostFarewell`, `Hosts.kind`, cleaning), `HostWords.swift`, `HostCopy.swift`, `HostPage.swift`, `RelayCheck.swift` (protocol + `NWConnection` implementation).

*Files changed.* `Pairing.swift` (`PairedClient.hostKind`, `noteHostKind`, log line), `ControlServer.swift` (record kind on `auth`, `paired`, `shellGrant`; `ConnectedMac.host`; log lines; default name), `Protocol.swift` (`ProviderStats.connectedMacs` excludes PCs; `connectedPCs`, `connectedComputers`), `ShellCredentials.swift` (`build` copies the kind), `ShellClient.swift` (`open(…shell:)`, `.host`, `.goingAway`), `ShellProtocol.swift` (only what stage 1 left out of the Swift types: `ShellError.signedOut`, `.shellNotAllowed`), `MacProfiles.swift` (`statusText(_:now:kind:showKind:)`), `AppLink.swift` (`controlTarget`). App: `ShellModel.swift` (new published fields, storage of facts and farewells, `accessRefused`, `connectingSince`, `newSession(…shell:)`, `page`, pruning), `MacWatcher.swift` (`Seen.host`), `AppModel.swift` (`connectedComputers` in `tick`, `connectedComputerIDs`). `protocol/fixtures.json`: section `hostCopy`.

*Tests added* (`Packages/PassthroughCore/Tests/PassthroughCoreTests/`): `HostFactsTests` (cleaning and limits; lenient decode; unknown kind), `HostKindTests` (`Hosts.kind` precedence; old `PairedClient` JSON decodes with nil kind; new JSON read by a struct without the field), `HostWordsTests`, `HostCopyTests` (fixture vectors; the Mac variants equal today's literals, listed in the test), `HostPageTests` (one test per row of the table in §4, plus precedence: farewell beats relay, refusal beats host facts until a newer `host`), `AppLinkTests` additions (`controlTarget`), `MacProfilesTests` additions (kind prefix), `ShellGrantTests` additions (`shellGrant` with `hostKind` stores it; without it leaves nil; an iPad id is never given a host kind), `ControlAuthTests`/`CoreTests` additions (`hello.hostKind` recorded only after `auth` succeeds). In `Tests/ShellHostTests/`: `ShellClientHostTests` (a scripted `ByteStream`: `ready` then `host` → `.host`; `host` before `ready` → protocol violation, the attempt ends; going-away → `.goingAway` then `.disconnected`; `open` with a shell encodes `"shell":"…"`, without one the line equals today's fixture line `{"t":"open","cols":80,"rows":24,"ref":1}` modulo key order; `error signed_out` with `ref` → `.openFailed(.signedOut)`).

*Docs.* `CHANGELOG.md` (Unreleased: "The phone apps keep what kind of computer each paired one is. Nothing to do when you rebuild."). `protocol/README.md`: one paragraph under "Remote shell" on what a phone does with `host` (kept per computer, cleaned, never trusted before `ready`), if stage 1 did not write it.

*Verify by hand.* Build and run against today's Mac: every screen reads as before; the log view says "Paired *name*". `-PTDemoShell ready` unchanged.

*Leaves out.* All UI.

### PR 2: Phones know a PC: its page, its words and the shell chooser (iPhone and iPad)

*Scope.* Everything a person sees in the iOS app.

*Files added.* `iOS/App/Shell/NewShellControl.swift`, `iOS/App/Home/HostFigure.swift`.

*Files changed.* `MacHomeView.swift` (branch into `macRows`/`pcRows`; Screen row by `page.screen`; lock row for a PC; Try again while connecting; switcher label), `MacHeroCard.swift` (title, detail and amber box from `page` + `HostCopy`; figure by kind), `MacSwitcher.swift` (titles, kind prefix, icon), `ShareScreenSheet.swift` (Macs only), `RemoteShellCard.swift` (statuses, steps by kind, shells notice, session prefix, control), `RootView.swift` (tab label and icon by kind; `router.openScreen`; `runPendingLink` uses `controlTarget`), `TerminalScreen.swift` (`.new(shell:)`, the two `+` buttons, name fallback), `ShellHistoryView.swift`, `ActivityTab.swift`, `SettingsView.swift`, `PairSheet.swift` (cable link wording, VPN-prompt line), `ThisPhoneView.swift` (paired list icons and "Forget this PC", PC-only status lines), `HotspotCard.swift`, `AppModel.swift` (`cableLinkNeedsVPNPrompt`; fix button on a refused configuration), `ProxyHost.swift` (`InProcessHost` keeps the screen awake only when a Mac is paired), `TunnelController.swift` (`hasSavedConfiguration`), `ScreenModel.swift` (the three guards of §4; "Choose a computer first."), `ShellModel.swift` (`ShellError.message(_ w: HostWords)`; `Reach.message` through `HostCopy`; demo PC), `Info.plist` (two usage strings).

*Tests added.* `PassthroughCoreTests/HostWordingTests.testNoStrayMacLiterals` (the source scan over `iOS/App`, `iOS/Shared`). Additions to `HostCopyTests` for the setup steps (cable link on/off, prompt needed or not, iPad). `HostPageTests`: the gate (`screen != .available` for every windows input in this stage).

*Docs.* `CHANGELOG.md` ("Works now: a paired PC shows as a PC… Not yet: a PC can't grant a shell until the Windows app's next stage; its screen comes later."). `docs/GUIDE.md` §Windows (what the phone shows for a PC; the cable link and the VPN prompt), §Remote shell "Several Macs" → "Several computers". `README.md`: the phone-app paragraph says "Mac or PC" where it lists what the app shows.

*Verify by hand.* The checklist under *Tests*.

*Leaves out.* The widget; Android; any screen viewer; renaming `Mac…` types and files.

### PR 3: Phones know a PC: the widget, links and shortcuts

*Scope.* `iOS/Shared/MacSnapshot.swift`, `iOS/Widgets/MacWidget.swift`, `iOS/App/Home/MacActivityController.swift`, `iOS/App/Home/AppIntents.swift` (the note), `RootView.swift` (`seen` passes kind and note; if PR 2 has not landed, only this part), `SettingsView.swift` notifications row if not in PR 2.

*Tests added.* `PassthroughCoreTests/AppLinkTests` (already in PR 1) is what covers the links. `MacSnapshot` lives in the app targets, which have no test target; add `HostCopyTests.testWidgetLines` for a new pure `HostCopy.widgetHeadline(kind:reachable:stale:awake:charging:)` and `widgetDetail(…)` moved into Core, and have `MacWidgetView` call them. A JSON test in Core for a `MacSnapshot`-shaped payload is not possible without moving the type; instead `HostWordingTests` scans `iOS/Widgets` too.

*Docs.* `CHANGELOG.md`; `docs/GUIDE.md` (widget paragraph).

*Verify by hand.* Add the widget; select a PC in the demo; the widget shows the PC's name, the `pc` icon, "Reachable"; select a Mac with Keep awake on: unchanged. Run "Keep Mac awake" from Shortcuts with a PC selected and one Mac paired (it switches to the Mac), with two Macs paired (the note), and with a Mac selected (unchanged).

*Leaves out.* A Live Activity for a PC; PC notifications.

### PR 4: Phones know a PC: Android

*Scope.* The Android app, core and UI together (it may be split at review into core and UI on the same lines as PRs 1 and 2).

*Files added.* `core/Host.kt`, `core/HostWords.kt`, `core/RelayCheck.kt`, `ui/shell/HostCopy.kt`, `ui/shell/HostPage.kt`, `ui/shell/NewShellControl.kt`.

*Files changed.* `core/Pairing.kt` (`PairedClient.hostKind`, `noteHostKind`, log), `core/ControlServer.kt` (record kind; logs; default name), `core/Protocol.kt` (`ConnectedMac.host`), `core/ShellProtocol.kt` (what stage 1 left out: `ShellError.SIGNED_OUT`, `SHELL_NOT_ALLOWED`), `core/ShellCredentials.kt` (kind; key-status wording through `HostWords`), `core/ShellConnection.kt` (`open(…, shell)`, `ShellEvent.Host`, `ShellEvent.GoingAway`), `service/AppSettings.kt` (three new maps), `service/ServingNotification.kt`, `ui/shell/ShellViewModel.kt`, `ui/shell/MacWatcher.kt`, `ui/shell/ShellLogic.kt` (`ShellReach.message(words, …)`, `ShellFormat.status(session, now, shellName)`), `ui/shell/MacProfiles.kt`, `ui/shell/RemoteShellCard.kt`, `ui/shell/ShellHistoryScreen.kt`, `ui/shell/TerminalScreen.kt`, `ui/shell/ShellDemo.kt` (a demo PC), `ui/mac/MacScreen.kt` (PC rows: status card, lock, shells; no internet/awake/VPN rows; Try again while connecting), `ui/mac/MacSwitcher.kt`, `ui/mac/MacSwitches.kt`, `ui/mac/ActivityScreen.kt`, `ui/MainTabs.kt`, `ui/PhoneScreen.kt`, `ui/PairSheet.kt`, `ui/SettingsScreen.kt`, `ui/lock/LockGate.kt`.

*Tests added* (`android/app/src/test/java/dev/dpatel/passthrough/`): `core/HostTests.kt` (cleaning, lenient decode, kind precedence, old JSON), `core/HostWordsTests.kt`, `ui/shell/HostCopyTests.kt` (the same `hostCopy` vectors, with device "phone" rows), `ui/shell/HostPageTests.kt` (the same rows as Swift), `ui/shell/HostWordingTests.kt` (source scan), additions to `core/ShellConnectionTests.kt` (`host` after `ready`, before `ready`, going-away, `open` with and without `shell`, `signed_out`), `core/ShellGrantTests.kt` (`hostKind` stored), `ui/shell/MacProfilesTests.kt` (kind prefix), `ui/shell/ShellLogicTests.kt` (status prefix), `ui/mac/MacSwitchesTests.kt` (no awake/VPN models for a PC).

*Docs.* `CHANGELOG.md`; `docs/GUIDE.md` §Android specifics (a PC's shell on Android; no screen); `android/README.md` if it lists what the app shows.

*Verify by hand.* The Android items of the checklist.

*Leaves out.* Any screen on Android (MP: later).

## Interfaces

### This stage defines (others depend on these): name, shape, owner

| Name | Shape | Owner | Used by |
|---|---|---|---|
| `Hosts.kind(live:stored:)` | Swift and Kotlin, above | this stage | stage 6 (which backend), stage 7 (computers) |
| `PairedClient.hostKind` | optional field in `pairing.clients` | this stage | stage 6, 7 |
| `HostFacts`, `HostShell`, `HostFarewell` (cleaned, storable) | above | this stage (wire originals: stage 1) | stage 6 (`user` pre-fills the sign-in sheet; `console`/`idleSeconds` drive the takeover prompt; `rdp`) |
| `HostWords`, `HostCopy` | above | this stage | stage 6 adds the screen view's sentences to `HostCopy` and converts `iOS/App/Screen/*`; stage 7 uses the nouns for "computers" |
| `fixtures.json` → `hostCopy` | vectors | this stage | stage 6 appends |
| `HostPage`, `HostScreenState`, `ScreenBackends.supported(for:)` | above | this stage | stage 6 sets `["rdp"]` for `windows` and handles `.available` |
| `ShellModel.canOpenScreen`, `router.openScreen` | the single way into the screen | this stage | stage 6 routes a PC to its backend here |
| `ShellClient.open(cols:rows:shell:)`, `Event.host`, `Event.goingAway`; Kotlin equivalents | above | this stage | stage 8's C# port mirrors the event names |
| `RelayCheck` | `func answers(url: String) async -> Bool` | this stage | stage 6 ("via relay" wording) may reuse |
| Stored keys `shell.hostFacts`, `shell.farewells`, `shell.lastShell` | JSON maps by client id | this stage | stage 6 adds its own per-computer keys beside them |

### This stage consumes (from which stage)

All from **stage 1** (protocol groundwork). Its plan was not on disk when this was written; the shapes below are MP §2 "Protocol changes" made concrete. This stage depends on the Swift and Kotlin types, so a different spelling in stage 1 is absorbed in `Host.swift` / `Host.kt` and `ShellClient` / `ShellConnection` only.

1. **`host`** on the shell connection, from the host, after `ready` and again whenever it changes; never before `ready`:
   `{"t":"host","host":{"kind":"windows","os":"Windows 11 Pro","user":"name@outlook.com","signedIn":true,"console":"locked","idleSeconds":840,"shells":[{"id":"pwsh","name":"PowerShell","default":true},{"id":"wsl:Ubuntu","name":"Ubuntu"}],"screens":["rdp"],"rdp":"ready","sleepAfter":1800}}`.
   Consumed: every field listed. `kind` read as a string. `sleepAfter` assumed to be seconds (0 or absent: it does not sleep by itself). `console` is one of `active`, `locked`, `signedOut`, `otherUser`. Expected ordering after `ready`: `macInfo`, `host`, `macState`, `sessions` (MP §2 "Core"); this stage does not depend on the order among them.
2. **`hostKind`** (`"mac"` / `"windows"`), optional, on the control channel's `shellGrant` and on stored credentials (`ShellCredential`, so also `screenPass.pass`). Requested in addition on `hello` (Corrections 1).
3. **`open.shell`**: optional string, a shell id from that host's `host.shells`. Absent: the host's default.
4. **Error `signed_out`** answering `open` (with `ref`).
5. **Going away**: a line from the host on live connections saying why it is leaving, assumed `{"t":"goodbye","reason":"sleeping"}` with reasons `sleeping`, `turned_off`, `shutting_down`, followed by the connection closing. Unknown reasons are stored and shown as "can't reach, cause unknown".
6. **What a PC answers to Mac-only requests** (MP §2 table): relied on for `events` → empty `eventList` (Activity tab), `push` → `pushState on:false` (Settings row), `macState` with `battery`, `charging`, `locked`, `control:false` (page rows). This stage never sends `setAwake`, `setVPN`, `screen`, `screenVideo` or `screenGrant` to a `windows` host.
7. Requested additions (Corrections 2 and 3): `host.access` and/or error `shell_not_allowed`; `sessions[].shell`.

Nothing is consumed from stages 3 to 9. Stage 3 is the first that can exercise this stage's PC paths end to end.

## Tests

**Swift (`swift test` in `Packages/PassthroughCore`)**: `HostFactsTests`, `HostKindTests`, `HostWordsTests`, `HostCopyTests`, `HostPageTests`, `HostWordingTests`, `ShellClientHostTests`, and the additions to `ShellGrantTests`, `MacProfilesTests`, `AppLinkTests`, `CoreTests` named under each PR. `ProtocolFixtureTests` gains `testHostCopyVectors`.

**Kotlin (`./gradlew testDebugUnitTest lintDebug`)**: `HostTests`, `HostWordsTests`, `HostCopyTests`, `HostPageTests`, `HostWordingTests`, and the additions to `ShellConnectionTests`, `ShellGrantTests`, `MacProfilesTests`, `ShellLogicTests`, `MacSwitchesTests`.

**Fixtures added**: `hostCopy` (about 45 vectors: each `HostCopy` key × `mac`/`windows` × device `iPhone`/`iPad`/`phone` where the sentence names the device). The wire fixtures (`host`, `open` with `shell`, `signed_out`, going-away, `shellGrant` with `hostKind`) are stage 1's; this stage's client tests replay those lines.

**Cases that must exist by name** (the ones most likely to be skipped):

* `open` without a shell encodes exactly as before stage 2.
* A `PairedClient` JSON written before this stage decodes, and its kind is Mac.
* `host` before `ready` ends the attempt and stores nothing.
* A `host` with 100 shells, a 10 000-character name, a newline in `user`, and an id with a space is cleaned to the limits and the bad shell is dropped.
* A remembered shell id the host no longer lists is not sent.
* For every `windows` input, `HostPage.screen != .available` while `ScreenBackends.supported(for: .windows)` is empty.
* `noteHostKind` does nothing for an iPad's id.
* `controlTarget` for: Mac selected; PC selected with one Mac; PC selected with two Macs; PC selected with a Mac that has no shell access.

**By hand (no PC host exists yet; uses the demo and today's Mac)**:

1. Today's Mac, iPhone: pair, grant, open a shell, the screen, Keep awake with its Live Activity, the widget, a notification. Nothing reads differently except the generic labels listed in §7.
2. `-PTDemoShell ready` with the demo PC selected: tab reads "PC"; hero "Reachable"; no Internet, Keep awake, VPN or Share rows; Lock row present; Screen row dimmed with its sentence; shells card with the split control listing PowerShell, Windows PowerShell, Command Prompt, Ubuntu, Git Bash; choosing Ubuntu changes the caption; relaunch keeps it.
3. Demo variants (new `-PTDemoShell` values `pcSignedOut`, `pcOtherUser`, `pcAppClosed`, `pcShellOff`, `pcAsleep`, `pcTurnedOff`, `pcNoRelay`, `pcRevoked`, `pcNoAccess`, `pcHome`): each shows its sentence from MP's table.
4. VoiceOver on the split control: "New shell, PowerShell, button"; the actions rotor lists each shell; "Choose a shell" opens the menu and reads the footnote last. Voice Control: "Tap New shell", "Tap Choose a shell". Largest accessibility text size: nothing truncated. The same with TalkBack on Android.
5. With the demo PC selected: tap the dimmed Screen row (nothing opens); open `passthrough://mac?mac=demo-pc` and a session link; run both Shortcuts. `ScreenView` never shows the login or the Screen Sharing question.
6. Fresh install, no VPN configuration: the pairing sheet shows "Turn on the cable link" and the VPN line; tap it, refuse the iOS prompt: the fix button appears and starts the link in the app; the screen dims as usual (no Mac paired).
7. iPad: step 3 has no button and no VPN line.
8. Switcher with a Mac and the demo PC: "Your computers", rows "Mac · Connected · 1 shell open" and "PC · Connected"; with Macs only: no prefix.
9. Android: items 2, 3, 4 and 8 with its demo; the notification reads "Waiting for a computer on USB".
10. An iPhone build from `main` (before this stage) against a Mac from `dev` after stage 1: shell, screen, Keep awake all work.
11. Stage 3's first real-PC run re-does items 2 to 5 against the PC, and adds: `hostKind` on the first grant makes the PC appear as a PC before it has ever been dialed.

## Security considerations for this stage

* **Host-supplied text is shown, never run.** `os`, `user`, shell names and ids come from the host over an authenticated connection, but a host is not the phone. They are length-capped, single-lined and stripped of control characters before they reach a view, VoiceOver, the widget or storage (§2 "Limits"). Nothing from `host` is put on the Lock Screen: the widget's `note` is one of this app's own fixed strings, chosen by state.
* **The shell id sent to the host is always one the host listed on that connection.** The phone composes no id. (The PC resolves ids through its own catalog, MP §2 "Shell chooser"; this is the phone's half.)
* **Kind is not an authority.** It selects words, rows and which screen path may be tried. A computer that lies about its kind gains nothing: a Mac claiming `windows` only hides its own Keep awake and VPN rows; a PC claiming `mac` is asked for `screenVideo` and refuses. The one thing kind protects is the user's Mac password: the gates in §4 mean a host known as `windows` is never offered the Screen Sharing login, including a login saved for another computer (`ScreenLoginStore` is keyed by client id and is read only inside the gated functions).
* **Kind is recorded only from an authenticated peer**: after `auth` or `paired` on the control channel (`ControlServer.swift:181-204`), after `ready` on the shell connection. `hello.hostKind` from an unauthenticated peer is held on the `Peer` and written only once it proves the pairing.
* **A farewell cannot be forged by a stranger** (it is read only after `ready`), and it changes a sentence, never a decision: the app still retries.
* **The relay check** opens a TLS connection to a host the phone already dials for that computer, sends nothing, and never uses the relay token. It runs only after a failed connect, at most once per attempt.
* **Stored facts hold no secret**: `shell.hostFacts` has the account name the host sent (needed later to pre-fill the sign-in sheet). It lives in the app's own defaults, not the App Group shared with the extension, and not the widget's group. It is removed when the computer is forgotten.
* **The in-app cable link** (the refusal fallback) exposes the same loopback ports the extension does, under the same pairing proofs; nothing new listens.
* **Share screen stays Mac to Mac.** A PC is never offered as a viewer or as a screen to share, so no `screenGrant` or `screenPass` reaches a host that would mishandle it.
* **Logs**: the new code logs kinds and states, never `user`, shell names, keys or tokens.

## UX states and strings for this stage

MP §1 gives the sentences for the PC's page; they are used verbatim, with "this iPhone" following the device ("this iPad", "this phone"). Listed here are only the strings this stage adds or decides.

**Hero titles for a PC**: "Reachable" (connected), "Connecting…", "Reconnecting…", "Can't reach it", "Asleep" (went to sleep), "Remote access is off" (turned off), "Shut down" (shut down), "Can't reach it from here" (no relay), "No access" (revoked), "Paired" (no access yet), and the three phone-side titles unchanged ("Unlock to continue", "Needs a passcode", "Plug in to renew").

**Sentences (PC)**

| Key | Text |
|---|---|
| unreachable | "Can't reach *X*. It may be asleep, off, or offline. Last heard 14:02." (MP). Without a last-heard time the last sentence is dropped. |
| unreachable, local only | "Can't reach *X*. Use the same Wi-Fi, or turn on Tailscale on both devices." |
| wentToSleep | "*X* went to sleep at 14:02. It sleeps after 30 minutes; turn on Stay awake in Passthrough on the PC." (MP). Without `sleepAfter`: "*X* went to sleep at 14:02. Turn on Stay awake in Passthrough on the PC to keep it reachable." |
| turnedOff | "Remote access was turned off on *X* at 14:02. Turn it on there." (MP) |
| shutDown | "*X* was shut down or restarted at 14:02. It is reachable again once Windows has started." (new) |
| noRelay | "Can't reach *X* from here. The relay isn't answering; it works on the PC's own network or Tailscale." (MP) |
| revoked | "*X* no longer lets this iPhone in. Plug it into the PC to get access again." (MP) |
| pairedNoAccess | "Paired. Turn on Remote access on *X*, then plug this iPhone in once." (MP) |
| shell nobodySignedIn | "Sign in to *X* to use its shell." (MP) |
| shell someoneElse | "Someone else is signed in to *X*. Its shell starts when you sign in." (MP) |
| shell appNotOpen | "Passthrough isn't open on *X*. Open it there." (MP) |
| shell switchedOff | "*X* doesn't let this iPhone open shells. Turn on Shell for it in Passthrough's settings on the PC." (MP) |
| screen notInThisVersion | "*X*'s screen isn't in this version of Passthrough yet. Its shell works." (new, for the time before stage 6; stage 6 changes the remaining case to MP's "Update Passthrough on this iPhone to see a PC's screen.") |
| screen switchedOff | "Screen is off for this iPhone. On *X*, open Passthrough's settings and turn on Screen for it." (MP) |
| screen remoteDesktopOff | "Remote Desktop is off on *X*. Turn it on in Passthrough's settings there." (MP) |
| screen windowsHome | "*X* runs Windows Home, which has no Remote Desktop. The shell works." (MP) |
| screen noPassword | "Your account on *X* has no password Remote Desktop can use. Add one on the PC." (MP) |
| screen remoteDesktopProblem | "Remote Desktop on *X* needs a look. Open Passthrough's settings on the PC." (new: covers `service` and `exposed`) |
| reachBlock, noAccess | "To use *X* from this iPhone, turn on Remote access there. The steps are below." |
| lock row | "Screen lock"; "Locked — its shells keep running" / "Unlocked"; button **Lock**; hint "Its shells keep running" |
| timeline | "A PC keeps no timeline yet." |
| notifications | "*X* doesn't send notifications yet. A shell that needs you still shows in the app." |
| links | "Keep awake and the VPN are a Mac's. Choose a Mac under Your computers, then try again." |

**New shell**: title "New shell"; caption the preferred shell's name; menu items the shells' names; footnote "Shells open as you, never as administrator." (MP); VoiceOver actions "New *PowerShell* shell"; chevron label "Choose a shell"; session rows "Ubuntu · running · 4m" (MP).

**Switcher**: "Your computers"; "Add a computer"; rows "PC · Connected", "PC · Connected · 2 shells open", "PC · Last heard 2 hours ago", "PC · Paired, no access yet", "PC · Sign in needed" (when `host.signedIn == false`), and the same with "Mac · " once any paired computer is not a Mac.

**Pairing and setup**: "The cable link is off, so the computer can't reach this iPhone to pair."; **Turn on the cable link**; "iOS asks to add a VPN configuration. That is how the cable link works in the background. Nothing is sent through it for a PC; a Mac's internet goes through it only while you share." (pairing sheet, kind not known); "iOS asks to add a VPN configuration. That is how the cable link works; no traffic is sent through it for a PC." (PC steps, MP verbatim); **Use it only while Passthrough is open**; the three steps in §6.

**Widget (PC)**: "Reachable"; "Last heard 14:02"; "Sign in needed"; "Open Passthrough to see your computer here."

**Generic**: "Your computers", "Add a computer", "Pair a Mac or PC", "Paired computers", "Forget all paired computers", "Choose a computer first.", tab "Mac" / "PC" / "Computer".

## Risks and how each is retired

| Risk | Retired by |
|---|---|
| Stage 1 spells a field or message differently from §"consumes" | The spelling is used in four files (`Host.swift`, `ShellClient.swift`, `Host.kt`, `ShellConnection.kt`). PR 1 is written after stage 1(b) merges, against its fixtures; the client tests replay stage 1's fixture lines, so a mismatch fails `swift test`. |
| A Mac string changes by accident while moving it into `HostCopy` | `HostCopyTests` holds today's Mac sentences as literals and compares. Item 1 of the hand checklist. |
| New Mac literals creep back in | The source-scan tests. |
| The split control's footnote is cut off inside a SwiftUI `Menu` | Checked in hand item 4 at the largest text size. Fallback, decided now: the footnote becomes the menu's `Section` header (always shown in full) rather than a trailing item. |
| A PC is shown as a Mac between pairing and its first grant | Corrections 1 (`hello.hostKind`). If stage 1 declines it, the row "Paired, no access yet" shows Mac steps until the grant; the grant then corrects it. Stated in the guide in that case. |
| "No relay" is claimed when the PC is simply off | The sentence is used only when the relay's host does not complete a TLS handshake within 3 s; otherwise the generic sentence. The check is skipped for the default relays. |
| The 30 s Try again adds a second way to dial and races the redial task | It calls the same `connect()`, which cancels `redialTask` first (`ShellModel.swift:475-477`). |
| `ShellCredential` equality now includes the kind, restarting watches | One restart per computer, the first time its kind is learned; covered by `MacProfilesTests.watchChanges` with a kind change. |
| PC-only users dislike a permanent VPN badge for a link used once | Open question 1; the refusal fallback ships either way. |
| The page file grows two code paths that drift | Both kinds read the same `HostPage` and `HostCopy`; the view branches once, on which rows exist. Renaming and splitting the view is deliberately later. |
| Nothing real to test a PC against until stage 3 | The demo states, the fixture replays, and item 11 of the checklist, which is added to stage 3's done-when. |
| Android and iOS copy drift | The shared `hostCopy` vectors. |

## Decisions made here

1. **A computer that never says what it is, is a Mac.** Reason: it is today's behaviour exactly, so today's Mac needs no change; the neutral word "computer" for an old Mac would be a regression for every current user. The neutral noun is used only for lists and for a kind this build does not know.
2. **The kind is stored on `PairedClient`, not on `ShellGrant`.** Reason: a computer that is paired but has granted nothing needs a kind too, and one field has one writer path.
3. **No data migration.** Reason: every new field is optional and its absence already means the right thing.
4. **The kind prefix in switcher rows ("PC · Connected") appears only when at least one paired computer is not a Mac.** Reason: MP asks for the kind in the status line; a Mac-only user gains nothing from "Mac · " on every row and loses room on a one-line label.
5. **One wording mechanism: `HostWords` + `HostCopy` in code, shared vectors, a source scan.** Reason: neither platform has string tables, most sentences already interpolate, and the only variable is the host's kind. String catalogs would add tooling without removing the branch.
6. **A PC's Lock row does not consult `macState.control`.** Reason: MP says a PC sends `control:false` (no Keep awake or VPN from the phone) and that Lock is supported; on the Mac `control` gates all three (`protocol/README.md:530`, `MacHomeView.swift:566-575`). For a `windows` host the phone treats `control` as covering `setAwake`/`setVPN` only. Stage 1's README should say so.
7. **The Screen row for a PC says "isn't in this version yet" until stage 6**, not MP's "Update Passthrough on this iPhone…". Reason: before stage 6 exists there is no update to get, and house rules say a control that can't work says why truthfully. The reducer already has MP's state; stage 6 changes one string and one constant.
8. **"New session" becomes "New shell" everywhere, for a Mac too.** Reason: MP names the control "New shell"; the app uses both words today (`MacHomeView.swift:597` against `RemoteShellCard.swift:78`), and one control cannot have two names.
9. **The pairing sheet says "cable link" for every computer.** Reason: the sheet cannot know the kind, and for a Mac the same switch is what makes the cable usable at all; "internet sharing" stays the name of the Mac tab's row.
10. **MP's choice of the extension for the cable link is kept; the in-app link is added only as the fix for a refused VPN configuration.** Reason: stay inside the master plan; the fallback costs a button and an existing code path.
11. **Share screen stays between Macs in this stage.** Reason: `screenGrant`/`screenPass` to or about a PC is stage 7 (`computerGrant`), and offering it now would fail in front of the user.
12. **Keep awake and VPN shortcuts with a PC selected switch to the only Mac, or say why not.** Reason: the shortcuts are named for a Mac; failing because the wrong computer is on screen would be a silent no.
13. **A going-away reason of `shutting_down` gets its own sentence** though MP's table has none. Reason: MP lists the reason on the wire; without a sentence it would fall to "may be asleep, off, or offline" when the app knows better.
14. **`Mac…` type and file names are not renamed.** Reason: a rename across 30 files in the same PRs would hide the behaviour change; it can be its own PR later, like MP's "Remote Shell tab" rename.
15. **Widget: a PC never shows awake wording; richer PC state in the widget (console in use, UAC waiting) is MP's later item.** Reason: this stage's job is that the widget is not wrong; MP ranks "widget and switcher state for PCs" after the must-haves.
16. **The relay check is a TLS handshake to the relay's host, not an HTTP probe.** Reason: it does not depend on a path the pinned relay version may or may not serve.
17. **`sleepAfter` is read as seconds.** Reason: every other duration on the wire is seconds; to be confirmed against stage 1's fixtures.

## Corrections to the master plan

1. **`hello` needs `hostKind` too.** MP adds `hostKind` to `shellGrant` and stored credentials "so a new PC is never shown as a Mac before its first connection". But MP's own row "Paired, no access yet" ("Paired. Turn on Remote access on *Office-PC*…") is shown *before any grant exists*, when the phone has only `hello.name` (`ControlServer.swift:169`). Without a kind on `hello`, that row and the PC's setup steps cannot be chosen, and a PC on the cable is counted as "a Mac online through this iPhone" (`Protocol.swift:174`, `ThisPhoneView.swift:147`). Fix: optional `hostKind` on the control channel's `hello`; old phones ignore it. This plan consumes it when present and degrades as described in §7 when not.
2. **Nothing on the wire says "Shell is off for this phone".** MP's phone table has "Shell switch off" and "Access revoked" as different rows, and per-phone Shell and Screen switches, but its protocol list has no way to tell a phone with Screen on and Shell off why `open` is refused (`not_authorized` would close the connection the screen needs). Fix, either or both: `host.access` = `{"shell":bool,"screen":bool}` (per connection, so the page can say it without the user trying), and an error `shell_not_allowed` for `open`/`attach`, mirroring `screen_not_allowed`. This plan handles both.
3. **Session rows cannot show the kind ("Ubuntu · running · 4m") from the wire as specified.** `sessions[]` has no shell field (`ShellProtocol.swift:189-217`), and MP adds none. Fix: optional `shell` (the catalog id) on `ShellSessionInfo`. Without it the phone can label only sessions it opened itself in the current run.
4. **`control:false` and "Lock supported" contradict today's meaning of `control`**, which gates `lock` as well (`protocol/README.md:530`). See Decisions 6; stage 1's README should define `control` for a PC as covering Keep awake and the VPN only (or the PC should send `control:true` and refuse `setAwake`/`setVPN`, which would make today's phones show two dead switches: worse).
5. **MP's phone table has no row for `shutting_down`**, though the reason is on the wire. Sentence added (Decisions 13).
6. **"About 350 strings … name the Mac"**: the count on the phones is about 135 lines in the iOS app, widgets and shared Swift, and about 110 in the Android app (table in §3); of the iOS ones about 45 are Mac-only rows that a PC's page simply does not show, and 15 are the screen viewer's, which stage 6 owns. The macOS app is outside this stage.
7. **MP's wording for the VPN prompt fits the PC's setup steps but not the pairing sheet**, where the kind is not yet known and the same switch serves a Mac's internet. A second, kind-neutral sentence is used there (§6).
8. **The old-app note** ("an iPhone app from before the phone work will ask for 'your Mac's' login when Screen is tapped on a PC") is right, and the mechanism is specific: `screen_video_unavailable` or `bad_request` to `screenVideo` triggers `fallBackToScreenSharing` (`ScreenModel.swift:394-395`). A PC that answered `screenVideo` with `screen_not_allowed` instead would stop old apps at a plain refusal with no login prompt. MP lists both answers as possible; stage 1 should prefer `screen_not_allowed` whenever the app is too old to do RDP.

## Open questions for the owner (each with a recommended default)

1. **Should a phone with no Mac paired get the cable link without the VPN configuration (in the app, only while Passthrough is open)?** It removes the iOS VPN prompt and the always-on VPN badge for PC-only users; it costs renewal of access while the app is closed (the app must be open when the phone is plugged in after the PC's key changes). *Recommended default:* no for this stage: keep MP's wording and the extension, ship the refusal fallback, and revisit after stage 4 shows how often re-grants matter.
2. **The interim Screen sentence for a PC before stage 6**: "*X*'s screen isn't in this version of Passthrough yet. Its shell works." *Recommended default:* use it; stage 6 replaces it with MP's "Update Passthrough on this iPhone to see a PC's screen." for the remaining too-old case.
3. **"New session" → "New shell" for Macs as well.** *Recommended default:* yes (one name for one control).
4. **The kind prefix in switcher rows only when the list is mixed.** *Recommended default:* yes. The alternative is "Mac · " on every row for every user.
5. **Keep awake / VPN shortcuts with a PC on screen switch to the only paired Mac by themselves.** *Recommended default:* yes when exactly one Mac has shell access; otherwise the note. The alternative is always the note.
6. **Corrections 1 to 3 change stage 1's wire** (`hello.hostKind`, `host.access` / `shell_not_allowed`, `sessions[].shell`). *Recommended default:* accept all three into stage 1(b); each is one optional field. If declined, this stage ships with the degraded behaviour stated beside each.
7. **The tab's title follows the selected computer ("Mac" / "PC").** MP says the tab title follows the kind. With both kinds paired the title changes as the selection does. *Recommended default:* follow the selection, as MP says; the alternative is a fixed "Computer".
8. **The PC's figure on the page**: SF Symbol `pc` in the laptop's frame (and a desktop icon on Android). *Recommended default:* yes for this stage; a drawn figure to match the Mac's animated laptop can come with the screen work.
