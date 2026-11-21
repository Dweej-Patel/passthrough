# Stage 6: The PC's screen on iPhone and iPad

## Goal and done-when

An iPhone or iPad opens a paired PC's screen through Windows Remote Desktop, carried over the app's own authenticated connection (`rdp` → `rdpReady` → raw bytes), with the sign-in sheet, Windows keys, shape and text size, copy and paste, and a sentence for every state in the master plan's two tables.

Done when:

1. The seam PR is merged and the Mac's stream and Screen Sharing behave exactly as before (the tests in *Tests* pin it; the Mac checklist in PR 1 passes by hand).
2. `scripts/build-freerdp.sh` rebuilds `Vendor/FreeRDP/FreeRDP.xcframework` (ios-arm64, ios-arm64-simulator, macos-arm64) from pinned sources on a clean Mac, and `swift test` plus both app builds pass in CI with it.
3. Every item of the master plan's *Screen states, each from the phone on cellular* list (master plan §6) passes on an iPhone and an iPad against a real PC running stage 5.
4. Thirty minutes of use shows no memory growth (Instruments, *Allocations* and *VM Tracker*; flat within 5 MB after the first minute).
5. Measured frame rate, data use, CPU and energy (the table in *Performance*) are in the flag-off PR.
6. A certificate that is not the one in `rdpReady` ends the view before any NTLM byte leaves (automated, and by hand with a stand-in).
7. The debug flag is gone and the docs listed in master plan §5 for stage 6 are updated.

## What exists today (verified, with path:line)

All paths are under `D:\projects\passthrough`.

**The model holds two concrete clients and speaks their types.**
- `iOS/App/Screen/ScreenModel.swift:112-113` holds `rfb: RFBClient?` and `video: ScreenVideoClient?`; almost every method branches on which is set (`:690-694`, `:708-722`, `:729-733`, `:737-758`, `:790-800`, `:811`).
- Public surface in RFB types: `connect(_ login: RFBClient.Login, remember:)` `:261`; `pointer(at:buttons: RFBClient.Buttons)` `:687`; `click(at:button:)` `:697`; `key(_ keysym: UInt32, modifiers: [UInt32])` `:728`; `type(_:modifiers:)` `:736`; `pendingLogin` `:179`.
- Frames reach the canvas three ways today, none published: `onFrame: (CGImage)` `:42`, `onVideoFrame: (CMSampleBuffer) -> Bool` `:44`, pointer `onMacPointer` `:47` and `onPointerShape` `:49`. There is no pixel-surface path.
- Phases: `login`, `confirmScreenSharing`, `connecting`, `live`, `failed`, `movedAway` (`:25-36`). The connecting view shows one sentence, "Connecting to …" (`iOS/App/Screen/ScreenView.swift:361`).
- Connection: `open(video:)` `:269-289` takes a `ShellClient` from `ShellModel.screenConnection` (`iOS/App/Shell/ShellModel.swift:509-516`), sends `requestScreen` on `.ready` (`ScreenModel.swift:379-381`), and builds the client on `.screen(stream, initialBytes)` (`:382-404`).
- Reconnect: drops of a view that worked are retried, at most `maxReconnects = 4`, the count reset after `steadyAfter = 15` s live (`:155-157`, `:499-513`).
- Background: observers at `:214-231`; going away only stops the microphone, sound and the curtain (`:234-251`); nothing reconnects on return except the canvas asking for a keyframe (`iOS/App/Screen/ScreenCanvas.swift:102-107`).
- Shape: `viewPixelsChanged` keeps the largest size per orientation, ignores changes under 3 %, debounces 400 ms (`ScreenModel.swift:1118-1137`); the canvas does not report while the keyboard is up (`ScreenCanvas.swift:440-442`, `:785-798`).
- Copy and paste: paste puts the phone's clipboard on the Mac then sends ⌘V (`ScreenModel.swift:787-801`); copy asks and waits 5 s or 2 s (`:808-821`); what comes back goes to `MacClipboard.put`, local-only for 120 s (`iOS/App/Shell/TerminalHost.swift:25-31`).

**The canvas and key row use RFB types and keysym arrays.**
- `ScreenCanvas.swift:24-25` `onPointer`/`onClick: (CGPoint, RFBClient.Buttons)`; `:32-33` `onKey: (UInt32, [UInt32])`, `onText: (String, [UInt32])`; `heldModifiers: [UInt32]` `:73`; `onSpace: (ScreenModel.SpaceAction)` `:38`.
- Layers: `content` shows a `CGImage` (`:424`), `video` is an `AVSampleBufferDisplayLayer` (`:60`, `:428-436`), `pointer` is a `CALayer` positioned from a shape and hot spot (`:64`, `:559-574`).
- Three-finger swipes call `onSpace` (`:876-897`). Hardware keys: `pressesBegan` sends specials and modified characters as keysyms (`:940-967`); everything else arrives through `UITextInput` (`iOS/App/Screen/ScreenTextInput.swift:27-48`), backed by `KeyboardDocument` (marked text is typed once final: `Packages/PassthroughCore/Tests/ScreenClientTests/KeyboardDocumentTests.swift:75`).
- Trackpad, mouse and Pencil are already handled whatever the touch mode (`ScreenCanvas.swift:175-193`, `:204-215`, `:338-381`); the iPad's own pointer is hidden over the screen (`:328-330`).
- Key row: esc, tab, ⌃, ⌥, ⌘, fn, four arrows, copy, paste (`:1003-1016`), modifiers held for the next key (`:934-937`, `:1040-1051`).

**The view.**
- Menus are separate `Equatable` views so an open menu is not rebuilt (`ScreenView.swift:428-432`): `ScreenClipboardMenu` `:434`, `ScreenDesktopsMenu` `:455`, `ScreenDisplayMenu` `:490`. Lock goes through the shell connection, not keys (`:477`).
- iPad: a floating bar that slides aside (`:107-189`); a connected keyboard brings the key row up by itself (`:65-69`).
- `ScreenLoginForm` takes an account name and password and a *Remember* toggle (`:640-696`); it returns `RFBClient.Login`.
- The whole view is covered while the device's screen is captured (`:55`, `iOS/App/Lock/CaptureCover.swift:1-13`).

**The login store** is keyed by Mac id only: one generic-password item per Mac, service `<id>.screen-login`, this-device-only, user presence, read with the app lock's context and `interactionNotAllowed` so it never prompts (`iOS/App/Screen/ScreenLoginStore.swift:14`, `:19-21`, `:24-38`, `:44`).

**The clients.**
- `RFBClient` owns `Login` (`Packages/PassthroughCore/Sources/ScreenClient/RFBClient.swift:15-19`), `Buttons` with RFB's bit values (`:46-54`), events `connected/frame/clipboard/bell/closed` (`:33-43`), failures (`:21-31`).
- `ScreenVideoClient.pointer` takes `RFBClient.Buttons` (`ScreenVideoClient.swift:157`); its events are at `:41-68`.
- `RFBKeys` is the keysym table, in PassthroughCore, used by the Mac host too (`Packages/PassthroughCore/Sources/PassthroughCore/RFBKeys.swift:5-36`; `Sources/ScreenHost/InputInjector.swift:324`; `macOS/App/Views/RemoteScreenWindow.swift:146`, `:638`, `:719`).
- `ByteStream` is callback-based (`Sources/PassthroughCore/ByteStream.swift:8-18`): `receive(maximumLength:completion:)`, `send(_:isComplete:completion:)`, `cancel()`, `onTerminated`.

**The hand-over.** `ShellClient.requestScreen(video:)` sets `screenRequested` and sends `screen` or `screenVideo` (`ShellClient.swift:431-437`); the reader stops splitting lines at `screenReady`/`screenVideoReady` (`:572-574`, `:791-794`); `handOver` gives the stream and the bytes after the line to the caller and goes quiet (`:798-808`). Errors arrive as `.failed(ShellError, session:)` (`:757-769`); `ShellError` has no `rdp_unavailable`, `try_later` or `signed_out` yet (`ShellProtocol.swift:277-300`).

**Not in the tree yet** (searched: no match for `rdpReady`, `hostKind`, `rdp_unavailable`, `try_later`, `signed_out` in any `.swift`, `.kt`, `.cs`, `.json`, `.md` outside `Spikes/`): the `host` message, the `rdp` request, host kind in profiles. Stages 1, 2 and 5 bring them; this stage consumes them (see *Interfaces*).

**Build and vendoring.**
- The package's floors are iOS 17.5 / macOS 14.5, and the Mac slice of the one binary dependency is arm64 only (`Packages/PassthroughCore/Package.swift:6-7`, `:23-25`). `ScreenClient` is compiled `-O` in Debug through `unsafeFlags` (`:56-57`).
- Vendoring convention: source cloned into a gitignored folder, patches applied from `Vendor/<Name>/patches`, one static library per SDK, `xcodebuild -create-xcframework`, outputs committed (`scripts/build-hev.sh:10-49`; `.gitignore` "Vendored tun2socks SOURCE"; `Vendor/HevSocks5Tunnel/` holds `HevSocks5Tunnel.xcframework`, `lib/`, `include/`, `patches/`, `LICENSES.md`). `build-hev.sh` clones `--depth 1` of the default branch with no pin (`:12`): this stage's script is stricter.
- The iOS app links package products per target in `project.yml:46-61`; the tunnel extension links the hev xcframework directly (`:124-125`). There are no app test targets: only the package is tested (`project.yml` has none; `.github/workflows/ci.yml:24-36`).
- CI: `swift test` on `macos-15` with Xcode 26.3, then both apps built unsigned (`.github/workflows/ci.yml:20-70`).
- Notices list each vendored component with licence and how it is built (`THIRD_PARTY_NOTICES.md:5-10`); CONTRIBUTING records what a dependency added to each app's size (`CONTRIBUTING.md:31`) and names the vendored folders and their scripts (`:76-79`).

## Design

### 1. The seam

Everything here is PR 1 and changes no behaviour.

#### Neutral types (PassthroughCore, new file `ScreenInput.swift`)

```swift
/// Pointer buttons held. Raw values are RFB's, so both existing wire formats keep their bytes.
public struct ScreenButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8)
    public static let left   = ScreenButtons(rawValue: 1)
    public static let middle = ScreenButtons(rawValue: 2)
    public static let right  = ScreenButtons(rawValue: 4)
}

/// An account on the computer being viewed.
public struct ScreenLogin: Sendable, Equatable {
    public var username: String      // as typed: "name", "PC\\name", "name@outlook.com"
    public var password: String
    public init(username: String, password: String)
}
extension ScreenLogin: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    // prints the username and "<redacted>", as ShellCredential does (ShellClient.swift:32-48)
}

/// A key by X keysym: what the canvas, the key row and both Mac wire formats already carry.
public typealias ScreenKey = UInt32

/// The keysym table. `RFBKeys` stays as a typealias until the Mac's window moves (stage 7c).
public enum ScreenKeys { /* today's RFBKeys, unchanged, plus: */
    public static let insert: UInt32 = 0xFF63
    public static let windows: UInt32 = 0xFFEB     // Super_L
    public static let alt: UInt32 = 0xFFE9         // Alt_L (a PC's Alt; `option` stays Meta_L for the Mac)
    public static let printScreen: UInt32 = 0xFF61
}
public typealias RFBKeys = ScreenKeys

/// Modifiers held around one key. Raw values 1…8 are ScreenVideoWire.Modifiers' (ScreenVideoWire.swift:214-221).
public struct ScreenModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public static let command = ScreenModifiers(rawValue: 1)
    public static let shift   = ScreenModifiers(rawValue: 2)
    public static let option  = ScreenModifiers(rawValue: 4)   // Alt on a PC
    public static let control = ScreenModifiers(rawValue: 8)
    public static let windows = ScreenModifiers(rawValue: 16)
    /// Press order (release is the reverse): control, option, shift, command, windows.
    public var keysyms: [UInt32] { get }
}
```

`RFBClient.Buttons` keeps only what is RFB's own: `wheelUp`, `wheelDown`, and `init(_ buttons: ScreenButtons)`. `RFBClient.Login` becomes `typealias Login = ScreenLogin`. `ScreenVideoClient.pointer(x:y:buttons:)` takes `ScreenButtons`.

One observable difference, accepted: held modifiers are pressed in a fixed order instead of the order tapped on the key row (`ScreenModel.swift:730-733` today). No app on a Mac tells them apart; the test `testRFBModifierOrderIsFixed` states the order.

#### `ScreenBackend` (ScreenClient target, new file `ScreenBackend.swift`; no UIKit, so macOS shares it in stage 7c)

```swift
/// What the view may offer for the backend in use. The menus and the key row read these, never the backend's type.
public struct ScreenCapabilities: OptionSet, Sendable {
    public let rawValue: UInt32
    public static let macStream       = ScreenCapabilities(rawValue: 1 << 0)  // curtain, sound, microphone, Use Here, gestures, fn, quality, Mac's-display/fit choice
    public static let smoothScroll    = ScreenCapabilities(rawValue: 1 << 1)  // pixel deltas; without it, wheel notches
    public static let unicodeText     = ScreenCapabilities(rawValue: 1 << 2)  // text(_:) carries any character
    public static let resize          = ScreenCapabilities(rawValue: 1 << 3)  // layout(_:) is honoured
    public static let drawsOwnPointer = ScreenCapabilities(rawValue: 1 << 4)  // frames leave the pointer out; pointer events say where and what
    public static let signIn          = ScreenCapabilities(rawValue: 1 << 5)  // needs a ScreenLogin
    public static let windowsKeys     = ScreenCapabilities(rawValue: 1 << 6)  // Windows key row, Windows menu, Windows gestures
    public static let frameAcks       = ScreenCapabilities(rawValue: 1 << 7)  // presented(_:) must be called per sample
}

public struct ScreenLayoutRequest: Equatable, Sendable {
    public enum Shape: Sendable { case hostDisplay, device, standard }   // standard: 16:10 (PC only)
    public var shape: Shape
    public var pixels: CGSize          // the view's area in pixels (device), or the cap (hostDisplay)
    public var deviceScale: CGFloat    // UIScreen.scale
    public var space: Int              // 80, 100, 125 (ScreenModel.spaces)
    public var fps: Int
    public var quality: ScreenVideoWire.Quality
    public var idiom: Idiom            // .phone, .pad: picks the text-size table
}

public enum ScreenCopyResult: Sendable { case text(String), nothing, tooLong, notText }

public enum ScreenSignInProblem: Sendable, Equatable {
    case wrongPassword, passwordExpired, accountLocked, accountDisabled, notAllowedRemotely, other(String)
}

public enum ScreenEnd: Sendable, Equatable {
    case closedHere                    // close() was called
    case connectionLost                // transport ended underneath
    case signIn(ScreenSignInProblem)
    case identityMismatch              // not the certificate the host announced (PC), or no login offered (Mac)
    case takenOver                     // someone signed in at the computer / another connection took the session
    case signedOut                     // the remote session logged off
    case hostEnded(String)             // the host ended it and said why (licence, policy)
    case unsupported(String)           // a peer this backend can't talk to
    case protocolError(String)
}

public enum ScreenBackendEvent: @unchecked Sendable {
    case phase(ScreenConnectPhase)                                   // PC only today
    case size(width: Int, height: Int)                               // first means live
    case image(CGImage)                                              // Screen Sharing
    case sample(CMSampleBuffer, number: UInt32)                      // the Mac's stream
    case surface(ScreenSurface, dirty: [CGRect])                     // Remote Desktop; `dirty` in surface pixels, already copied in
    case pointerPosition(CGPoint?, visible: Bool)                    // screen pixels; nil: only visibility
    case pointerShape(CGImage, size: CGSize, hotSpot: CGPoint)
    case pointerHidden
    case copied(ScreenCopyResult)
    case clipboardChanged(String)                                    // Screen Sharing's unasked ServerCutText
    case bell
    case notice(ScreenBackendNotice)                                 // .sessionBusy, .firstFrameAfterResize …
    case macStream(MacStreamEvent)                                   // fitted, viewers, movedAway, curtained, microphone, sound, soundPacket
    case ended(ScreenEnd)
}

public enum ScreenConnectPhase: Sendable, Equatable { case negotiating, identityChecked, signedIn, starting }

public protocol ScreenBackend: AnyObject, Sendable {
    var capabilities: ScreenCapabilities { get }
    /// The Mac's stream only: its extra controls. Nil elsewhere.
    var macStream: MacStreamControls? { get }

    func start()
    /// Ends it; `.ended(.closedHere)` follows once. Safe to call twice and from any thread.
    func close()

    // Input. Points are screen pixels of the last `.size`.
    func pointer(at point: CGPoint, buttons: ScreenButtons)
    /// Fingers moved `delta` pixels with the pointer at `point`; `notch`: pixels a wheel notch is worth.
    /// The backend keeps the remainder between calls (today's ScreenModel.scrollRemainder).
    func scroll(at point: CGPoint, by delta: CGPoint, notch: CGFloat)
    func scrollEnded()
    /// Press and release, with `modifiers` held around it.
    func key(_ key: ScreenKey, modifiers: ScreenModifiers)
    /// A key held for as long as the user holds it (fn; a hardware modifier).
    func hold(_ key: ScreenKey, down: Bool)
    /// Typed text, no modifiers. Return and Tab inside it are keys.
    func text(_ text: String)
    /// Puts `text` on the far clipboard and pastes it there. False: too long, nothing sent.
    func paste(_ text: String) -> Bool
    /// Copies the far selection; `.copied` answers. One at a time.
    func copySelection()

    func layout(_ request: ScreenLayoutRequest)
    func presented(_ number: UInt32)
    func needsKeyframe()
    /// The app left the foreground or came back.
    func setActive(_ active: Bool)
}

public protocol MacStreamControls: AnyObject, Sendable {
    func useHere()
    func curtain(_ hidden: Bool)
    func sound(_ on: Bool)
    func microphone(_ on: Bool)
    func voice(_ samples: Data)
    func function(_ down: Bool)
    func gesture(_ gesture: ScreenVideoWire.Gesture, phase: ScreenVideoWire.GesturePhase, value: Double)
}
```

Events arrive on the queue given to the backend's `init` (main), as both clients do today.

`ScreenSurface` is in section 3.

#### The two adapters (ScreenClient)

- `ScreenSharingBackend(stream:initialBytes:login:queue:onEvent:)` wraps `RFBClient`. Moves in from `ScreenModel`: the wheel-notch arithmetic (`ScreenModel.swift:716-721`), modifier press/release around a key (`:730-733`), per-character keysym typing (`:756-758`), paste as `clipboard` + ⌘V with `lastPaste` kept so the Mac's echo is not taken as a copy (`:797-800`, `:537`), copy as ⌘C with the 2 s window (`:811-819`). `RFBClient.Failure` maps to `ScreenEnd`: `loginFailed → .signIn(.wrongPassword)`, `noLoginOffered → .identityMismatch`, `unsupportedServer → .unsupported`, `protocolError → .protocolError`, `connectionLost → .connectionLost`.
- `MacStreamBackend(stream:initialBytes:layout:queue:onEvent:)` wraps `ScreenVideoClient` and is its own `MacStreamControls`. Moves in: pixel-to-unit pointer scaling (`:691`), "move there first, then scroll" (`:710`), the keysym→mask reduction (`:1155-1165`), long text as paste (`:740-742`), Return/Tab split (`:744-753`), copy with the 5 s timeout (`:814-819`).

`ScreenModel` keeps: phases, the Screen Sharing consent, the upgrade to the stream (`:561-682`, now swapping one `ScreenBackend` for another), reconnect counting, the curtain, sound and microphone state (through `backend.macStream`), notices, settings, path watching. It holds `private var backend: (any ScreenBackend)?` and a second one for the upgrade. `canHideMac`/`canUseMicrophone`/`pinchesMac` read `capabilities.contains(.macStream)`.

Canvas callbacks become `onPointer/onClick: (CGPoint, ScreenButtons)`, `onKey: (ScreenKey, ScreenModifiers)`, `onText: (String, ScreenModifiers)`, `heldModifiers: ScreenModifiers`. `onSpace` becomes `onSwipe: (ScreenSwipe)` with `ScreenSwipe { left, right, up, down }`; the model maps a swipe to `SpaceAction` for a Mac (`ScreenCanvas.swift:889-893`'s mapping moves to the model) and to a Windows shortcut for a PC.

#### What pins "unchanged"

The app has no test target, so the logic that moves is tested where it lands, in `ScreenClientTests`, against the existing fake stream (`ScreenClientTests.swift:145`) and fake RFB server (`:177`):

- `testScreenSharingBackendBytes`: pointer, click, key with ⌘, typed "aé\n", paste, wheel scroll of 2.5 notches then 0.5 more produce exactly the bytes the pre-refactor code produced. The expected bytes are captured from `dev` before the refactor and committed as literals.
- `testMacStreamBackendMessages`: the same inputs produce the same `ScreenVideoWire` messages, including the pointer move before a scroll, long text going as clipboard + ⌘V, and Return inside text going as a key.
- `testButtonsKeepTheirWireValues`, `testModifierMaskValues`: raw values equal RFB's and `ScreenVideoWire.Modifiers`'.
- `testFailureMapping`: each `RFBClient.Failure` → `ScreenEnd`.
- All existing `RFBClientTests`, `ScreenVideoClientTests`, `ScreenHostTests`, `ShellListenerTests` pass untouched except for the renamed button type.

By hand (PR 1 description): the Mac's stream, forced Screen Sharing, the upgrade from one to the other, copy and paste both ways, three-finger swipes, hardware keyboard, Pencil, trackpad.

### 2. The engine

#### Layout

```
Vendor/FreeRDP/
  FreeRDP.xcframework/            ios-arm64, ios-arm64-simulator, macos-arm64: libfreerdp-vendor.a + Headers/
  Package.swift                   one binaryTarget, product "FreeRDPVendor" (a local package can't name a path outside its root)
  patches/                        0001-no-dynamic-addins.patch (and any later fix, each with a header saying why)
  SOURCES.lock                    tag, commit and SHA-256 of each archive the script built from
  SIZE.md                         per-slice library size and the measured app delta
  LICENSES.md
Packages/PassthroughCore/
  Sources/CRemoteDesktop/         the C shim: include/pt_rdp.h, pt_rdp.c, pt_bridge.c  (depends on FreeRDPVendor)
  Sources/RemoteDesktop/          Swift: RemoteDesktopBackend, RDPSession, ScreenSurface+IOSurface, WindowsKeymap,
                                  WindowsDisplay, RDPClipboard, RDPEndReason, WindowsScreenFlow
  Tests/RemoteDesktopTests/       + Tests/CRDPStandIn/ (a C test helper: X.224 answers and a TLS server)
```

`Package.swift` gains `.package(path: "../../Vendor/FreeRDP")`, the two targets and a `RemoteDesktop` library product. `RemoteDesktop` depends on `ScreenClient` (for the protocol), `PassthroughCore` and `CRemoteDesktop`. Linker settings on `CRemoteDesktop`: frameworks VideoToolbox, CoreMedia, CoreVideo, CoreFoundation, Security; no `libz`. The product is linked into the iOS app (and, in stage 7c, the Mac's helper process) and nothing else.

#### The C shim (`pt_rdp.h`)

Swift never sees a FreeRDP type: the settings struct, the callback tables and the macros stay in C, and the shim is the only file that includes FreeRDP headers. Its surface:

```c
typedef struct pt_rdp pt_rdp;
typedef struct { int32_t x, y, w, h; } pt_rect;

typedef struct {
    const char *username, *domain, *password;     // copied; the shim's copies are zeroed in pt_rdp_free and after sign-in
    const char *client_name;                      // "iPhone" / "iPad": never the device's own name
    uint32_t width, height;                       // first desktop size
    uint32_t desktop_scale, device_scale;         // 100…500; 100, 140 or 180
    uint32_t phys_width_mm, phys_height_mm;
    int allow_h264;                               // 0: fallback build/setting (see Performance)
    uint32_t max_clipboard_bytes;                 // 1 MiB
} pt_rdp_config;

typedef struct {                                  // every callback runs on the engine thread
    void *user;
    int  (*verify_certificate)(void *user, const uint8_t *der, size_t len);            // 1 accept, 0 refuse
    void (*phase)(void *user, int phase);                                              // PT_PHASE_*
    void (*desktop)(void *user, uint32_t w, uint32_t h, const uint8_t *bgra, uint32_t stride);  // new or resized primary buffer
    void (*painted)(void *user, const pt_rect *rects, uint32_t count);                 // between EndPaint and the next BeginPaint
    void (*pointer_shape)(void *user, const uint8_t *bgra, uint32_t w, uint32_t h, uint32_t hot_x, uint32_t hot_y);
    void (*pointer_visible)(void *user, int visible, int system_default);
    void (*pointer_moved)(void *user, uint32_t x, uint32_t y);
    void (*clipboard_offered)(void *user, int has_text);                               // the PC's clipboard changed
    void (*clipboard_text)(void *user, const uint16_t *utf16, size_t units, int too_long);
    int  (*clipboard_wanted)(void *user, const uint16_t **utf16, size_t *units);       // the PC asks for ours; 0 refuse
    void (*logon_info)(void *user, uint32_t data, uint32_t type);
    void (*drain)(void *user);                                                         // run queued commands now
} pt_rdp_callbacks;

typedef struct { uint32_t last_error, error_info, sspi_error; int certificate_refused, aborted, transport_closed; } pt_rdp_end;

pt_rdp *pt_rdp_new(const pt_rdp_config *, const pt_rdp_callbacks *);
pt_rdp_end pt_rdp_run(pt_rdp *);                  // blocks: connect, loop, disconnect. Call on the engine thread.
void pt_rdp_free(pt_rdp *);

// Any thread.
void pt_rdp_abort(pt_rdp *);                      // ends pt_rdp_run within 200 ms
void pt_rdp_wake(pt_rdp *);                       // makes the loop call `drain`
size_t pt_rdp_feed(pt_rdp *, const uint8_t *, size_t);   // bytes from the network; returns free space left in the inbox
void pt_rdp_feed_closed(pt_rdp *);
size_t pt_rdp_take(pt_rdp *, uint8_t *, size_t);  // bytes for the network; 0 when none
void pt_rdp_set_outbox_ready(pt_rdp *, void (*ready)(void *user), void *user);  // called (engine thread) when the outbox goes non-empty

// Engine thread only (from `drain`).
int pt_rdp_key(pt_rdp *, uint32_t scancode, int extended, int down);
int pt_rdp_unicode(pt_rdp *, uint16_t unit, int down);
int pt_rdp_mouse(pt_rdp *, uint16_t x, uint16_t y, uint8_t buttons_down, uint8_t buttons_changed, int moved);
int pt_rdp_wheel(pt_rdp *, uint16_t x, uint16_t y, int16_t rotation, int horizontal);
int pt_rdp_layout(pt_rdp *, uint32_t w, uint32_t h, uint32_t desktop_scale, uint32_t device_scale, uint32_t orientation,
                  uint32_t phys_w_mm, uint32_t phys_h_mm);   // 0 when display control isn't open yet
int pt_rdp_clipboard_offer(pt_rdp *, int has_text);
int pt_rdp_clipboard_fetch(pt_rdp *);
int pt_rdp_suppress_output(pt_rdp *, int suppress);
```

Inside, modelled on upstream's own iOS client (`client/iOS/FreeRDP/ios_freerdp.m` at the pinned tag: `freerdp_client_context_new`, `PreConnect` subscribing to channel-connected events and calling `freerdp_client_load_addins`, `PostConnect` calling `gdi_init(instance, PIXEL_FORMAT_BGRA32)` and registering pointer callbacks, a loop of `freerdp_get_event_handles` → wait → `freerdp_check_event_handles`).

#### Settings the shim sets (all names checked against `include/freerdp/settings_types_private.h` at the tag)

| Purpose | Settings |
|---|---|
| NLA only, nothing weaker | `NlaSecurity`=1; `TlsSecurity`, `RdpSecurity`, `ExtSecurity`, `AadSecurity`, `RdstlsSecurity`=0; `NegotiateSecurityLayer`=1; `UseRdpSecurityLayer`=0; `RestrictedAdminModeRequired`, `RemoteCredentialGuard`, `SmartcardLogon`=0 |
| The certificate is ours to judge | `ExternalCertificateManagement`=1; `IgnoreCertificate`, `AutoAcceptCertificate`=0; `AutoDenyCertificate`=1 (belt for the path not taken); `CertificateAcceptedFingerprints`=NULL; `instance->VerifyX509Certificate` = the pin check |
| No gateway, proxy, redirection of the connection | `GatewayEnabled`=0; `ProxyType`=none; `SupportMultitransport`=0; `NetworkAutoDetect`=0; `AutoReconnectionEnabled`=0 (reconnects are ours, through the relay) |
| Graphics | `SupportGraphicsPipeline`=1; `GfxH264`, `GfxAVC444`, `GfxAVC444v2`= `allow_h264`; `GfxProgressive`, `GfxProgressiveV2`, `GfxPlanar`=1; `GfxSmallCache`=1; `ColorDepth`=32; `SoftwareGdi`=1; `RemoteFxCodec`=0; `NSCodec`=0; `JpegCodec`=0 |
| Legacy caches off | `BitmapCacheEnabled`, `BitmapCacheV3Enabled`, `BitmapCachePersistEnabled`=0; `OffscreenSupportLevel`=0; `GlyphSupportLevel`=0 (none) |
| No device redirection | `DeviceRedirection`, `RedirectDrives`, `RedirectPrinters`, `RedirectSmartCards`, `RedirectSerialPorts`, `RedirectParallelPorts`=0; `AudioPlayback`, `AudioCapture`=0; `RemoteApplicationMode`=0; `SupportVideoOptimized`=0 |
| Clipboard, text only | `RedirectClipboard`=1; `ClipboardFeatureMask` = text in both directions, no files (flag names: see *unverified*) |
| Shape | `DesktopWidth`, `DesktopHeight`, `DesktopScaleFactor`, `DeviceScaleFactor`, `DesktopOrientation`; `SupportDisplayControl`=1; `DynamicResolutionUpdate`=1; `SupportMonitorLayoutPdu`=1; `UseMultimon`=0 |
| Input | `UnicodeInput`=1; `HasHorizontalWheel`=1; `HasExtendedMouseEvent`=0; `KeyboardLayout`=0 (the PC's own; see *Open questions*) |
| Session | `ConsoleSession`=0; `AuthenticationOnly`=0; `Username`, `Domain`, `Password`; `ServerHostname`="passthrough-relay" (never resolved: our `ConnectLayer` ignores it), `ServerPort`=3389; `ClientHostname`= config `client_name` |

Channels loaded: `drdynvc` with `rdpgfx` and `disp`; static `cliprdr`. Everything else is compiled out (section 4), and `0001-no-dynamic-addins.patch` makes `freerdp_load_dynamic_channel_addin_entry` return null, because at the tag `freerdp_load_channel_addin_entry` falls back to a dynamic load whenever the static table has no entry (`libfreerdp/common/addin.c:370-385`).

#### The transport bridge

FreeRDP's hook, verified in `include/freerdp/transport_io.h` and `libfreerdp/core/transport.c` at the tag:

- `rdpTransportIo.ConnectLayer(transport, hostname, port, timeout) → rdpTransportLayer*` (since 3.9.0); set with `freerdp_get_io_callbacks` / `freerdp_set_io_callbacks` in `PreConnect`. `transport_connect` calls it in place of opening a socket (`transport.c:644`), then the default `AttachLayer` wraps the layer in a BIO (`:1641-1660`).
- The layer is five callbacks: `Read(user, buf, n)` and `Write(user, buf, n)` return bytes, or a negative number with `errno` (`EAGAIN` means retry; since 3.17.0 a return of 0 from `Read` is "closed"); `Wait(user, waitWrite, timeoutMs)` returns whether it is ready; `GetEvent(user)` returns the WinPR `HANDLE` FreeRDP waits on for readability; `Close(user)`. Create with `transport_layer_new(transport, contextSize)`; FreeRDP frees it and calls `Close` (`transport.c:2053-2063`).
- Threading: FreeRDP calls `Read` from whichever thread runs `freerdp_connect` / `freerdp_check_event_handles`; writes are serialized by the transport's own write lock (`transport.c:1505`). We go further and make every FreeRDP call from one thread, so the contract we rely on is the weakest one.

`pt_bridge.c` implements the layer over two byte rings guarded by one mutex and a condition variable:

```
network ──ByteStream.receive──▶ pt_rdp_feed ──▶ [inbox ring, 4 MiB] ──▶ layer.Read   (engine thread)
network ◀──ByteStream.send──── pt_rdp_take ◀── [outbox ring, 1 MiB] ◀── layer.Write  (engine thread)
```

- **Inbox.** `pt_rdp_feed` appends, sets the readable event (a manual-reset WinPR event made with `CreateEvent`) and signals the condition. `Read` copies out; when the ring empties it resets the event, re-checking under the mutex so a feed between the copy and the reset is not lost; with nothing to read it returns −1 with `errno = EAGAIN`, or 0 once `pt_rdp_feed_closed` was called and the ring is empty.
- **Back-pressure in, never dropping.** The Swift side keeps one `stream.receive(maximumLength: 256 KiB)` outstanding and issues the next only while `pt_rdp_feed` reports at least 512 KiB free; otherwise it waits for the bridge's "inbox below half" callback. The network's own flow control then slows the PC. Nothing is discarded and the inbox cannot exceed 4 MiB.
- **Outbox.** `Write` appends what fits and returns that count; with no room it returns −1/`EAGAIN`, and FreeRDP calls `Wait(waitWrite: true, …)`, which sleeps on the condition until there is room, the timeout passes, or the bridge is closed. The Swift side drains with one `stream.send` in flight (64 KiB at most each), started by the "outbox ready" callback and continued from each send's completion.
- **A stuck peer.** If the outbox has been full for 15 s, or a send completes with an error, or `onTerminated` fires, the bridge is closed: both rings report closed, the event is set, the condition is broadcast. `pt_rdp_run` returns with `transport_closed`.
- **`Wait` for reading** (used throughout the blocking connect phase: `BIO_C_WAIT_READ`, `transport.c:2158-2172`) sleeps on the same condition until bytes, closed, or the timeout. It sleeps in slices of at most 100 ms and checks the abort flag between them, so cancellation never waits on a network timeout.
- **`initialBytes`** from the hand-over are fed before the first read. Remote Desktop speaks second, so they are normally empty.

#### Thread ownership

| Thread | Owns |
|---|---|
| Engine thread (`Thread`, one per session, name `rdp`, QoS `.userInteractive`, 1 MiB stack) | Every FreeRDP call; the GDI buffer; copying dirty rectangles into the surface; converting pointer shapes |
| `RDPSession.io` (serial `DispatchQueue`) | `stream.receive`/`send` and their completions; feeding and draining the rings |
| Main | `RemoteDesktopBackend`'s public methods and events; presenting the surface |

Commands from main (`key`, `pointer`, `layout`, …) are appended to a locked array, then `pt_rdp_wake`; the engine loop calls `drain`, which runs them. Pointer moves are coalesced there: only the last of a run of pure moves is sent. The queue is capped at 4 096 commands; past that, pure moves are dropped first, then the session is closed as `protocolError("input backlog")`.

The loop: `handles = freerdp_get_event_handles(...) + wakeEvent`; `WaitForMultipleObjects(handles, 250 ms)`; `freerdp_check_event_handles`; `drain`; until `freerdp_shall_disconnect_context` or abort.

#### Teardown

`close()` (main): mark closed, `pt_rdp_abort` (which calls `freerdp_abort_connect_context` and closes the bridge), then on the engine thread after `pt_rdp_run` returns: `pt_rdp_free` (FreeRDP's disconnect, `gdi_free`, context free; password copies zeroed), release the surface, hop to `io` to `stream.cancel()`, then to main for `.ended`. The model shuts the iroh dialer down after `.ended`, as it does today (`ScreenModel.swift:365-368`). A session that has not ended 2 s after `close()` is logged as a leak (never the password, never bytes) and its stream cancelled anyway.

Only one engine thread exists per app at a time: `RemoteDesktopBackend.start()` waits for a previous session's thread to finish (bounded by the same 2 s).

### 3. Frames, pointer, resize

#### `ScreenSurface`

```swift
/// The latest picture as shared pixels: BGRA, 8 bits, premultiplied-first with alpha ignored, sRGB.
public final class ScreenSurface: @unchecked Sendable {
    public let width: Int, height: Int
    /// What a layer shows: assign to `CALayer.contents`. Changes identity on every `present()` that returns true.
    public var front: IOSurface { get }
    /// Main thread, once per display refresh: swaps in what was painted since the last call. False: nothing new.
    public func present() -> Bool
}
```

Two `IOSurface`s per desktop size (front, back), `kCVPixelFormatType_32BGRA`, plus FreeRDP's own primary buffer: three copies of the desktop.

- On `painted(rects)` (engine thread, right after FreeRDP's `EndPaint`, read from `gdi->primary->hdc->hwnd->cinvalid[0..<ninvalid]`): take the surface lock; copy those rectangles, plus the rectangles the back surface missed at the last swap, from the primary buffer into the back surface; mark it ready. More than 64 rectangles collapse to their bounding box.
- On the display link (main): `present()` try-locks (a miss skips this refresh); if ready, swap front and back, remember the just-presented rectangles as "missed" for the new back, and the canvas sets `content.layer.contents = surface.front`.
- Two paints between refreshes land in the same back surface; the newest wins. Nothing queues.

Memory: 4 bytes × pixels × 3. iPhone 16 Pro Max fit (1320×2868): 45 MB. Standard 1920×1200: 28 MB. iPad Pro 13-inch fit (2064×2752): 68 MB. The desktop is capped at 4 096 on its longer side and 8.3 million pixels (100 MB); a larger view is asked for at a proportionally smaller size.

#### The canvas's surface path (`ScreenCanvas.swift`)

- New `func show(surface: ScreenSurface)` sets `screenSize` exactly as `show(_:size:)` does (`:412-425`), hides `video`, and starts `surfaceLink`: a `CADisplayLink` at 30–60 Hz preferred 60, paused when `present()` has returned false for 30 consecutive refreshes and resumed by the next `.surface` event. 60 is the target: Remote Desktop's own pipeline tops out there.
- `content.layer.contents` already scales with the zoom (`:94-95`); `contentsGravity` stays `.resize`.
- `ScreenCanvas.makeUIView` wires `model.onSurface = { view.show(surface:) }` beside `onFrame`/`onVideoFrame` (`:1148`, `:1167`).
- The dimmed last picture while reconnecting: the canvas keeps the front surface after the backend ends; the view overlays 45 % black and the sentence. The surface is released when the next one arrives or the view closes.
- Fallback if `IOSurface` as layer contents misbehaves on some iOS version: wrap the front surface in a `CVPixelBuffer` and enqueue it on the existing `video` layer (`:428-436`). Recorded in *Risks*.

#### Pointer

`capabilities` includes `.drawsOwnPointer`: the GFX pipeline leaves the pointer out. `Pointer_New` converts with `freerdp_image_copy_from_pointer_data(..., PIXEL_FORMAT_BGRA32, ...)` into a buffer the shim hands to `pointer_shape`; Swift builds a `CGImage` (premultiplied) and sends `.pointerShape`, size and hot spot in desktop pixels, which is what `setPointerShape` wants (`ScreenCanvas.swift:559-574`). Shapes larger than 384×384 are refused (the protocol's large-pointer limit); the last shape stays. `SetNull` → `.pointerHidden`; `SetDefault` → a built-in arrow image; `SetPosition` → `.pointerPosition`. A cache of the last 32 converted shapes keyed by the `rdpPointer` address avoids re-encoding on every `Set`.

#### Shape, text size, resize (`WindowsDisplay.swift`, pure and tested)

Two shapes, chosen in the Display menu and remembered per computer:

- **Fit to this iPhone / iPad** (default): the desktop is the view's area in pixels, so one Windows pixel is one device pixel. Width and height are rounded down to even numbers, clamped to 200…8 192 (display control's limits, `include/freerdp/channels/disp.h:37-41`) and to the caps above. It turns with the device.
- **Standard (16:10)**: 1 920×1 200 on a phone, 2 560×1 600 on an iPad, landscape whatever way the device is held, shown fitted with pinch to zoom as any screen larger than the view is today.

Text size is the Windows scale factor. The three choices of today's menu (`ScreenModel.spaces`, `ScreenView.swift:528-535`) pick how many Windows points the short side should have; the scale is the largest Windows step that still gives that many:

| | Larger text | Default | More space |
|---|---|---|---|
| Fit, iPhone (short side target, points) | 480 | 600 | 760 |
| Fit, iPad | 800 | 1 000 | 1 280 |
| Standard, iPhone (1 920×1 200) | 175 % | 150 % | 125 % |
| Standard, iPad (2 560×1 600) | 250 % | 200 % | 150 % |

`desktopScale = largest of {100,125,150,175,200,225,250,300,350,400,450,500} ≤ shortSidePixels / target × 100`. Example: iPhone 16 Pro portrait, 1 206 px wide, Default → 200 % (603 points wide). `deviceScale` = 100 below 150 %, 140 from 150 % to 225 %, 180 above. Physical size in millimetres is sent from the device's real diagonal (a table by `DeviceFacts` model family; 0 when unknown).

Flow:

1. The first size is known before connecting (the connecting view already measures the area: `ScreenView.swift:366-374`), so the first frame is the right shape.
2. A change of view pixels follows today's rules unchanged (largest per orientation, 3 % threshold, never while the keyboard is up), then a 400 ms debounce, then `layout`. At most one layout per second; a newer request replaces a waiting one.
3. `pt_rdp_layout` sends one monitor through display control's `SendMonitorLayout` (flags primary, left/top 0, the fields above; orientation 0 or 90 for information). Before the display-control channel has opened it returns 0 and the request is kept and sent when it does.
4. Windows answers with a resize: FreeRDP's `DesktopResize` → `gdi_resize` → `desktop` callback → a new `ScreenSurface` → `.size`. Until then the old picture stays, scaled.
5. If no resize arrives within 3 s the request is forgotten and a notice says "*Office-PC* kept its screen as it was." (once per view). A PC whose display control never opens gets the first size only.

A text-size change sends the same layout with a new scale factor; Windows applies it without a new sign-in on Windows 10 1803 and later (*unverified* for the session's already-running apps: on the real-PC checklist).

#### Background and return

- **Leaving** (`didEnterBackground`): `setActive(false)` → `pt_rdp_suppress_output(1)` (the PC stops sending pictures), a background task is begun, and after 20 s still in the background the backend is closed with a clean disconnect. Windows keeps the session, disconnected, and the PC's own screen stays locked.
- **Returning** (`willEnterForeground`): if the session is still up, `suppress_output(0)` and it is live at once. If it was closed for the background, or died while suspended, the model reconnects by itself: the last picture dimmed, "Reconnecting…", a new `ShellClient`, `rdp`, the same account. Windows reattaches the same session.
- The login for that reconnect is the one this view signed in with, kept in memory for as long as the view is open (cleared in `stop()`), so a login the user chose not to remember still survives a trip to another app. Nothing is read from the Keychain for a reconnect.
- Automatic reconnects (background or a dropped link) are limited to 2 in a row; a session that was live for 30 s resets the count. That keeps a flapping link under the host's cap of 4 `rdp` opens in 10 minutes, where an open that lasted over 30 s does not count (master plan §2 *Guessing*). The third failure shows "The connection to *Office-PC* was lost." with **Try again**.
- A view that ended because someone signed in at the PC never reconnects by itself.

### 4. Build and vendoring

#### Pins (as of 2026-11-21; re-check at implementation)

| Component | Version | Pin |
|---|---|---|
| FreeRDP | 3.33.1, released 2026-11-10 | tag `3.33.1`, commit `65bcca1913a28cbdd7eb913599f692bd2b707991`; archive `https://pub.freerdp.com/releases/freerdp-3.33.1.tar.gz`, SHA-256 written into the script when PR 2 is made |
| OpenSSL | newest 3.5.x (the LTS line) | release tarball from `github.com/openssl/openssl/releases`, SHA-256 from the release page, checked against the signed `.sha256` |

3.33.1, not 3.33.0: the direct VideoToolbox H.264 backend arrived in it (release notes: "apple videotoolbox h264 encoder/decoder support"; `cmake/ConfigOptionsVideoToolbox.cmake` enables `WITH_APPLE_VIDEOTOOLBOX` by default for `CMAKE_SYSTEM_NAME` `iOS` ≥ 8.0 and `Darwin` ≥ 10.10). Upstream's own iOS notes still ask for FFmpeg for H.264 (`docs/README.ios`); that predates the backend and we do not follow it.

#### `scripts/build-freerdp.sh`, step by step

1. `set -euo pipefail`; refuse to run unless `xcodebuild`, `cmake` ≥ 3.30 (upstream's iOS project asks for it) and `ninja` are present; print their versions.
2. Download both archives into gitignored `Vendor/freerdp-src/` (add to `.gitignore` beside `Vendor/hev-socks5-tunnel/`); verify each SHA-256 against the constants at the top of the script; stop on mismatch. No `git clone` of a moving branch.
3. Unpack fresh (delete any earlier tree); apply `Vendor/FreeRDP/patches/*.patch` with `patch -p1`; a patch that does not apply stops the script.
4. For each slice (`iphoneos` arm64 min 17.5; `iphonesimulator` arm64 min 17.5; `macosx` arm64 min 14.5):
   - **OpenSSL**: `./Configure <target> no-shared no-tests no-apps no-docs no-engine no-dso no-module no-legacy no-ui-console no-comp no-ssl3 no-dtls no-srp no-psk no-sm2 no-sm3 no-sm4 no-idea no-seed no-camellia no-aria no-bf no-cast no-whirlpool no-rmd160 no-mdc2 no-ocb no-siv no-cms no-ts no-ct no-ocsp --prefix=<slice>/ossl -Os`, with targets `ios64-xcrun`, `iossimulator-arm64-xcrun`, `darwin64-arm64-cc` and the min-version flag; `make build_libs install_dev`. (MD4 and RC4, which NTLM needs and OpenSSL 3 keeps in its legacy provider, come from FreeRDP's own code: next step.)
   - **FreeRDP**: `cmake -G Ninja` with `cmake/ios.toolchain.cmake` (`PLATFORM=OS64` / `SIMULATORARM64`, `DEPLOYMENT_TARGET=17.5`) for iOS, plain `CMAKE_OSX_ARCHITECTURES=arm64 CMAKE_OSX_DEPLOYMENT_TARGET=14.5` for the Mac, and:
     ```
     -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_SHARED_LIBS=OFF -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF
     -DOPENSSL_ROOT_DIR=<slice>/ossl -DCMAKE_FIND_ROOT_PATH=<slice>/ossl
     -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT=OFF -DWITH_CLIENT_SDL=OFF -DWITH_SERVER=OFF -DWITH_SAMPLE=OFF
     -DWITH_CHANNELS=ON -DWITH_CLIENT_CHANNELS=ON -DWITH_MANPAGES=OFF -DWITH_WINPR_TOOLS=OFF -DBUILD_TESTING=OFF
     -DWITH_APPLE_VIDEOTOOLBOX=ON -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_CAIRO=OFF -DWITH_OPENH264=OFF
     -DWITH_JPEG=OFF -DWITH_OPUS=OFF -DWITH_FDK_AAC=OFF -DWITH_GFX_AV1=OFF -DWITH_RDPEUDP=OFF -DWITH_OPENCL=OFF
     -DWITH_AAD=OFF -DWITH_KRB5=OFF -DWITH_PKCS11=OFF -DWITH_SMARTCARD_EMULATE=OFF -DWITH_FUSE=OFF
     -DWITH_CLIPRDR_FILE_APPLE=OFF -DWITH_MACAUDIO=OFF -DWITH_THIRD_PARTY=OFF -DWITH_CCACHE=OFF
     -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_MD5=ON -DWITH_INTERNAL_RC4=ON
     -DWITH_VERBOSE_WINPR_ASSERT=OFF -DWITH_DEBUG_ALL=OFF -DWITHOUT_FREERDP_3x_DEPRECATED=ON
     -DCHANNEL_DRDYNVC=ON -DCHANNEL_RDPGFX=ON -DCHANNEL_DISP=ON -DCHANNEL_CLIPRDR=ON
     ```
     and `-DCHANNEL_<X>=OFF` for every other folder under `channels/` at the tag: `AINPUT AUDIN DRIVE ECHO ENCOMSP GEOMETRY GFXREDIR LOCATION PARALLEL PRINTER RAIL RDP2TCP RDPDR RDPEAR RDPECAM RDPEI RDPEMSC RDPEWA RDPSND REMDESK SERIAL SMARTCARD SSHAGENT TELEMETRY TSMF URBDRC VIDEO`. The script lists `channels/*/` itself and fails if it finds a folder that is neither in the on list nor the off list, so a channel added upstream can't slip in.
   - `-DWITH_SMARTCARD_EMULATE=OFF` is what removes the zlib requirement (`CMakeLists.txt:139-143`). At the tag there is no `BUILTIN_CHANNELS` switch: client channels are always object libraries compiled into the client library (`channels/CMakeLists.txt:172-190`).
   - `cmake --build`, `cmake --install` into `<slice>/out`.
   - Merge `libfreerdp-client3.a`, `libfreerdp3.a`, `libwinpr3.a`, `libssl.a`, `libcrypto.a` into `libfreerdp-vendor.a` with `libtool -static`; `strip -S`.
   - **Checks, each failing the script**: `nm -g` shows no `dlopen` reference from `addin.o`; no symbol matching `rdpsnd|rdpdr|drive_|printer_|smartcard_|rail_|urbdrc|tsmf` is defined; `g_Subsystem_VideoToolbox` is defined; the library's public symbols do not collide with `IrohLib` (a list of the iroh framework's exported C symbols is compared).
5. Headers: `<slice>/out/include/freerdp3/freerdp`, `winpr3/winpr` and the generated config headers are copied to one `Headers/` tree, with a `module.modulemap` declaring module `FreeRDPVendor` whose umbrella is a single header listing the fifteen headers the shim includes. OpenSSL's headers are not shipped: the shim does not use them (the test stand-in gets them from the build tree through an environment variable, on the Mac only).
6. `xcodebuild -create-xcframework -library … -headers …` ×3 → `Vendor/FreeRDP/FreeRDP.xcframework`.
7. Write `Vendor/FreeRDP/SOURCES.lock` (versions, commit, archive hashes, the Xcode and CMake versions used, every CMake and Configure flag) and the per-slice byte sizes into `Vendor/FreeRDP/SIZE.md`.
8. Print the three sizes and "built Vendor/FreeRDP/FreeRDP.xcframework".

Committed under `Vendor/FreeRDP/`: the xcframework, `Package.swift`, `patches/`, `SOURCES.lock`, `SIZE.md`, `LICENSES.md` (FreeRDP and WinPR: Apache-2.0 with their `LICENSE` text; OpenSSL: Apache-2.0; the bundled notices upstream requires). Not committed: sources and build trees.

#### `project.yml`, CI, size

- `project.yml`: under `Passthrough` add `- package: PassthroughCore` / `product: RemoteDesktop` with the comment "Remote Desktop to a PC. App only: never link it into an extension." Nothing else changes; the tunnel, widget and notification targets do not get it. `Config/Package.resolved` does not change (a local path package has no pin).
- CI: no FreeRDP build in the normal jobs; they consume the committed binary. `core-tests` gains the shim's compile (seconds). New workflow `vendor-check.yml`, on `workflow_dispatch` and on any PR touching `scripts/build-freerdp.sh` or `Vendor/FreeRDP/**`: runs the script on `macos-15`, then compares the fresh `SOURCES.lock` and the exported-symbol list of each slice with the committed ones (byte-for-byte equality is not promised by the toolchain, so it is not required), and uploads the fresh xcframework as an artifact. Timeout 60 minutes.
- Expected size, to be replaced by measurements in PR 2 and PR 4: each slice's static library 12–20 MB (so 35–60 MB committed, against 10 MB for everything under `Vendor/` today); the iOS app's zip grows by an estimated 4–7 MB after dead-stripping (OpenSSL about 2.5 MB, FreeRDP and WinPR 2–4 MB). Recorded in `Vendor/FreeRDP/SIZE.md` and in CONTRIBUTING's size sentence (`CONTRIBUTING.md:31`), measured as that sentence was: the zip of an unsigned Release build before and after.

#### After an upstream advisory

FreeRDP's releases this autumn each close a dozen or more advisories (3.32.2, 3.33.0 and 3.33.1 list 11 to 19 each), so this is routine work, not an exception. The rule, written into CONTRIBUTING and SECURITY.md:

1. Watch `FreeRDP/FreeRDP` releases and security advisories, and OpenSSL's security page.
2. For each advisory, decide whether it touches code we build: core, crypto, gdi, codec, cache, the `rdpgfx`, `disp`, `cliprdr`, `drdynvc` channels, client/common, WinPR. Server-only and disabled-channel advisories are noted and skipped.
3. Deadline: **7 days** from publication for one that touches our build and can be triggered by the server; **30 days** otherwise, by taking the next upstream release. Past the deadline, the PC screen is turned off in the app by a one-line change (the kill switch in *Security considerations*) until the rebuild lands.
4. The rebuild PR: bump the three constants, run the script, commit the outputs, run `swift test` and the short real-PC list (*Tests*), update `THIRD_PARTY_NOTICES.md`, `SIZE.md`, and the changelog line "Remote Desktop engine updated to FreeRDP x.y.z (security)".

### 5. Sign-in

#### The sheet (reuses `ScreenLoginForm`)

`ScreenLoginForm` gains a `style` and returns `ScreenLogin`:

```swift
enum Style {
    case mac(name: String)                                   // today's text, unchanged
    case windows(name: String, account: String?, device: String)
}
```

For `.windows`, with the master plan's wording (§1 *Screen, first time*):

- Title: "Sign in to *Office-PC*".
- Body: "Windows asks for your account's password, not your PIN. Passthrough passes it to Windows and keeps it on this iPhone behind Face ID."
- One secure field labelled "Password for *name@outlook.com*", the account taken from `host.user`; focus starts there. The account field is hidden until **Use a different account** (a plain button under the field) reveals it, pre-filled and editable, with the placeholder "Account name or email".
- **Remember on this iPhone**, on. The caption under it reads "Behind Face ID" / "Behind Touch ID" / "Behind your passcode" by what the device has (`LAContext.biometryType`).
- Error line, when shown: the sentence for the problem (*UX states*).
- **Sign in** (disabled while the password is empty) and **Cancel**.
- When `host.user` is absent (an older PC build, or the account has no name to show) the account field is shown from the start.

Account forms accepted, split in `WindowsAccount.parse` (pure, tested): `DOMAIN\user` → domain and user; `user@host` → user as typed, no domain; `user` → user, no domain; `.\user` → user, no domain. Leading and trailing spaces are trimmed; an empty user is refused in the form.

#### The store (generalising `ScreenLoginStore`)

```swift
enum ScreenLoginStore {
    enum Realm: String { case screenSharing, windows }
    struct Key: Hashable { var hostID: String; var realm: Realm; var account: String }   // account: lowercased, trimmed

    static func read(_ key: Key, context: LAContext) -> ScreenLogin?          // never prompts (as today)
    static func readAsking(_ key: Key, reason: String) async -> ScreenLogin?   // one system prompt, then reads
    @discardableResult static func save(_ login: ScreenLogin, key: Key, context: LAContext) -> Bool
    static func delete(_ key: Key)
    static func deleteAll(hostID: String)                                      // the computer was forgotten or revoked
    static func savedAccounts(hostID: String, realm: Realm) -> [String]        // names only, from an index; no Keychain read
    static func lastAccount(hostID: String) -> String?
}
```

- Screen Sharing items keep today's shape exactly (service `<id>.screen-login`, account = Mac id), so nothing saved is lost: `Key(realm: .screenSharing)` ignores `account` and maps to it. `read(macID:)`/`save(_:macID:)`/`delete(macID:)` remain as thin wrappers for the Mac paths.
- Windows items: service `<id>.screen-login.windows`, `kSecAttrAccount` = `hostID` + U+001F + account. Same protection as today: `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`, `.userPresence`, data-protection Keychain (`ScreenLoginStore.swift:19-21`, `:44`). Value: JSON `{ "username": …, "password": … }` with the username as typed.
- The index of saved account names and the last account used are `UserDefaults` (`screenLoginAccounts.<hostID>`, `screenLoginLast.<hostID>`): names are not secret, and a protected item cannot be listed without a prompt.

#### Opening the screen

1. Account = `lastAccount(hostID)` ?? `host.user`.
2. If the index says a login is saved for it: `read` with the app lock's context. The app was unlocked moments ago, so this returns without a prompt, as for a Mac.
3. If that returns nil though the index says one is saved (the context is stale, or the lock is off in Settings): `readAsking` shows one system prompt, reason "Sign in to *Office-PC*". Cancel or failure falls to the sheet, with the saved login untouched.
4. No saved login: the sheet.

A device without a passcode can't save (the access control fails to create): the toggle is off and disabled, captioned "Set a passcode on this iPhone to remember it."

#### Forget rules

| Event | Saved login for that host + account |
|---|---|
| Windows refused the password (`wrongPassword`) | deleted, then the sheet |
| Password expired or must change | deleted |
| Account locked, disabled, or not allowed remotely | kept (the password may be right) |
| Certificate mismatch, rate limit, any transport failure | kept |
| Signed in with *Remember* off | deleted if one was saved |
| *Use a different account* | the other account's login is kept |
| The computer is forgotten, or `not_authorized` says access was revoked | `deleteAll(hostID)` |
| The app's "Forget saved sign-ins" row for that computer (its page, shown when any are saved) | `deleteAll(hostID)` |

Saving happens only after Windows accepted the login (phase `signedIn`), as for a Mac (`ScreenModel.swift:524-526`).

### 6. Keys

#### Key row for a PC (when `capabilities` has `.windowsKeys`)

`esc`, `tab`, `ctrl`, `alt`, `⊞`, `←`, `↑`, `↓`, `→`, copy, paste: the master plan's row. Against the Mac's row (`ScreenCanvas.swift:1003-1016`): ⌥ becomes `alt`, ⌘ becomes `⊞`, `fn` is gone. `ScreenKeyRow.build` takes the key list from the canvas (`keys(for: capabilities)`) instead of a literal.

`⊞`: a tap arms it for the next key, like the other modifiers. A second tap within 0.35 s sends the Windows key alone (Start) and disarms. A second tap later than that disarms.

#### Keysym → scancode (`WindowsKeymap.swift`, pure and tested)

- `static func scancode(for key: ScreenKey) -> (code: UInt8, extended: Bool)?` over one table: every `ScreenKeys` constant (Esc 0x01, Tab 0x0F, Return 0x1C, Backspace 0x0E, arrows E0 4B/48/4D/50, Home E0 47, End E0 4F, Page Up E0 49, Page Down E0 51, Insert E0 52, Delete E0 53, F1–F10 0x3B–0x44, F11 0x57, F12 0x58, Control 0x1D, Shift 0x2A, Alt 0x38, Windows E0 5B, Print Screen E0 37) and the US-layout position of every printable ASCII character with whether it needs Shift.
- **Text** (no modifier, or Shift only): each UTF-16 unit as a Unicode key event, down then up; Return and Tab as their scancodes. This is what makes dictation, emoji, accents and every IME work without knowing the PC's layout: `KeyboardDocument` already types marked text only once it is final.
- **A key with Control, Alt or Windows held**: scancodes only. Modifiers down in the fixed order, the key's scancode (adding Shift if the character needs it), then everything up in reverse. A character with no entry in the table is dropped and the modifiers are still released.
- `hold(_:down:)` sends the one scancode, for hardware modifiers.

#### Hardware keyboard

`pressesBegan` (`ScreenCanvas.swift:940-967`) asks the model for the mapping, so the canvas stays backend-neutral:

| Key | To a PC |
|---|---|
| ⌘ | Control (default), or ⊞ when *⌘ acts as* is set to *Windows key* |
| ⌥ | Alt |
| ⌃ | Control |
| ⇧ | Shift |
| F1–F12, Esc, Tab, arrows, Home, End, Page Up/Down, forward Delete | their scancodes (F-keys and F13 → Print Screen are added to the `special` table) |
| Globe, Caps Lock | not sent |

*⌘ acts as: Ctrl / Windows key* is a picker at the bottom of the Windows menu, shown while a hardware keyboard is connected, stored in `UserDefaults` (`screenCommandIsWindows`). ⌘Tab, ⌘Space, ⌘H and Globe shortcuts belong to iPadOS and never reach the app; the Windows menu has Alt+Tab and Start for that.

#### The Windows menu (replaces *Desktops* when `.windowsKeys`)

`ScreenWindowsMenu`, an `Equatable` view like its siblings. Items and what each sends:

| Item | Sent |
|---|---|
| Ctrl+Alt+Del | Control↓ Alt↓ Delete↓ Delete↑ Alt↑ Control↑ |
| Start | Windows↓ Windows↑ |
| Task View | Windows + Tab |
| Alt+Tab | Alt + Tab |
| Show desktop | Windows + D |
| Close window | Alt + F4 |
| Delete | Delete |
| F1–F12 (a submenu) | the key |
| Lock | the shell connection's `lock`, as the Mac's item does (`ScreenView.swift:477`); shown when `host` says the PC can be locked |
| ⌘ acts as (hardware keyboard only) | setting |

No Sign out (master plan). The menu's section header reads "Or swipe with three fingers" over Task View, Show desktop and the two desktop moves, as the Mac's does (`ScreenView.swift:468`).

#### Three-finger swipes on a PC

| Swipe | Sent |
|---|---|
| left | Control + Windows + → (the next virtual desktop comes in from the right, as on a Mac) |
| right | Control + Windows + ← |
| up | Windows + Tab (Task View) |
| down | Windows + D (Show desktop) |

Pinch always zooms this view: `pinchToMac` is false without `.macStream`, so `macPinch`/`macRotate` stay off (`ScreenCanvas.swift:402-404`).

#### Pointer and scroll

`pt_rdp_mouse` sends a move, and a button event when `buttons_changed` is non-zero (left/right/middle → `PTR_FLAGS_BUTTON1/2/3` with `PTR_FLAGS_DOWN`). Scroll: `capabilities` has `.smoothScroll`; the backend turns pixel deltas into wheel rotation at 120 units per `notch` pixels, keeps the remainder, sends vertical (`PTR_FLAGS_WHEEL`) and horizontal (`PTR_FLAGS_HWHEEL`) separately, each clamped to ±255 per event (the 9-bit field) and split if larger. Fingers moving down bring earlier content in: positive rotation.

#### Copy and paste

Policy unchanged: only on a tap, text only, two minutes on the phone.

- **Copy from PC**: send Control + Insert (not Ctrl+C: master plan). Arm a 2 s window. The PC's clipboard change arrives as a format list; if it offers Unicode text and the window is open, fetch it (`pt_rdp_clipboard_fetch` → format data request for `CF_UNICODETEXT`), convert, `.copied(.text)` → `MacClipboard.put` and "Copied from *Office-PC*". No offer in 2 s → "Nothing was copied. Select something on *Office-PC* first." An offer without text → "Only text can be copied to this iPhone." Over 1 MiB → "That's too long to copy to this iPhone." Format lists arriving with no window open are acknowledged and never fetched: the PC cannot push its clipboard to the phone.
- **Paste on PC**: read `UIPasteboard.general.string` on the tap; over 1 MiB of UTF-16 → "That's too long to paste on *Office-PC*."; else hold it as the *offer*, announce a format list with `CF_UNICODETEXT`, wait for the PC's acknowledgement (or 500 ms), send Shift + Insert. When the PC asks for the data, answer from the offer. The offer lasts 10 s from the tap: within it, any number of requests are answered (Windows' clipboard history asks too); after it, requests are refused and an empty format list is announced. The phone's clipboard is never read except on the tap.
- The capability set sent to the PC carries no file-copy flags; file-contents requests are answered with failure.

### 7. The state machine for a PC

Pure logic in `WindowsScreenFlow` (RemoteDesktop target; time and effects injected; tested row by row), driven by `ScreenModel`.

```swift
struct WindowsScreenFlow {
    enum State: Equatable {
        case askTakeover                              // someone is using it
        case signIn(error: SignInError?)              // the sheet
        case connecting(Step, since: TimeInterval)    // Step: reaching, signingIn, startingSession, notAnswering
        case live(firstTime: Bool)
        case reconnecting(attempt: Int)               // last picture dimmed
        case ended(Ending)                            // a sentence and its buttons
    }
    enum Input { case begin(HostInfo, savedLogin: Bool), takeoverAnswer(Bool), login(ScreenLogin, remember: Bool),
                 shell(ShellClient.Event), backend(ScreenBackendEvent), host(HostInfo), tick(TimeInterval),
                 background, foreground, tryAgain, cancel }
    enum Effect { case openConnection, requestRDP, startBackend(certSHA256: String, ScreenLogin), closeBackend,
                  saveLogin, forgetLogin, announce(String), close }
    mutating func handle(_ input: Input, now: TimeInterval) -> [Effect]
}
```

`ScreenModel.Phase` gains `connecting` detail and a neutral ending so the view needs no PC knowledge: `case connecting(message: String?, action: PhaseAction?)`, `case ended(message: String, actions: [PhaseAction])` (`.tryAgain`, `.done`, `.cancel`, `.connectAnyway`); `.failed(String)` stays as the Mac's and maps to `ended` with **Try again**.

#### Order of events

1. **begin.** No `host` yet for this computer (first connection ever): open the connection and wait for `host` up to 2 s after `ready`; a PC that sends none is treated as `console: unknown`.
2. **Checks from `host` before anything is sent**, first match wins: `screens` lacks `rdp` or `rdp` ≠ `ready` → the refusal sentence for that detail, ended. `console == active && idleSeconds < 120` → `askTakeover`. `console == otherUser` → connecting, with the "someone else" sentence and **Cancel**.
3. **Login.** Saved → use it. None → `signIn(nil)`. The connection is opened only after there is a login in hand, so an idle sheet never holds a relay slot or counts against the cap.
4. **Reaching.** New `ShellClient` (as `open(video:)` does today) → `.ready` → `requestScreen(.rdp)`.
5. **`.rdp(stream, initialBytes, certSHA256)`** → `startBackend`. Step `signingIn`, timers start.
6. Backend phases move the step; the first `.size` makes it `live`.

#### Connecting phases and timers

| Step | Entered | Shown | Leaves when |
|---|---|---|---|
| reaching | the connection is opened | "Reaching *Office-PC*…" | `rdpReady`; or a refusal; or `disconnected` → "Can't reach *Office-PC*. It may be asleep, off, or offline." **Try again**; `ShellClient` already bounds each dial (4 s per address, 10 s for iroh: `ShellClient.swift:177-179`) |
| signingIn | backend started | "Signing in to Windows…" | backend `.phase(.signedIn)`; or 5 s → startingSession; or an ending |
| startingSession | 5 s after signingIn began with no picture, or on `.signedIn` | "Windows is starting your session. After a restart this can take a minute." | first `.size` → live; 20 s after signingIn began **and not yet signed in** → notAnswering; 90 s after `.signedIn` with no picture → ended "Windows didn't start a session on *Office-PC*." **Try again** |
| notAnswering | 20 s, sign-in not complete | "Windows isn't answering at sign-in. This happens on some Windows 11 versions." **Try again** | still connecting underneath: a late `.signedIn` returns to startingSession; **Try again** closes and starts over (it counts as one of the host's opens); 60 s in all → closed, same sentence |

Backend phases come from the shim: `negotiating` (the X.224 request is written), `identityChecked` (our certificate check passed), `signedIn` (FreeRDP's `PostConnect`: NLA and the connection sequence are done), then the first paint.

#### Endings: what FreeRDP or the host says → what is shown

`RDPEndReason.classify(_ end: pt_rdp_end, logon: [(data, type)], closedHere: Bool) -> ScreenEnd` (pure, tested with every row):

| Cause (checked in this order) | `ScreenEnd` | Sentence (master plan's unless marked new) | Buttons |
|---|---|---|---|
| `certificate_refused` | `.identityMismatch` | "This isn't the Remote Desktop *Office-PC* told us to expect, so nothing was sent." | **Done** only |
| `closedHere` / `aborted` | `.closedHere` | none | |
| `FREERDP_ERROR_CONNECT_WRONG_PASSWORD`, `…_LOGON_FAILURE`, `FREERDP_ERROR_AUTHENTICATION_FAILED` | `.signIn(.wrongPassword)` | sheet: "Windows didn't accept that password. If you changed it, type the new one." Saved login forgotten | retype |
| `…_ACCOUNT_LOCKED_OUT` | `.signIn(.accountLocked)` | "Windows has locked this account after too many wrong passwords. Wait, or unlock it at the PC." | **Done** |
| `…_PASSWORD_EXPIRED`, `…_PASSWORD_MUST_CHANGE`, `…_PASSWORD_CERTAINLY_EXPIRED` | `.signIn(.passwordExpired)` | "Windows wants a new password for this account. Change it at the PC." | **Done** |
| `…_LOGON_TYPE_NOT_GRANTED`, `…_ACCOUNT_RESTRICTION`, `…_ACCESS_DENIED`, `FREERDP_ERROR_INSUFFICIENT_PRIVILEGES`, `FREERDP_ERROR_SERVER_INSUFFICIENT_PRIVILEGES`, error info `SERVER_INSUFFICIENT_PRIVILEGES` (9) | `.signIn(.notAllowedRemotely)` | "This account isn't allowed to sign in through Remote Desktop. Allow it in Passthrough's settings on *Office-PC*." | **Done** |
| `…_ACCOUNT_DISABLED`, `…_ACCOUNT_EXPIRED` | `.signIn(.accountDisabled)` | new: "This account is turned off on *Office-PC*." | **Done** |
| `…_NO_OR_MISSING_CREDENTIALS` | `.signIn(.other)` | the sheet, no error | retype |
| `FREERDP_ERROR_SECURITY_NEGO_CONNECT_FAILED`, `…_HYBRID_REQUIRED_BY_SERVER`, `…_NTLM_BLOCKED`, `FREERDP_ERROR_TLS_CONNECT_FAILED` | `.unsupported` | new: "*Office-PC*'s Remote Desktop wouldn't sign in the way Passthrough requires. Check Remote Desktop in Passthrough's settings there." | **Try again** |
| error info `DISCONNECTED_BY_OTHER_CONNECTION` (5) | `.takenOver` | "Someone signed in at *Office-PC*, so this view ended." | **Try again** only; never automatic |
| error info `RPC_INITIATED_DISCONNECT_BY_USER` (0xB), `LOGOFF_BY_USER` (0xC), `RPC_INITIATED_LOGOFF` (2) | `.signedOut` | new: "You were signed out of Windows on *Office-PC*." | **Try again**, **Done** |
| error info `RPC_INITIATED_DISCONNECT` (1), `SERVER_DENIED_CONNECTION` (7), `IDLE_TIMEOUT` (3), `LOGON_TIMEOUT` (4), licence codes 0x100–0x10A | `.hostEnded` | new: "Windows on *Office-PC* ended the session." (licence: "…ended the session: it has no Remote Desktop licence to give.") | **Try again** |
| `transport_closed`, `FREERDP_ERROR_CONNECT_TRANSPORT_FAILED`, anything else | `.connectionLost` | see below | |

`.connectionLost` is the ambiguous one: the relay carries opaque bytes, so a closed stream may be a dropped link, the Screen switch turned off, or **Stop** on the PC. Resolution, in order:

1. If the shell connection (the app's ordinary one to that PC, in `ShellModel`) has delivered a reason for this view in the last 5 s (see *Corrections*: `screenEnded` with `switched_off` or `stopped`), use it: "*Office-PC* turned Screen off for this iPhone." **Done**, or "This view was stopped from *Office-PC*." **Try again**. No reconnect.
2. Otherwise, if it had been live: `reconnecting` (last picture dimmed, "Reconnecting…"), up to the limit in section 3. The reconnect's own answer classifies the rest: `screen_not_allowed` → the Screen-off sentence; `rdp_unavailable` → its detail's sentence; `rdpReady` → carry on.
3. Otherwise, or past the limit: "The connection to *Office-PC* was lost." **Try again**.

Host refusals to `rdp` (`ShellClient.Event.failed`):

| Error | Sentence | Buttons |
|---|---|---|
| `screen_not_allowed` | "Screen is off for this iPhone. On *Office-PC*, open Passthrough's settings and turn on Screen for it." | **Done** |
| `too_many_screens` | new: "*Office-PC*'s screen is already open on as many devices as it allows." | **Try again** |
| `try_later` | "Too many sign-ins from this iPhone. Try again in 10 minutes." | **Done** |
| `rdp_unavailable` `off` | "Remote Desktop is off on *Office-PC*. Turn it on in Passthrough's settings there." | **Try again** |
| `rdp_unavailable` `edition` | "*Office-PC* runs Windows Home, which has no Remote Desktop. The shell works." | **Done** |
| `rdp_unavailable` `account` | "Your account on *Office-PC* has no password Remote Desktop can use. Add one on the PC." | **Done** |
| `rdp_unavailable` `service` | new: "Remote Desktop isn't running on *Office-PC*. Restart the PC, or turn it on in Passthrough's settings there." | **Try again** |
| `rdp_unavailable` `exposed` | new: "Remote Desktop on *Office-PC* is open to the network, so Passthrough won't use it. Close it in Passthrough's settings there." | **Done** |
| `bad_request` (a PC build from before stage 5) | new: "Update Passthrough on *Office-PC* to see its screen." | **Done** |
| `screen_only`, `not_authorized` | today's handling (`ScreenModel.swift:405-407`); `not_authorized` also forgets saved sign-ins for the host | |

Other rows of the master plan's table:

- **Before taking a PC someone is using**: `askTakeover` shows "Someone is using *Office-PC* right now. Connecting locks its screen and they lose their place." with **Not now** (the default: the prominent button, the one Return and VoiceOver's first focus land on) and **Connect anyway**. *Not now* closes the view. The check is made on the `host` in hand when the view opens and again when the fresh screen connection's own `host` arrives, before `rdp` is sent; a reconnect of a view that was live does not ask again.
- **Another account signed in**: while `host.console == otherUser`, the connecting view shows "Someone else is signed in to *Office-PC*. Windows is asking them to let you in." with **Cancel**, in place of the step's own sentence, and the 20 s and 90 s timers are suspended (Windows waits for that person; the spike measures for how long). The same sentence is shown if the backend reports the logon notice Windows sends for a busy session (`.notice(.sessionBusy)` from the `LogonErrorInfo` callback; the values that mean it are confirmed by the stage 0 relay spike).
- **Live, first time**: once per computer (`UserDefaults` `screenLockedNoticeShown.<hostID>`), the notice capsule shows for 6 s: "*Office-PC*'s own screen is locked while you're here, and stays locked when you leave."
- **Path**: the Display menu's first row reads "Through Windows Remote Desktop · direct" (or "· on this network", "· via relay") from `connectionPath`; the bar shows "via relay" only then, where `slowReason` is shown today (`ScreenView.swift:206-207`).

### 8. iPad

- **Trackpad and mouse** already drive the far pointer whatever the touch mode (`ScreenCanvas.swift:175-193`); for a PC the secondary click is the right button, and scrolling uses the wheel path of section 6 with horizontal scroll. The iPad's pointer is already hidden over the screen. A middle-button click (a mouse's wheel button) is added: `buttonMaskRequired = .init(rawValue: 4)` → `.middle`; harmless for a Mac.
- **Pencil**: unchanged (a pen on the screen).
- **Hardware keyboard**: section 6. With one attached the key row shows by itself (`ScreenView.swift:65-69`), now the Windows row.
- **Floating bar**: *Desktops* becomes *Windows* (label "Windows", symbol `square.grid.2x2`) when `.windowsKeys`; the microphone button is absent (it reads `canUseMicrophone`); the hint line reads "Drag to move · tap to click · three fingers switch desktops · or use a trackpad" as today, with "Through Windows Remote Desktop · via relay" taking its place when relayed.
- **Split View, Slide Over, Stage Manager**: the view's area changes freely; *Fit* follows it through the same debounce, with the one-per-second limit. Below 200 points on either side the desktop keeps its last size and is scaled. An external display is not used.
- **Shape**: *Fit to this iPad* gives a desktop of the iPad's own pixels (2 064×2 752 on the 13-inch); *Standard* is 2 560×1 600.

### 9. Accessibility

- **Phases are announced**: each change of the connecting sentence, each ending, and "Connected to *Office-PC*" on live post `UIAccessibility.post(.announcement)`; the connecting view's text is also a live label so a focus resting there reads the new one.
- **The takeover prompt's default is the safe one**: *Not now* is first in the accessibility order, is the `.borderedProminent` button and takes Return; *Connect anyway* has the hint "Locks the PC's screen for whoever is using it."
- **Keys named in words**: key row labels "Escape", "Tab", "Control", "Alt", "Windows key" (hint: "Double-tap twice for Start", value "held" when armed), arrows as today, "Copy from the PC to this iPhone", "Paste on the PC". Menu items read "Control Alt Delete", "Alt Tab", "F 1"… not symbols.
- **The sheet**: the password field's label is the full "Password for *account*"; the error is announced when it appears and focus moves to the field; *Use a different account* is a button, not a link in text.
- **The canvas** is one element labelled "*Office-PC*'s screen", trait `allowsDirectInteraction`, as a remote picture must be; the Windows menu makes every swipe's action reachable without gestures. (The Mac's canvas gets the same label in PR 1's wake; it has none today.)
- **Dynamic Type**: the sheet, the prompt and every ending scroll and wrap (`fixedSize(horizontal: false, vertical: true)` as the form does at `ScreenView.swift:655`); the key row keeps its size, as today.
- **Reduce Motion**: the dimming and the bar's slide use opacity only when it is on. **Colour**: an ending's kind is carried by its symbol and sentence, never by the warning tint alone.
- **Switch Control and Full Keyboard Access**: every bar control is a real `Button`/`Menu` (already so); with Full Keyboard Access on, Tab belongs to iOS, so the Windows menu's F-keys submenu gains a "Tab" item when `UIAccessibility.isFullKeyboardAccessEnabled` (hypothetical API name: use whatever the SDK offers; otherwise always show it).

### 10. Performance and battery

#### What is measured, and how

On an iPhone (the oldest A-series the owner has, and a current one) and an iPad, against the owner's PC, on Wi-Fi, cellular direct and cellular through the relay. Three workloads, five minutes each: text editing and scrolling a web page; a 1080p video in a browser window; idle desktop.

| Measure | Tool | Pass line |
|---|---|---|
| Frames presented per second | a counter in `ScreenSurface.present()` behind `PTScreenStats` (DEBUG and a hidden long-press on the path row), shown as an overlay and logged once a second | ≥ 30 while scrolling; ≥ 24 on video, on Wi-Fi |
| Input-to-photon delay | 240 fps slow-motion video of a key press beside the PC's own display, ten samples | median ≤ 150 ms on Wi-Fi, ≤ 250 ms on cellular direct |
| Data use | bytes through the bridge, both ways, in the same log | reported; no line (it is Windows' encoder) |
| CPU | Instruments *Time Profiler*, engine thread and main | engine thread ≤ 60 % of one core while scrolling |
| Energy | Instruments *Energy Log*, and battery % over 30 minutes of mixed use | reported beside the Mac's stream on the same device |
| Memory | *Allocations* + *VM Tracker*, 30 minutes with ten rotations and five background trips | flat within 5 MB after the first minute |
| Hardware decode | the shim logs FreeRDP's `h264->hwAccel` once per session and which codec each surface command used (counts only) | reported: this is the spike's question |

The numbers go into the flag-off PR's description and into `docs/GUIDE.md` as one line.

#### What "hardware decode" means here, honestly

With `WITH_APPLE_VIDEOTOOLBOX`, FreeRDP decodes H.264 through a `VTDecompressionSession` and asks it for planar YUV in memory (`libfreerdp/codec/h264_videotoolbox.m:327-361`: "Do not ask VideoToolbox to scale, convert to RGB"), then converts to BGRA on the CPU and copies into the primary buffer. So the decode can be hardware while the colour conversion and two copies are not. And Windows decides per region what to send: text and UI usually arrive as its progressive or ClearCodec tiles, decoded on the CPU, with H.264 used for some content or the whole screen depending on the host's settings. Which mix a default Windows 11 host picks is the stage 0 spike's pass/fail line, not something this plan assumes.

#### Fallback, written before the work (master plan §3, spike line)

In order, each tried only if the one before misses the pass lines:

1. **Accept CPU decode.** If the pass lines hold without H.264 being used at all, ship it; set `allow_h264 = 0` if H.264 through this path is slower than the progressive codec (it can be, because of the conversion).
2. **Cap the work**: offer *Standard* as the default shape on phones older than a chosen chip, and cap the desktop at 2 million pixels there.
3. **Zero-copy H.264** for full-screen AVC420 only: a patch that hands the decoded `CVPixelBuffer` to the surface instead of converting (our own patch under `Vendor/FreeRDP/patches`, offered upstream). Only if profiling shows the conversion is the cost.
4. **Pull the PC's own stream forward** (master plan stage 9) if Remote Desktop cannot be made good enough on cellular. That is the owner's call (*Open questions*).

## Pull requests, in order

Titles follow the repo's style ("Area: what it does now").

### PR 1. Screen view: one seam for whatever shows the screen

- **Scope**: section 1 exactly. Neutral types, `ScreenBackend`, the two adapters, `ScreenModel`/canvas/view/key row/login store moved onto them. No PC code, no new behaviour.
- **Files**: add `Sources/PassthroughCore/ScreenInput.swift`; rename `RFBKeys.swift` → `ScreenKeys.swift` (typealias kept); add `Sources/ScreenClient/ScreenBackend.swift`, `ScreenSharingBackend.swift`, `MacStreamBackend.swift`; change `RFBClient.swift`, `ScreenVideoClient.swift` (button type), `iOS/App/Screen/ScreenModel.swift`, `ScreenCanvas.swift`, `ScreenTextInput.swift`, `ScreenView.swift`, `ScreenLoginStore.swift` (returns `ScreenLogin`), `macOS/App/Views/RemoteScreenWindow.swift` (button type only), tests that name `RFBClient.Buttons`.
- **Tests**: the five in *What pins "unchanged"*.
- **Docs**: `docs/GUIDE.md` type table (the row for `ScreenClient`, about line 328) gains the seam; changelog: nothing user-visible, one line under *Unreleased* "Internal: the screen view no longer depends on which protocol shows the screen."
- **By hand**: the Mac checklist at the end of section 1.
- **Leaves out**: the surface event is declared but nothing produces or draws it.

### PR 2. Remote Desktop engine: FreeRDP and OpenSSL, vendored and built by script

- **Scope**: section 4, and the smallest shim that proves the link: `pt_rdp_version()` returning FreeRDP's and OpenSSL's version strings and whether the VideoToolbox subsystem is present.
- **Files**: `scripts/build-freerdp.sh`; `Vendor/FreeRDP/**`; `.gitignore`; `Packages/PassthroughCore/Package.swift`; `Sources/CRemoteDesktop/`; `Sources/RemoteDesktop/EngineVersion.swift`; `.github/workflows/vendor-check.yml`; `THIRD_PARTY_NOTICES.md`; `CONTRIBUTING.md` (vendored list, the rebuild rule, size note placeholder with measured library sizes); `SECURITY.md` (the rebuild deadline).
- **Tests**: `testEngineVersionsMatchTheLock` (the linked library reports the versions in `SOURCES.lock`); `testVideoToolboxIsCompiledIn`; `testNoUnexpectedChannels` (asks the shim for the static channel table's names: exactly `drdynvc`, `rdpgfx`, `disp`, `cliprdr`).
- **By hand**: run the script on a clean checkout; both apps still build; the iOS app does not link the product yet, so its size is unchanged.
- **Leaves out**: any session code. The app does not link it.

### PR 3. Remote Desktop engine: a session over the app's own connection

- **Scope**: sections 2 and 3 in the package: the full shim, the bridge, `RDPSession`, `RemoteDesktopBackend` (a `ScreenBackend`), `ScreenSurface`, `WindowsKeymap`, `WindowsDisplay`, `RDPClipboard`, `RDPEndReason`, `WindowsAccount`. `ShellClient` gains the `rdp` request if stage 1 did not add it (*Interfaces*).
- **Files**: `Sources/CRemoteDesktop/*`, `Sources/RemoteDesktop/*`, `Tests/RemoteDesktopTests/*`, `Tests/CRDPStandIn/*`, `ShellClient.swift`, `ShellClientTests` additions.
- **Tests**: the *RemoteDesktopTests* list under *Tests*.
- **Docs**: `protocol/README.md` gets nothing (no wire change); GUIDE's package table gains `RemoteDesktop`.
- **By hand**: a command-line check in the package, opt-in like the live Screen Sharing test (GUIDE about line 435): `PASSTHROUGH_LIVE_RDP=1 PASSTHROUGH_RDP_HOST=… PASSTHROUGH_RDP_USER=… PASSTHROUGH_RDP_PASSWORD=… PASSTHROUGH_RDP_CERT_SHA256=… swift test --filter testLiveRemoteDesktop` connects from the Mac over a plain TCP `ConnectionStream` to a PC on the LAN (with its Remote Desktop open, for this test only), checks sign-in, a first frame, a resize, and a clipboard round trip.
- **Leaves out**: any iOS UI.

### PR 4. iPhone and iPad: a PC's screen, behind a debug switch

- **Scope**: the app links `RemoteDesktop`; `ScreenModel` opens a PC with it when `UserDefaults` `PTWindowsScreen` is true (off by default; settable in DEBUG builds from the existing debug settings, and by `defaults` on a development device). The canvas's surface path. A bare flow: `host`-less, the existing connecting sentence, the Mac-style login form, endings as `failed`. Pointer, scroll, text and special keys work; the Mac key row is shown.
- **Files**: `project.yml`; `ScreenModel.swift` (the PC branch, `onSurface`); `ScreenCanvas.swift` (surface layer and link); `ScreenView.swift` (routing); `iOS/App/Screen/WindowsScreen.swift` (new: the model's PC half, kept out of the 1 200-line file).
- **Tests**: `ScreenSurfaceTests` (swap, missed rectangles, try-lock) in the package.
- **Docs**: CONTRIBUTING's size sentence gets the measured app delta; changelog "Not yet: a PC's screen (in progress behind a developer switch)."
- **By hand**: with the switch on, open a PC running stage 5: picture, pointer, typing. With it off: tapping the screen on a PC shows stage 2's "not yet" state unchanged.
- **Leaves out**: everything in PRs 5–8.

### PR 5. PC screen: the Windows sign-in sheet and saved sign-ins

- **Scope**: section 5. Still behind the switch.
- **Files**: `ScreenView.swift` (`ScreenLoginForm.Style`), `ScreenLoginStore.swift`, `WindowsScreen.swift`, the computer's page (the "Forget saved sign-ins" row), `ShellModel`/profile removal paths calling `deleteAll`.
- **Tests**: `WindowsAccountTests` (parse forms); `ScreenLoginKeyTests` (key encoding, legacy mapping, index upkeep) with the Keychain calls behind a small protocol faked in the package; forget-rule table test in `WindowsScreenFlowTests`.
- **Docs**: GUIDE §Windows "Signing in"; SECURITY.md: where the Windows password lives and when it is forgotten.
- **By hand**: first open asks once; second open is one tap with no prompt; wrong password forgets and asks; *Remember* off leaves nothing saved; removing the PC removes its items (check with a second install of the same PC).

### PR 6. PC screen: Windows keys, the Windows menu, gestures, copy and paste

- **Scope**: section 6 and the iPad items of section 8. Behind the switch.
- **Files**: `ScreenCanvas.swift` (key list by capability, `⊞`, swipes as `ScreenSwipe`, hardware map hook, middle button), `ScreenView.swift` (`ScreenWindowsMenu`, clipboard menu labels by host kind), `WindowsScreen.swift`, `RDPClipboard.swift`.
- **Tests**: `WindowsKeymapTests` (every table entry; Shift for shifted characters; unknown character drops cleanly; modifier order and release); `WindowsShortcutTests` (each menu item and swipe → the exact scancode sequence); `RDPClipboardTests` (copy window, unasked offers never fetched, paste offer lifetime, size caps).
- **Docs**: GUIDE §Windows "Keys", "Copy and paste".
- **By hand**: every menu item; the four swipes; Ctrl+C in a console does not arrive from *Copy*; Japanese and emoji typed from the on-screen keyboard; a hardware keyboard with both *⌘ acts as* settings.

### PR 7. PC screen: shape and text size

- **Scope**: the Display menu for a PC (*Fit to this iPhone* / *Standard (16:10)*, text size), per-computer memory (`UserDefaults` `screenShape.<hostID>`, `screenSpace.<hostID>`), resize with debounce, the path row. Behind the switch.
- **Files**: `ScreenView.swift` (`ScreenDisplayMenu` reads capabilities: no quality, curtain, sound or pinch rows without `.macStream`), `WindowsScreen.swift`, `WindowsDisplay.swift`.
- **Tests**: `WindowsDisplayTests`: the table in section 3 for six device sizes × two orientations × three text sizes; even sizes; clamps; the pixel cap; debounce and one-per-second with injected time.
- **Docs**: GUIDE §Windows "Shape and text size".
- **By hand**: rotate five times quickly → one resize; keyboard up → none; Split View on iPad; *Standard* on a phone pans and zooms; text size changes without a new sign-in.

### PR 8. PC screen: every state says what it is

- **Scope**: section 7 and the background/reconnect half of section 3: `WindowsScreenFlow`, the connecting steps, the takeover prompt, every ending, the first-time notice, reconnect, accessibility announcements. Behind the switch.
- **Files**: `Sources/RemoteDesktop/WindowsScreenFlow.swift`, `ScreenModel.swift` (`Phase` detail), `ScreenView.swift` (prompt, endings with their buttons, dimmed last picture), `WindowsScreen.swift`.
- **Tests**: `WindowsScreenFlowTests`: one test per row of both tables in section 7, the timers with injected time, reconnect limits, "taken over never reconnects", "no connection is opened while the sheet waits"; `RDPEndReasonTests`: every row of the endings table.
- **Docs**: GUIDE §Windows troubleshooting: the sentences and what to do.
- **By hand**: the master plan's screen-state list (§6), on Wi-Fi.

### PR 9. A PC's screen on iPhone and iPad

- **Scope**: remove `PTWindowsScreen`; stage 2's "See and control the screen" row opens it for any PC whose `host` lists `rdp`. Measurements. The kill switch constant (`RemoteDesktopBackend.isEnabled`) stays, true.
- **Files**: the switch's uses; `README.md`, `docs/GUIDE.md` (§Windows *Screen*, known limits, the measured line), `CHANGELOG.md` ("Works now: a PC's screen from iPhone and iPad…" / "Not yet: sound, files on the clipboard, Android"), `SECURITY.md` (the section in *Security considerations*), `windows/README.md` checklist cross-reference.
- **Tests**: none new.
- **By hand**: the whole master-plan list on cellular, iPhone and iPad; the 30-minute memory run; the performance table.

Each PR leaves `dev` working: 1 is behaviour-neutral, 2–3 add unlinked or unreached code, 4–8 are behind a switch that is off.

## Interfaces

### This stage defines (others depend on these)

| Name | Shape | Owner | Used by |
|---|---|---|---|
| `ScreenBackend`, `ScreenBackendEvent`, `ScreenCapabilities`, `ScreenLayoutRequest`, `ScreenEnd`, `MacStreamControls` | section 1 | `ScreenClient` target | stage 7c (the Mac's window), a later Android port as a reference |
| `ScreenButtons`, `ScreenLogin`, `ScreenKey`/`ScreenKeys`, `ScreenModifiers` | section 1 | `PassthroughCore` | stage 7c, stage 8b's key mapping as the reference table |
| `ScreenSurface` | section 3 | `RemoteDesktop` (declared in `ScreenClient` as a protocol-free class so the event can carry it) | stage 7c's surface path |
| `RemoteDesktopBackend(stream:initialBytes:certSHA256:login:layout:clientName:queue:onEvent:)` | a `ScreenBackend` | `RemoteDesktop` | stage 7c, inside its sandboxed helper |
| `pt_rdp.h` | section 2 | `CRemoteDesktop` | only `RemoteDesktop` |
| `WindowsKeymap`, `WindowsDisplay`, `WindowsAccount`, `RDPEndReason`, `WindowsScreenFlow` | pure types | `RemoteDesktop` | stage 7c reuses all five; stage 8 ports none |
| `Vendor/FreeRDP/FreeRDP.xcframework` with a macos-arm64 slice, `scripts/build-freerdp.sh`, the rebuild rule | section 4 | repo | stage 7c |
| `ScreenLoginStore.Key` with realms | section 5 | iOS app | stage 7c writes the Mac's equivalent beside it |

### This stage consumes

| From | What | If it is not there when this stage starts |
|---|---|---|
| Stage 1b | `ShellEnvelope` types `rdp`, `rdpReady` with `certSHA256` (hex or base64 as the fixtures say; this stage compares bytes after decoding); errors `rdp_unavailable` + `detail` (`off`, `edition`, `account`, `service`, `exposed`), `try_later`, `too_many_screens`, `screen_not_allowed`; the `host` message decoded as `HostInfo { kind, os, user, signedIn, console, idleSeconds, shells, screens, rdp, sleepAfter }` and `ShellClient.Event.host(HostInfo)` | blocked: PR 3 cannot land |
| Stage 1b or this stage's PR 3 | `ShellClient.requestScreen(_ kind: ScreenRequest)` with `.rdp`, and `Event.rdp(any ByteStream, initialBytes: Data, certSHA256: Data)`. `isScreenReady` (`ShellClient.swift:791-794`) learns `rdpReady`; `handOver` (`:798-808`) passes the hash. `requestScreen(video:)` stays as a wrapper | PR 3 adds it, with `ShellClientTests` for the hand-over and for a `rdpReady` without a valid 32-byte hash being a protocol violation |
| Stage 2 | host kind stored with each computer (`hostKind`), the last `HostInfo` per computer on `ShellModel`, the PC's page with its "See and control the screen" row and the page-level sentences, wording helpers that say "the PC" | PR 4 onward need it; PRs 1–3 do not |
| Stage 5 | a PC that answers `rdp` | needed for every by-hand check from PR 3's live test onward (the live test alone can use a LAN PC directly) |
| Stage 0 spikes | *FreeRDP on an iPhone* (NLA over the hook; which codecs a default host sends; size); *Relay* (what "another account signed in" does; whether same-account sessions reattach) | PR 2 and PR 3 are that spike made permanent if it has not been run; the answers it would have given are the first two items of the real-hardware checklist |

## Tests

### Automated, in `swift test`

**ScreenClientTests** (PR 1): `testScreenSharingBackendBytes`, `testMacStreamBackendMessages`, `testButtonsKeepTheirWireValues`, `testModifierMaskValues`, `testRFBModifierOrderIsFixed`, `testFailureMapping`.

**RemoteDesktopTests** (PRs 2–8). What a fake transport can and cannot do: the first exchange (X.224) is plain and deterministic, so it is tested byte for byte; TLS and NLA use fresh randomness, so a recording cannot be replayed through them. The stand-in therefore goes as far as a real TLS handshake and stops.

- Engine and build: `testEngineVersionsMatchTheLock`, `testVideoToolboxIsCompiledIn`, `testNoUnexpectedChannels`.
- Bridge (`pt_bridge.c` through Swift): bytes in order across wrap-around; `Read` with nothing → `EAGAIN`; closed → 0 only after the ring is empty; the event is set exactly when readable (a feed racing a read, 10 000 iterations on two threads, loses no wake-up); `Write` to a full outbox returns `EAGAIN` and `Wait` returns when drained; abort wakes a `Wait` within 200 ms; the inbox never exceeds 4 MiB while the fake stream offers 64 MiB (receive is paused, nothing dropped, all 64 MiB arrive in order).
- **Recorded negotiation** (`Tests/RemoteDesktopTests/Fixtures/x224-*.bin`): the client's first bytes are a connection request asking for `PROTOCOL_HYBRID` (with or without `HYBRID_EX`) and never for plain TLS or standard RDP security alone; a stand-in answering "selected: standard RDP security" ends `.unsupported` and nothing more is written; "selected: TLS only" the same; a negotiation failure (`HYBRID_REQUIRED_BY_SERVER` is not a failure for us; `SSL_NOT_ALLOWED` is) maps per the table.
- **Certificate pin** (`CRDPStandIn`: answers X.224 with "selected: HYBRID", then serves TLS with a test certificate using the vendored OpenSSL; macOS only): the callback receives that certificate's DER; with the right SHA-256 the phase reaches `identityChecked` and the stand-in sees the first CredSSP bytes; with a wrong one the session ends `.identityMismatch` and the stand-in receives **zero** application bytes after the handshake. Also: a certificate chain whose leaf differs from the pin but whose issuer matches is refused (the pin is on the leaf).
- Teardown: `close()` during negotiation, during TLS, and with the transport stalled each give exactly one `.ended(.closedHere)` within 2 s, the stream cancelled, no thread left (thread count before and after).
- Pure logic: `WindowsKeymapTests`, `WindowsShortcutTests`, `WindowsDisplayTests`, `WindowsAccountTests`, `RDPClipboardTests`, `RDPEndReasonTests`, `WindowsScreenFlowTests`, `ScreenSurfaceTests`, `ScreenLoginKeyTests`.
- Input queue: pure moves coalesce; the cap closes the session; commands after `close()` are dropped.
- Secrets: `String(describing:)` and `dump` of `ScreenLogin` show no password; the shim's log callback is given every FreeRDP log line during the stand-in tests and none contains the test password.

**PassthroughCoreTests** (PR 3, if the client method is added here): `rdp` hand-over, bad hash, an `error` answer leaving the connection a shell connection.

**Opt-in live test**: `testLiveRemoteDesktop` (PR 3).

### Fixtures added

No protocol fixtures (stage 1 owns them). Binary fixtures under `Tests/RemoteDesktopTests/Fixtures/`: the three X.224 answers, one test certificate and key (generated by a committed script, marked test-only), expected scancode sequences as JSON.

### Real hardware (added to `windows/README.md`'s checklist, phone side)

From the master plan's list (§6), each on cellular from an iPhone, then once on an iPad on Wi-Fi: in use at the PC (the prompt, both answers); signed in and idle; locked; signed out after `shutdown /r`; monitor off; lid closed on mains; a UAC prompt (visible and answerable); another account signed in; wrong password; password changed since it was saved; too many tries; Screen switch off mid-view; Remote Desktop turned off in Settings mid-view and before; Windows Home; a sleeping PC; taken back at the PC; return from background after 5 s, after 60 s, after 10 minutes.

Added by this stage:

1. A Microsoft account whose `host.user` is an email signs in with the pre-filled name.
2. A stand-in for Remote Desktop (a test build of the service announcing a wrong hash) → the hard stop, and a packet capture of the relay shows no CredSSP bytes.
3. Text size change mid-session; rotation; Split View.
4. Copy from a console window (Ctrl+Insert does not interrupt it); paste 500 KB of text; copy 2 MB (refused with its sentence).
5. Japanese IME, emoji, dictation.
6. Hardware keyboard and trackpad on iPad: every row of the hardware table; horizontal scroll.
7. VoiceOver through the whole first run.
8. Thirty minutes mixed use: memory flat; the performance table filled in.
9. Which codec the host used and whether `hwAccel` was true (the spike's line).
10. Short list after any engine rebuild: sign in, type, scroll, rotate, copy, paste, background and return.

## Security considerations for this stage

- **What this adds to the app that holds every key.** A large C library parsing bytes from a peer, inside the process that holds the shell keys for every computer. FreeRDP's recent releases each fix many memory-safety advisories, some reachable by a malicious server. Mitigations: the peer is not arbitrary (it is reached only through a host this phone already proved a key to, and only after the certificate matched the one that host announced, so an attacker needs the PC's Remote Desktop itself, or the Passthrough service on it); the build is minimal (four channels, no legacy codecs or caches, no redirection, no add-in loading, no gateway, no UDP); the pin and the rebuild deadline; a kill switch (`RemoteDesktopBackend.isEnabled`, a constant) for the gap between an advisory and a rebuild. iOS offers no helper process to isolate it in; the Mac does, and stage 7c uses one. This is said in `SECURITY.md`.
- **The certificate.** `ExternalCertificateManagement` routes every server certificate to our callback before FreeRDP's own store, its trust-on-first-use path and its `certificates.json` are consulted (`libfreerdp/crypto/tls.c:1808-1826` at the tag). The callback takes the leaf from the PEM chain, hashes its DER with SHA-256 (CryptoKit) and compares in constant time with the 32 bytes from `rdpReady`. No match: return 0, set `certificate_refused`, and nothing of the login has been sent (NTLM starts only after TLS). There is no prompt and no way to continue. FreeRDP's known-hosts file is never written: the config path points at a directory that is never created (`ConfigPath` set to a path under the app's temporary directory, checked absent in a test).
- **NLA only.** A host that selects anything else is refused before TLS. With NLA the password is never sent to a server that cannot prove knowledge of it, and CredSSP binds the TLS public key, so even a certificate-pin bug would not hand the password to a relay in the middle.
- **The password.** In memory: the sheet's field, `ScreenLogin` in the model for the life of the view (for reconnects), the shim's copy, and FreeRDP's settings until `PostConnect`, where the shim overwrites and clears `Password`. The shim zeroes its copies in `pt_rdp_free`. It is never logged: FreeRDP's log is routed through one callback that drops everything below warning in Release and passes the rest through `ptLog` after replacing the username and any line containing "password". At rest: the Keychain item of section 5 only.
- **The clipboard.** Text only, both ways only on a tap, size-capped, the phone's clipboard offered for 10 s after the tap and never otherwise; the PC's clipboard fetched only inside the 2 s after *Copy*. No file lists, no file contents.
- **What the view can do on the PC** is whatever the signed-in Windows account can, UAC and the lock screen included: more than shell access (master plan §2 *Stated honestly*). The first-time notice and the guide say the PC's own screen locks.
- **Rate limits.** The app opens `rdp` only with a login in hand, retries automatically at most twice, and never retries a wrong password, so it cannot lock the account by itself: a saved wrong password costs one attempt, then the sheet.
- **Screen capture.** The PC's screen is covered while the device's screen is recorded or mirrored, by the existing cover (`ScreenView.swift:55`); the sign-in sheet is inside the same view.
- **Client name.** The name sent to Windows is "iPhone" or "iPad", never the device's own name (which is often a person's name) and never the phone id.
- **Supply chain.** Sources are pinned by hash, patches are in the repo, the script is the only way the binary is made, `vendor-check` rebuilds and compares symbols on every change to it. The committed binary is still a binary: a reviewer of a rebuild PR is asked to run the script and compare `SOURCES.lock` and sizes (CONTRIBUTING).

## UX states and strings for this stage

All of the master plan's strings for *Screen, first time*, *Before taking a PC someone is using*, *While connecting*, *Leaving and coming back*, and both state tables (§1) are used as written; section 7 above maps each to its cause. The device word comes from `ThisDevice.name` ("iPhone"/"iPad") wherever the master plan writes "iPhone".

New strings this stage introduces (each marked "new" in section 7 or below), for the owner's eye:

| Where | String |
|---|---|
| Ending | "Windows didn't start a session on *Office-PC*." |
| Ending | "This account is turned off on *Office-PC*." |
| Ending | "*Office-PC*'s Remote Desktop wouldn't sign in the way Passthrough requires. Check Remote Desktop in Passthrough's settings there." |
| Ending | "You were signed out of Windows on *Office-PC*." |
| Ending | "Windows on *Office-PC* ended the session." / "…ended the session: it has no Remote Desktop licence to give." |
| Refusal | "*Office-PC*'s screen is already open on as many devices as it allows." |
| Refusal | "Remote Desktop isn't running on *Office-PC*. Restart the PC, or turn it on in Passthrough's settings there." |
| Refusal | "Remote Desktop on *Office-PC* is open to the network, so Passthrough won't use it. Close it in Passthrough's settings there." |
| Refusal | "Update Passthrough on *Office-PC* to see its screen." |
| Reaching failed | "Can't reach *Office-PC*. It may be asleep, off, or offline." (the page's sentence without "Last heard") |
| Notice | "*Office-PC* kept its screen as it was." |
| Notices | "Copied from *Office-PC*" · "Nothing was copied. Select something on *Office-PC* first." · "Only text can be copied to this iPhone." · "That's too long to copy to this iPhone." · "That's too long to paste on *Office-PC*." (today's sentences with the PC's name) |
| Sheet | "Use a different account" · "Account name or email" · "Sign in" · "Behind Face ID" / "Behind Touch ID" / "Behind your passcode" · "Set a passcode on this iPhone to remember it." |
| System prompt reason | "Sign in to *Office-PC*" |
| Page row | "Forget saved sign-ins" |
| Menus | "Windows" (menu) · "Ctrl+Alt+Del" · "Start" · "Task View" · "Alt+Tab" · "Show desktop" · "Close window" · "Delete" · "Function keys" · "Lock *Office-PC*" · "⌘ acts as" with "Ctrl" / "Windows key" · "Fit to this iPhone" · "Standard (16:10)" · "Through Windows Remote Desktop · direct" / "· on this network" / "· via relay" · "Copy from *Office-PC*" · "Paste on *Office-PC*" |
| Accessibility | "Windows key" · "Connected to *Office-PC*" · "*Office-PC*'s screen" · "Locks the PC's screen for whoever is using it." |

## Risks and how each is retired

| Risk | Retired by |
|---|---|
| NLA does not complete over the transport hook on iOS (blocking waits, WinPR events on iOS) | PR 3's stand-in tests cover the hook through TLS; `testLiveRemoteDesktop` covers NLA from the Mac slice; the first by-hand run of PR 4 covers the phone. If the hook fails: the documented alternative is FreeRDP's older `TCPConnect`/`TransportAttach` callbacks with one end of a `socketpair` and a pump thread. No loopback TCP socket in either case |
| A default Windows 11 host sends mostly CPU-decoded codecs and it is too slow or too hot | The measurements and the four-step fallback in section 10 |
| A local Swift package cannot see `Vendor/FreeRDP` | Avoided by giving `Vendor/FreeRDP` its own one-line `Package.swift`. If Xcode mishandles headers inside a static-library xcframework (it has, with clashing module maps), the fallback is to copy the fifteen headers into `Sources/CRemoteDesktop/vendor-include/` from the script and ship the xcframework without headers |
| OpenSSL symbols clash with another linked library | The script's symbol comparison against `IrohLib`; if they clash, build OpenSSL with a symbol prefix |
| Repository growth: 35–60 MB per rebuild, several rebuilds a year | Measured in PR 2. If over 60 MB, or the owner prefers, the alternative in *Open questions* |
| Upstream's pace of advisories outruns a one-maintainer project | The 7/30-day rule with the kill switch; the minimal build skips most advisories; stage 9's own stream is the long-term exit |
| `IOSurface` as layer contents flickers or leaks on some iOS | The 30-minute memory run; fallback to the sample-buffer layer (section 3) |
| Display control is refused or slow on some Windows builds; text-size changes need a new sign-in | The 3 s give-up and its notice; real-PC item 3. If scale changes need a new sign-in, text size applies at the next connection and the menu says "Applies next time you connect." |
| The main-thread try-lock starves presentation under constant paints | The frame counter; if seen, switch to a third surface so the presenter never contends |
| "Another account signed in" behaves differently from the master plan's sentence | Stage 0 relay spike; the sentence and the timers' suspension are in one place (`WindowsScreenFlow`) |
| Ctrl+Alt+Del, Win+Tab or Ctrl+Win+arrows sent as scancodes do not act in the session | Real-PC check in PR 6; any that fail are removed from the menu with a line in the guide, not faked |
| Letter shortcuts land on the wrong key on a PC with a non-QWERTY layout | Stated in the guide as a limit; see *Open questions* |
| A view cannot learn why the relay closed | *Corrections* item 1; until stage 1/5 carry the reason, the reconnect's answer classifies two of the three cases and "stopped from the PC" reads as a lost connection |
| `host.user` is in a form Windows will not accept for NLA (a Microsoft account's email, a display name) | Real-PC item 1; *Use a different account* is always there; stage 5 can send the form that works once known |

## Decisions made here

1. **The neutral input types live in PassthroughCore, the backend protocol in ScreenClient.** The Mac host and the Mac's window already use the key table and button type; UIKit stays out of both.
2. **Scroll, typing and paste logic move from the model into each backend.** That is where the per-protocol differences are, and it is the only way to test them without an app test target.
3. **Mac-only controls are a side protocol (`MacStreamControls`), not optional methods on `ScreenBackend`.** A PC backend then cannot be asked for a curtain, and the view decides by capability.
4. **Modifiers are a set with a fixed press order.** Simpler than keysym arrays and required for scancodes; the one behavioural nuance is pinned by a test.
5. **The ring buffers and the layer live in C, in the shim.** No Swift closure runs on FreeRDP's read path, and the bridge is testable from Swift.
6. **One thread makes every FreeRDP call.** It relies on the least of FreeRDP's threading promises.
7. **Back-pressure instead of a drop-at-limit on the way in.** A screen stream that loses bytes is dead; pausing `receive` lets the transport slow the PC.
8. **Three copies of the desktop, dirty-rectangle copies, two IOSurfaces.** Tear-free with no per-frame allocation; memory stated and capped.
9. **FreeRDP 3.33.1, not 3.33.0**, for the direct VideoToolbox backend; **no FFmpeg, no OpenH264, no zlib, no JSON library**.
10. **MD4, MD5 and RC4 from FreeRDP's internal code**, so OpenSSL is built without its legacy provider.
11. **A patch removes dynamic add-in loading** rather than trusting that no path reaches it.
12. **`Vendor/FreeRDP` is its own tiny Swift package**, so the binary stays under `Vendor/` per convention and SwiftPM can still name it.
13. **Sources pinned by archive hash, not by clone** (stricter than `build-hev.sh`).
14. **FreeRDP's auto-reconnect is off.** Every connection must pass the relay's `rdp` checks and caps again, and the certificate may have been re-made.
15. **The connection is opened only once a login is in hand**, so a sheet left open holds no relay slot and costs no attempt.
16. **A view's login stays in memory while the view is open**, so returning from the background reconnects even when *Remember* is off.
17. **At most two automatic reconnects in a row**, to stay under the host's four opens in ten minutes.
18. **Lock goes through the shell connection's `lock`**, as for a Mac, not through Win+L.
19. **Windows scale factor from a short-side target in points**, with separate tables for phone and iPad (the numbers are starting points for the owner's eye).
20. **Twenty seconds in the background before disconnecting**; suppress-output at once.
21. **The 20-second "isn't answering" timer runs only until sign-in completes**; after that the session gets 90 s to draw (*Corrections* 2).
22. **Clipboard offer lasts 10 s and answers repeated requests**, because Windows' clipboard history asks more than once.
23. **The client name sent to Windows is the device kind**, not its name.
24. **The PC's keyboard layout is left alone** (`KeyboardLayout` 0); text is Unicode, shortcuts are US positions.
25. **The state machine is a pure type in the package**, so every row of the tables is a unit test.

## Corrections to the master plan

1. **A view cannot tell "Screen turned off" or "stopped from the PC" from a dropped link.** After `rdpReady` the screen connection is opaque bytes, and the *going away* reasons (§2 *Protocol changes*) are defined for the host leaving, on shell connections. The state table has two sentences that need a cause. Proposed for stage 1b (fixtures) and stage 5 (sending it): when the host ends a relay on purpose, it sends `screenEnded` with `reason` (`switched_off`, `stopped`) on every other live connection of that phone, just before closing the relay; and after **Stop** it answers that phone's `rdp` with `try_later` for 30 s so an automatic reconnect cannot undo it. This plan works without it (section 7, `.connectionLost`), with "stopped" degraded to "lost".
2. **The connecting timers are ambiguous.** "After 5 s … this can take a minute" and "after 20 s Windows isn't answering at sign-in" cannot both run from the same start for a PC that really is starting a session after a restart. This plan reads the 20 s as "sign-in has not completed" and gives a signed-in session 90 s to draw (section 7).
3. **"FreeRDP 3.33.x" should read "3.33.1 or later".** The hardware H.264 path the spike asks about does not exist in 3.33.0 without FFmpeg.
4. **"OpenSSL 3 LTS"** should name the line: 3.5.x. The 3.0 line's support has run out or is about to (*unverified*: check OpenSSL's release strategy page when pinning).
5. **"Static channels only" is not a build switch any more.** In 3.33.1 client channels are always compiled in; what remains is a run-time fallback to dynamic loading, which this plan removes with a patch.
6. **The phone has no sentence for `rdp_unavailable` `service` or `exposed`, for `too_many_screens`, or for a PC too old to know `rdp`.** Proposed in *UX states*. (The PC-side wording for *exposed* exists; the phone-side does not.)
7. **Sign-in errors beyond the table**: a disabled or expired account, a signed-out session, and a licence refusal have no row. Proposed in *UX states*.
8. **"Frames land on a shared BGRA surface presented on the display link" understates the cost**: with FreeRDP's VideoToolbox backend the decode may be hardware but conversion to BGRA is CPU work. The spike's line "the hardware H.264 decoder is used" should be read with the frame-rate and energy lines, not alone.
9. **The seam needs one more event than the master plan lists**: connection phases (`negotiating`, `identityChecked`, `signedIn`), or the connecting sentences cannot be driven.
10. **Stage 2 must store the last `host` per computer**, not only the kind: the takeover prompt and the refusals are decided from it before any screen connection exists.

## Open questions for the owner (each with a recommended default)

1. **Commit a 35–60 MB binary on every engine update, or fetch it?** Default: commit, as the master plan says, and revisit if PR 2 measures over 60 MB. Alternative: publish each build as a release asset and name it in `Vendor/FreeRDP/Package.swift` by URL and checksum, as iroh-ffi is consumed; the repo stays small, at the cost of a build that needs the network once.
2. **The rebuild deadline after an advisory.** Default: 7 days when a server can trigger it in code we build, 30 days otherwise, with the PC screen switched off in the app past the deadline.
3. **Text-size targets** (section 3's table). Default as written; they need ten minutes with a real PC and both devices.
4. **Default shape on a phone.** Default: *Fit to this iPhone* (master plan). If Windows dialogs are cramped at the default text size, the alternative is *Standard* by default on phones and *Fit* on iPads.
5. **The PC's keyboard layout.** Default: leave it alone; Ctrl/Alt/Win shortcuts with letters are sent as US key positions, so on an AZERTY or Dvorak PC a few land on other letters (said in the guide). Alternative: ask Windows for the US layout for the remote session, which makes shortcuts exact but can add a layout to the account's language bar.
6. **How long a view survives in the background.** Default: 20 s, then a clean disconnect and an automatic reconnect on return.
7. **If the performance lines are missed after fallback steps 1–3**: ship Remote Desktop as it is with a "works best on Wi-Fi" note, or hold the feature for the PC's own stream (stage 9)? Default: ship with the note; move stage 9 up.
8. **The Remote Desktop licence note in an ending** ("it has no Remote Desktop licence to give"): keep, or fold into the generic "Windows ended the session"? Default: keep; it is the one case with a different fix.
9. **A "Forget saved sign-ins" row on the computer's page.** Default: yes, shown only when something is saved.

## Appendix: FreeRDP facts relied on, and how each was checked

Checked on 2026-11-21 against the source at tag `3.33.1` (commit `65bcca19…`) fetched from GitHub, and the GitHub release notes.

**Verified in source or release notes**

| Fact | Where |
|---|---|
| Latest release is 3.33.1 (2026-11-10); 3.33.0 was 2026-11-02 | GitHub releases API |
| 3.33.1 adds "apple videotoolbox h264 encoder/decoder support" and iOS client fixes including a text clipboard | 3.33.1 release notes |
| `WITH_APPLE_VIDEOTOOLBOX` exists, defaults on for iOS ≥ 8.0 and macOS ≥ 10.10, and turns on GFX H.264 | `cmake/ConfigOptionsVideoToolbox.cmake`; `CMakeLists.txt:461-466`; `libfreerdp/codec/CMakeLists.txt:167-176` |
| That backend decodes to planar YUV in memory, leaves hardware/software choice to Apple, and records `hwAccel` | `libfreerdp/codec/h264_videotoolbox.m:323-392` |
| `rdpTransportLayer` (Read, Write, Close, Wait, GetEvent), `rdpTransportIo.ConnectLayer`/`AttachLayer` since 3.9.0, `transport_layer_new/free`, `freerdp_get/set_io_callbacks`; return and `errno` contract; 3.16 and 3.17 behaviour notes | `include/freerdp/transport_io.h` |
| `transport_connect` calls `ConnectLayer`; the default attach wraps the layer in a BIO; `EAGAIN` → retry; `BIO_C_WAIT_READ/WRITE` → `Wait`; `BIO_C_GET_EVENT` → `GetEvent`; `transport_layer_free` calls `Close` | `libfreerdp/core/transport.c:644`, `:1641-1660`, `:2053-2190` |
| The reference TCP layer resets its event before each read | `libfreerdp/core/tcp.c:1430-1452` |
| `ExternalCertificateManagement` sends every certificate to `VerifyX509Certificate(instance, pem, length, host, port, flags)`; a return ≤ 0 refuses | `libfreerdp/crypto/tls.c:1756-1826`; `include/freerdp/freerdp.h:300-315` |
| `VerifyCertificateEx` and its flags (`VERIFY_CERT_FLAG_FP_IS_PEM` …) | `include/freerdp/freerdp.h:66-73`, `:231-249` |
| Every setting named in section 2's table exists | `include/freerdp/settings_types_private.h` |
| Sign-in failures map from NT status to `FREERDP_ERROR_CONNECT_*` (wrong password, logon failure, locked out, expired, must change, disabled, restriction, logon type not granted, access denied, NTLM blocked) | `libfreerdp/core/nla.c:2285-2380`; `include/freerdp/error.h:300-380` |
| `ERRINFO_*` values (1–0xC, licence 0x100–0x10A) and `freerdp_error_info`, `freerdp_get_last_error`, `LogonErrorInfo` callback | `include/freerdp/error.h:48-77`; `include/freerdp/freerdp.h:317`, `:721`, `:768` |
| Display control: `SendMonitorLayout`, `DisplayControlCaps`, the monitor layout struct, 200–8192 limits | `include/freerdp/client/disp.h`; `include/freerdp/channels/disp.h` |
| Input functions (`freerdp_input_send_keyboard_event_ex`, `_unicode_keyboard_event`, `_mouse_event`, `_extended_mouse_event`), pointer flags, `WheelRotationMask` 0x01FF | `include/freerdp/input.h` |
| Scancode constants, extended flag | `include/freerdp/scancode.h` |
| cliprdr client context callbacks (monitor ready, format list, data request/response, file contents) | `include/freerdp/client/cliprdr.h` |
| Pointer callbacks (`New`, `Free`, `Set`, `SetNull`, `SetDefault`, `SetPosition`), `graphics_register_pointer`, `freerdp_image_copy_from_pointer_data` | `include/freerdp/graphics.h`; `include/freerdp/codec/color.h:406-410` |
| GDI: `gdi_init(instance, format)`, `gdi_init_ex` with a caller's buffer, `gdi_resize`, `primary_buffer`, `stride`, `hwnd->invalid/cinvalid/ninvalid`, `gdi_send_suppress_output` | `include/freerdp/gdi/gdi.h:451-557`; `libfreerdp/gdi/gdi.c:1345-1358` |
| Upstream's iOS client structure (client context, pre/post connect, the event loop, BGRA32 GDI) | `client/iOS/FreeRDP/ios_freerdp.m` |
| CMake options named in the script exist; zlib is needed only for smartcard emulation; client channels are always object libraries; `WITH_INTERNAL_MD4/MD5/RC4` exist and upstream's macOS bundle script sets them | `cmake/ConfigOptions.cmake`; `CMakeLists.txt:139-143`; `winpr/CMakeLists.txt:118-120`; `channels/CMakeLists.txt:172-190`; `client/common/CMakeLists.txt:63-76`; `scripts/bundle-mac-os.sh:260-278` |
| The channel folders at the tag | GitHub contents API for `channels/` |
| Channel loading falls back to a dynamic load when the static table has no entry | `libfreerdp/common/addin.c:370-385` |
| Upstream ships `cmake/ios.toolchain.cmake` with `PLATFORM=OS64`/`SIMULATORARM64` | `docs/README.ios` |

**Not verified** (from memory or inference; each has a test or a checklist item)

1. Which codecs a default Windows 11 Pro host chooses for a client offering H.264 and progressive, and whether iOS then decodes in hardware.
2. That FreeRDP's NLA completes over a custom transport layer on iOS (the hook is verified; the end-to-end run is not).
3. The numeric values and names of the logon notification types Windows sends for a busy session (`LOGON_MSG_SESSION_BUSY_OPTIONS` and relatives): not found in the headers fetched.
4. That `ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION` is what a client sees when someone signs in at the PC's console.
5. The `ClipboardFeatureMask` flag names and exact semantics.
6. That GFX frame acknowledgements are sent by FreeRDP's GDI glue without help from the client.
7. That clearing `Password` in settings after `PostConnect` has no later reader (auto-reconnect and redirection are off).
8. That Ctrl+Alt+Del, Win+Tab, Win+D and Ctrl+Win+arrows sent as scancodes act inside the remote session.
9. That Unicode key events carry supplementary characters as surrogate pairs correctly to Windows apps.
10. That a display-control layout changing only the scale factor applies without a new sign-in.
11. The effect of `DeviceScaleFactor` 100/140/180 on Windows 11.
12. OpenSSL: that 3.5 is the current LTS line, and the exact `Configure` target names (`ios64-xcrun`, `iossimulator-arm64-xcrun`, `darwin64-arm64-cc`) and `no-*` options in that line.
13. That OpenSSL built with `no-legacy` plus FreeRDP's internal MD4/RC4 is enough for NTLM (upstream's macOS script sets the internal options, which suggests so).
14. That SwiftPM and Xcode expose headers and a module map from a static-library xcframework in a local package to a C target (believed; fallback written).
15. That `IOSurface` assigned to `CALayer.contents` updates reliably at 60 Hz on iOS 17.5+.
16. That a Microsoft account's email, as `host.user`, is accepted as the NLA user name.
17. The expected binary sizes (estimates until PR 2 measures them).
18. FreeRDP's minimum CMake for the library itself (the iOS client project asks for 3.30; the root project may accept less).
