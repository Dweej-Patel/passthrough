# Stage 7: Mac ↔ PC

Four tracks that ship separately. Each has its own section under *Design*, its own PRs and its own done-when. Paths are relative to `the repo root` unless absolute. "Master plan" is `scalable-watching-hummingbird-of-…md`.

What this stage delivers to a user: **the Mac reaches a PC's shell and screen**, by a phone's hand-over or by pairing the two computers directly. The reverse direction (a PC reaching a Mac) is used in stage 8, but everything the Mac must do as a host for it, and the whole pairing protocol in both implementations, is built here.

## Goal and done-when

**Track (a), computer access and the phone hand-over.** A host (Mac or PC) keeps *computers* apart from phones and from `viewer.` passes, lets one in only with its key **and** a signature from that computer's identity key, limits it to the scopes it was given, and removes it with the phone that granted it. The iPhone's *Share screen with a Mac* becomes *Share with another computer*.
*Done when*: from an iPhone with "May share access with other computers" on at the host, *Shell and screen* handed to a second computer works on Wi-Fi and through a relay; with the switch off the item is not offered and a forged `computerGrant` gets `not_allowed`; a credential copied to a third machine is refused (`not_authorized`) because it cannot sign; revoking the phone at the host closes the computer's shells and view within a second; a failed hand-over leaves nothing behind on the host; an iPhone build from before this stage still shares a Mac's screen with a Mac (`screenGrant`) once the switch is on; Swift, Kotlin and C# suites pass on the same fixtures.

**Track (b), direct pairing.** Two computers on one network pair with no phone: both open *Add a computer*, one picks the other, each owner ticks what the other may do, each types the six digits the other shows.
*Done when*: Mac ↔ PC pairing completes in both dial directions; the Swift and C# implementations produce the digits in `fixtures.json` from the fixed vector and pair with each other in the macOS CI job; a wrong digit ends it on both with nothing stored on either; three failures close the sheet; a peer from another subnet is dropped before TLS; with Local Network denied on the Mac the sheet says so with its fix.

**Track (c), the Mac's screen window on a PC.** *Screen* on a PC under *Your computers* asks Touch ID, signs in to Windows (saved login behind the same Touch ID), and shows the PC in a window with the keys mapped and a *Windows* menu.
*Done when*: every state in the master plan's "The screen view on a PC" table (§1) can be produced from the Mac and reads as written with "this Mac" for "this iPhone"; `Passthrough.app` itself does not link FreeRDP or OpenSSL (`otool -L`, `nm`), the engine runs only in the sandboxed helper; killing the helper mid-view shows "The connection to *Office-PC* was lost." with **Try Again** and the app stays up; 30 minutes of use shows no memory growth in either process.

**Track (d), shells across computers and *Your computers*.** *New shell ▾* opens the other computer's shell in the default terminal; running sessions list with **Open** / **End**; Settings has *Computers with access* and *Other computers*.
*Done when*: a PowerShell and a WSL session on the PC open in Terminal.app and iTerm titled "*Office-PC* · PowerShell"; resizing the window resizes the far terminal; closing the window leaves the session listed with **Open**; Wi-Fi off and on for 20 s reattaches by itself with the scrollback redrawn; the tool exits with the far shell's exit status; a `computer.` id with only `screen` scope is refused `open` on the Mac (`not_allowed`); a C# `ShellClient` test peer with `shell` scope opens a zsh on the Mac in the macOS CI job (what stage 8 will do for real).

## What exists today (verified, with path:line)

**Host side, Mac.**
- One store, two Keychain items: `shell.phones` and `shell.screenPasses` (`Packages/PassthroughCore/Sources/ShellHost/ShellAccessStore.swift:65-66`). Passes are `ShellPhone` records with `screenOnly`, `grantedBy`, `viewerOf` (`:26-32`), routed to their own item on write (`:449-468`) and filtered on read so a pass in the phones' item, or one whose granter is gone, is never used (`:490-517`).
- A phone may not claim a `viewer.` id (`:145-148`). `grantViewer` checks the granter is a phone with Screen, keeps the older pass for the same viewer until the new one is used, caps at `ScreenPass.maxPerGranter` = 8 by dropping the oldest (`:180-202`; cap at `Sources/PassthroughCore/ShellProtocol.swift:309`). `supersede(by:)` removes the older ones on first use (`:209-219`).
- Revoking a phone removes what it granted in the same write (`:346-348`), fails closed (`:386-421`). A pass may see the screen only while its granter may (`:240-246`).
- The proof is checked against two key slots whatever the id, with throwaway keys for missing ones, so every attempt costs the same (`ShellHost/ShellListener.swift:566-583`). There is no signature and no per-listener binding value today.
- Screen-only is enforced in three places: decided at `authorized` and failing closed on the id prefix (`:588`); nothing but `ready` is sent (`:736-742`, also `:762`, `:770`); every request except `screenVideo`, `ping`, `pong` is answered `screen_only` (`:859-863`). Grant handlers: `screenGrant` / `screenPass` / `screenRevoke` (`:936-944`, bodies `:955-1011`), each off the queue with `busy` set.
- The app's handlers: `RemoteShellController.swift:842-866` (grant, with a `.quiet` notice), `:869-890` (keep a pass; any phone with access may hand one over or replace one, with a notice), `:893-905` (revoke), `:910-920` (superseded on first use). Revoke of a phone cuts its passes' connections and forgets passes it handed over (`:780-798`, `:935-941`).
- `NotchNotice` has two kinds: `.quiet` and `.lowered` ("stays until dismissed, with a way to undo it") (`macOS/App/Views/NotchNotice.swift:11-15`). The pass notices use `.quiet`.

**Viewer side, Mac.**
- `ScreenPassStore`: Keychain item `screenPasses`, one `ReceivedScreenPass` per Mac, at most 16, a newer one for the same Mac replaces the older **with no check on certificate or iroh id** (`ShellHost/ScreenPassStore.swift:31-33`, `:61-77`); forgetting by sender (`:93-95`).
- `ShellCredential` has no host kind, no scopes (`Sources/PassthroughCore/ShellClient.swift:6-28`). `ShellClient` proves with the HMAC only (`:675-679`); `open(cols:rows:)` takes no shell (`:310`).
- `RemoteScreenWindow` starts from a `ReceivedScreenPass` (`macOS/App/Views/RemoteScreenWindow.swift:91-98`), gates once per window with `LAContext` (`:100-113`), and knows only the stream: `ScreenVideoClient` (`:142`, `:236`), `RFBClient.Buttons` in its input surface (`:146`, `:330`), `AVSampleBufferDisplayLayer` as the only picture path (`:391`, `:466-474`). All shortcuts go to the far side while live (`:621-625`); modifiers are passed as they are (`:728-735`).
- The scene is `WindowGroup("Screen", id:, for: String.self)` keyed by `macID` (`macOS/App/PassthroughMacApp.swift:35-37`). The app is an agent: `LSUIElement: true` (`project.yml:330`) and `.accessory` activation policy (`PassthroughMacApp.swift:82`), so **it has no menu bar today**, and no `.commands` anywhere under `macOS/App`.

**Phone.**
- `iOS/App/Shell/ScreenShareModel.swift`: Face ID (`:49-57`), `screenGrant` on a kept-open connection to the shared Mac (`:77-114`), build the pass from the credential as refreshed by this connection's `macInfo` (`:88-94`), `screenPass` to the viewer (`:117-147`), `screenRevoke` on failure with a 2 s grace (`:169-187`), 40 s overall (`:23`).
- `iOS/App/Home/ShareScreenSheet.swift`: lists the phone's other Macs (`:14`), header "Which Mac should see …?" and a footer that says it "can't open Passthrough's shells" (`:37-39`).

**Terminals on the Mac.**
- `passthrough-term` has `hook`, `new`, `attach SESSION TOKEN`, `list` (`Packages/PassthroughCore/Sources/passthrough-term/main.swift:10-14`, `:57-121`); raw mode and restore in `LocalTerminalClient.run` (`Sources/PassthroughCore/LocalTerminalClient.swift:124-127`), SIGWINCH through a pipe (`:323-340`), outcomes `ended(Int32)`, `detached`, `unavailable`, `lost`, `listed` (`:40-49`).
- Wire: kinds 1–4 and 16–21, modes `hook|new|attach|list`, unknown kinds skipped (`Sources/PassthroughCore/LocalTerminalWire.swift:16-41`, `:130-153`).
- Socket: mode 0600 (`ShellHost/LocalTerminalServer.swift:87`), same-user check with `getpeereid` (`:126-127`), 5 s for `hello` (`:150`). Tokens: one window, one minute, second use reported (`ShellHost/LocalTerminalAccess.swift:34`, `:113-150`).
- "Open here" writes a 0700 `.command` file in a 0700 folder that `exec`s the script with `attach <id> <token>` and opens it with `NSWorkspace` (`macOS/App/Shell/RemoteShellController.swift:697-732`).
- `PassthroughTerm` is an Xcode `tool` target built from the package's sources and embedded in the app (`project.yml:393-410`, `:255-260`).

**Menu panel and settings.**
- Panel: `PhoneHereSection()` then `OtherScreensSection()` (`macOS/App/Views/MenuPanelView.swift:41-42`); the latter lists `shell.screenPasses` and opens the window (`:644-672`). "Open here" button at `:565`.
- Settings ▸ Remote Shell: `PhonesSection`, `ScreenGuestsSection` ("Macs that can see this screen", `RemoteShellSettings.swift:351-383`), `OtherMacScreensSection` ("Other Macs' screens", `:396-422`), order at `:24-36`. Phones' revoke text at `:472`.

**Identity and network pieces to reuse.**
- `MacIdentity`: P-256 key in the data-protection Keychain plus a self-made certificate, by label, with `delete(label:)` (`Sources/PhoneTransport/MacIdentity.swift:35-51`, `:67-97`).
- The iroh secret key is 32 raw bytes in the Keychain (`RemoteShellController.swift:152`, `:484-490`) and is replaced by *Reset built-in identity*; dialers use a fresh ephemeral endpoint key (`SECURITY.md:131`). So the iroh id is not usable as a computer's identity.
- `HandshakeLimiter`: 16 unproven, 2 per host, 10 s (`Sources/PhoneTransport/HandshakeLimiter.swift:15-16`, `:66-68`, `:98`). `LocalAddresses.Interface` carries `prefixLength` (`ShellHost/LocalAddresses.swift:10-14`); the arrival address comes from the connection's path (`ShellListener.swift:24`).
- Bonjour types allowed today: `_passthrough._tcp`, `_passthrough-sh._tcp`; the Local Network sentence names only the phone (`project.yml:334-335`).

**Docs and fixtures.**
- `SECURITY.md:123` ends "Anything that gets a shell, or a transcript, to a device that was not paired over the cable is a vulnerability." `SECURITY.md:127` covers Screen. Screen passes: `protocol/README.md:781-815`.
- `protocol/fixtures.json` has no `computer` or `pair` entry on this branch (top-level keys end at `shell`). `protocol/README.md:6-8` still names two suites.

**Windows.** Only `Passthrough.Core` and `Passthrough.App` exist (`windows/README.md:8-11`); no shell, service, access store or WinUI settings pages for Remote access. Everything Windows in this stage sits on stages 3–5.

## Design

### 0. Shared definitions (used by all four tracks)

**Computer id.** `computer.` + lowercase UUID, minted only by a host. `Computers.idPrefix = "computer."`, `Computers.isComputerID(_:)` in `ShellProtocol.swift` beside `ScreenPass` (C#: `Shell/Computers.cs`). Any id with the prefix is a computer whatever the store says (fails closed, as `:588` does for passes).

**Identity key.** One per computer (Mac: per macOS account; PC: per Windows account), used only to sign shell proofs as a viewer. P-256 ECDSA. It is **not** the TLS key (on a PC that lives with the service, while the viewer is the tray app; and resetting either must not break the other) and **not** the iroh key (see above).
- Mac: Keychain label `computer.identity`, data-protection Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, created in the Secure Enclave (`kSecAttrTokenIDSecureEnclave`); if that fails (a VM, CI) a non-extractable software key with the same label. No user-presence flag: it signs on every reconnect; Touch ID gates the window, not the proof.
- PC (interface here, implementation in stage 8a): a non-exportable per-user CNG key, Platform Crypto Provider when present, else the software provider.
- Public key on the wire and at rest: the 65-byte X9.63 point (`04 ‖ X ‖ Y`), base64, field name `idKey`. Shown to people as the first 8 hex digits of its SHA-256.
- Signature on the wire: raw `r ‖ s`, 64 bytes, base64, field name `sig`. (SecKey gives DER: convert with `P256.Signing.ECDSASignature(derRepresentation:).rawRepresentation`. .NET: `DSASignatureFormat.IeeeP1363FixedFieldConcatenation`.)

```swift
public protocol ComputerIdentitySigning: Sendable {
    var publicKey: Data { get }                       // 65 bytes
    func sign(_ message: Data) throws -> Data         // 64 bytes, r ‖ s
}
public enum ComputerProof {
    public static let label = "passthrough-computer-v1"
    public enum Path: UInt8 { case tls = 1, iroh = 2 }
    public static func message(nonce: Data, path: Path, hostBinding: Data, computerID: String) -> Data
    public static func isValid(_ sig: Data, publicKey: Data, message: Data) -> Bool
    public static let decoyKey: Data                  // a fixed valid point, for the constant-work rule
}
```

**Scopes.** Strings `shell` and `screen`. A set; an empty set is never stored.

**Host id.** The host's `clientID` (the Mac's is what phones store as `macID`; the PC's is `HostIdentity`'s client id). It keys the viewer-side store and the replace rule.

### (a) Computer access and the phone hand-over

#### a.1 The proof

```
{"t":"proof","phoneID":"computer.<uuid>","mac":"<base64 32>","sig":"<base64 64>"}

mac = HMAC-SHA256(shellKey, "passthrough-shell-v1" ‖ nonce)                       (unchanged)
sig = ECDSA-P256-SHA256(identity key,
        "passthrough-computer-v1" ‖ 0x00 ‖ path ‖ nonce ‖ hostBinding ‖ UTF-8(phoneID))
path        = 0x01 over TLS, 0x02 over iroh
hostBinding = TLS: the 32 raw bytes of SHA-256(host certificate DER) (what `certSHA256` is the hex of)
              iroh: the 32 raw bytes of the host's endpoint id (what `irohID` is the hex of)
```

`hostBinding` makes a signature good for one host only (one identity key signs for every host the computer reaches). The line still fits `proofLineLimit` 4096.

*Client* (`ShellClient`): new init parameter `identity: (any ComputerIdentitySigning)? = nil`. When `credential.phoneID` is a computer id it adds `sig`, taking `hostBinding` from `credential.certSHA256` for a TCP attempt and `credential.irohID` for an iroh attempt (`attempt.isIroh`, `ShellClient.swift:697`). No identity, or signing throws: the attempt ends with `ConnectError.protocolViolation` and nothing is sent.

*Host* (`ShellGate`): new init parameters `hostBinding: Data` and `path: ComputerProof.Path` (ShellListener passes `identity.certificate`'s SHA-256; IrohShellListener its endpoint id), and a closure `computerKey: @Sendable (String) -> Data?` answered from memory.

**Verification order** (replaces the body of `verify`, `ShellListener.swift:566-583`):
1. Decode; require `t == proof`, `phoneID`, `mac` (base64). Else fail.
2. HMAC against two slots exactly as today (missing slots are throwaway keys).
3. If `phoneID` has the `computer.` prefix: **always** run one ECDSA verification, whatever step 2 found: against `computerKey(phoneID)` when there is one and `sig` decodes to 64 bytes, otherwise against `ComputerProof.decoyKey` with a 64-byte decoy signature. The result counts only when the real key and a real `sig` were used.
4. Accept iff step 2 matched a real key **and** (not a computer id **or** step 3 was valid).
5. Every failure is the same line, `error not_authorized`, after the same work.

A phone id that sends `sig` has it ignored. A computer id without `sig` fails at step 4 after the decoy verification. Constant-time rules: the HMAC compare is CryptoKit's (`isValidAuthenticationCode`); the ECDSA verification handles only public values, so its own timing is not a concern; what must not vary is *whether* it runs, which step 3 fixes by prefix (the prefix is the peer's own claim, so it tells nothing). `keyConfirmed` / `previousKey` never apply to a computer: a computer is re-granted under a new id, not re-keyed.

#### a.2 Host store (Mac: `ShellAccessStore`; PC: `Shell/AccessStore`, same rules)

A third secret item, `shell.computers`, apart from `shell.phones` and `shell.screenPasses`: a build from before this stage reads neither a computer as a phone nor as a pass. Computers stay in the one in-memory list (one cache, one write lock, one fail-closed removal path), routed to their item the way passes are (`:449-468`). `ShellPhone` gains, all optional and absent for phones and passes:

| Field | Meaning |
|---|---|
| `identityKey: Data?` | the 65-byte point recorded at grant; a computer record without it is dropped on read |
| `shell: Bool?` | shell scope (a computer's; phones on a PC have their own Shell switch from stage 3) |
| `screen: Bool?` | existing field: screen scope |
| `screenPending: Bool?` | PC hosts only: a phone asked for screen; not usable until the owner allows it at the PC |
| `kind: String?` | `mac` / `windows`, for the status line |
| `grantedBy: String?` | existing: the phone's id; **nil for a computer paired directly** |
| `viewerOf: String?` | existing: the computer's host id (`clientID`), so re-granting replaces |
| `share: Bool?` | **on a phone's record**: "May share access with other computers". Absent = off |

`pairingSlot` is the granting phone's slot for a hand-over (so forgetting the pairing removes the computer through `revoke(pairingSlot:)`), and the constant `computer.direct` for a directly paired one.

On read: a computer record is kept only if its id has the prefix, `identityKey` is 65 bytes starting `04`, and `grantedBy` is nil or names a phone in the list; anything else sets `needsTidy`. `record(_:)` refuses any id with either minted prefix (extend `:145`).

New store API (Swift signatures; C# mirrors them):

```swift
public func grantComputer(by granter: String, name: String, viewer: String, kind: String?,
                          identityKey: Data, scopes: Set<String>, screenNeedsOwner: Bool)
    -> Result<(id: String, key: Data, scopes: [String], pending: [String], replaced: [String]), ShellError>
public func addPairedComputer(name: String, viewer: String, kind: String, identityKey: Data,
                              scopes: Set<String>) -> Result<(id: String, key: Data), ShellError>
public func commitPairedComputer(_ id: String) -> [ShellPhone]      // removes older direct records for the same identityKey
public func supersedeComputer(by id: String) -> [ShellPhone]        // first use: older hand-overs by the same phone for the same viewer go
public func setComputerScope(_ scope: String, _ on: Bool, for id: String) -> Bool   // off fails closed like setScreenAllowed
public func revokeComputer(_ id: String, grantedBy granter: String) -> (done: Bool, removed: [ShellPhone])
public func computerKey(_ id: String) -> Data?                       // from memory
public func scopes(of id: String) -> Set<String>                     // from memory, with the granter's limits applied
public func setShareAllowed(_ allowed: Bool, forPhone: String) -> Bool
public func shareAllowed(forPhone: String) -> Bool                   // from memory
```

Rules in `grantComputer`, in this order: name valid as `ScreenPass.isValidName`; `viewer` 1…128 characters; `identityKey` a valid point; scopes non-empty and known → else `bad_request`. Granter must be a phone (not a pass, not a computer) → else `not_authorized`. Granter's `share` on → else `not_allowed`. `screen` asked and the granter lacks Screen → `screen_not_allowed`. `shell` asked and the granter's Shell switch is off (PC) → `not_allowed`. Caps: 8 computers per phone, 16 computers per host in all (`Computers.maxPerGranter`, `Computers.maxTotal`); over either → **refused** `too_many_computers` (a working computer with a shell is not dropped silently, unlike the oldest pass). An older record by the same phone for the same `viewer` stays until the new one first connects (as passes), and does not count toward the cap. On a PC (`screenNeedsOwner`), an asked `screen` is stored as `screenPending` and returned in `pending`.

**Effective scopes** (`scopes(of:)`), asked from memory on every request: `shell` iff `shell == true` and (direct, or the granter still exists and, on a PC, has its Shell switch on). `screen` iff `screen == true` and (direct, or the granter exists and has Screen). Turning a phone's Screen off therefore ends its computers' views too: `setScreenAllowed(false)` callers iterate `viewers(grantedBy:)`, which already returns every record with that `grantedBy` (`:228-230`).

**Cascade.** Unchanged code path: `revoke(phoneID:)` removes `phoneID == id || grantedBy == id` (`:346-348`); the controller then disconnects every removed id and ends the sessions each opened (`RemoteShellController.swift:791`, `:801-808`). Revoking a computer removes only it. Turning "May share" off stops new grants and removes nothing; the footer says so.

**No onward grant.** A connection whose id is a pass or a computer is refused every grant message (a.3), and `grantComputer` refuses a granter that is not a phone.

#### a.3 What a `computer.` connection gets and may send

`ShellConnection` replaces `screenOnly: Bool` with `role: .phone | .pass | .computer`, decided at `authorized` by prefix first (`:588`).

After `ready`: `macInfo` (so the stored addresses and iroh details stay current; a pass still gets none), then `host` (stage 1; without `shells` when the computer lacks `shell`), then, with `shell` scope only, `macState` with `control: false`, then `sessions`. Pushes (`pushSessions`, `pushMacState`) follow the same rule. Scope changes are pushed by closing the connection (the viewer reconnects and reads the new `host`).

`host` gains two optional fields (fixtures in PR a1): `share` (bool, sent to phones: this phone may share access) and `idKey` (this computer's identity public key, present only when it can keep access to other computers).

| Request | `computer.` with `shell` | with `screen` | neither scope applies |
|---|---|---|---|
| `ping`, `pong` | yes | yes | yes |
| `list`, `open` (+`shell`), `attach`, `input`, `resize`, `close`, `viewing` | yes | | `not_allowed` |
| `screenVideo` (Mac host) | | yes, as a pass's view: `curtain` refused, Use Here ignored | `screen_not_allowed` |
| `rdp` (PC host, stage 5) | | yes, unless `screenPending` | `screen_not_allowed` |
| `screen` (the RFB relay) | `screen_not_allowed` always: as for a pass, its login would let it try the Mac's password | | |
| `history`, `transcript`, `events`, `push`, `lock`, `setAwake`, `setVPN` | `not_allowed` | | |
| `screenGrant`, `screenPass`, `screenRevoke`, `computerGrant`, `computerPass`, `computerRevoke` | `not_allowed` | | |

The check sits where the screen-only check is (`:859-863`), before the `switch`. Sessions a computer opens count among the 8, carry its name as `phoneLabel`, and end with it (`closeSessions(openedBy:)`). `ScreenViewLimit` counts a computer like a phone (2 per id).

#### a.4 Messages (the shapes stage 1(c) reserved; PR a1 adds to `fixtures.json` whatever stage 1 left out)

| `t` | From | Fields | Meaning |
|---|---|---|---|
| `computerGrant` | phone | `name`, `viewer`, `scopes`, `idKey`, `kind`? | Issue access for another computer. |
| `computerGranted` | host | `phoneID` (the `computer.` id), `key` (base64 32), `scopes`, `pending`? | What was recorded; `pending` lists scopes waiting for the owner at the host (`screen` on a PC). |
| `computerPass` | phone | `pass` (a `ShellCredential` with `hostKind`), `scopes`, `pending`? | Keep access to another computer. |
| `computerPassSaved` | computer | none | Kept. |
| `computerRevoke` | phone | `phoneID` | Take back one this phone was granted and could not hand over. |
| `computerRevoked` | host | none | Gone (answered also when there was nothing of this phone's by that id: `bad_request`, as `screenRevoke`). |

Errors: `bad_request`, `not_authorized`, `not_allowed`, `screen_not_allowed`, `too_many_computers` (new), `pass_not_saved`, and on the receiving side `pass_conflict` (new: the replace rule refused it). A host from before this stage answers `computerGrant` with `bad_request`.

`screenGrant` (the old pass) is kept and now also needs the phone's `share` switch (`not_allowed` without it). See *Decisions* for the upgrade rule.

#### a.5 The receiving side

New store `ComputerReachStore` (Mac: Keychain item `computers.reach`; PC: stage 8a's Hello-wrapped store behind the same interface), apart from `screenPasses`:

```swift
public struct ReachableComputer: Codable, Equatable, Sendable, Identifiable {
    public var credential: ShellCredential     // phoneID is the computer. id; gains optional hostKind
    public var scopes: [String]
    public var pending: [String]?
    public var from: String?                   // the phone's label; nil when paired directly
    public var fromPhoneID: String?            // revoking that phone here forgets it
    public var receivedAt: Date
    public var id: String { credential.macID }
}
public final class ComputerReachStore {
    public static let maxComputers = 16
    public var computers: [ReachableComputer] { get }
    public func save(_ c: ReachableComputer) -> SaveResult     // .saved(replaced:), .conflict, .notUsable, .failed
    public func update(hostID: String, macInfo: ShellEnvelope) // addresses and iroh details only, validated as a phone does
    public func remove(hostID: String) -> Bool
    public func remove(fromPhones: Set<String>) -> (done: Bool, hostIDs: [String])
}
```

`Computers.isUsable(_ pass:)`: as `ScreenPass.isUsable` (`ShellProtocol.swift:341-347`) with a `computer.` id.

**Replace rule.** A credential for a host id already in the store replaces it only when `certSHA256` is equal **and** `irohID` is equal (both absent counts as equal). Otherwise `.conflict` → `pass_conflict`, nothing changes, and a `.lowered`-style notice says so. Reason: over iroh the viewer knows the host only by `irohID`, so a swapped one would send the next Windows sign-in to someone else. Only an authenticated `macInfo` from the host itself changes iroh details (`update`). The same rule is added to nothing else: `ScreenPassStore` keeps its behaviour.

Who may hand one over: any phone with shell access to the receiving computer, as today (`RemoteShellController.swift:873`); not a pass, not a computer. Handler `onComputerPass` mirrors `screenPassHandler` (`:869-890`).

On a Mac, the identity key is created on first need: when the first `host` is built with `idKey`, at app start if Remote Shell is on.

#### a.6 The phone flow (rewrite of `ScreenShareModel` → `ComputerShareModel`, `ShareScreenSheet` → `ShareComputerSheet`)

Entry: *Share with another computer* on a computer's page, shown only when that host's last `host` said `share: true`. Sheet: a choice *Screen only* / *Shell and screen* (default *Screen only*), under the second "It can run commands as you on *X*.", then the list of the phone's other computers by name and kind.

1. Face ID / passcode, reason "Let *V* use *H*".
2. **Ask the receiver first.** One-off connection to V; read `host`. No `idKey` within 5 s of `ready` → fail "*V* needs the latest Passthrough to use other computers." (or, when `host.kind` is `windows` and stage 8 has not landed there, the same sentence). Keep the connection open.
3. **Grant.** One-off connection to H; on `ready` send `computerGrant{name: V's name, viewer: V's host id, scopes, idKey, kind}`; apply `macInfo` and `host` from this connection to the phone's own credential for H first, as today (`ScreenShareModel.swift:88-94`).
4. On `computerGranted`: build the pass = the phone's current credential for H with `phoneID` and `shellKey` replaced, `hostKind` from H's `host`, checked with `Computers.isUsable`.
5. **Hand over.** `computerPass{pass, scopes, pending}` on V's open connection.
6. `computerPassSaved` → close both, done: "*V* can now open shells on *H* and see its screen. Find it under Your computers on *V*." With `pending: [screen]`: "… can now open shells on *H*. To let it see the screen too, allow it in Passthrough on *H*."
7. **Any failure after step 4** (V answers an error, V's connection drops, 40 s pass): `computerRevoke{phoneID}` on H's still-open connection, 2 s grace, close (the structure of `failed`, `:169-187`). A host that never hears the revoke is covered by first-use supersede and by the owner's notice.

Messages: `not_allowed` at step 3 → "*H* doesn't let this iPhone share access. Turn on May share access with other computers for it in Passthrough's settings on *H*." `too_many_computers` → "*H* already lets as many computers in as it allows. Remove one in its settings first." `pass_conflict` → "*V* already has access to a computer called *H* with different details. Remove it under Other computers on *V*, then try again." `bad_request` from H → "*H* needs the latest Passthrough to share with another computer."

Fallback kept for one release: when H's `host` is absent (a Mac from before stage 1) the sheet offers only *Screen only* and runs the old `screenGrant` flow unchanged. `ScreenShareModel` stays as that path's model until removed.

Android: not in this stage (its app has no Share screen today); it decodes the new fields and nothing else.

#### a.7 The switch and the settings rows (host)

- Mac, Settings ▸ Remote Shell ▸ *Phones with access*: per phone, under Screen: toggle **May share access with other computers**, off. Footer: "Lets this phone give another of your computers access to this Mac, from anywhere. Turning it off stops new sharing; computers it already let in stay until you remove them."
- PC, Settings ▸ Remote access ▸ *Phones with access*: the same toggle and footer with "this PC" (master plan §1 line 56). Through `IAccessAdmin.SetMayShareAsync(phoneId, bool)`.
- The *Computers with access* section itself is track (d) on the Mac and PR a4 on the PC.

#### a.8 Notices (each stays until dismissed; `.lowered`, plus a row in the panel/flyout until **OK**)

| When | Mac | PC |
|---|---|---|
| A phone granted a computer `shell` (± screen) | "*iPhone* gave *Office-PC* access to this Mac" / "It can open shells as you and see the screen. Remove it in Passthrough's settings." **Revoke** | "*iPhone* gave *MacBook* access to this PC's shell." **Revoke** |
| … with `screen` pending (PC) | | "*iPhone* gave *MacBook* access to this PC's shell. Let it see the screen too? Windows still asks for your password." **Allow screen** · **Revoke** |
| A phone granted `screen` only | "*iPhone* gave *Office-PC* access to this Mac's screen" **Revoke** | (pending form above without the shell clause) |
| This computer was handed access | "You can now reach *Office-PC*" / "From *iPhone*. Find it under Your computers." (quiet) | same |
| A hand-over was refused by the replace rule | "*iPhone* tried to replace this Mac's access to *Office-PC* with different details. Nothing was changed." | same with "this PC" |

The old pass notice (`RemoteShellController.swift:856-858`) becomes `.lowered` with **Revoke** too.

#### a.9 `SECURITY.md`

Replace the last sentence of `:123` with:

> A shell, or a transcript, reaches only: a phone paired over the cable; a computer that such a phone handed access to, and only while that phone keeps its own access and the owner has turned on *May share access with other computers* for it at the host; or a computer the owner paired at both keyboards by typing each one's six digits into the other. A computer proves a key and signs the host's challenge with an identity key that never leaves it, so a copied credential opens nothing. Anything that gets a shell or a transcript to a device outside those three, lets a computer do more than the scopes recorded for it, lets a computer or a pass grant access onward, or leaves a computer's access standing after the phone that granted it is removed, is a vulnerability.

Add a paragraph "Computers" (hand-over: what the phone holds in passing, the relay token going with the credential, the replace rule) and, in track (b), "Pairing two computers" (b.9's argument, shortened). Amend `:127`: a computer's `screen` scope is a Screen permission; on a PC it must be allowed at the PC.

### (b) Direct pairing

Core type `ComputerPairing` (Swift: `Packages/PassthroughCore/Sources/PassthroughCore/ComputerPairing.swift`, pure; C#: `Passthrough.Core/Trust/ComputerPairing.cs`). Transport and discovery sit outside it behind `ByteStream` / `Stream`.

#### b.1 Discovery

Service `_passthrough-pair._tcp`, domain `local.`, advertised **only while the Add a computer sheet is open**, never over peer-to-peer Wi-Fi (`includePeerToPeer = false`).

- Instance name: `pt-` + 8 lowercase hex digits, random per sheet opening (the *tag*).
- TXT, each entry `key=value`, values UTF-8:

| Key | Value |
|---|---|
| `v` | `1` |
| `k` | `mac` or `windows` |
| `n` | the computer's name, cut to 63 bytes on a character boundary |
| `l` | `1` this computer accepts connections; `0` it can only dial |
| `w` | present only on an `l=1` computer whose user picked an `l=0` one: that one's tag ("dial me") |

- A Mac always listens. A PC listens when stage 4's install is in place (the firewall rule below); otherwise it advertises `l=0` with port 9 and never accepts.
- **Who dials.** Where the user picks the other, that computer dials, if the picked one has `l=1`. If the picked one has `l=0`, the picker sets `w` to its tag; the `l=0` computer, seeing its own tag in a browsed `w`, dials that instance. Both `l=0` (two PCs without the install): the row is shown disabled, "Turn on Remote access on one of the PCs first."
- A browse result with a missing or other `v`, an unknown `k`, an empty `n`, or this computer's own tag is not listed. At most 16 results listed.
- Crossing dials (both picked each other): each side keeps the connection whose **dialer's tag is smaller** (byte order) and closes the other with `fail busy`.

#### b.2 Addresses: same subnet or link-local only

Checked on the peer's address against the local address the connection uses, **before TLS**, by the listener on accept and by the dialer on the resolved address:

- IPv4: an interface of this computer has an address A with prefix length p such that the connection's local address is A and peer ≡ A under p; or both are in 169.254/16 on that interface.
- IPv6: peer in `fe80::/10` with the connection's interface; or peer and local address share an on-link /64 of that interface.
- The interface must not be loopback, point-to-point or a tunnel (so not Tailscale: the sheet's text says "this network").
- Local address unknown → refused.

`PairingAddressPolicy.isOnLink(peer:local:interfaces:) -> Bool`, pure, with fixtures (`pair.addresses`). macOS: interfaces from `getifaddrs` (`LocalAddresses.interfaces()`, which already has `prefixLength` and `isPointToPoint`), local address from `connection.currentPath?.localEndpoint` (waiting for the path as `awaitArrival` does, `ShellListener.swift:318-345`). Windows: `NetworkInterface.GetAllNetworkInterfaces()` → `UnicastIPAddressInformation.PrefixLength`, excluding `NetworkInterfaceType.Loopback/Tunnel/Ppp` and adapters that are not `OperationalStatus.Up`; local address from `Socket.LocalEndPoint`. Windows firewall rule (needed from stage 4's install): inbound TCP, program = the installed `Passthrough.exe`, remote addresses `LocalSubnet`, every profile, named "Passthrough (add a computer)".

#### b.3 TLS

TLS 1.3 only, ALPN `passthrough-pair/1`, **both sides present a certificate** (the listener requests one). Each side's certificate is self-made for this sheet: a P-256 key and certificate created when the sheet opens and deleted when it closes (Mac: `MacIdentity.loadOrCreate(label: "pairing.<tag>")` then `delete`, with a sweep of `pairing.*` at launch; PC: a persisted per-user CNG key named `Passthrough pairing <tag>`, deleted on close, since Schannel cannot serve an in-memory key). **Nothing is pinned**: neither side knows the other yet. Each side accepts any single well-formed P-256 leaf and records the SHA-256 of the DER it was shown; that hash goes into the transcript in the peer's block, and each side puts its own certificate's hash in its own block. A relay in the middle therefore changes the transcript and the digits. The long-lived certificate a host's shell listener uses travels later, inside the sealed credential.

#### b.4 Messages

Newline-delimited JSON, `t` first, absent fields omitted, each line at most 4096 bytes except `grant` (16384). `D` is the dialer, `L` the listener.

```
1. D→L {"t":"hello","v":1,"role":"dialer","id":"…","name":"…","kind":"mac","iroh":"<64 hex>","idKey":"<b64 65>","keeps":true,"commit":"<b64 32>"}
2. L→D {"t":"hello","v":1,"role":"listener","id":"…","name":"…","kind":"windows","idKey":"<b64 65>","keeps":false,"eph":"<b64 65>","nonce":"<b64 32>"}
3. D→L {"t":"reveal","eph":"<b64 65>","nonce":"<b64 32>"}
        — both now compute the transcript and both codes; the UI shows step 3 (scopes), then step 4 (digits) —
4. each {"t":"confirm","mac":"<b64 32>"}            sent once its own user typed the other's digits correctly
5. each {"t":"grant","box":"<b64>"}                 sent once it has sent its confirm and verified the peer's
6. each {"t":"done"}                                the peer's grant was opened and (if it held a credential) stored
   any  {"t":"fail","reason":"mismatch|busy|cancelled|timeout|version|bad_request|not_saved"}   then close
```

Field rules: `id` 1…128 bytes; `name` 1…64 characters, one line (`ScreenPass.isValidName`); `kind` `mac`|`windows`; `iroh` optional, valid as `IrohInfo.isValidID`; `idKey`, `eph` 65 bytes starting `04` and on the curve; `nonce` 32 bytes; `keeps` whether this computer can keep access to another (a PC without Windows Hello or a PIN, or before stage 8a: `false`). `commit = SHA-256("passthrough-pair-v1 commit" ‖ ephD ‖ nonceD)`; L checks it at step 3 in constant time, and a wrong one is `fail bad_request`. `v` other than 1 → `fail version`. An unknown `t`, a message out of order, or a second `hello` → `fail bad_request`.

#### b.5 Transcript, codes, keys

`LP(x)` = 2-byte big-endian length, then the bytes.

```
block(X) = role (1 byte: 0x44 'D' or 0x4C 'L')
         ‖ LP(id) ‖ kind (0x01 mac, 0x02 windows) ‖ flags (bit 0 = keeps)
         ‖ eph (65) ‖ nonce (32)
         ‖ cert (32: X's certificate's SHA-256; X uses its own, the other side what it observed on this connection)
         ‖ LP(iroh: 32 raw bytes, or empty) ‖ idKey (65) ‖ LP(name, UTF-8)

T = "passthrough-pair-v1" ‖ 0x00 ‖ block(D) ‖ block(L)
H = SHA-256(T)

code(role) = big-endian-u64( HMAC-SHA256(key = H, "passthrough-pair-v1 code " ‖ role)[0..<8] ) mod 1 000 000
             as six digits with leading zeros; role is the ASCII "dialer" or "listener"

Z   = ECDH(own ephemeral private key, peer's eph)            (x coordinate, 32 bytes)
PRK = HMAC-SHA256(key = H, Z)                                (HKDF-Extract, salt H)
Kc  = HKDF-Expand(PRK, "passthrough-pair-v1 confirm", 32)
Kd  = HKDF-Expand(PRK, "passthrough-pair-v1 grant dialer", 32)
Kl  = HKDF-Expand(PRK, "passthrough-pair-v1 grant listener", 32)

confirm.mac(role) = HMAC-SHA256(Kc, "passthrough-pair-v1 confirm " ‖ role)
grant.box(role)   = AES-256-GCM(key = Kd or Kl by sender's role, nonce = 12 zero bytes, aad = H, plaintext) ‖ tag (16)
```

**The two codes.** The dialer shows `code("dialer")` and asks for the listener's; the listener shows `code("listener")` and asks for the dialer's. A typed code is compared locally in constant time and never sent. The codes are not secrets (they come from public values); what protects the pairing is that a person carries them between two screens.

**After both verify.** `grant`'s plaintext is JSON: `{"credential":{…ShellCredential…},"scopes":["shell","screen"]}` for what this computer's own owner ticked, or `{"none":true}` when the owner ticked nothing or the peer said `keeps:false`. The credential is the one a phone would build: this host's id, name, `hostKind`, shell certificate hash, port, advertisable addresses, iroh id, relay and relay token, a fresh 32-byte key, and the new `computer.` id. Before sending it the host records the computer with `addPairedComputer` (bound to the peer's `idKey` from the transcript, `grantedBy` nil); it keeps it only if the peer's `done` arrives within 15 s, else removes it. On `done` it calls `commitPairedComputer` (older direct records for the same identity key go) and shows its notice. The receiver stores through `ComputerReachStore.save` (the replace rule applies; a conflict is `fail not_saved` and the host removes its record). An AEAD failure is `fail bad_request`.

#### b.6 State machine (one exchange)

`idle → helloSent/helloReceived → revealed (digits known) → [scopes chosen] → awaitingDigits → confirmed (own) → bothConfirmed → granted → done`. Any state → `failed(reason)` on `fail`, a closed connection, a bad message, or a timer.

Timers and limits:
- Handshake limiter in front of the listener: 2 unproven connections per address, 16 in all, 10 s to reach `revealed` (`HandshakeLimiter`, no reserved slots).
- **One pairing at a time**: the first connection to reach `revealed` is the exchange; every other connection, and any new one until the exchange ends, gets `fail busy`.
- **Five minutes** from `revealed` to `done`, then `fail timeout` ("That took too long. Nothing was shared.").
- **Single-shot digits**: one wrong entry sends `fail mismatch`, ends the exchange on both, stores nothing.
- **Three failures close the sheet**: failures counted are `mismatch` (either side's) and `bad_request`; `busy`, `cancelled` and a lost connection are not counted. On the third the sheet closes itself, stops advertising and listening, with "Too many tries. Open Add a computer again on both computers."
- The sheet as a whole stops advertising after 10 minutes without an exchange.
- After `done` both stop advertising at once.
- Threading: Swift, a serial queue per sheet; C#, one async loop per connection; the UI is told through a single `onState` callback. Digits typed are passed in with `submit(code:)`; scope choices with `allow(_ scopes:)`; both may arrive in either order before `confirm` is sent.

#### b.7 Test vector (goes into `fixtures.json` as `pair.vectors[0]`; computed for this plan with Python's `cryptography`, re-derive in all three suites)

Inputs: ephemeral private scalars `11…11` (dialer) and `22…22` (listener), 32 bytes each; identity private scalars `33…33` and `44…44`; `nonceD` = bytes 0x00…0x1f, `nonceL` = 0x20…0x3f; `certD` = SHA-256("dialer certificate"), `certL` = SHA-256("listener certificate"); dialer `id` `mac-0001`, kind mac, `keeps` true, iroh = 32 bytes of 0xaa, name `MacBook`; listener `id` `pc-0002`, kind windows, `keeps` false, no iroh, name `Office-PC`.

```
ephD   040217e617f0b6443928278f96999e69a23a4f2c152bdf6d6cdf66e5b80282d4ed194a7debcb97712d2dda3ca85aa8765a56f45fc758599652f2897c65306e5794
ephL   04d65a93977caa3d1b081852ff57a79e465f1660577304baead505dd3a48589cf350185e895372df6221ea3a137557e473fddb6755f05bd507c3c533fce9c91285
idKeyD 0451a7580833898ea1b183cbd7350a4099078c6ef1c1e18e970cd7683035f25e7d0110522712b0b5a7cff081685486984a94e6831edac46e7360fa9d834a7a81a1
idKeyL 045b36890dacbd7c9a96bb74a1ee28b3d2d75b72e09a20ef25cf8e6fd8a9f0350d0e14bed8d4682a34d83538bdff5b96e89a6666ec0db5745d02fa1210072df75a
certD  bfb39649b1a8d12ff1e88e702d085be9d5e2c3efd666cba45ae4cdfb1cb46335
certL  c5cfbd82ef49fabe38d47d9bf5a18741ca58ec77c6149e15770ec46edbd97d77
commit 53c17e9d1bcc859b9e44d6cda812b7b86f6f00875f3f77e1d3fcbc6635cd8d4d
|T|    489 bytes
H      57237725b1cce4e22096c905b78d9cd2bbe49eab0b55c28462ec0c561f98fd46
code("dialer")   609523        code("listener") 959136
Z      ccfc261f58193c98ca4ad4a53bbac6f0ee29bc4d48438090446908622ca79af6
Kc     29eae7143b734405233e9295fec193143584f63ecdc8a5a4c48d54453273f6d8
Kd     a446911fbce5086d207f369e783ac98178b050915525deb5ddd45c015df6a32c
Kl     17c2197eec685a9894f7055b8ce11774574c2c78583ecdaaae0f57bca6c9c7fb
confirm.mac("dialer")   98a727fe8d9ef7852eb69bc1ffea3a8e2104c1d952fa2adc3d966fb4e28eb73c
confirm.mac("listener") 13e708030c16b268fbf20111ea34751dc32ea5e8e3cc32e37f403aedb565785f
grant.box("dialer") of {"none":true}   5bd29e5916b337887fdf631afe7368011954844fab37800cbd5ed7eeef
```

Further vectors to add in the PR (derived by the suites, digits pinned once two suites agree): one with both `keeps` true and both iroh ids; one with a non-ASCII name; one where a single byte of `certL` differs (the digits must differ from the first vector's).

A vector for the computer proof (a.1), fixture `shell.computerProofs[0]`: identity key = `idKeyD` above (base64 `BFGnWAgziY6hsYPL1zUKQJkHjG7xweGOlwzXaDA18l59ARBSJxKwtafP8IFoVIaYSpTmgx7axG5zYPqdg0p6gaE=`), nonce = bytes 0x64…0x83, path TLS, `hostBinding` = `certL` above, id `computer.0f8fad5b-d9cb-469f-a165-70867728950e`; a valid signature (ECDSA is randomised, so suites verify, they do not reproduce): `dxPgDz8jMgx5aw/oxbkKt5vIbDtF+ecQaBKlOlDIoXxKeE/juRG4vzo3Uqp1JkNjEPwuGxvE8t7rM+nq5gDxHA==`. The same signature must fail with path iroh, with another id, and with one bit of the nonce changed.

#### b.8 UI

Five steps, wording from the master plan's "Add a computer" (§1, lines 129-134); only what it does not give is written here.

**macOS.** A window scene `Window("Add a computer", id: AddComputerWindow.id)` (the pattern of Welcome and Shell History, since the app is an agent with a menu panel), opened from: Settings ▸ Remote Shell ▸ *Other computers* ▸ **Add a computer…**, and the menu panel's *Your computers* header (a "+" button with the help text "Add a computer"; with no computers yet, a row "Add a computer…"). SwiftUI, fixed width 460.
1. Looking: the step-1 sentence, a spinner, after 10 s the "Nothing found yet…" line, and always the phone alternative.
2. A list of rows: letter avatar, name, "PC" / "Mac". A row whose computer can only dial and has not yet connected reads "Waiting for *Office-PC*…" after it is picked.
3. "What may *Office-PC* do on this Mac?" two checkboxes, off; under *Open shells*: "It can run commands as you on this Mac."; under *See the screen*: "It can see and control this Mac's screen." When the peer said `keeps: false`: the boxes are replaced by "*Office-PC* can't keep access to other computers yet. You'll still be able to reach it from this Mac." **Continue**. If Remote Shell is off on this Mac, the boxes are disabled with "Turn on Remote Shell to let other computers in." and a **Turn on** button.
4. This Mac's six digits in two groups of three (monospaced digits, large), "Type these on *Office-PC*." and a field "Digits shown on *Office-PC*". The field accepts a paste with a space; **Continue** enables at six digits.
5. The step-5 sentence and **Done**. If both sides allowed nothing: "Neither computer allowed anything, so nothing was added."

**The Local Network prompt.** macOS asks the first time the sheet browses or advertises; nothing before that touches the network for pairing. Step 1 says, above the spinner, until the first browse result or state change: "macOS may ask to let Passthrough find devices on your network. Choose Allow." If the browser or listener reports the policy denial (`NWError.dns` −65570, `kDNSServiceErr_PolicyDenied`): "Passthrough isn't allowed to look on your network. Turn it on in System Settings ▸ Privacy & Security ▸ Local Network." **Open System Settings** (`x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork`). `project.yml`: add `_passthrough-pair._tcp` to `NSBonjourServices`, and extend `NSLocalNetworkUsageDescription` to "Passthrough listens for your linked phone on the local network, and finds your other computer when you add one."

**Windows.** A WinUI 3 settings page, Settings ▸ Remote access ▸ *Other computers* ▸ **Add a computer…**, also reached from the flyout's *Your computers* header. The same five steps as a `ContentDialog`-free page (a UAC or Hello prompt would dismiss a flyout). Step 3: "What may *MacBook* do on this PC?" with the footers "It can run commands as you on this PC. Shells never run as administrator." and "Uses Windows Remote Desktop. It still asks for your Windows password." Without the install: step 3 reads "Turn on Remote access to let other computers in." and the page still pairs to receive access (once stage 8a lets it keep any).

**Accessibility.** macOS: each step change posts a VoiceOver announcement with the step's sentence; the digits have the accessibility label of the six digits read singly ("6, 0, 9, 5, 2, 3") and are selectable; the field is labelled "Digits shown on *Office-PC*"; a failure moves focus to its sentence; everything reachable by Tab, **Continue** is the default button, Esc cancels (and sends `fail cancelled`). Windows: automation names on both checkboxes and the field; the digits are one `TextBlock` with `AutomationProperties.Name` spelling the digits singly; the result list and the status sentence are live regions (`Polite`; failures `Assertive`); no state by colour alone; high-contrast brushes; Enter continues, Esc cancels.

#### b.9 Soundness (short)

*Setting*: an attacker on the same network who can advertise, dial and accept, and runs one exchange with each computer (A ↔ M and M ↔ B) while both sheets are open.

- **It cannot make the digits agree.** Take A dialing M, and M dialing B. M can first take A's `commit` (which hides A's key and nonce), then finish its exchange with B, so it knows `T_B` and both of B's digits. For A's exchange it must now send its own `eph` and `nonce` **before** A reveals; `T_A` then depends on A's 32-byte nonce it has not seen, so `code(T_A)` is uniform over a million from M's view. In the other arrangement (M dials A, B dials M) the same holds with the roles swapped: whoever commits is bound before the other's nonce arrives, and whoever answers has chosen before the reveal. The observed-certificate hashes add that even a pure TLS relay (same keys and nonces forwarded) changes `T`, because each side hashes its own certificate and the one it saw.
- **What a person does.** The person reads A's digits and types them on B, and B's on A. B accepts only if what was typed equals `code("dialer")` of **its own** transcript; A likewise. With M in the middle each check passes with probability 10⁻⁶, independently. So per exchange M has a one-in-a-million chance of fooling A, and the same of fooling B; three failures close the sheet, so about 3 × 10⁻⁶ per opening, and every failure is shown on both screens.
- **No blind confirmation.** No step asks "do these match?" or "allow *name*?". Acceptance is computed by each machine from digits the attacker cannot predict; a person who does exactly what the sheet says cannot approve a session with someone else. A person cannot skip the step either: with no typed code there is no `confirm`, and with no `confirm` there is no `grant`.
- **After the digits.** `confirm` proves each side holds the ephemeral private key the transcript names, and credentials are sealed under keys from that exchange with `H` as associated data, so the credentials are safe even if the TLS layer were at fault.
- **What it can do**: make a computer appear in the list under any name (picking it leads to digits that will not match, or to digits on a machine the person is not looking at); occupy the single exchange (`busy`) so pairing has to be retried; burn the three tries. None shares anything. It cannot pair from another subnet, and it learns each computer's name, kind and identity public key while the sheet is open, nothing else.
- **Outside the model**: someone who can see both screens and type on both keyboards; malware running as the user on either computer.

### (c) The Mac's screen window on a PC

#### c.1 The seam and the surface path

`RemoteScreenWindow` becomes host-neutral, with the same seam stage 6 extracts on iOS (master plan §2 "Viewers"). If stage 6 placed `ScreenBackend` in the package (`ScreenClient`), use it as is; otherwise PR c1 moves it there. The Mac needs exactly this of it:

```swift
public protocol ScreenBackend: AnyObject {
    var capabilities: ScreenCapabilities { get }      // .gestures, .curtain, .copyByKey, .windowsKeys, .resize, .sound …
    var onEvent: ((ScreenBackendEvent) -> Void)? { get set }
    func start(); func stop()
    func pointer(x: Double, y: Double, buttons: PointerButtons)
    func scroll(dx: Int, dy: Int)
    func key(_ keysym: UInt32, modifiers: KeyModifiers)          // neutral: .control .alt .shift .meta
    func text(_ text: String)
    func sendClipboard(_ text: String) -> Bool
    func copySelection()
    func resize(width: Int, height: Int, scale: Int)
}
public enum ScreenBackendEvent {
    case size(width: Int, height: Int)
    case sample(CMSampleBuffer, number: UInt32)                  // the Mac's stream
    case surface(IOSurface, width: Int, height: Int)             // a shared BGRA surface (new one after a resize)
    case surfaceDirty([CGRect])
    case pointerShape(CGImage, size: CGSize, hotSpot: CGPoint), pointer(x: Double, y: Double, visible: Bool)
    case copied(CopyResult)
    case phase(ScreenPhase)                                      // reaching, signingIn, startingSession, slowSignIn
    case needsSignIn(SignInRequest), ended(ScreenEnd)
}
```

PR c1 changes no behaviour: `RemoteScreenModel` holds `any ScreenBackend` instead of `ScreenVideoClient` (`RemoteScreenWindow.swift:142`); `RFBClient.Buttons` (`:146`, `:330`, `:559`) becomes `PointerButtons`; `ScreenVideoWire.Modifiers` in `RemoteKeys` (`:728`) becomes `KeyModifiers`, mapped back inside `StreamBackend` (a thin wrapper of `ScreenVideoClient`). `RemoteScreenView` gains a second layer: a plain `CALayer` whose `contents` is the `IOSurface`, `contentsGravity = .resizeAspect`, redrawn with `setNeedsDisplay(_:)` on dirty rectangles, shown instead of the `AVSampleBufferDisplayLayer` when the backend delivers surfaces. `pictureRect` and the pointer layer are shared.

The window's value changes from `macID: String` to `ScreenTarget: Codable, Hashable { case pass(macID), computer(hostID) }`; the scene (`PassthroughMacApp.swift:35`) and `OtherScreensSection` (`MenuPanelView.swift:657`) follow. `start` picks the credential from `ScreenPassStore` or `ComputerReachStore`, and the backend from the credential's `hostKind` and the host's `host.screens`: `video` → `StreamBackend`; `rdp` → `RDPHelperBackend`.

#### c.2 The engine runs in a sandboxed helper, from the first commit

**Decision**: the engine never runs inside `Passthrough.app`, not even in a debug build on `dev`. Order: the helper with a *fake* engine first (a test pattern, echoing input), which proves the boundary, the sandbox and the build; then stage 6's engine target is linked into the helper. Reason: the master plan requires it ("on the Mac it runs in a sandboxed helper process"), and an in-process first cut would have to be thrown away while putting FreeRDP next to every key the app holds.

**Target** (`project.yml`): `PassthroughScreenEngine`, `type: xpc-service`, `platform: macOS`, sources `macOS/ScreenEngine`, bundle id `$(PASSTHROUGH_ID).mac.screen-engine`, embedded by `PassthroughMac` (XcodeGen puts it in `Contents/XPCServices`), hardened runtime on, `ARCHS: arm64`, Release `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`. Depends on stage 6's engine product and its vendored xcframework (Mac slice). **`PassthroughMac` does not depend on either** (see *Corrections*). Its `Info.plist` `XPCService` dictionary: `ServiceType = Application`, `RunLoopType = dispatch_main`, `_MultipleInstances = true` (one process per window, so one PC's server cannot reach another PC's session or password in memory; fallback in *Risks*).

**Entitlements** (`macOS/ScreenEngine/ScreenEngine.entitlements`): `com.apple.security.app-sandbox = true`. Nothing else: no network client or server, no files, no keychain group, no camera or microphone, no Apple Events, no JIT.

**What crosses the boundary** (`NSXPCConnection`, interface `ScreenEngineXPC`, every object type whitelisted, the app checks the service's code signature is its own team's, the service checks the app's):

| Direction | What | How |
|---|---|---|
| app → helper | **Transport bytes**: the app keeps the authenticated `ShellClient` stream (after `rdpReady`) and never gives the helper a network socket | one end of a `socketpair(AF_UNIX, SOCK_STREAM)`, passed once as a `FileHandle` in `start`; the app splices the other end to the `ByteStream` with back-pressure (a 4 MiB backlog closes the view). The engine's transport hook reads and writes the descriptor. |
| app → helper | Session set-up | `start(config:transport:reply:)`: width, height, scale, the account name and domain, **the password** (it has to reach CredSSP, which runs in the engine), the expected certificate's SHA-256 from `rdpReady`, keyboard layout id |
| helper → app | **Frames** | an `IOSurface` (BGRA, created in the helper) sent with `surface(_:width:height:)`, again after a resize; then `dirty([rects], seq)`; the app acks `presented(seq)` so the helper sends at most 2 unacked updates |
| helper → app | Pointer | `pointerShape(bgra: Data, width, height, hotX, hotY)` (at most 256 × 256), `pointerHidden`, `pointerDefault` |
| app → helper | **Input** | `pointer(x, y, buttons)`, `scroll(dx, dy)`, `key(keysym, modifiers, down)`, `text(String)` (≤ 4 KiB a call), `releaseAll()` |
| both | **Clipboard text** | app → helper `clipboard(String)` on *Send Clipboard* only; helper → app `copied(String?)` only as the answer to `copy()`; ≤ 64 KiB, Unicode text only. The helper is never told the Mac's clipboard otherwise. |
| helper → app | State | `phase(code)`, `ended(code, detail)` with stage 6's error codes |

The app treats everything from the helper as hostile input: sizes at most 16384 a side and 50 million pixels (the limits the RFB client uses, `protocol/README.md:776`), the surface's real dimensions and pixel format checked against the message, rectangles clipped, strings length-checked before decoding, unknown codes mapped to "The connection to *Office-PC* was lost."

**Lifecycle.** Created when the window connects (after Touch ID, after `rdpReady`); `invalidate()` when the window closes, the view ends or the app quits. `interruptionHandler` / `invalidationHandler` → `ended(.connectionLost)`; the window offers **Try Again**, which makes a new connection and a new helper. The helper exits when its connection goes, and after 10 s with no `start`. The password is zeroed in the app after `start` returns and in the helper after CredSSP completes or fails.

#### c.3 Touch ID, sign-in sheet, Keychain

- **Gate**: as today, once per window (`RemoteScreenWindow.swift:100-113`), reason "see and control *Office-PC*'s screen". The same `LAContext` then reads the saved Windows login, so there is one prompt.
- **Store**: stage 6 generalises `ScreenLoginStore` to host and account; on the Mac it is `WindowsLoginStore` in `Packages/PassthroughCore/Sources/ScreenClient/` (moved there from `iOS/App/Screen/` if stage 6 left it in the iOS app), service `…​.windows-login`, account `<hostID>` (one saved login per PC), value JSON `{username, domain?, password}`, data-protection Keychain, `SecAccessControl` `.userPresence` with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, read with `interactionNotAllowed` on the already-evaluated context (`ScreenLoginStore.swift:24-38`). Deleted on a refused sign-in, on *Remove* under Other computers, and by a "Forget saved sign-in" item in the window's *Windows* menu.
- **Sheet** (a SwiftUI `.sheet` on the window): title "Sign in to *Office-PC*", body "Windows asks for your account's password, not your PIN. Passthrough passes it to Windows and keeps it on this Mac behind Touch ID.", a secure field labelled "Password for *name@outlook.com*" (from `host.user`), a link "Use a different account" that reveals an account field, a **Remember** checkbox (on), **Sign In** (default) and **Cancel**. Wrong password: the sheet again with "Windows didn't accept that password. If you changed it, type the new one."
- **Before taking a PC in use** (`host.console == active` and `idleSeconds < 120`): an alert, "Someone is using *Office-PC* right now. Connecting locks its screen and they lose their place." **Not Now** (default) · **Connect Anyway**.

#### c.4 Keys

`PCKeyMap` (pure, in `ScreenClient`, table-tested):

```swift
public enum PCKeyMap {
    /// Shortcuts that never leave this Mac while the picture has the keyboard.
    public static func staysLocal(keyCode: UInt16, flags: MacFlags) -> Bool
    /// The neutral modifiers a PC gets for this Mac's.
    public static func modifiers(_ flags: MacFlags) -> KeyModifiers
}
```

- ⌘ → Ctrl, ⌥ → Alt, ⌃ → Ctrl, ⇧ → Shift. ⌘ and ⌃ together are one Ctrl.
- Stay local: **⌘Tab** (the system takes it before the app anyway), **⌘`** (next window), **⌃⌘F** (full screen). Checked first in `performKeyEquivalent` (`RemoteScreenWindow.swift:621-625`), which returns `super` for them. Everything else, ⌘Q and ⌘W included, goes to the PC as Ctrl+Q and Ctrl+W, which is what "Keys go to *Office-PC*" promises; the window closes with its close button or the *Window* menu.
- A lone press of ⌘ sends nothing (no Start menu by accident). Fn+⌫ → Delete. F1–F12 as they are.
- Shortcuts go as keysym + modifiers (the backend turns them into scancodes, stage 6); text goes through `NSTextInputClient` as Unicode, as today (`:642-655`), so input methods and dead keys compose on the Mac.
- On losing key status or going to the background: `releaseAll()`.

#### c.5 The Windows menu, the menu bar, the window

The app is an agent with no menu bar (`project.yml:330`, `PassthroughMacApp.swift:82`). **While at least one screen window is open the app switches to the regular activation policy** (Dock icon, menu bar), and back to accessory when the last closes; this is also what makes the accessibility rule "every toolbar action is also in the menu bar" possible. It applies to views of Macs too.

Menu bar (SwiftUI `.commands` on the `WindowGroup`): the standard app, Edit (Copy/Paste disabled while live, since they go to the PC), View (**Enter Full Screen ⌃⌘F**, *Fit to window* / *Actual size*), Window, and for a PC:

**Windows** ▸ Send Ctrl+Alt+Del · Start · Task View · Switch Apps (Alt+Tab) · Show Desktop · Close Window (Alt+F4) · Lock · — · Send Clipboard · Copy from PC · — · Forget Saved Sign-In. No Sign out and no Restart (master plan §1). For a Mac the menu is **Mac** ▸ Send Clipboard · Copy from Mac.

Window: title the computer's name; subtitle "Keys go to *Office-PC* · direct" / "· local network" / "· through a relay" (today's path words, `:256-261`); toolbar **Windows ▾** (the same items), **Send Clipboard**, **Copy from PC** (sends Ctrl+Insert and takes the answer, never Ctrl+C; paste on the PC is the user's own Ctrl+V after *Send Clipboard*); full screen through the standard green button and ⌃⌘F, the toolbar auto-hiding. First live view shows once, under the toolbar for 6 s: "*Office-PC*'s own screen is locked while you're here, and stays locked when you leave."

Size: the session takes the window's content size in pixels (capped at 4096 a side, at the Mac's backing scale, mapped to Windows' 100/125/150/175/200 % steps), resized through display control 300 ms after the window stops changing size; never on a mere move. A *View ▸ Standard (16:10)* item fixes 1920 × 1200.

#### c.6 Clipboard and reconnect

- Clipboard: text only, only on the two actions above, 64 KiB cap, beep on failure as today (`:356-359`, `:277`). What comes from the PC is put on the pasteboard as plain text with no transient marker, as the Mac view does (`:274-275`): it is the user's explicit copy.
- Reconnect: when the view ends by a lost connection, sleep/wake of this Mac, or a helper crash: keep the last surface dimmed, "Reconnecting…", redial with 1, 2, 4, 8 s waits for 30 s, then "The connection to *Office-PC* was lost." **Try Again**. A reconnect reuses the login already unlocked for this window (kept in memory for the window's life, zeroed on close); it does not ask Touch ID again. Never reconnect by itself after "Someone signed in at *Office-PC*, so this view ended.", a refused sign-in, `screen_not_allowed`, the certificate hard stop, or a stop from the PC.
- A change of the stored credential (`ComputerReachStore` notification, as `.passthroughScreenPassChanged` today, `:80-88`): replaced → reconnect; removed → "This Mac no longer has access to *Office-PC*."

### (d) Shells across computers on the Mac, and *Your computers*

#### d.1 `passthrough-term remote`

```
passthrough-term remote COMPUTER TOKEN        (COMPUTER is the host id; the app writes both into the .command file)
```

**Bridge.** The app holds the credential, the identity key and the `ShellClient` connection; the tool is a dumb terminal on the existing Unix socket. Nothing secret reaches the tool or its command line: the token is a one-minute, one-window capability for one target.

*Wire additions* (`LocalTerminalWire`; old tools skip unknown kinds, `:130-153`):
- `Mode.remote`; `Hello` gains nothing new: `token` carries the capability, and what it stands for (computer, shell id or session to attach, title) is kept by the app.
- Kind `notice = 22` (app → terminal, UTF-8): a status line the tool prints dimmed on its own line (`\r\n\e[2m[…]\e[0m\r\n`), used for reconnecting.
- `Refused` reasons added: `unreachable`, `no_access` (revoked or scope missing), `signed_out`, `too_many_sessions` (existing).

*App side.* `LocalTerminalAccess.grantRemote(_ target: RemoteTarget, file: URL?) -> String` with `RemoteTarget { hostID, shell: String?, session: String?, title }`; `admits` for `.remote` consumes it exactly as `.attach` does (once, a minute, second use → `onContested`). `LocalTerminalServer` gets `remote: (@Sendable (RemoteTarget, RemoteTerminalSink) -> RemoteTerminalSession?)`; `LocalTerminalConnection` routes input, resize and close to the session instead of the `ShellSessionManager`. `RemoteTerminalBridge` (in `ShellHost`, tested with a fake `ShellClient` seam) per window:

1. Connect (`ShellClient(credential:, identity:, mode: .automatic)`, with a Bonjour look-up by name as the screen window does, `RemoteScreenWindow.swift:168-178`). Not ready in 15 s → `refused unreachable`.
2. On `ready`: `open(cols:rows:shell:)` or `attach(session:)`. On `opened`/`attached` → frame `started` with the session id. `openFailed` → `refused` with the reason.
3. `output` → `output` frames (64 KiB pieces, the existing pause/resume marks). `input` frames → `client.input`. `resize` frames → `client.resize`. Terminal reports the tool's terminal sends go through as input (the far host filters them, `protocol/README.md:414-417`).
4. `ended(exitStatus)` → frame `ended`; done.
5. `detached` (another device took the session) → `refused stopped`; the tool prints "[no longer shown here; the session carries on]".
6. `disconnected` → `notice` "Reconnecting to *Office-PC*…", redial after 1, 2, 4, 8, 15 s … for 2 minutes; on `ready` `attach` the same session, send `output` of `\e[0m\e[2J\e[3J\e[H` then the replay, then `replayed`. After 2 minutes, or `no_such_session` → `notice` "The connection to *Office-PC* was lost. If the session is still running, open it again from Passthrough." and close.
7. The window closes (socket EOF): disconnect. **The session keeps running** on the other computer; it shows under *Your computers* with **Open** / **End**.

*Tool side* (`main.swift`, new `case "remote"`): raw mode, SIGWINCH and restore are `LocalTerminalClient.run`'s, unchanged; a new `Outcome.remoteLost`. The window title is set by the app, which sends `\e]0;Office-PC · PowerShell\a` as the first `output`, so the tool stays dumb. Exit codes: the far shell's exit status on `ended`; 0 on detached; 75 (`EX_TEMPFAIL`) when the connection was lost for good; 1 with a sentence on `refused` ("Can't reach *that computer*. It may be asleep, off, or offline.", "This Mac no longer has access to that computer.", "Sign in to that PC to use its shell.", "This window may not open that. Use New shell in Passthrough."). Typed by hand without a token it prints the last one.

*Opening* (`RemoteShellController.openRemoteShell(hostID:shell:session:)`): `openInTerminal`'s method (`:697-732`) with `exec '<script>' remote <hostID> <token>`, file name "Passthrough *Office-PC* <8 hex>.command", `plain: sharesNewTerminals` so the hook leaves that window's own shell alone. The socket runs only while Remote Shell is on today (`:645-672`, `:320-329`); **it now also runs whenever this Mac has at least one computer it can reach**, with `isSharing` false in that case (so `hook`/`new`/`list` stay refused).

No Touch ID for a shell (the master plan asks it for Screen only); see *Open questions*.

#### d.2 The chooser and the session list

`RemoteComputersModel` (`@MainActor`, in `macOS/App/Shell/`): one entry per `ReachableComputer` plus the old passes. For each computer with `shell` or `screen` it holds a **watch connection** (`ShellClient`) only while the menu panel is open and for 60 s after, giving: reachability, `host` (kind, shells, console, rdp), and `sessions` (with `shell` scope). Its `macInfo` updates the store (`ComputerReachStore.update`).

- **New shell ▾**: click opens the default (`host.shells` entry with `default`, caption its name; a Mac host has one, "zsh" or whatever `host.shells` says); the chevron lists what the computer reports, footed for a PC "Shells open as you, never as administrator." The last choice is remembered per computer (`UserDefaults`, `remoteShellChoice.<hostID>`), validated against the current list.
- **Sessions**: rows "*PowerShell* · running · 4m" with **Open** (a new terminal window attached to it) and **End** (`close`, after a confirmation "End this shell on *Office-PC*? Anything running in it stops."). Only sessions whose `origin` is not `mac` and that are running.
- **Screen**: opens `RemoteScreenWindow` with `.computer(hostID)`; hidden without `screen` scope; with `pending: [screen]` shown disabled with "Allow Screen for this Mac in Passthrough on *Office-PC*."

#### d.3 Where it sits

**Menu panel**: `YourComputersSection()` replaces `OtherScreensSection()` at `MenuPanelView.swift:42`, same place (after `PhoneHereSection`). Header "Your computers" with the "+" (Add a computer). One row per computer: letter avatar, name, status line ("PC · Connected · 1 shell open", "PC · Not reachable", "Mac · Screen only" for an old pass), then the buttons **Screen**, **New shell ▾**, and its sessions indented beneath. Hidden when the Mac has no computers and no passes (the "+" then lives only in Settings, so the panel does not grow for people who never use it).

**Settings ▸ Remote Shell** (`RemoteShellSettings.swift:24-36`):
- **Computers with access** replaces `ScreenGuestsSection` (`:351-383`), shown when there is any computer or pass: per row the name, "PC · from *iPhone* · 12 Nov" or "PC · added here · 12 Nov", toggles **Shell** and **Screen** (for an old pass: "Screen only", no toggles), **Revoke…** with the confirmation "Its shells and any view of the screen close." Footer: "Computers you let in, from here or from a phone. One let in from a phone goes when that phone does."
- **Other computers** replaces `OtherMacScreensSection` (`:396-422`), always shown: per row the name, "PC · Shell and screen · from *iPhone*", **Remove** ("This Mac forgets how to reach *Office-PC*, and its saved Windows sign-in. *Office-PC* still lists this Mac until you revoke it there."), then **Add a computer…**. Footer: "What this Mac can reach. Removing one here only forgets it on this Mac."
- `PhonesSection` gains the *May share* toggle (a.7).

#### d.4 The Mac as a host for a PC's shell (what stage 8 consumes)

Nothing beyond track (a): `ShellListener` and `IrohShellListener` accept a `computer.` id with the signed proof; with `shell` scope it gets `macInfo`, `host` (`kind: mac`, `shells: [{id:"login", name:"zsh", default:true}]` from the user's login shell; a Mac ignores `open.shell` other than its one id and answers an unknown id `bad_request`), `macState` (`control:false`), `sessions`, and the shell requests in a.3's table. The sessions are ordinary sessions: recorded, listed to phones under the computer's name, shown on this Mac with "Open here". Stage 8's `Client/ShellClient` in C# is tested against exactly this in PR d1's loopback test.

## Pull requests, in order

Tracks are independent after a1 and a2; (b) needs (a); (c) and (d) need (a) for a credential to use, and each other for nothing. Titles in the repo's style.

### Track (a)

**a1. "Protocol: computers prove a key and a signature, and what a phone may ask for them"**
Scope: `protocol/README.md` new section *Computers* (a.1, a.3 table, a.4, replace rule) and `host`'s `share`/`idKey`; `fixtures.json`: `shell.computerProofs`, the six messages, the two new errors, `host` examples; envelopes and `Computers`/`ComputerProof` in Swift (`ShellProtocol.swift`), Kotlin (`core`), C# (`Shell/`); `ShellCredential.hostKind` if stage 1 did not add it. No behaviour.
Tests: fixture round-trips in three suites; proof vector verifies, and fails for the three alterations.
Docs: protocol README, CHANGELOG ("Not yet").
By hand: nothing visible.
Leaves out: any listener or store change.

**a2. "Remote shell: a computer's access, kept apart and bound to its identity key (Mac)"**
Scope: `ShellAccessStore` (third item, fields, API of a.2), `ShellGate.verify` (a.1), `ShellConnection` roles and the a.3 table, `ShellListener`/`IrohShellListener` binding values, `ShellClient` `identity` parameter, `ComputerIdentity` (Keychain/Secure Enclave) in `macOS/App/Shell/`, controller wiring (`computerKey`, scopes, revoke cascade to connections), `screenGrant` gated by `share` with the upgrade rule.
Files: `ShellHost/ShellAccessStore.swift`, `ShellListener.swift`, `IrohShellListener.swift`, `PassthroughCore/ShellClient.swift`, `ShellProtocol.swift`, `macOS/App/Shell/RemoteShellController.swift`, new `macOS/App/Shell/ComputerIdentity.swift`.
Tests (`ShellHostTests`): store (separate item; old build's view; refused ids; caps; cascade; fail-closed scope off; pending; effective scopes follow the granter), gate (decoy verification always runs for the prefix: counted with an injected verifier; missing `sig`; wrong binding; iroh vs TLS), connection (each row of a.3; what follows `ready` per scope), client (adds `sig` only for a computer id).
Docs: SECURITY.md (a.9), GUIDE, CHANGELOG.
By hand: with a debug menu item that mints a computer record for this Mac's own identity, connect from a second Mac build.
Leaves out: phone UI, receiving side, settings UI.

**a3. "Remote shell: the Mac keeps access to other computers, and phones can hand it over"**
Scope: `ComputerReachStore`, `computerGrant`/`computerPass`/`computerRevoke` handlers in `ShellConnection` and the controller, notices (a.8), the *May share* toggle in `PhonesSection`, `host.share`/`host.idKey` sent.
Tests: handlers (order kept with `busy`; grant taken back when the phone left, as `:963-966`); replace rule; sender revoked mid-save; `macInfo` update never touches key or pin.
By hand: with a4's phone build.
Leaves out: any UI to *use* the access (tracks c, d).

**a4. "iPhone: Share with another computer"**
Scope: `ComputerShareModel`, `ShareComputerSheet`, the entry point's condition, strings; old flow kept for hosts without `host`.
Tests: model state machine with a fake `ShellClient` (each failure revokes; order of the two connections; 40 s).
Docs: GUIDE, README wording, CHANGELOG.
By hand: the track's done-when list.
Leaves out: Android.

**a5. "Windows host: computers with access" (after stages 4 and 5)**
Scope: C# ports of a2/a3's host side into `Shell/AccessStore`, `ShellGate`, `ShellConnection`; `IAccessAdmin` additions (`ListComputersAsync`, `SetComputerScopeAsync`, `RevokeComputerAsync`, `SetMayShareAsync`, `AddPairedComputerAsync`, `CommitPairedComputerAsync`); the relay's check "screen set at this PC" (`screenPending` → `screen_not_allowed`); WinUI: the toggle, the *Computers with access* list, the flyout notice with **Allow screen** · **Revoke**.
Tests: `Passthrough.Core.Tests` mirrors of a2/a3; cross-account refusal for computer records; the Swift `ShellClient` with an identity against the C# host in the macOS CI job.
Docs: `windows/README.md` checklist, GUIDE §Windows, CHANGELOG.

### Track (b)

**b1. "Protocol: pairing two computers"**: `protocol/README.md` section *Pairing two computers* (b.1–b.6, b.9 shortened), `fixtures.json` `pair` (constants, vectors, address cases), `ComputerPairing` + `PairingAddressPolicy` in Swift and C# with tests on the vectors, including a full in-memory exchange of the Swift implementation against itself and the C# one against itself. No network, no UI.

**b2. "Mac: Add a computer"**: `PairingService` (NWListener/NWBrowser, per-sheet identity, limiter, address check), `AddComputerWindow`, the entry points, `project.yml` Bonjour and usage string, stores wired (`addPairedComputer`, `ComputerReachStore`), notices, SECURITY.md paragraph, GUIDE. Tests: service against a loopback peer with the address policy injected; three-failure and timeout paths; denial state. By hand: two Macs pair both ways (Mac ↔ Mac works from this PR).

**b3. "Windows: Add a computer" (after stage 4; a5 first)**: `Passthrough.Windows` DNS-SD advertise/browse and `SslStream` with a per-sheet CNG key, the WinUI page, the firewall rule consumed from the install, `keeps: false` until stage 8a. Tests: Core exchange C# ↔ Swift over loopback TCP in the macOS CI job (both roles); Windows-only tests for the DNS-SD TXT encoding. By hand: Mac ↔ PC both dial directions; a PC without the install pairs as dial-only; wrong digit; other subnet.

### Track (c) (after stage 6's seam and engine; a3 for a credential)

**c1. "Mac screen window: one seam for the stream and other screens"**: c.1 with `StreamBackend` only; `ScreenTarget`. Behaviour unchanged. Tests: model tests with a fake backend; snapshot of the window states.

**c2. "Mac: a sandboxed helper for screen engines"**: the XPC target with the fake engine, `RDPHelperBackend` talking to it, the surface layer, the input path, validation of everything the helper sends, behind a hidden default (`defaults write … screenEngineDemo`). Tests: the app-side validators (hostile sizes, rectangles, strings); an integration test that starts the service, draws the pattern, and survives `kill -9`. CONTRIBUTING: the new target.

**c3. "Mac: a PC's screen, in the helper" (hidden default)**: stage 6's engine linked into the helper; `rdp` request, `rdpReady` pin passed in, transport splice, phases and error mapping; no sign-in UI yet (a debug sheet). THIRD_PARTY_NOTICES and CONTRIBUTING size note for the Mac zip.

**c4. "Mac: sign in to a PC, with the login kept behind Touch ID"**: `WindowsLoginStore`, the sheet, the takeover alert, every refusal's sentence.

**c5. "Mac: keys, the Windows menu and the window for a PC's screen"**: `PCKeyMap`, activation policy switch, `.commands`, toolbar, subtitle, full screen, resize, clipboard actions, reconnect; hidden default removed. Tests: key table; reconnect policy (which endings redial). Docs: GUIDE, README, CHANGELOG "Works now".

### Track (d) (after a3)

**d1. "Remote shell: this Mac's terminal windows can show another computer's shell"**: wire additions, `LocalTerminalAccess.grantRemote`, server routing, `RemoteTerminalBridge`, `passthrough-term remote`, socket lifetime change, `openRemoteShell`. Tests: `LocalTerminalWireTests` (new kind and mode, old parser skips 22); `LocalTerminalTests` (token rules for remote; bridge with a fake client: open, attach, reconnect and replay order, exit codes, detach); the C# `ShellClient` test peer with `shell` scope against the Swift listener, in the macOS CI job (uses stage 8a's client if present, else a minimal test client in `Passthrough.Core.Tests`). SECURITY.md: the terminals paragraph (`:125`) gains the remote token. By hand: a debug menu item "New shell on …".

**d2. "Mac: Your computers"**: `RemoteComputersModel`, `YourComputersSection`, chooser, sessions with Open/End, the two settings sections, removal of `ScreenGuestsSection`/`OtherMacScreensSection`/`OtherScreensSection`. Tests: model (watch connection lifetime, status line strings, remembered shell validated); panel snapshots (`PanelSnapshots.swift`). Docs: GUIDE, README, CHANGELOG.

Each PR leaves `dev` working: a1 is inert; a2 adds a store nobody writes to until a3; c2–c4 sit behind a hidden default; d1 has no UI entry until d2.

## Interfaces

### This stage defines (others depend on these): name, shape, owner

| Name | Shape | Owner |
|---|---|---|
| Computer proof | a.1: `sig` field, message layout, binding, verification order | protocol README *Computers*; Swift `ComputerProof`, C# `Shell/ComputerProof` |
| `ComputerIdentitySigning` / `IComputerIdentity` | 0: 65-byte public key, `sign` → 64 bytes | Swift here; C# interface here, CNG implementation stage 8a |
| Host store rules for computers | a.2 table and API | Swift `ShellAccessStore`; C# `Shell/AccessStore` (a5) |
| What a `computer.` connection gets and may send | a.3 | both hosts; stage 8's client relies on it |
| `computerGrant` … `computerRevoked`, `too_many_computers`, `pass_conflict` | a.4 | fixtures (a1) |
| `host.share`, `host.idKey` | optional fields | fixtures (a1) |
| `ReachableComputer`, `ComputerReachStore` interface, the replace rule | a.5 | Swift here; C# interface here (`Client/IComputerReachStore`), Hello-wrapped implementation stage 8a |
| Pairing protocol | b.1–b.7, fixtures `pair` | protocol README; `ComputerPairing` Swift and C# |
| `PairingAddressPolicy` | b.2 | Swift and C# |
| `ScreenEngineXPC` | c.2 table | macOS only |
| `PCKeyMap` | c.4 | `ScreenClient` |
| `LocalTerminalWire` mode `remote`, kind 22, refusals | d.1 | Swift; the model for `passthrough-term.exe` (stage 8a) |

### This stage consumes (from which stage)

| From | What |
|---|---|
| Stage 1 | `host` (kind, user, shells, screens, rdp, console), `open.shell`, `signed_out`, `rdp`/`rdpReady`, the reserved `computer.` prefix and `computerGrant`/`computerPass` names, `hostKind` on credentials, the C# suite reading fixtures, the Windows CI job and `dotnet test` on the macOS job |
| Stage 2 | iOS profiles with host kind, `ShellClient.open(…shell:)`, the PC page where *Share with another computer* sits |
| Stage 3 | C# `ShellGate`/`ShellConnection`/`AccessStore`, per-phone Shell switch, the shell catalog behind `host.shells` |
| Stage 4 | the service and pipe, `IAccessAdmin` (extended in a5), account-keyed records, the install's firewall rule for the app's pairing listener (**new requirement on stage 4**: inbound TCP, program `Passthrough.exe`, `LocalSubnet`, every profile), DNS-SD wrapper, WinUI Remote access settings page |
| Stage 5 | the relay and its "who may use it" check (a5 adds the `screenPending` rule), `rdpReady.certSHA256`, the relay's refusal reasons and caps |
| Stage 6 | `ScreenBackend` seam and neutral input types, the RDP engine package target and xcframework **with a Mac slice**, a transport mode that reads and writes a file descriptor (or its ring-buffer bridge fed from one), keysym → scancode, the error codes and sentences, the generalised login store |

**What stage 8 consumes from this stage**: the Mac as host for `computer.` ids (a.2, a.3, d.4); the proof and identity interface (it implements the CNG key and turns `keeps` and `host.idKey` on); `IComputerReachStore` and the replace rule (it adds Hello wrapping); the C# pairing code and page from b3 (it only flips `keeps`); `computerPass` reception on the PC (it implements the handler against its store); the `remote` bridge's behaviour (reconnect, replay, exit codes) as the specification for `passthrough-term.exe`; the *Your computers* row layout and status strings for the flyout.

## Tests

**Automated.**
- `swift test` — `PassthroughCoreTests`: fixtures for the new messages, `ComputerProofTests`, `ComputerPairingTests` (vector, commit mismatch, order violations, each `fail`, three-failure counter, timeout with an injected clock, crossing dials tie-break), `PairingAddressPolicyTests`, `PCKeyMapTests`, `LocalTerminalWireTests`. `ShellHostTests`: `ComputerAccessStoreTests`, `ShellGateComputerTests`, `ComputerConnectionTests`, `ComputerReachStoreTests`, `RemoteTerminalBridgeTests`, `LocalTerminalTests` additions.
- `dotnet test windows/tests/Passthrough.Core.Tests`: the same fixtures; access store and gate mirrors; pairing; address policy with Windows interface fixtures.
- Cross-implementation on the macOS CI job: Swift `ShellClient` + identity ↔ C# host; C# client ↔ Swift host (`shell` scope, opens a session); pairing Swift ↔ C# in both roles.
- `./gradlew testDebugUnitTest lintDebug`: the envelope decodes the new fields and messages (Android acts on none).
- App targets: `ComputerShareModel` (iOS), `RemoteComputersModel`, helper-message validators and the helper kill test (macOS).

**Fixtures added.** `shell.computerProofs`, `shell.messages` (six), errors, `host` with `share`/`idKey`; `pair.constants` (labels, limits: 3 failures, 300 s, 10 s handshake, line limits), `pair.vectors`, `pair.txt` (encoded TXT examples), `pair.addresses` (allowed/refused cases).

**Real-hardware checklist** (added to `windows/README.md` and the GUIDE's test notes).
1. Hand-over, iPhone on cellular: Mac → PC shell and screen; PC shows the pending-screen notice; **Allow screen** makes Screen usable without a new hand-over.
2. Copy `computers.reach` to another Mac (same user data restored): the PC refuses it.
3. Revoke the iPhone on the PC while the Mac has a shell open and a view live: both end, the row goes.
4. Pairing on Wi-Fi, on Ethernet + Wi-Fi mixed (same subnet), on a guest network (nothing found, the sentence shows), with Tailscale up on both (still pairs on the LAN; never over the tailnet).
5. Local Network denied, then allowed, without restarting the app.
6. A second Mac running the pairing as an impostor (a debug build that accepts any dial): the digits never match; three tries close both sheets.
7. Screen: each row of the master plan's state table from the Mac; full screen on a second display; lid closed and opened on the Mac mid-view; helper killed in Activity Monitor.
8. Shell: Terminal.app, iTerm, Ghostty as the `.command` handler; vim and Claude Code over the bridge; a 10 MB `cat`; resize storms.
9. VoiceOver through Add a computer and the screen window's menus; Narrator through the Windows page.

## Security considerations for this stage

- **A new way to a shell.** Until now only a cable pairing gave one. The three ways are now named in SECURITY.md (a.9) and each has its own owner action: the cable; the per-phone switch (off) plus the phone's Face ID; digits typed at both keyboards.
- **Copied credentials.** The identity key is non-extractable (Secure Enclave on the Mac). A backup, a synced Keychain item or a stolen file gives the HMAC key but no signature. Stated limit: code running as the user on the viewer can ask the key to sign (it is not user-presence-gated); that is inside "code running as you".
- **A phone is now a bigger key.** A phone with *May share* on can put a shell on any computer it also reaches. Mitigations: off by default; grants only what the phone itself has; a notice that stays, with **Revoke**; the cascade; on a PC, screen still waits for the owner.
- **The receiving side trusts the phone's description of the host.** A hostile phone with access to V can hand V a credential to a computer it controls under a friendly name, and V's user might type a Windows password into it. Unchanged from passes in kind; mitigated by the notice naming the phone, by the replace rule (it cannot redirect an entry that already exists), and by the RDP pin coming from the host that the credential authenticates.
- **Relay tokens** travel inside handed-over and paired credentials, so the other computer holds the host's relay token (as `protocol/README.md:797-799` says for passes). Said in SECURITY.md.
- **Pairing listener**: open only while the sheet is, behind the limiter and the address check, nothing parsed past 4096 bytes before the commit, one exchange at a time, no long-lived key presented (per-sheet certificate), name and identity public key visible to the LAN while open.
- **Digits are not secrets** and are never sent; logs must not need them, and do not record them anyway. `LogText.Redact` / `ptLog` never see `key`, `box`, `eph` private parts or the Windows password; `ShellCredential`'s description already hides the key (`ShellClient.swift:30-36`), and `ReachableComputer` gets the same.
- **The engine helper.** A server-triggered memory bug lands in a process with no network, no files and no Keychain. What it still has: the Windows password for *that* PC (it was just given it, and the far end is that PC or nothing, because the certificate is pinned before CredSSP), the picture, and **the general pasteboard, which the App Sandbox does not hide**. So a compromised helper could read what is on the Mac's clipboard while a view is open. This is an accepted limit to state in SECURITY.md; the helper links no AppKit, and one process per window keeps PCs apart.
- **The bridge socket.** `remote` needs a one-time token, so another process of the user's cannot open a shell on the other computer through the socket; the accepted limit is the one already written for *Open here* (`SECURITY.md:125`).
- **No onward grant, no escalation**: enforced at the store (`grantComputer` requires a phone) and at the connection (a.3), and tested in both places.
- **Old builds**: a Mac from before a2 never reads `shell.computers` or `computers.reach`; downgrading leaves both items unused, and the computers' ids are refused by prefix-free code only because their keys are not in the phones' item.

## UX states and strings for this stage

Strings the master plan gives are cited, not repeated: Add a computer steps 1–5 and "Those digits don't match. Nothing was shared." (§1 lines 129-134); the phone's choice and its caption (line 136); the screen view table (lines 95-109) with "this Mac" for "this iPhone"; the sign-in sheet (line 62, "this Mac behind Touch ID"); the takeover prompt (line 63); the connecting phases (line 64); revoke text "Its shells and any view of the screen close." (line 143).

New strings (Mac wording; PC swaps "this PC"):

| Where | State | String | Action |
|---|---|---|---|
| Phones with access | toggle | "May share access with other computers" + footer in a.7 | |
| Phone, share sheet | each failure | a.6 | |
| Phone, share sheet | working | "Confirming it's you…" → "Asking *V*…" → "Asking *H* for access…" → "Handing it to *V*…" | |
| Notices | | a.8 table | Revoke / Allow screen / OK |
| Add a computer | picked a dial-only PC | "Waiting for *Office-PC*…" | Cancel |
| Add a computer | other side busy | "*Office-PC* is pairing with something else. If that isn't you, close Add a computer on both and start again." | Try Again |
| Add a computer | other side cancelled / lost | "*Office-PC* stopped. Nothing was shared." | Try Again |
| Add a computer | timeout | "That took too long. Nothing was shared." | Try Again |
| Add a computer | third failure | "Too many tries. Open Add a computer again on both computers." | (sheet closes) |
| Add a computer | couldn't store | "This Mac couldn't save its access to *Office-PC*. Nothing was shared." | Try Again |
| Add a computer | already at 16 | "This Mac already lets 16 computers in. Remove one in Settings first." | Open Settings |
| Add a computer | Local Network | b.8 | Open System Settings |
| Add a computer | peer can't keep access | b.8 step 3 | Continue |
| Your computers | status line | "PC · Connected", "PC · Connected · 2 shells open", "PC · Connecting…", "PC · Not reachable", "Mac · Screen only" | |
| Your computers | PC signed out | under New shell: "Sign in to *Office-PC* to use its shell." | **Screen** |
| Your computers | no shell scope | New shell absent | |
| Your computers | screen pending | "Allow Screen for this Mac in Passthrough on *Office-PC*." | |
| Your computers | access revoked | "*Office-PC* no longer lets this Mac in. Add it again, or share it from your phone." | Remove |
| End session | confirm | "End this shell on *Office-PC*? Anything running in it stops." | End · Cancel |
| Terminal | reconnecting | "[Reconnecting to *Office-PC*…]" | |
| Terminal | lost | "[The connection to *Office-PC* was lost. If the session is still running, open it again from Passthrough.]" | |
| Terminal | taken elsewhere | "[no longer shown here; the session carries on]" (existing) | |
| Screen window | subtitle | "Keys go to *Office-PC* · direct" | |
| Screen window | no access | "This Mac no longer has access to *Office-PC*." | |
| Screen window | first live | master plan line 99 | |
| Settings | sections | d.3 | |

## Risks and how each is retired

| Risk | Retired by |
|---|---|
| Stage 1's reserved message shapes differ from a.4 | a1 is fixtures-first and reconciles before any code; this file's shapes are what stage 7 *needs* (notably `idKey` in `computerGrant`) |
| Secure Enclave key creation fails in the app's signing set-up | a2 falls back to a software non-extractable key and logs which; the hardware checklist item 2 runs on both |
| Mutual TLS with self-made certificates behaves differently in Network.framework and Schannel (client certificate request in TLS 1.3, per-sheet CNG key) | b1 keeps the exchange transport-free; b3 opens with a one-day probe of `SslStream` ↔ `NWConnection` both ways; if a side cannot present a certificate, the fallback is server-certificate only with the dialer's block carrying 32 zero bytes, which the ECDH confirm and sealed grants already make safe (decide in b1, since it changes the vector) |
| `_MultipleInstances` is not documented | c2 proves it on the minimum macOS (14.5) and current; fallback: one helper process, one live PC view at a time, the second window says "Close the view of *Other-PC* first." |
| IOSurface tearing with one surface | c2's test pattern includes a moving edge; if it tears, two surfaces alternate and `dirty` names which |
| Stage 6's engine assumes its in-process ring buffer | c3 feeds that bridge from the descriptor with one reader thread; no engine change needed |
| Agent app turning regular while a screen window is open surprises (a Dock icon appears) | c5 ships it for PC and Mac views alike so it is one rule; open question below offers the alternative |
| A dial-only PC (`w` signalling) is fiddly in DNS-SD updates | b3 by hand on a PC without the install; if TXT updates prove slow, the Mac re-registers the service |
| Terminal apps other than Terminal.app handle `.command` differently (title, closing) | checklist item 8; the title is set by an OSC from the app, not by the file |
| Watch connections add load on a host with many computers | they exist only while the panel is open + 60 s, one per computer, and count as ordinary connections |
| Gating old `screenGrant` on the new switch breaks a working set-up after update | the upgrade rule (a phone that has a live pass gets the switch on, once) and the changelog line |
| The Mac zip grows by the engine | recorded in CONTRIBUTING in c3; only the helper carries it |

## Decisions made here

1. **The identity key is its own P-256 signing key**, not the TLS key and not the iroh key (section 0 gives the reasons). The record stores the full public key, since verification needs it.
2. **The signature binds the host** (certificate hash or endpoint id, plus a path byte), so one identity key is safe across hosts.
3. **Computers get a third secret item but live in the one store**, so the cascade and fail-closed removal stay one code path.
4. **The cap refuses** (`too_many_computers`) instead of dropping the oldest: a silently removed computer with a shell open is worse than a clear refusal.
5. **On a PC a phone's hand-over cannot enable Screen by itself** (`screenPending`), from the master plan's "computers whose screen scope was set at this PC" (§2, relay); the PC shows **Allow screen**. On a Mac a handed-over screen scope works at once, as passes do today, because the stream involves no password.
6. **A computer on a Mac gets `screenVideo` only**, never the RFB relay; no curtain, no Use Here (as a pass).
7. **Computers get no history, transcripts, events, push or lock.** Nothing in this plan's UI needs them, and a small surface is easier to keep right. (A shell can read the files anyway; this is not a boundary.)
8. **`screenGrant` now also needs the *May share* switch.** Upgrade rule: at first launch of the build with a2, a phone that has at least one pass in the store gets `share: true` written once; every other phone is off.
9. **The receiver's identity key reaches the phone in `host.idKey`**, so no new request type is needed and the phone asks the receiver before the host.
10. **Strict replace rule** (certificate and iroh id both equal), with `pass_conflict` and a notice; only the host's own `macInfo` changes iroh details.
11. **Pairing certificates are per sheet and unpinned**; identity public keys, host ids and `keeps` are added to the transcript; credentials are sealed under ECDH-derived keys so the result does not rest on TLS alone. AES-256-GCM rather than ChaCha20-Poly1305, because .NET's ChaCha needs a newer Windows than a dial-only Windows 10 PC may have.
12. **Codes come from the transcript hash only**, eight bytes reduced mod 10⁶ (bias below 10⁻¹³).
13. **Tunnels are not "this network"** for pairing, even Tailscale: the sheet promises the same Wi-Fi, and the phone hand-over covers everything else.
14. **On Windows the pairing runs in the tray app**, not the service: it is per account, bound to UI, and needs none of the service's keys; the service only records the computer through `IAccessAdmin`. This needs a firewall rule for the app from the install.
15. **A PC can pair before it can keep access** (`keeps: false`), so b3 does not wait for stage 8a.
16. **The engine never runs in the app process**, and the helper lands first with a fake engine.
17. **One helper process per window.**
18. **The app becomes a regular app while a screen window is open**, to have a menu bar.
19. **`passthrough-term remote` always needs the app's token**; typing it by hand is refused with a pointer to the menu.
20. **Closing a terminal window leaves the far session running**; ending is explicit (**End**), as the master plan says.
21. **Watch connections only while the panel is open.**
22. **Android gets no share flow** in this stage.

## Corrections to the master plan

1. §2 "Viewers" says the engine is "linked into the two apps only". On the Mac it must be linked into the **helper only**; the Mac app links neither FreeRDP nor OpenSSL. (iOS unchanged.)
2. §2 "Direct pairing" lists what the transcript holds; this plan **adds** both identity public keys, both host ids and the `keeps` flags. Without the identity key in the transcript the issued credential could be bound to a key the digits never covered.
3. §2 "Computers" says the proof "adds a signature over the nonce". The signature must also cover the **host binding and the computer id** (a.1), or a signature could be replayed toward another host that shares nothing but the computer.
4. §1 "Mac and PC together" has both computers "show six digits" right after picking; a computer that **can only dial** (a PC without the install) needs the extra "dial me" signal (`w`), and two such PCs cannot pair directly. The sheet says so.
5. §1 says a *Windows* menu sits "in the menu bar" on the Mac; the Mac app is an agent with **no menu bar today** (`project.yml:330`). Decision 18 supplies one.
6. §2 says a computer's access is granted "via `computerGrant`/`computerPass`"; a failed hand-over also needs **`computerRevoke`**, and the phone needs `host.share` to know whether to offer the item and `host.idKey` to bind the grant.
7. §2 "Secrets" ties a PC's ability to hold credentials to Windows Hello; pairing therefore needs the `keeps` flag so the other side can say so instead of failing after the digits.
8. §3 stage 4's firewall bullet covers the service's port and iroh only; **the pairing listener needs its own rule** (b.2).
9. §5 lists stage 7's docs as protocol *Computers* and SECURITY.md; also needed: `project.yml` usage string and Bonjour type, CONTRIBUTING (the XPC target, the Mac size note), THIRD_PARTY_NOTICES check for the Mac zip.
10. `protocol/README.md:794` says "Only the Mac mints `viewer.` ids"; with PCs as hosts the *Computers* section says "only a host".

## Open questions for the owner (each with a recommended default)

1. **Should updating flip *May share* on for phones that already granted a screen pass?** Default: yes, once, only for phones with a live pass (decision 8), so nothing that works stops; everyone else is off.
2. **Should a shell on another computer ask Touch ID, as Screen does?** The master plan asks it for Screen only. Default: no prompt for a shell, with a setting "Ask Touch ID before opening a shell on another computer" (off) added in d2.
3. **Dock icon while a screen window is open** (decision 18). Default: yes. The alternative keeps the app an agent and puts the *Windows* menu only in the toolbar, which drops "every toolbar action is also in the menu bar" for this window.
4. **Pairing over Tailscale.** Default: no (decision 13). Allowing it would let two computers in different places pair with digits read over a phone call, at the cost of trusting everyone on the tailnet to be unable to race the exchange (they could not complete it, only disturb it).
5. **May a directly paired computer read shell history later?** Default: not in this plan (decision 7); revisit when the PC's flyout wants a history list.
6. **The clipboard limit of the sandbox** (the helper could read the Mac's pasteboard if compromised). Default: accept and document. The alternative is a custom sandbox profile through an unsupported call, which is not recommended.
7. **Cap of 16 computers per host and 8 per phone.** Default: keep; both are constants.
8. **On a Mac, should a phone's hand-over of Screen also wait for the owner, as on a PC?** Default: no, to match how passes work today; say yes if the Mac should be as strict as the PC now that the hand-over can include a shell.
9. **Retire the old screen-only pass flow?** Default: keep `screenGrant` and existing passes working for one release after a4, then remove the phone's fallback (hosts keep honouring existing passes "for good", as the master plan says).
