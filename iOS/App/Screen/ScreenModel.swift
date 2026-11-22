import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import IrohTransport
import LocalAuthentication
import UIKit
import PassthroughCore
import RemoteDesktop
import ScreenClient

/// One view of the selected Mac's screen: its own shell connection, which asks
/// for the screen. First the Mac's own H.264 stream (`MacStreamBackend`,
/// protocol/README.md "Screen video"): smooth, and no password. A Mac that
/// can't stream (it lacks Screen Recording or Accessibility, or predates it)
/// says so, and the same connection asks for Screen Sharing instead, handed
/// to a `ScreenSharingBackend` with the Mac's login ("Screen"). Whichever it
/// is, the view speaks to it as a `ScreenBackend`. That fallback sends a
/// saved login only once the user agrees (`confirmScreenSharing`), or chose
/// "Always" for that Mac: whatever answers as Screen Sharing gets it. While
/// on Screen Sharing it keeps trying the stream on a second connection
/// (`upgrade`) and switches to it as soon as one shows the screen. Frames go straight to
/// the canvas (`onFrame`, `onVideoFrame`; not published: a frame must not
/// re-render the SwiftUI screen around it); takes pointer and key input.
@MainActor
final class ScreenModel: ObservableObject {
    enum Phase: Equatable {
        /// Waiting for the Mac's account name and password; `error` says why again.
        case login(error: String?)
        /// The Mac's own stream didn't work: asking whether to use Screen
        /// Sharing, which sends the Mac's login (`useScreenSharing`).
        case confirmScreenSharing
        case connecting
        case live
        case failed(String)
        /// Another device took this view over ("Use Here" there); it can be taken back.
        case movedAway(to: String)
    }

    @Published private(set) var phase = Phase.connecting
    /// The latest frame.
    private(set) var image: CGImage?
    /// The canvas, which draws each frame as it arrives.
    var onFrame: ((CGImage) -> Void)?
    /// The canvas's video display; false (or unset) when it couldn't take the frame, and a keyframe is asked for.
    var onVideoFrame: ((CMSampleBuffer) -> Bool)?
    /// The Mac's own stream leaves the pointer out: the canvas draws it, where the
    /// Mac says it is (in screen pixels; or off this display) when this phone isn't moving it.
    var onMacPointer: ((CGPoint?, Bool) -> Void)?
    /// What the pointer looks like: the image, its size and tip in screen pixels.
    var onPointerShape: ((CGImage, CGSize, CGPoint) -> Void)?
    /// The last of each, for a canvas made after they came: the Mac says what the pointer
    /// looks like once, as a view starts, before there is a canvas to draw it.
    private(set) var pointerShape: (image: CGImage, size: CGSize, hotSpot: CGPoint)?
    private(set) var macPointer: (point: CGPoint, onScreen: Bool)?
    /// The Mac's screen in pixels.
    @Published private(set) var screenSize = CGSize.zero
    @Published private(set) var macName = "your Mac"
    /// Why the view is on Screen Sharing rather than the Mac's own stream; nil when it isn't.
    @Published private(set) var slowReason: String?
    /// Said briefly over the screen: what a copy or paste did.
    @Published private(set) var notice: String?
    /// A Copy is waiting for the Mac's answer; another waits for it.
    @Published private(set) var copying = false
    /// The Mac says its own displays are hidden (black to whoever is at it) while this view shows the screen.
    @Published private(set) var macHidden = false
    /// Only the Mac's own stream can leave the black out of what it sends; Screen Sharing would show it.
    var canHideMac: Bool { macStream != nil }
    /// This device as the Mac's microphone (the Mac's "Passthrough Microphone" input device).
    enum Microphone: Equatable { case off, starting, on }
    @Published private(set) var microphone = Microphone.off
    /// Only the Mac's own stream carries voice (not Screen Sharing).
    var canUseMicrophone: Bool { macStream != nil }
    private var voiceCapture: PhoneVoiceCapture?
    /// The Mac takes this device's voice: it should be recording.
    private var capturing = false
    /// Play the Mac's sound here (the user's choice, off until chosen), and whether the Mac sends it now.
    @Published private(set) var playsSound = UserDefaults.standard.bool(forKey: ScreenModel.playsSoundKey)
    private static let playsSoundKey = "screenPlaysMacSound"
    private var soundLive = false
    private var soundPlayer: MacSoundPlayer?
    private var microphoneTimeout: Task<Void, Never>?
    /// The user's choice: the Mac makes a display in this device's shape and shows that
    /// (`Fit.device`), or shows its own display as it is (`Fit.mac`, the default).
    @Published private(set) var fitsDevice = ScreenModel.fitsDeviceSetting
    /// What the Mac's stream shows now: `mac` while `fitsDevice` means the Mac couldn't make one.
    @Published private(set) var fitted: ScreenVideoWire.Fit?
    /// The user's choice of what matters most on a slow link, kept for the next view.
    @Published private(set) var quality = ScreenModel.qualitySetting
    /// The user's choice of text size on a display made for this device: the display's
    /// size against the stream's, in percent (80 larger text, 100, 125 more space).
    @Published private(set) var space = ScreenModel.spaceSetting
    static let spaces = [80, 100, 125]
    /// The user's choice on the Mac's own display: pinch and rotate go to the Mac instead of zooming this view.
    @Published private(set) var pinchesMacOnItsDisplay = UserDefaults.standard.bool(forKey: ScreenModel.pinchKey)
    private static let pinchKey = "screenPinchGoesToMac"
    /// Pinch and rotate go to the app under the fingers on the Mac (its own stream only:
    /// Screen Sharing has no gestures): always on a display made for this device, where
    /// the text is already this device's size; on the Mac's own display if the user chose it.
    var pinchesMac: Bool { macStream != nil && (fitsDevice || pinchesMacOnItsDisplay) }
    /// The other devices viewing the Mac's screen now (their names), for "Use Here".
    @Published private(set) var otherViewers: [String] = []
    /// "Use Here" was asked for before the stream was up (taking the view back): sent once it is.
    private var usesHereOnStart = false
    /// How the view reaches the Mac: the local network, straight over the internet,
    /// or through a relay (farther, so slower). Nil while unknown.
    @Published private(set) var connectionPath: ShellPath?

    private var shell: ShellModel?
    private var context: LAContext?
    private var macID: String?
    /// The PC's keys as its credential says now: a Windows login is saved with them and read only while they match.
    private var windowsPin: String?
    private var client: ShellClient?
    private var dialer: IrohShellDialer?
    /// What shows the screen now: the Mac's own stream or Screen Sharing.
    private var backend: (any ScreenBackend)?
    /// Bumped by every backend this view makes its own (and by the stream taking
    /// over from Screen Sharing), so what an earlier one still says is dropped.
    private var backendToken = 0
    /// The Mac's own stream's controls, while it shows the screen.
    private var macStream: (any MacStreamControls)? { backend?.macStream }
    /// Screen Sharing shows the screen (the stream is tried again meanwhile).
    private var onScreenSharing: Bool { backend is ScreenSharingBackend }
    /// This view shows a PC (through its Remote Desktop), not a Mac.
    @Published private(set) var windowsView = false
    /// The user's choices for this PC, remembered per computer: the desktop's shape, and Windows' text size on it.
    @Published private(set) var windowsShapeChoice = WindowsDisplay.Shape.fit
    @Published private(set) var windowsSpace = 100
    /// The shape Windows was last asked for (the first desktop, then every change), and when (uptime).
    private var windowsAsked: ScreenShape?
    private var windowsAskedAt: TimeInterval?
    private var windowsLayoutTask: Task<Void, Never>?
    private var windowsResizeWatch: Task<Void, Never>?
    /// "…kept its screen as it was" is said once a view.
    private var saidKeptShape = false
    /// A hardware keyboard's ⌘ on a PC: Control (the default), or the Windows key. Kept for every PC.
    @Published private(set) var commandIsWindows = UserDefaults.standard.bool(forKey: ScreenModel.commandIsWindowsKey)
    private static let commandIsWindowsKey = "screenCommandIsWindows"
    /// How the sign-in sheet asks: a Mac's account, or a PC's Windows account (the last used here, else the one the PC named).
    var loginStyle: ScreenLoginForm.Style {
        guard windowsView else { return .mac }
        return .windows(account: macID.flatMap { ScreenLoginStore.lastAccount(hostID: $0) ?? shell?.factsByMac[$0]?.user })
    }
    /// The login this PC view signed in with, kept while the view is open so a dropped
    /// view (or one back from the background) reconnects without asking again.
    /// The login this view signed in with, and the PC it is for (its id and keys): reused only for that PC.
    private var windowsLogin: (login: ScreenLogin, remember: Bool, host: String, pin: String)?
    /// The connection is asking for the Mac's own stream (not Screen Sharing).
    private var wantsVideo = false
    /// Where the Mac last heard the pointer was, in screen pixels.
    private var lastPointer: CGPoint?
    /// The stream has shown its size: a stream ending before that never worked, so Screen Sharing is tried.
    private var videoStarted = false
    private var noticeTask: Task<Void, Never>?
    /// Ends a Copy the Mac doesn't answer (the stream: a Mac that predates
    /// copying; Screen Sharing: one whose clipboard didn't change).
    private var copyTimeout: Task<Void, Never>?
    /// Says so when the Mac doesn't answer a request to hide its display (one that predates it).
    private var hideTimeout: Task<Void, Never>?
    /// What the Mac was last asked (`askMacHidden`) and hasn't answered yet.
    private var askedHidden: Bool?
    /// The user's choice, kept for the next view: a display in this device's shape.
    private static let fitsDeviceKey = "screenFitsDevice"
    private static var fitsDeviceSetting: Bool { UserDefaults.standard.bool(forKey: fitsDeviceKey) }
    private static let qualityKey = "screenQuality"
    private static var qualitySetting: ScreenVideoWire.Quality {
        ScreenVideoWire.Quality(rawValue: UInt8(clamping: UserDefaults.standard.integer(forKey: qualityKey))) ?? .sharp
    }
    private static let spaceKey = "screenSpace"
    private static var spaceSetting: Int {
        let value = UserDefaults.standard.integer(forKey: spaceKey)
        return spaces.contains(value) ? value : 100
    }
    /// The screen view's area in pixels, as the device is held now (the canvas says when it changes).
    private var viewPixels: CGSize?
    private var relayoutTask: Task<Void, Never>?
    /// How the connection's path was when it was ready, and the watch on it since (iroh can move from a relay to a direct path).
    private var readyPath: ShellPath?
    private var upgradeReadyPath: ShellPath?
    private var upgradeStream: (any ByteStream)?
    private var pathTask: Task<Void, Never>?
    /// The relay notice is said once a view.
    private var saidRelay = false
    /// Drops in a row that were reconnected without asking, and since when this stream has shown the screen.
    private var reconnects = 0
    private var liveSince: TimeInterval?
    static let maxReconnects = 4
    /// A view that lasted this long was working: the next drop starts the count again.
    static let steadyAfter: TimeInterval = 15
    /// Another device took the view over, by this name (`movedAway`); the stream ends next.
    private var movedTo: String?
    /// What the upgrade's stream said before its size, for when it takes over.
    private var upgradeEarly: [ScreenBackendEvent] = []
    /// When this phone last moved the Mac's pointer: for a moment after, where the
    /// Mac says it is is an echo of that, already drawn.
    private var lastPointerAt: TimeInterval = 0
    /// The user's choice, kept for the next view: hide the Mac's display while viewing.
    private static let hidesMacKey = "screenHidesMacDisplay"
    /// Hidden unless the user turned it off: a view starts private.
    private static var hidesMac: Bool { UserDefaults.standard.object(forKey: hidesMacKey) as? Bool ?? true }
    /// Hidden only while someone is looking: this app going to the background (put
    /// away, the phone locked) shows the Mac's display again, and coming back hides it again.
    private var appObservers: [NSObjectProtocol] = []
    private var hiddenBeforeAway = false
    /// The answer to the background's ask isn't remarked on.
    private var quietCurtain = false
    /// Bumped by every start and stop, so a stale connection's events are dropped.
    private var generation = 0
    private var pendingLogin: (login: ScreenLogin, remember: Bool)?
    /// While on Screen Sharing: a second connection trying the Mac's own
    /// stream, swapped in once it shows its size (`promote`).
    private var upgrade: (client: ShellClient?, dialer: IrohShellDialer?, video: MacStreamBackend?)?
    private var upgradeTask: Task<Void, Never>?
    /// Bumped per upgrade attempt; the promoted one's stream keeps its token.
    private var upgradeToken = 0
    private var promotedToken: Int?
    private var upgradeAttempts = 0
    /// The wait before each try of the stream while on Screen Sharing; the
    /// last repeats for as long as the view lasts.
    static let upgradeDelays: [TimeInterval] = [3, 5, 10, 20, 30]

    /// Uses the saved login if there is one, else asks for it.
    /// `takeOver`: "Use Here" from a view another device took: this one ends theirs once it's up.
    func begin(shell: ShellModel, context: LAContext, takeOver: Bool = false) {
        #if DEBUG
        if let demo = Self.demoState { return applyDemo(demo) }
        #endif
        self.shell = shell
        self.context = context
        guard let mac = shell.macs.first(where: { $0.macID == shell.selectedMacID }) else {
            phase = .failed("Choose a computer first.")
            return
        }
        // A PC's screen is its Remote Desktop, behind the developer switch: never the Mac's paths.
        if shell.kind(of: mac.macID) == .windows, PCScreen.isOn { return beginWindows(mac) }
        windowsView = false
        windowsLogin = nil
        // Before anything is dialled: a PC is never asked for the Mac's screen.
        if refusesNonMac(mac.macID, name: mac.macName) { return }
        macID = mac.macID
        macName = mac.macName
        slowReason = nil
        saidRelay = false
        observeApp()
        reconnects = 0
        open(video: true)
        usesHereOnStart = takeOver
    }

    private func observeApp() {
        guard appObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        appObservers = [
            // A call, Siri or an alarm took the audio and gave it back: the Mac's sound plays again.
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
                guard ended else { return }
                MainActor.assumeIsolated { self?.audioCameBack() }
            },
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appWentAway() }
            },
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appCameBack() }
            },
        ]
    }

    /// The view outlives a short trip away, but no one is watching the Mac meanwhile.
    private func appWentAway() {
        // A PC stops sending pictures while no one looks.
        backend?.setActive(false)
        // Not listening while no one is looking at the Mac, nor playing its sound.
        stopMicrophone()
        if soundLive {
            macStream?.sound(false)
            stopSound()
        }
        guard macStream != nil, macHidden || askedHidden == true else { return }
        hiddenBeforeAway = true
        quietCurtain = true
        // Long enough for the ask to get out before iOS suspends the app.
        let task = UIApplication.shared.beginBackgroundTask()
        askMacHidden(false, saysIfUnanswered: false)
        Task {
            try? await Task.sleep(for: .seconds(2))
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    private func appCameBack() {
        backend?.setActive(true)
        if playsSound, phase == .live { macStream?.sound(true) }
        guard hiddenBeforeAway else { return }
        hiddenBeforeAway = false
        if macStream != nil, Self.hidesMac { askMacHidden(true, saysIfUnanswered: false) }
    }

    /// Screen Sharing, with the Mac account's login.
    func connect(_ login: ScreenLogin, remember: Bool) {
        #if DEBUG
        if Self.demoState != nil { return applyDemo("live") }
        #endif
        if windowsView { return connectWindows(login, remember: remember) }
        // A Mac login is never sent to anything but a Mac.
        if let macID, refusesNonMac(macID, name: macName) { return }
        pendingLogin = (login, remember)
        open(video: false)
    }

    private func open(video: Bool) {
        let login = pendingLogin
        stop()
        pendingLogin = login
        guard let shell else { return }
        generation += 1
        let gen = generation
        wantsVideo = video
        videoStarted = false
        lastPointer = nil
        upgradeAttempts = 0
        phase = .connecting
        guard let connection = shell.screenConnection(onEvent: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, generation: gen) }
        }) else {
            phase = .failed("Choose a computer first.")
            return
        }
        client = connection.client
        dialer = connection.dialer
    }

    /// The Mac can't stream its screen itself: Screen Sharing on the same
    /// connection with a login typed for this view, or the saved one if the
    /// user chose "Always" for this Mac; otherwise they are asked first.
    private func fallBackToScreenSharing() {
        // A kind learned late (its `host` came after the screen was asked for) still never gets here.
        if let macID, refusesNonMac(macID, name: macName) { return }
        wantsVideo = false
        slowReason = "Slower: allow Passthrough Screen Recording and Accessibility on \(macName) for the smooth view."
        if pendingLogin == nil, let macID, Self.alwaysUsesScreenSharing(macID: macID), let context,
           let saved = ScreenLoginStore.read(macID: macID, context: context) {
            pendingLogin = (saved, false)
        }
        if pendingLogin != nil {
            client?.requestScreen(video: false)
        } else {
            stop()
            phase = .confirmScreenSharing
        }
    }

    /// The user agreed to Screen Sharing (`always`: from now on for this
    /// Mac, without asking): with the saved login, else the login form.
    func useScreenSharing(always: Bool) {
        guard let macID else { return }
        if refusesNonMac(macID, name: macName) { return }
        if always { Self.setAlwaysUsesScreenSharing(macID: macID) }
        if let context, let saved = ScreenLoginStore.read(macID: macID, context: context) {
            connect(saved, remember: false)
        } else {
            phase = .login(error: nil)
        }
    }

    /// The Mac's screen path (its own stream, Screen Sharing and its login) is a Mac's
    /// only: for a PC, or a computer of a kind this build doesn't know, it ends
    /// here, says why, and nothing is dialled or sent. True when it ended.
    private func refusesNonMac(_ id: String, name: String) -> Bool {
        guard let shell else { return false }
        let kind = shell.kind(of: id)
        guard kind != .mac else { return false }
        stop()
        let words = HostWords(kind: kind, name: name, device: ThisDevice.name)
        let state = id == shell.selectedMacID ? shell.page.screen : .notInThisVersion
        phase = .failed(HostCopy.screen(state == .available || state == .noRow ? .notInThisVersion : state, words)
                        ?? "\(words.name)'s screen isn't in this version of Passthrough yet.")
        return true
    }

    private static let screenSharingAlwaysKey = "screenSharingAlwaysMacs"

    /// The user chose "Always" for this Mac: a fallback sends its saved login without asking.
    static func alwaysUsesScreenSharing(macID: String) -> Bool {
        UserDefaults.standard.stringArray(forKey: screenSharingAlwaysKey)?.contains(macID) ?? false
    }

    private static func setAlwaysUsesScreenSharing(macID: String) {
        var macs = UserDefaults.standard.stringArray(forKey: screenSharingAlwaysKey) ?? []
        guard !macs.contains(macID) else { return }
        macs.append(macID)
        UserDefaults.standard.set(macs, forKey: screenSharingAlwaysKey)
    }

    /// Ends the view; the shell sessions are untouched.
    func stop() {
        generation += 1
        fitted = nil
        otherViewers = []
        movedTo = nil
        usesHereOnStart = false
        upgradeEarly = []
        pointerShape = nil
        macPointer = nil
        liveSince = nil
        pathTask?.cancel()
        pathTask = nil
        connectionPath = nil
        upgradeStream = nil
        relayoutTask?.cancel()
        windowsLayoutTask?.cancel()
        windowsResizeWatch?.cancel()
        windowsAsked = nil
        windowsAskedAt = nil
        stopMicrophone()
        stopSound()
        backend?.close()
        backend = nil
        backendToken += 1
        copyTimeout?.cancel()
        copying = false
        hideTimeout?.cancel()
        askedHidden = nil
        macHidden = false
        hiddenBeforeAway = false
        quietCurtain = false
        pendingLogin = nil
        client?.disconnect()
        client = nil
        dialer?.shutdown()
        dialer = nil
        dropUpgrade()
        promotedToken = nil
    }

    private func handle(_ event: ShellClient.Event, generation gen: Int) {
        guard gen == generation else {
            if case let .screen(stream, _) = event { stream.cancel() }
            return
        }
        switch event {
        case let .ready(path):
            readyPath = path
            client?.requestScreen(video: wantsVideo)
        case let .screen(stream, initialBytes) where wantsVideo:
            client = nil   // it let go of the stream; the dialer stays up for it
            watchPath(of: stream, dialer: dialer, startingAt: readyPath)
            backendToken += 1
            let token = backendToken
            let video = MacStreamBackend(stream: stream, initialBytes: initialBytes, layout: layout()) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event, generation: gen, token: token) }
            }
            backend = video
            video.start()
            if usesHereOnStart {
                usesHereOnStart = false
                video.useHere()
            }
        case .failed(.screenVideoUnavailable, _) where wantsVideo, .failed(.badRequest, _) where wantsVideo:
            fallBackToScreenSharing()
        case let .screen(stream, initialBytes):
            client = nil   // it let go of the stream; the dialer stays up for it
            guard let login = pendingLogin?.login else { return stream.cancel() }
            watchPath(of: stream, dialer: dialer, startingAt: readyPath)
            backendToken += 1
            let token = backendToken
            let screenSharing = ScreenSharingBackend(stream: stream, initialBytes: initialBytes, login: login) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event, generation: gen, token: token) }
            }
            backend = screenSharing
            screenSharing.start()
        case let .failed(error, _):
            phase = .failed(error.message ?? "Your Mac refused the connection.")
            stop()
        case .disconnected:
            phase = .failed("Couldn't reach \(macName). Check that it's awake and Remote shell is on.")
            stop()
        case let .host(info) where HostKind(wire: info.kind) != .mac:
            // Told only now that this isn't a Mac: its screen path ends before anything more is asked.
            stop()
            phase = .failed(HostCopy.screen(.notInThisVersion, HostWords(kind: HostKind(wire: info.kind), name: macName, device: ThisDevice.name))
                            ?? "Choose a computer first.")
        default:
            break
        }
    }

    private func handle(_ event: ScreenBackendEvent, generation gen: Int, token: Int) {
        // Not this view's backend now (Screen Sharing after the stream took over and closed it): nothing it still says counts.
        guard gen == generation, token == backendToken, let backend else { return }
        let isStream = backend.macStream != nil
        switch event {
        case let .size(width, height):
            screenSize = CGSize(width: width, height: height)
            phase = .live
            if windowsView {
                // The answer to a change of shape (or the first desktop): nothing is waited for now.
                windowsResizeWatch?.cancel()
                if liveSince == nil {
                    liveSince = ProcessInfo.processInfo.systemUptime
                    windowsSignedIn()
                }
            } else if isStream {
                let first = !videoStarted
                videoStarted = true
                if first { liveSince = ProcessInfo.processInfo.systemUptime }
                if first, Self.hidesMac { askMacHidden(true, saysIfUnanswered: false) }
                if first, playsSound { macStream?.sound(true) }
            } else {
                // Screen Sharing logged in.
                if let pending = pendingLogin, pending.remember, let macID, let context {
                    ScreenLoginStore.save(pending.login, macID: macID, context: context)
                }
                pendingLogin = nil
                scheduleUpgrade()
            }
        case let .image(image):
            self.image = image
            let size = CGSize(width: image.width, height: image.height)
            if size != screenSize { screenSize = size }
            onFrame?(image)
        case let .sample(sample, number):
            // Not shown (no canvas yet, or its display failed): what follows needs a new keyframe.
            if onVideoFrame?(sample) != true { backend.needsKeyframe() }
            backend.presented(number)
        case let .copied(result):
            // An answer after Copy timed out (and said so) changes nothing now.
            guard copying else { return }
            switch result {
            case let .text(text) where !text.isEmpty: copied(text)
            case .text: copyFailed("Nothing was copied. Select something on \(macName) first.")
            case .nothing: copyFailed("Nothing was copied. Select something on \(macName) first.")
            case .tooLong: copyFailed("That's too long to copy to this \(ThisDevice.name).")
            case .notText: copyFailed("Only text can be copied to this \(ThisDevice.name).")
            }
        case let .clipboardChanged(text):
            // Screen Sharing sends the Mac's clipboard whenever it changes, whatever is on it:
            // taken only as the answer to Copy's ⌘C (the backend already leaves out the phone's own paste).
            if copying, !text.isEmpty { copied(text) }
        case .bell:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case let .pointerPosition(point, visible):
            guard screenSize.width > 0 else { return }
            // Echoes of this phone's own moves are drawn already (only whether it's on this display
            // counts then); the Mac's own moves (its trackpad) aren't.
            let echo = ProcessInfo.processInfo.systemUptime - lastPointerAt <= 1.5
            macPointer = (echo ? macPointer?.point ?? point : point, visible)
            onMacPointer?(echo ? nil : point, visible)
        case let .pointerShape(image, size, hotSpot):
            pointerShape = (image, size, hotSpot)
            onPointerShape?(image, size, hotSpot)
        case .pointerHidden, .phase:
            break
        case let .macStream(event):
            handle(event)
        case let .ended(end):
            if windowsView {
                windowsEnded(end)
            } else if isStream {
                streamEnded()
            } else {
                screenSharingEnded(end)
            }
        }
    }

    /// What only the Mac's own stream says.
    private func handle(_ event: MacStreamEvent) {
        switch event {
        case let .microphone(state):
            microphoneAnswered(state)
        case let .sound(state):
            soundAnswered(state)
        case let .soundPacket(packet):
            soundPlayer?.play(packet)
        case let .curtained(hidden):
            hideTimeout?.cancel()
            let asked = askedHidden
            askedHidden = nil
            if quietCurtain {
                quietCurtain = false
            } else if asked == true, !hidden {
                show("\(macName) couldn't hide its display.")
            } else if hidden != macHidden {
                show(hidden ? "\(macName)'s own display is hidden" : "\(macName)'s display is showing again")
            }
            macHidden = hidden
        case let .fitted(fit):
            let before = fitted
            fitted = fit
            if fit == .mac, fitsDevice, before != .mac {
                show("\(macName) couldn't make a display for this \(ThisDevice.name), so this is its own.")
            }
        case let .viewers(names):
            otherViewers = names
        case let .movedAway(name):
            movedTo = name
        }
    }

    /// The Mac's own stream ended.
    private func streamEnded() {
        if let movedTo {
            stop()
            phase = .movedAway(to: movedTo)
            return
        }
        let worked = videoStarted
        stop()
        guard worked else {
            // The Mac said yes but couldn't capture or encode after all
            // (its display didn't come on in time, say). `upgrade` tries again.
            slowReason = "Slower: \(macName) couldn't stream its screen just then. This switches to the smooth view once it can."
            if let macID, Self.alwaysUsesScreenSharing(macID: macID), let context,
               let saved = ScreenLoginStore.read(macID: macID, context: context) {
                return connect(saved, remember: false)
            }
            phase = .confirmScreenSharing
            return
        }
        // A view that worked and dropped (the network changed, a tunnel, the Mac's stream
        // ending) comes back by itself; only a few drops in a row ask the user.
        if let liveSince, ProcessInfo.processInfo.systemUptime - liveSince > Self.steadyAfter { reconnects = 0 }
        guard reconnects < Self.maxReconnects else {
            phase = .failed("The connection to \(macName) was lost.")
            return
        }
        reconnects += 1
        phase = .connecting
        let attempt = reconnects, gen = generation
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300 * attempt))
            guard let self, gen == self.generation, self.phase == .connecting else { return }
            self.open(video: true)
        }
    }

    /// Screen Sharing ended.
    private func screenSharingEnded(_ end: ScreenEnd) {
        stop()
        switch end {
        case .closedHere:
            break
        case .signIn:
            if let macID { ScreenLoginStore.delete(macID: macID) }
            image = nil
            phase = .login(error: "Your Mac didn't accept that name and password.")
        case .unsupported:
            phase = .failed("Screen Sharing on your Mac answered in a way this app doesn't understand.")
        case .identityMismatch:
            phase = .failed("What answered as Screen Sharing on \(macName) didn't ask for a login, which your Mac's Screen Sharing always does. Passthrough didn't connect.")
        case .protocolError:
            phase = .failed("The screen connection broke. Try again.")
        case .connectionLost, .takenOver, .signedOut, .hostEnded:
            phase = .failed("The connection to \(macName) was lost.")
        }
    }

    // MARK: A PC (behind the developer switch, `PCScreen`)

    /// A PC's screen through its Remote Desktop: the sign-in first (the connection
    /// opens only with a login in hand), then `rdp` on a connection of its own.
    private func beginWindows(_ pc: ShellCredential) {
        windowsView = true
        macID = pc.macID
        macName = pc.macName
        windowsPin = pc.loginPin
        windowsShapeChoice = UserDefaults.standard.string(forKey: Self.windowsShapeKey(pc.macID)).flatMap(WindowsDisplay.Shape.init) ?? .fit
        let space = UserDefaults.standard.integer(forKey: Self.windowsSpaceKey(pc.macID))
        windowsSpace = WindowsDisplay.spaces.contains(space) ? space : 100
        saidKeptShape = false
        slowReason = nil
        saidRelay = false
        observeApp()
        reconnects = 0
        // Held for this PC and these keys only: another computer (or this id with other keys) never gets it.
        if let held = windowsLogin, held.host == pc.macID, held.pin == pc.loginPin {
            return connectWindows(held.login, remember: held.remember)
        }
        windowsLogin = nil
        // The account last used here, else the one the PC says Remote Desktop takes; its saved
        // login is read with the app lock's context, so it never prompts.
        let account = ScreenLoginStore.lastAccount(hostID: pc.macID) ?? shell?.factsByMac[pc.macID]?.user
        if let account, let context,
           let saved = ScreenLoginStore.readWindows(hostID: pc.macID, account: account, pin: pc.loginPin, context: context) {
            return connectWindows(saved, remember: true)
        }
        stop()
        phase = .login(error: nil)
    }

    private func connectWindows(_ login: ScreenLogin, remember: Bool) {
        stop()
        // Kept for as long as the view is open, so a dropped view reconnects with it.
        windowsLogin = (login, remember, macID ?? "", windowsPin ?? "")
        guard let shell else { return }
        generation += 1
        let gen = generation
        lastPointer = nil
        phase = .connecting
        // The login is this PC's: a connection to whichever computer is selected now (it may have changed while
        // this view retried) must not get it.
        guard let macID, shell.selectedMacID == macID, shell.kind(of: macID) == .windows else {
            windowsLogin = nil
            phase = .failed("Choose \(macName) again to see its screen.")
            return
        }
        guard let connection = shell.screenConnection(onEvent: { [weak self] event in
            MainActor.assumeIsolated { self?.handleWindows(event, generation: gen) }
        }) else {
            phase = .failed("Choose a computer first.")
            return
        }
        guard connection.mac.macID == macID else {
            connection.client.disconnect()
            connection.dialer?.shutdown()
            windowsLogin = nil
            phase = .failed("Choose \(macName) again to see its screen.")
            return
        }
        client = connection.client
        dialer = connection.dialer
    }

    private var windowsWords: HostWords { HostWords(kind: .windows, name: macName, device: ThisDevice.name) }

    private func handleWindows(_ event: ShellClient.Event, generation gen: Int) {
        guard gen == generation else {
            if case let .rdp(stream, _, _) = event { stream.cancel() }
            return
        }
        switch event {
        case let .ready(path):
            readyPath = path
            client?.requestRDP()
        case let .rdp(stream, initialBytes, certSHA256):
            client = nil   // it let go of the stream; the dialer stays up for it
            guard let login = windowsLogin?.login else { return stream.cancel() }
            watchPath(of: stream, dialer: dialer, startingAt: readyPath)
            backendToken += 1
            let token = backendToken
            let shape = windowsShape()
            windowsAsked = shape
            let made = RemoteDesktop.backend(stream: stream, initialBytes: initialBytes, certSHA256: certSHA256, login: login,
                                             width: shape.width, height: shape.height, desktopScale: shape.desktopScale,
                                             deviceScale: shape.deviceScale, clientName: ThisDevice.name,
                                             slowLink: readyPath == .relay) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event, generation: gen, token: token) }
            }
            guard let made else {
                stream.cancel()
                stop()
                phase = .failed("\(macName)'s screen isn't in this build of Passthrough.")
                return
            }
            backend = made
            made.start()
        case let .rdpRefused(error, detail, retryAfter):
            stop()
            // Access was revoked: nothing saved for this PC stays.
            if error == .notAuthorized, let macID { ScreenLoginStore.deleteAll(hostID: macID) }
            let words = windowsWords
            phase = .failed(WindowsScreenCopy.refusal(error, detail: detail, retryAfter: retryAfter, words)?.sentence
                            ?? error.message(for: words) ?? "\(macName) refused the connection.")
        case let .failed(error, _):
            stop()
            phase = .failed(error.message(for: windowsWords) ?? "\(macName) refused the connection.")
        case .disconnected:
            stop()
            phase = .failed("Can't reach \(macName). It may be asleep, off, or offline.")
        default:
            break
        }
    }

    /// Windows took the login: kept (or forgotten) as the user chose, only now.
    private func windowsSignedIn() {
        guard let held = windowsLogin, let macID else { return }
        ScreenLoginStore.setLastAccount(held.login.username, hostID: macID)
        if !held.remember {
            ScreenLoginStore.deleteWindows(hostID: macID, account: held.login.username)
        } else if let context, let windowsPin {
            ScreenLoginStore.saveWindows(held.login, hostID: macID, pin: windowsPin, context: context)
        }
    }

    /// The PC's session ended.
    private func windowsEnded(_ end: ScreenEnd) {
        let now = ProcessInfo.processInfo.systemUptime
        let liveFor = liveSince.map { now - $0 }
        // A reason the PC gave on the app's other connection just now: the relay itself carries only Remote Desktop's bytes.
        let told = shell?.screenEnded.flatMap { $0.macID == macID && Date().timeIntervalSince($0.at) < 5 ? $0.reason : nil }
        stop()
        let words = windowsWords
        switch end {
        case .closedHere:
            return
        case .signIn(.wrongPassword):
            // A saved password Windows refused is forgotten: it costs one attempt, then the sheet.
            if let held = windowsLogin, let macID { ScreenLoginStore.deleteWindows(hostID: macID, account: held.login.username) }
            windowsLogin = nil
            phase = .login(error: WindowsScreenCopy.signInError(end))
            return
        case .signIn(.passwordExpired):
            if let held = windowsLogin, let macID { ScreenLoginStore.deleteWindows(hostID: macID, account: held.login.username) }
        case .signIn(.other):
            windowsLogin = nil
            phase = .login(error: nil)
            return
        default:
            break
        }
        if let told, let ending = WindowsScreenCopy.screenEnded(told, words) {
            phase = .failed(ending.sentence)
            return
        }
        // A view that worked and dropped comes back by itself, twice in a row at most (the PC
        // allows four opens in ten minutes); one live for 30 seconds starts the count again.
        if end == .connectionLost, let liveFor, let held = windowsLogin {
            if liveFor > 30 { reconnects = 0 }
            if reconnects < 2 {
                reconnects += 1
                phase = .connecting
                let attempt = reconnects, gen = generation
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500 * attempt))
                    guard let self, gen == self.generation, self.phase == .connecting else { return }
                    self.connectWindows(held.login, remember: held.remember)
                }
                return
            }
        }
        phase = .failed(WindowsScreenCopy.ending(end, words)?.sentence ?? "The connection to \(macName) was lost.")
    }

    // MARK: A PC's shape

    private static func windowsShapeKey(_ hostID: String) -> String { "screenShape.\(hostID)" }
    private static func windowsSpaceKey(_ hostID: String) -> String { "screenSpace.\(hostID)" }

    /// The desktop to ask Windows for: the view's own pixels as the device is held (the whole
    /// screen until it's laid out) or the standard 16:10, with Windows' text at the chosen size.
    private func windowsShape() -> ScreenShape {
        let screen = UIScreen.main
        let pixels = viewPixels ?? CGSize(width: screen.bounds.width * screen.scale, height: screen.bounds.height * screen.scale)
        return WindowsDisplay.shape(windowsShapeChoice, device: UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone,
                                    viewPixels: pixels, space: windowsSpace, host: windowsHostDisplay)
    }

    /// The PC's own monitor, when it said: the session keeps its scale, and "the PC's own size" is its pixels.
    var windowsHostDisplay: HostDisplay? { macID.flatMap { shell?.factsByMac[$0]?.display } }

    /// Fit to this device, the standard 16:10, or the PC's own size; kept for this PC.
    func setWindowsShape(_ shape: WindowsDisplay.Shape) {
        guard shape != windowsShapeChoice else { return }
        windowsShapeChoice = shape
        if let macID { UserDefaults.standard.set(shape.rawValue, forKey: Self.windowsShapeKey(macID)) }
        windowsShapeChanged()
    }

    /// How large things are on the PC's desktop here (80 larger text, 100, 125 more space): fewer or more pixels asked
    /// for, never another Windows scale. Kept for this PC.
    func setWindowsSpace(_ space: Int) {
        guard space != windowsSpace, WindowsDisplay.spaces.contains(space) else { return }
        windowsSpace = space
        if let macID { UserDefaults.standard.set(space, forKey: Self.windowsSpaceKey(macID)) }
        windowsShapeChanged()
    }

    /// The view turned, or a choice changed: a second after the last change, and at most once every two,
    /// Windows is asked for the new shape. A newer change replaces one that is waiting.
    private func windowsShapeChanged() {
        guard windowsView, backend != nil else { return }
        windowsLayoutTask?.cancel()
        let wait = WindowsDisplay.wait(now: ProcessInfo.processInfo.systemUptime, lastAsked: windowsAskedAt)
        let gen = generation
        windowsLayoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            guard !Task.isCancelled, let self, gen == self.generation, let backend = self.backend else { return }
            let shape = self.windowsShape()
            // A few percent either way isn't worth rearranging the PC's desktop for.
            guard WindowsDisplay.worthAsking(shape, current: self.windowsAsked) else { return }
            let resizes = shape.width != Int(self.screenSize.width) || shape.height != Int(self.screenSize.height)
            self.windowsAsked = shape
            self.windowsAskedAt = ProcessInfo.processInfo.systemUptime
            backend.reshape(shape)
            self.windowsResizeWatch?.cancel()
            guard resizes else { return }
            self.windowsResizeWatch = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, gen == self.generation, self.phase == .live, !self.saidKeptShape else { return }
                self.saidKeptShape = true
                self.show("\(self.macName) kept its screen as it was.")
            }
        }
    }

    // MARK: Back to the stream

    /// Tries the Mac's own stream again after the next delay, while Screen
    /// Sharing shows the screen. Whatever kept it from streaming (a display
    /// that was off, permissions granted since) may be gone by then.
    private func scheduleUpgrade() {
        guard onScreenSharing, upgrade == nil, upgradeTask == nil else { return }
        let delay = Self.upgradeDelays[min(upgradeAttempts, Self.upgradeDelays.count - 1)]
        upgradeAttempts += 1
        let gen = generation
        upgradeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, gen == self.generation else { return }
            self.upgradeTask = nil
            self.startUpgrade()
        }
    }

    /// A second connection asks for the stream; Screen Sharing carries on
    /// meanwhile (the Mac allows two views per phone).
    private func startUpgrade() {
        guard onScreenSharing, phase == .live, let shell else { return }
        upgradeToken += 1
        let gen = generation, token = upgradeToken
        guard let connection = shell.screenConnection(onEvent: { [weak self] event in
            MainActor.assumeIsolated { self?.handleUpgrade(event, token: token, generation: gen) }
        }) else { return }
        upgrade = (connection.client, connection.dialer, nil)
        upgradeEarly = []
    }

    private func handleUpgrade(_ event: ShellClient.Event, token: Int, generation gen: Int) {
        guard gen == generation, token == upgradeToken, upgrade != nil else {
            if case let .screen(stream, _) = event { stream.cancel() }
            return
        }
        switch event {
        case let .ready(path):
            upgradeReadyPath = path
            upgrade?.client?.requestScreen(video: true)
        case let .screen(stream, initialBytes):
            upgrade?.client = nil   // it let go of the stream; the dialer stays up for it
            upgradeStream = stream
            let video = MacStreamBackend(stream: stream, initialBytes: initialBytes, layout: layout()) { [weak self] event in
                MainActor.assumeIsolated { self?.handleUpgrade(event, token: token, generation: gen) }
            }
            upgrade?.video = video
            video.start()
        case .failed, .disconnected:
            upgradeFailed()
        default:
            break
        }
    }

    private func handleUpgrade(_ event: ScreenBackendEvent, token: Int, generation gen: Int) {
        guard gen == generation else { return }
        // Promoted: this is the view's own stream now.
        if token == promotedToken { return handle(event, generation: gen, token: backendToken) }
        guard token == upgradeToken, upgrade?.video != nil else { return }
        switch event {
        case .size:
            promote(token)
            // Said once, before the size: what it shows, the pointer's look, who else views.
            let early = upgradeEarly
            upgradeEarly = []
            early.forEach { handle($0, generation: gen, token: backendToken) }
            handle(event, generation: gen, token: backendToken)
        case .macStream(.fitted), .pointerShape, .macStream(.viewers):
            upgradeEarly.append(event)
        case let .macStream(.movedAway(name)):
            // Another device took over: this device's whole view goes, Screen Sharing too.
            movedTo = name
        case .ended:
            if let movedTo {
                stop()
                phase = .movedAway(to: movedTo)
                return
            }
            upgradeFailed()
        case .phase, .image, .sample, .pointerPosition, .pointerHidden, .copied, .clipboardChanged, .bell, .macStream:
            break   // the pointer's place goes again after the first format
        }
    }

    /// The stream shows the screen: it takes over and Screen Sharing ends.
    private func promote(_ token: Int) {
        guard let candidate = upgrade, let stream = candidate.video else { return }
        upgrade = nil
        promotedToken = token
        let screenSharing = backend
        // What Screen Sharing still says is dropped from here.
        backendToken += 1
        screenSharing?.close()
        dialer?.shutdown()
        dialer = candidate.dialer
        if let upgradeStream { watchPath(of: upgradeStream, dialer: candidate.dialer, startingAt: upgradeReadyPath) }
        upgradeStream = nil
        backend = stream
        wantsVideo = true
        slowReason = nil
        image = nil
        lastPointer = nil
        if copying { copyTimeout?.cancel(); copying = false }
        show("Switched to the smooth view")
    }

    private func upgradeFailed() {
        dropUpgrade()
        scheduleUpgrade()
    }

    private func dropUpgrade() {
        upgradeTask?.cancel()
        upgradeTask = nil
        guard let candidate = upgrade else { return }
        upgrade = nil
        candidate.video?.close()
        candidate.client?.disconnect()
        candidate.dialer?.shutdown()
    }

    // MARK: Input

    /// `point` in screen pixels.
    func pointer(at point: CGPoint, buttons: ScreenButtons) {
        lastPointer = point
        lastPointerAt = ProcessInfo.processInfo.systemUptime
        backend?.pointer(at: point, buttons: buttons)
    }

    func click(at point: CGPoint, button: ScreenButtons = .left) {
        pointer(at: point, buttons: button)
        pointer(at: point, buttons: [])
    }

    /// Fingers moved `delta` (screen pixels) with the pointer at `point`: content follows them.
    /// The stream scrolls by as much (its pixels are about the Mac's points); Screen Sharing
    /// only knows wheel notches, one per `notch` pixels.
    func scroll(at point: CGPoint, by delta: CGPoint, notch: CGFloat) {
        // The stream moves the pointer there first: an echo of that is drawn already.
        if macStream != nil, lastPointer != point {
            lastPointer = point
            lastPointerAt = ProcessInfo.processInfo.systemUptime
        }
        backend?.scroll(at: point, by: delta, notch: notch)
    }

    func scrollEnded() { backend?.scrollEnded() }

    /// The modifiers as the far computer takes them: a PC gets ⌘ as Control, or as the Windows key if the user chose that.
    private func farModifiers(_ modifiers: [UInt32]) -> ScreenModifiers {
        let held = ScreenModifiers(keysyms: modifiers)
        return windowsView ? WindowsShortcut.modifiers(held, commandIsWindows: commandIsWindows) : held
    }

    /// A key with modifiers held around it.
    func key(_ keysym: UInt32, modifiers: [UInt32] = []) {
        backend?.key(keysym, modifiers: farModifiers(modifiers))
    }

    func type(_ text: String, modifiers: [UInt32] = []) {
        guard let backend else { return }
        if modifiers.isEmpty { return backend.text(text) }
        let held = farModifiers(modifiers)
        for character in text {
            if let keysym = RFBKeys.keysym(for: character) { backend.key(keysym, modifiers: held) }
        }
    }

    /// The Mac's Fn (globe) key, down for as long as the phone's key is held (the Mac's own stream only).
    func function(_ down: Bool) { macStream?.function(down) }

    /// Mission Control's shortcuts, as macOS sets them by default (System
    /// Settings › Keyboard › Keyboard Shortcuts › Mission Control).
    enum SpaceAction {
        case previousDesktop, nextDesktop, missionControl, appWindows, showDesktop
    }

    /// Something sent from outside the canvas may move the Mac's caret or change its text
    /// (a paste, another desktop): the canvas forgets what was typed (`ScreenCanvasView.forgetTyped`).
    var onCaretMayMove: (() -> Void)?

    func perform(_ action: SpaceAction) {
        // A PC: the same swipes and menu rows mean Windows' own (virtual desktops, Task View, Show desktop).
        if windowsView {
            switch action {
            case .previousDesktop: return windows(.previousDesktop)
            case .nextDesktop: return windows(.nextDesktop)
            case .missionControl: return windows(.taskView)
            case .appWindows, .showDesktop: return windows(.showDesktop)
            }
        }
        onCaretMayMove?()
        switch action {
        case .previousDesktop: key(RFBKeys.left, modifiers: [RFBKeys.control])
        case .nextDesktop: key(RFBKeys.right, modifiers: [RFBKeys.control])
        case .missionControl: key(RFBKeys.up, modifiers: [RFBKeys.control])
        case .appWindows: key(RFBKeys.down, modifiers: [RFBKeys.control])
        case .showDesktop: key(RFBKeys.function(11))
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// A Windows shortcut (the Windows menu, a three-finger swipe), as scan codes.
    func windows(_ shortcut: WindowsShortcut) {
        guard windowsView, let backend else { return }
        onCaretMayMove?()
        let chord = shortcut.chord
        backend.key(chord.key, modifiers: chord.modifiers)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// What a hardware keyboard's ⌘ is on a PC; kept for every PC.
    func setCommandIsWindows(_ on: Bool) {
        commandIsWindows = on
        UserDefaults.standard.set(on, forKey: Self.commandIsWindowsKey)
    }

    /// Puts the phone's clipboard on the Mac's and pastes it there.
    func pastePhoneClipboard() {
        onCaretMayMove?()
        guard let text = UIPasteboard.general.string, !text.isEmpty, let backend else { return }
        // Longer than the Mac takes: pasting would paste what was there before.
        guard backend.paste(text) else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return show("That's too long to paste on \(macName).")
        }
    }

    /// ⌘C on the Mac, and what it copied onto this iPhone's clipboard
    /// (`MacClipboard`: this iPhone only, for two minutes). Only what changed
    /// the Mac's clipboard right after this ⌘C comes here: the stream answers
    /// with that (a second at most), and Screen Sharing's clipboard is taken
    /// only in the two seconds after it.
    func copyFromMac() {
        guard !copying, let backend else { return }
        copying = true
        backend.copySelection()
        copyTimeout?.cancel()
        // The stream's ⌘C may wait for typing to finish on the Mac.
        let answers = backend.macStream != nil
        // A PC answers within its own two-second window, then the text has to come over.
        let wait: Duration = answers ? .seconds(5) : windowsView ? .seconds(6) : .seconds(2)
        copyTimeout = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, self.copying else { return }
            self.copyFailed(answers ? "\(self.macName) didn't answer. Update Passthrough on it to copy from it."
                                    : "Nothing was copied. Select something on \(self.macName) first.")
        }

    }

    /// Hides the Mac's own displays while this view shows the screen (black to
    /// whoever is at the Mac), or shows them again; remembered for the next view.
    func setMacHidden(_ hidden: Bool) {
        UserDefaults.standard.set(hidden, forKey: Self.hidesMacKey)
        askMacHidden(hidden)
    }

    /// `saysIfUnanswered`: false for the ask every view starts with, so a Mac that
    /// predates hiding isn't remarked on each time; choosing it in the menu says so.
    private func askMacHidden(_ hidden: Bool, saysIfUnanswered: Bool = true) {
        guard let video = macStream else { return }
        video.curtain(hidden)
        askedHidden = hidden
        hideTimeout?.cancel()
        hideTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.askedHidden == hidden else { return }
            self.askedHidden = nil
            guard saysIfUnanswered else { return }
            self.show("\(self.macName) didn't answer. Update Passthrough on it to hide its display.")
        }
    }

    // MARK: Microphone

    /// Turns this device's microphone on for the Mac, or off. On: iOS is asked for the
    /// microphone (the first time), then the Mac; recording starts once the Mac takes it.
    func toggleMicrophone() {
        guard microphone == .off else { return stopMicrophone() }
        guard macStream != nil else { return }
        microphone = .starting
        let gen = generation
        Task { [weak self] in
            let allowed = await PhoneVoiceCapture.requestPermission()
            guard let self, gen == self.generation, self.microphone == .starting else { return }
            guard allowed else {
                self.microphone = .off
                return self.show("Allow the microphone for Passthrough in Settings.")
            }
            guard let video = self.macStream else { self.microphone = .off; return }
            video.microphone(true)
            self.microphoneTimeout?.cancel()
            self.microphoneTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.microphone == .starting else { return }
                self.microphone = .off
                self.show("\(self.macName) didn't answer. Update Passthrough on it to use the microphone.")
            }
        }
    }

    private func microphoneAnswered(_ state: ScreenVideoWire.MicrophoneState) {
        microphoneTimeout?.cancel()
        switch state {
        case .on:
            guard microphone == .starting, let video = macStream else { return }
            capturing = true
            if let error = applyAudio() {
                microphone = .off
                video.microphone(false)
                let reason = error as NSError
                ptLog(.warning, "screen: the microphone couldn't be started: \(reason.domain) \(reason.code) \(reason.localizedDescription)")
                // iOS keeps the microphone for a call or meeting in another app.
                if reason.domain == NSOSStatusErrorDomain, reason.code == 561_017_449 {   // '!pri': insufficient priority
                    return show("Another app has this \(ThisDevice.name)'s microphone (a call or meeting). Try again when it ends.")
                }
                return show("This \(ThisDevice.name)'s microphone couldn't be started.")
            }
            microphone = .on
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            show("\(macName) hears this \(ThisDevice.name)")
        case .off:
            if microphone != .off { stopMicrophone(tellMac: false) }
        case .notInstalled:
            stopMicrophone(tellMac: false)
            show("On \(macName), install \"Phone as microphone\" in Passthrough's Remote Shell settings.")
        case .failed:
            stopMicrophone(tellMac: false)
            show("\(macName) couldn't use its Passthrough Microphone.")
        }
    }

    private func stopMicrophone(tellMac: Bool = true) {
        microphoneTimeout?.cancel()
        guard microphone != .off else { return }
        microphone = .off
        if capturing {
            capturing = false
            _ = applyAudio()
        }
        if tellMac { macStream?.microphone(false) }
    }

    // MARK: The Mac's sound

    /// Plays what the Mac plays on this device (or stops); remembered for the next view.
    func setPlaysSound(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.playsSoundKey)
        playsSound = on
        guard let video = macStream else { return }
        video.sound(on)
        if !on { stopSound() }
    }

    private func soundAnswered(_ state: ScreenVideoWire.SoundState) {
        switch state {
        case .on:
            // Turned off again meanwhile.
            guard playsSound else { macStream?.sound(false); return }
            guard !soundLive else { return }
            soundLive = true
            _ = applyAudio()
        case .off:
            stopSound()
        case .failed:
            stopSound()
            if playsSound { show("\(macName) couldn't send its sound.") }
        }
    }

    private func stopSound() {
        guard soundLive else { return }
        soundLive = false
        _ = applyAudio()
    }

    /// The audio is this app's again after an interruption: what played is started again,
    /// and sound that had to be given up meanwhile is asked for again.
    private func audioCameBack() {
        guard playsSound, phase == .live, let video = macStream else { return }
        if soundLive { _ = applyAudio() } else { video.sound(true) }
    }

    /// The Mac's sound can't be played now (the session was refused, or the player didn't
    /// start): the Mac is told to stop sending it. `audioCameBack` asks again.
    private func soundCantPlay(_ error: Error) {
        ptLog(.warning, "screen: the Mac's sound can't be played: \(error.localizedDescription)")
        soundLive = false
        macStream?.sound(false)
    }

    /// One audio session for both directions, and changing it stops whatever runs: so
    /// both stop, the session is set for what's on now (`capturing`, `soundLive`), and
    /// those start again. The microphone's failure, if it couldn't start; then it's off.
    private func applyAudio() -> Error? {
        voiceCapture?.stop()
        voiceCapture = nil
        soundPlayer?.stop()
        soundPlayer = nil
        var failure: Error?
        if capturing, let video = macStream {
            do {
                try ScreenAudioSession.apply(recording: true, playing: soundLive)
                let capture = PhoneVoiceCapture(onSamples: { [video] in video.voice($0) }, onStopped: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.microphone != .off else { return }
                        self.stopMicrophone()
                        self.show("The microphone was turned off")
                    }
                })
                try capture.start()
                voiceCapture = capture
            } catch {
                failure = error
                capturing = false
            }
        } else {
            capturing = false
        }
        if !capturing {
            do {
                try ScreenAudioSession.apply(recording: false, playing: soundLive)
            } catch {
                if soundLive { soundCantPlay(error) }
            }
        }
        if soundLive {
            let player = MacSoundPlayer()
            do {
                try player.start()
                soundPlayer = player
            } catch {
                soundCantPlay(error)
            }
        }
        return failure
    }

    private func copied(_ text: String) {
        copying = false
        copyTimeout?.cancel()
        MacClipboard.put(text)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        show("Copied from \(macName)")
    }

    private func copyFailed(_ message: String) {
        copying = false
        copyTimeout?.cancel()
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        show(message)
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// The display lost its place (it was in the background, say): ask for a keyframe.
    func videoNeedsKeyframe() { backend?.needsKeyframe() }

    // MARK: Connection path

    /// Follows the screen connection's path: iroh starts on a relay and moves to a
    /// direct path once it can, or stays on the relay when it can't (both behind
    /// strict routers, say). Said once, when it stays on the relay.
    private func watchPath(of stream: any ByteStream, dialer: IrohShellDialer?, startingAt start: ShellPath?) {
        pathTask?.cancel()
        if connectionPath != start { connectionPath = start }
        // The local network (or Tailscale): no relay to watch for.
        guard start != .local, let dialer else { return }
        pathTask = Task { [weak self, stream] in
            var relayFor = 0
            while !Task.isCancelled {
                let path = dialer.path(of: stream)
                guard let self else { return }
                if path != .unknown, path != self.connectionPath { self.connectionPath = path }
                relayFor = path == .relay ? relayFor + 1 : 0
                // Still relayed after a while: not just the first moments before the direct path.
                if relayFor >= 3, !self.saidRelay, self.phase == .live {
                    self.saidRelay = true
                    self.show("Connected through a relay, so this may lag. It switches to a direct path when it can.")
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: Screen shape

    /// The user chose: a display in this device's shape, or the Mac's own as it is. Kept for the next view.
    func setFitsDevice(_ on: Bool) {
        guard on != fitsDevice else { return }
        fitsDevice = on
        UserDefaults.standard.set(on, forKey: Self.fitsDeviceKey)
        macStream?.relayout(layout())
    }

    /// This screen's top frame rate, as Smooth and Fast ask for it.
    static var topFPS: Int { min(120, max(60, UIScreen.main.maximumFramesPerSecond)) }

    /// What matters most when the link can't carry it all; kept for the next view.
    func setQuality(_ quality: ScreenVideoWire.Quality) {
        guard quality != self.quality else { return }
        self.quality = quality
        UserDefaults.standard.set(Int(quality.rawValue), forKey: Self.qualityKey)
        macStream?.relayout(layout())
    }

    /// Text size on a display made for this device; kept for the next view.
    func setSpace(_ space: Int) {
        guard space != self.space, Self.spaces.contains(space) else { return }
        self.space = space
        UserDefaults.standard.set(space, forKey: Self.spaceKey)
        macStream?.relayout(layout())
    }

    func setPinchesMacOnItsDisplay(_ on: Bool) {
        pinchesMacOnItsDisplay = on
        UserDefaults.standard.set(on, forKey: Self.pinchKey)
    }

    /// A pinch or rotation for the Mac, at its pointer.
    func gesture(_ gesture: ScreenVideoWire.Gesture, phase: ScreenVideoWire.GesturePhase, value: Double) {
        lastPointerAt = ProcessInfo.processInfo.systemUptime
        macStream?.gesture(gesture, phase: phase, value: value)
    }

    /// This device is used here now: the Mac ends the other devices' views.
    func useHere() {
        otherViewers = []
        macStream?.useHere()
    }

    /// Back from another device that took the view over: a new view, which takes it back.
    func takeBack(shell: ShellModel, context: LAContext) {
        begin(shell: shell, context: context, takeOver: true)
    }

    /// The canvas in pixels, as the device is held now: a display in its shape turns with it.
    func viewPixelsChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != viewPixels else { return }
        // Held the same way, it only ever grows: the view getting smaller is its own bars (the
        // side bar doubling up, a key row), which isn't worth remaking the Mac's display for.
        if let held = viewPixels, (size.width > size.height) == (held.width > held.height) {
            let grown = CGSize(width: max(size.width, held.width), height: max(size.height, held.height))
            if abs(grown.width - held.width) < held.width * 0.03, abs(grown.height - held.height) < held.height * 0.03 { return }
            viewPixels = grown
        } else {
            viewPixels = size
        }
        // A PC's desktop follows the view when it fits this device (the standard shape stays as it is).
        if windowsView { return windowsShapeChanged() }
        guard fitsDevice else { return }
        // Once the turn has settled: each change remakes the Mac's display.
        relayoutTask?.cancel()
        relayoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.macStream?.relayout(self.layout())
        }
    }

    /// What to ask the Mac for: its own display at no more than this device's
    /// pixels, or one made at exactly the screen view's pixels (the whole screen until it's laid out).
    private func layout() -> ScreenVideoClient.Layout {
        let native = UIScreen.main.nativeBounds.size
        let maxSide = Int(max(native.width, native.height))
        // Sharp keeps to 60 a second (more bits for each); the others go as fast as this screen does.
        let fps = quality == .sharp ? 60 : Self.topFPS
        guard fitsDevice else { return .init(width: maxSide, height: maxSide, fit: .mac, fps: fps, quality: quality) }
        let screen = UIScreen.main
        let pixels = viewPixels ?? CGSize(width: screen.bounds.width * screen.scale, height: screen.bounds.height * screen.scale)
        // Even sides (4:2:0), within what the Mac's encoder takes.
        let fit = min(1, 4096 / max(pixels.width, pixels.height))
        return .init(width: Int(pixels.width * fit) & ~1, height: Int(pixels.height * fit) & ~1, fit: .device, fps: fps, quality: quality,
                     space: space)
    }
}

#if DEBUG
// MARK: - Demo (DEBUG builds only)

extension ScreenModel {
    /// "login", "failed" or "live": a stand-in Mac screen, no connection.
    static var demoState: String? { UserDefaults.standard.string(forKey: "PTDemoScreen") }

    fileprivate func applyDemo(_ state: String) {
        macName = "My MacBook Pro"
        switch state {
        case "login": phase = .login(error: nil)
        case "failed": phase = .failed("Screen Sharing is off on your Mac. Turn it on in System Settings › General › Sharing.")
        default:
            let size = CGSize(width: 1512, height: 982)
            image = Self.demoImage(size)
            screenSize = size
            phase = .live
        }
    }

    /// A desktop with a couple of windows, drawn rather than shipped as an asset.
    private static func demoImage(_ size: CGSize) -> CGImage? {
        let renderer = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        return renderer.image { context in
            let cg = context.cgContext
            let colors = [UIColor(red: 0.16, green: 0.20, blue: 0.42, alpha: 1).cgColor, UIColor(red: 0.45, green: 0.25, blue: 0.55, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            UIColor.black.withAlphaComponent(0.35).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: size.width, height: 30))
            for (frame, title) in [(CGRect(x: 120, y: 120, width: 760, height: 520), "Terminal — zsh"),
                                   (CGRect(x: 640, y: 300, width: 720, height: 560), "Safari — passthrough")] {
                UIColor(white: 0.12, alpha: 1).setFill()
                UIBezierPath(roundedRect: frame, cornerRadius: 12).fill()
                UIColor(white: 0.22, alpha: 1).setFill()
                UIBezierPath(roundedRect: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 34), cornerRadius: 12).fill()
                (title as NSString).draw(at: CGPoint(x: frame.minX + 90, y: frame.minY + 8),
                                         withAttributes: [.font: UIFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: UIColor.white])
                for (index, color) in [UIColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                    color.setFill()
                    UIBezierPath(ovalIn: CGRect(x: frame.minX + 14 + CGFloat(index) * 22, y: frame.minY + 11, width: 13, height: 13)).fill()
                }
            }
            ("$ swift test\nAll tests passed." as NSString).draw(at: CGPoint(x: 140, y: 170), withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 18, weight: .regular), .foregroundColor: UIColor(red: 0.6, green: 1, blue: 0.7, alpha: 1)])
        }.cgImage
    }
}
#endif
