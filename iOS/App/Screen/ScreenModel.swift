import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import IrohTransport
import LocalAuthentication
import UIKit
import PassthroughCore
import ScreenClient

/// One view of the selected Mac's screen: its own shell connection, which asks
/// for the screen. First the Mac's own H.264 stream (`ScreenVideoClient`,
/// protocol/README.md "Screen video"): smooth, and no password. A Mac that
/// can't stream (it lacks Screen Recording or Accessibility, or predates it)
/// says so, and the same connection asks for Screen Sharing instead, handed
/// to an `RFBClient` with the Mac's login ("Screen"). That fallback sends a
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
    var canHideMac: Bool { video != nil }
    /// This device as the Mac's microphone (the Mac's "Passthrough Microphone" input device).
    enum Microphone: Equatable { case off, starting, on }
    @Published private(set) var microphone = Microphone.off
    /// Only the Mac's own stream carries voice (not Screen Sharing).
    var canUseMicrophone: Bool { video != nil }
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
    var pinchesMac: Bool { video != nil && (fitsDevice || pinchesMacOnItsDisplay) }
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
    private var client: ShellClient?
    private var dialer: IrohShellDialer?
    private var rfb: RFBClient?
    private var video: ScreenVideoClient?
    /// The connection is asking for the Mac's own stream (not Screen Sharing).
    private var wantsVideo = false
    /// Scroll not yet sent: a fraction of a point (stream) or of a wheel notch (Screen Sharing).
    private var scrollRemainder = CGPoint.zero
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
    private var upgradeEarly: [ScreenVideoClient.Event] = []
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
    /// What Paste last put on the Mac over Screen Sharing, which may send it back.
    private var lastPaste: String?
    /// Bumped by every start and stop, so a stale connection's events are dropped.
    private var generation = 0
    private var pendingLogin: (login: RFBClient.Login, remember: Bool)?
    /// While on Screen Sharing: a second connection trying the Mac's own
    /// stream, swapped in once it shows its size (`promote`).
    private var upgrade: (client: ShellClient?, dialer: IrohShellDialer?, video: ScreenVideoClient?)?
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
            phase = .failed("Choose a Mac first.")
            return
        }
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
        // Not listening while no one is looking at the Mac, nor playing its sound.
        stopMicrophone()
        if soundLive {
            video?.sound(false)
            stopSound()
        }
        guard video != nil, macHidden || askedHidden == true else { return }
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
        if playsSound, phase == .live { video?.sound(true) }
        guard hiddenBeforeAway else { return }
        hiddenBeforeAway = false
        if video != nil, Self.hidesMac { askMacHidden(true, saysIfUnanswered: false) }
    }

    /// Screen Sharing, with the Mac account's login.
    func connect(_ login: RFBClient.Login, remember: Bool) {
        #if DEBUG
        if Self.demoState != nil { return applyDemo("live") }
        #endif
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
            phase = .failed("Choose a Mac first.")
            return
        }
        client = connection.client
        dialer = connection.dialer
    }

    /// The Mac can't stream its screen itself: Screen Sharing on the same
    /// connection with a login typed for this view, or the saved one if the
    /// user chose "Always" for this Mac; otherwise they are asked first.
    private func fallBackToScreenSharing() {
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
        if always { Self.setAlwaysUsesScreenSharing(macID: macID) }
        if let context, let saved = ScreenLoginStore.read(macID: macID, context: context) {
            connect(saved, remember: false)
        } else {
            phase = .login(error: nil)
        }
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
        rfb?.close()
        rfb = nil
        stopMicrophone()
        stopSound()
        video?.close()
        video = nil
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
            let video = ScreenVideoClient(stream: stream, initialBytes: initialBytes, layout: layout()) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event, generation: gen) }
            }
            self.video = video
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
            let rfb = RFBClient(stream: stream, initialBytes: initialBytes, login: login) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event, generation: gen) }
            }
            self.rfb = rfb
            rfb.start()
        case let .failed(error, _):
            phase = .failed(error.message ?? "Your Mac refused the connection.")
            stop()
        case .disconnected:
            phase = .failed("Couldn't reach \(macName). Check that it's awake and Remote shell is on.")
            stop()
        default:
            break
        }
    }

    private func handle(_ event: ScreenVideoClient.Event, generation gen: Int) {
        guard gen == generation else { return }
        switch event {
        case let .size(width, height):
            screenSize = CGSize(width: width, height: height)
            let first = !videoStarted
            videoStarted = true
            if first { liveSince = ProcessInfo.processInfo.systemUptime }
            phase = .live
            if first, Self.hidesMac { askMacHidden(true, saysIfUnanswered: false) }
            if first, playsSound { video?.sound(true) }
        case let .frame(sample, number):
            // Not shown (no canvas yet, or its display failed): what follows needs a new keyframe.
            if onVideoFrame?(sample) != true { video?.requestKeyframe() }
            video?.shown(number)
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
        case let .cursor(x, y, visible):
            guard screenSize.width > 0 else { return }
            // Echoes of this phone's own moves are drawn already (only whether it's on this display
            // counts then); the Mac's own moves (its trackpad) aren't.
            let echo = ProcessInfo.processInfo.systemUptime - lastPointerAt <= 1.5
            let point = CGPoint(x: x * (screenSize.width - 1), y: y * (screenSize.height - 1))
            macPointer = (echo ? macPointer?.point ?? point : point, visible)
            onMacPointer?(echo ? nil : point, visible)
        case let .cursorShape(image, size, hotSpot):
            pointerShape = (image, size, hotSpot)
            onPointerShape?(image, size, hotSpot)
        case let .viewers(names):
            otherViewers = names
        case let .movedAway(name):
            movedTo = name
        case .closed:
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
    }

    private func handle(_ event: RFBClient.Event, generation gen: Int) {
        // No `rfb`: the stream took over and closed it; nothing it still says counts.
        guard gen == generation, rfb != nil else { return }
        switch event {
        case let .connected(width, height, _):
            screenSize = CGSize(width: width, height: height)
            phase = .live
            if let pending = pendingLogin, pending.remember, let macID, let context {
                ScreenLoginStore.save(pending.login, macID: macID, context: context)
            }
            pendingLogin = nil
            scheduleUpgrade()
        case let .frame(image):
            self.image = image
            let size = CGSize(width: image.width, height: image.height)
            if size != screenSize { screenSize = size }
            onFrame?(image)
        case let .clipboard(text):
            // Screen Sharing sends the Mac's clipboard whenever it changes, whatever is on it:
            // taken only as the answer to Copy's ⌘C, and never the phone's own paste coming back.
            if copying, !text.isEmpty, text != lastPaste { copied(text) }
        case .bell:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case let .closed(failure):
            stop()
            switch failure {
            case nil:
                break
            case .loginFailed?:
                if let macID { ScreenLoginStore.delete(macID: macID) }
                image = nil
                phase = .login(error: "Your Mac didn't accept that name and password.")
            case .unsupportedServer?:
                phase = .failed("Screen Sharing on your Mac answered in a way this app doesn't understand.")
            case .noLoginOffered?:
                phase = .failed("What answered as Screen Sharing on \(macName) didn't ask for a login, which your Mac's Screen Sharing always does. Passthrough didn't connect.")
            case .protocolError?:
                phase = .failed("The screen connection broke. Try again.")
            case .connectionLost?:
                phase = .failed("The connection to \(macName) was lost.")
            }
        }
    }

    // MARK: Back to the stream

    /// Tries the Mac's own stream again after the next delay, while Screen
    /// Sharing shows the screen. Whatever kept it from streaming (a display
    /// that was off, permissions granted since) may be gone by then.
    private func scheduleUpgrade() {
        guard rfb != nil, upgrade == nil, upgradeTask == nil else { return }
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
        guard rfb != nil, phase == .live, let shell else { return }
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
            let video = ScreenVideoClient(stream: stream, initialBytes: initialBytes, layout: layout()) { [weak self] event in
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

    private func handleUpgrade(_ event: ScreenVideoClient.Event, token: Int, generation gen: Int) {
        guard gen == generation else { return }
        // Promoted: this is the view's own stream now.
        if token == promotedToken { return handle(event, generation: gen) }
        guard token == upgradeToken, upgrade?.video != nil else { return }
        switch event {
        case .size:
            promote(token)
            // Said once, before the size: what it shows, the pointer's look, who else views.
            let early = upgradeEarly
            upgradeEarly = []
            early.forEach { handle($0, generation: gen) }
            handle(event, generation: gen)
        case .fitted, .cursorShape, .viewers:
            upgradeEarly.append(event)
        case let .movedAway(name):
            // Another device took over: this device's whole view goes, Screen Sharing too.
            movedTo = name
        case .closed:
            if let movedTo {
                stop()
                phase = .movedAway(to: movedTo)
                return
            }
            upgradeFailed()
        case .frame, .copied, .curtained, .cursor, .microphone, .sound, .soundPacket:
            break   // the pointer's place goes again after the first format
        }
    }

    /// The stream shows the screen: it takes over and Screen Sharing ends.
    private func promote(_ token: Int) {
        guard let candidate = upgrade, let stream = candidate.video else { return }
        upgrade = nil
        promotedToken = token
        let screenSharing = rfb
        rfb = nil
        screenSharing?.close()
        dialer?.shutdown()
        dialer = candidate.dialer
        if let upgradeStream { watchPath(of: upgradeStream, dialer: candidate.dialer, startingAt: upgradeReadyPath) }
        upgradeStream = nil
        video = stream
        wantsVideo = true
        slowReason = nil
        image = nil
        lastPointer = nil
        scrollRemainder = .zero
        lastPaste = nil
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
    func pointer(at point: CGPoint, buttons: RFBClient.Buttons) {
        lastPointer = point
        lastPointerAt = ProcessInfo.processInfo.systemUptime
        if let video, screenSize.width > 0 {
            video.pointer(x: point.x / max(screenSize.width - 1, 1), y: point.y / max(screenSize.height - 1, 1), buttons: buttons)
        } else {
            rfb?.pointer(x: Int(point.x), y: Int(point.y), buttons: buttons)
        }
    }

    func click(at point: CGPoint, button: RFBClient.Buttons = .left) {
        pointer(at: point, buttons: button)
        pointer(at: point, buttons: [])
    }

    /// Fingers moved `delta` (screen pixels) with the pointer at `point`: content follows them.
    /// The stream scrolls by as much (its pixels are about the Mac's points); Screen Sharing
    /// only knows wheel notches, one per `notch` pixels.
    func scroll(at point: CGPoint, by delta: CGPoint, notch: CGFloat) {
        scrollRemainder.x += delta.x
        scrollRemainder.y += delta.y
        if let video {
            // Scrolling goes where the pointer is: there first (a direct-mode scroll is under the fingers).
            if lastPointer != point { pointer(at: point, buttons: []) }
            let dx = Int(scrollRemainder.x), dy = Int(scrollRemainder.y)
            scrollRemainder.x -= CGFloat(dx)
            scrollRemainder.y -= CGFloat(dy)
            video.scroll(dx: dx, dy: dy)
        } else {
            let notches = Int(scrollRemainder.y / notch)
            guard notches != 0 else { return }
            scrollRemainder = CGPoint(x: 0, y: scrollRemainder.y - CGFloat(notches) * notch)
            // Fingers down (positive) bring earlier content in: the wheel turns up.
            let button: RFBClient.Buttons = notches > 0 ? .wheelUp : .wheelDown
            for _ in 0..<abs(notches) { click(at: point, button: button) }
        }
    }

    func scrollEnded() { scrollRemainder = .zero }

    /// A key with modifiers held around it.
    func key(_ keysym: UInt32, modifiers: [UInt32] = []) {
        if let video { return video.key(keysym, modifiers: Self.mask(modifiers)) }
        modifiers.forEach { rfb?.key($0, down: true) }
        rfb?.key(keysym, down: true)
        rfb?.key(keysym, down: false)
        modifiers.reversed().forEach { rfb?.key($0, down: false) }
    }

    func type(_ text: String, modifiers: [UInt32] = []) {
        if let video, modifiers.isEmpty {
            // Long text (a paste, dictation) is pasted: the Mac types only short text as keys,
            // and apps that read keys, not characters (Windows App's RDP), get nothing else right.
            if text.utf16.count > ScreenVideoWire.typedAsKeys, video.clipboard(text) {
                return key(0x76, modifiers: [RFBKeys.command])   // ⌘V
            }
            // Return and Tab are keys, not characters, to the apps on the Mac.
            var run = ""
            for character in text {
                if character == "\n" || character == "\r" || character == "\t", let keysym = RFBKeys.keysym(for: character) {
                    if !run.isEmpty { video.text(run); run = "" }
                    video.key(keysym, modifiers: [])
                } else {
                    run.append(character)
                }
            }
            if !run.isEmpty { video.text(run) }
            return
        }
        for character in text {
            if let keysym = RFBKeys.keysym(for: character) { key(keysym, modifiers: modifiers) }
        }
    }

    /// The Mac's Fn (globe) key, down for as long as the phone's key is held (the Mac's own stream only).
    func function(_ down: Bool) { video?.function(down) }

    /// Mission Control's shortcuts, as macOS sets them by default (System
    /// Settings › Keyboard › Keyboard Shortcuts › Mission Control).
    enum SpaceAction {
        case previousDesktop, nextDesktop, missionControl, appWindows, showDesktop
    }

    /// Something sent from outside the canvas may move the Mac's caret or change its text
    /// (a paste, another desktop): the canvas forgets what was typed (`ScreenCanvasView.forgetTyped`).
    var onCaretMayMove: (() -> Void)?

    func perform(_ action: SpaceAction) {
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

    /// Puts the phone's clipboard on the Mac's and pastes it there.
    func pastePhoneClipboard() {
        onCaretMayMove?()
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        if let video {
            // Longer than the Mac takes: pasting would paste what was there before.
            guard video.clipboard(text) else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return show("That's too long to paste on \(macName).")
            }
        } else {
            rfb?.clipboard(text)
            lastPaste = text
        }
        key(0x76, modifiers: [RFBKeys.command])   // ⌘V
    }

    /// ⌘C on the Mac, and what it copied onto this iPhone's clipboard
    /// (`MacClipboard`: this iPhone only, for two minutes). Only what changed
    /// the Mac's clipboard right after this ⌘C comes here: the stream answers
    /// with that (a second at most), and Screen Sharing's clipboard is taken
    /// only in the two seconds after it.
    func copyFromMac() {
        guard !copying, video != nil || rfb != nil else { return }
        copying = true
        if let video { video.copySelection() } else { key(0x63, modifiers: [RFBKeys.command]) }   // ⌘C
        copyTimeout?.cancel()
        // The stream's ⌘C may wait for typing to finish on the Mac.
        let wait: Duration = video != nil ? .seconds(5) : .seconds(2)
        copyTimeout = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, self.copying else { return }
            self.copyFailed(self.video != nil ? "\(self.macName) didn't answer. Update Passthrough on it to copy from it."
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
        guard let video else { return }
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
        guard video != nil else { return }
        microphone = .starting
        let gen = generation
        Task { [weak self] in
            let allowed = await PhoneVoiceCapture.requestPermission()
            guard let self, gen == self.generation, self.microphone == .starting else { return }
            guard allowed else {
                self.microphone = .off
                return self.show("Allow the microphone for Passthrough in Settings.")
            }
            guard let video = self.video else { self.microphone = .off; return }
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
            guard microphone == .starting, let video else { return }
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
        if tellMac { video?.microphone(false) }
    }

    // MARK: The Mac's sound

    /// Plays what the Mac plays on this device (or stops); remembered for the next view.
    func setPlaysSound(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.playsSoundKey)
        playsSound = on
        guard let video else { return }
        video.sound(on)
        if !on { stopSound() }
    }

    private func soundAnswered(_ state: ScreenVideoWire.SoundState) {
        switch state {
        case .on:
            // Turned off again meanwhile.
            guard playsSound else { video?.sound(false); return }
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
        guard playsSound, phase == .live, let video else { return }
        if soundLive { _ = applyAudio() } else { video.sound(true) }
    }

    /// The Mac's sound can't be played now (the session was refused, or the player didn't
    /// start): the Mac is told to stop sending it. `audioCameBack` asks again.
    private func soundCantPlay(_ error: Error) {
        ptLog(.warning, "screen: the Mac's sound can't be played: \(error.localizedDescription)")
        soundLive = false
        video?.sound(false)
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
        if capturing, let video {
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
    func videoNeedsKeyframe() { video?.requestKeyframe() }

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
        video?.relayout(layout())
    }

    /// This screen's top frame rate, as Smooth and Fast ask for it.
    static var topFPS: Int { min(120, max(60, UIScreen.main.maximumFramesPerSecond)) }

    /// What matters most when the link can't carry it all; kept for the next view.
    func setQuality(_ quality: ScreenVideoWire.Quality) {
        guard quality != self.quality else { return }
        self.quality = quality
        UserDefaults.standard.set(Int(quality.rawValue), forKey: Self.qualityKey)
        video?.relayout(layout())
    }

    /// Text size on a display made for this device; kept for the next view.
    func setSpace(_ space: Int) {
        guard space != self.space, Self.spaces.contains(space) else { return }
        self.space = space
        UserDefaults.standard.set(space, forKey: Self.spaceKey)
        video?.relayout(layout())
    }

    func setPinchesMacOnItsDisplay(_ on: Bool) {
        pinchesMacOnItsDisplay = on
        UserDefaults.standard.set(on, forKey: Self.pinchKey)
    }

    /// A pinch or rotation for the Mac, at its pointer.
    func gesture(_ gesture: ScreenVideoWire.Gesture, phase: ScreenVideoWire.GesturePhase, value: Double) {
        lastPointerAt = ProcessInfo.processInfo.systemUptime
        video?.gesture(gesture, phase: phase, value: value)
    }

    /// This device is used here now: the Mac ends the other devices' views.
    func useHere() {
        otherViewers = []
        video?.useHere()
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
        guard fitsDevice else { return }
        // Once the turn has settled: each change remakes the Mac's display.
        relayoutTask?.cancel()
        relayoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.video?.relayout(self.layout())
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

    private static func mask(_ modifiers: [UInt32]) -> ScreenVideoWire.Modifiers {
        modifiers.reduce(into: []) { mask, keysym in
            switch keysym {
            case RFBKeys.command: mask.insert(.command)
            case RFBKeys.shift: mask.insert(.shift)
            case RFBKeys.option: mask.insert(.option)
            case RFBKeys.control: mask.insert(.control)
            default: break
            }
        }
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
