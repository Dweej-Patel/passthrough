import CoreGraphics
import Foundation
import IOSurface
import PassthroughCore
import RemoteDesktop
import ScreenClient
import ScreenEngine

// The engine helper: one PC's Remote Desktop session, in a process of its own
// with nothing but the App Sandbox's defaults. It has no network, no files and
// no keychain; the session's bytes come over a socket pair from the app, which
// keeps the authenticated connection. One process per window, so what one PC's
// server can do to this process never reaches another PC's session or login.

/// The desktop's pixels in a surface shared with the app. The engine paints into it; the app is told what
/// changed, at most two updates ahead of what it has shown.
final class SurfacePainter: RemoteDesktopPainter, @unchecked Sendable {
    private let lock = NSLock()
    private var surface: IOSurface?
    private var size = (width: 0, height: 0)
    private var sequence: UInt64 = 0
    private var presented: UInt64 = 0
    /// What changed and hasn't been told yet (the app is two updates behind).
    private var waiting: CGRect?
    private let client: () -> (any ScreenEngineClientXPC)?

    init(client: @escaping () -> (any ScreenEngineClientXPC)?) {
        self.client = client
    }

    func desktop(width: Int, height: Int) {
        guard ScreenEngineCodes.validSize(width: width, height: height) else { return }
        let made = IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4, .bytesPerRow: width * 4,
            .pixelFormat: UInt32(0x4247_5241),   // 'BGRA'
        ])
        lock.lock()
        surface = made
        size = (width, height)
        waiting = nil
        lock.unlock()
        guard let made else { return }
        client()?.surface(made, width: width, height: height)
    }

    func painted(_ bgra: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int, dirty: CGRect) {
        lock.lock()
        guard let surface, size.width == width, size.height == height,
              let rect = ScreenEngineCodes.clipped(x: Int(dirty.minX), y: Int(dirty.minY), width: Int(dirty.width), height: Int(dirty.height),
                                                   in: size) else {
            return lock.unlock()
        }
        surface.lock(options: [], seed: nil)
        let rowBytes = surface.bytesPerRow
        let base = surface.baseAddress
        let x = Int(rect.minX), count = Int(rect.width) * 4
        for row in Int(rect.minY)..<Int(rect.maxY) {
            memcpy(base + row * rowBytes + x * 4, bgra + row * stride + x * 4, count)
        }
        surface.unlock(options: [], seed: nil)
        waiting = waiting.map { $0.union(rect) } ?? rect
        let send = takeUpdate()
        lock.unlock()
        if let send { client()?.dirty(x: send.x, y: send.y, width: send.width, height: send.height, sequence: send.sequence) }
    }

    /// The app has shown everything up to `number`.
    func shown(_ number: UInt64) {
        lock.lock()
        if number > presented, number <= sequence { presented = number }
        let send = takeUpdate()
        lock.unlock()
        if let send { client()?.dirty(x: send.x, y: send.y, width: send.width, height: send.height, sequence: send.sequence) }
    }

    /// Under `lock`: the next update to tell, unless two are already unanswered.
    private func takeUpdate() -> (x: Int, y: Int, width: Int, height: Int, sequence: UInt64)? {
        guard let rect = waiting, sequence - presented < 2 else { return nil }
        waiting = nil
        sequence += 1
        return (Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height), sequence)
    }
}

/// One connection from the app: its session, from `start` until it ends. Every call is hopped to main, where the
/// backend's input and events live.
final class EngineSession: NSObject, ScreenEngineXPC, @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private var backend: (any ScreenBackend)?
    private var painter: SurfacePainter?
    private var started = false

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    private var client: (any ScreenEngineClientXPC)? {
        connection?.remoteObjectProxyWithErrorHandler { _ in } as? any ScreenEngineClientXPC
    }

    func start(username: String, password: String, certSHA256: String, clientName: String, width: Int, height: Int,
               desktopScale: Int, deviceScale: Int, slowLink: Bool, transport: FileHandle, reply: @escaping (Bool) -> Void) {
        // The descriptor is this process's own copy from here on, whatever becomes of the handle.
        let descriptor = dup(transport.fileDescriptor)
        DispatchQueue.main.async { [self] in
            guard !started, descriptor >= 0 else {
                if descriptor >= 0 { Darwin.close(descriptor) }
                return reply(false)
            }
            started = true
            let stream = FileDescriptorStream(descriptor: descriptor)
            let painter = SurfacePainter { [weak self] in self?.client }
            // Nil in a build without the engine: the app is told the session didn't start.
            guard let backend = RemoteDesktop.backend(
                stream: stream, initialBytes: Data(), certSHA256: certSHA256,
                login: ScreenLogin(username: username, password: password), width: width, height: height,
                desktopScale: desktopScale, deviceScale: deviceScale, clientName: clientName, slowLink: slowLink, queue: .main, painter: painter,
                onEvent: { [weak self] event in self?.handle(event) }) else {
                stream.cancel()
                return reply(false)
            }
            self.painter = painter
            self.backend = backend
            backend.start()
            reply(true)
        }
    }

    private func handle(_ event: ScreenBackendEvent) {
        guard let client else { return }
        switch event {
        case let .phase(phase):
            client.phase(ScreenEngineCodes.code(phase))
        case let .pointerShape(image, _, hotSpot):
            // The image's own bytes: BGRA, straight alpha, exactly width x height.
            guard let data = image.dataProvider?.data as Data?, data.count == image.width * image.height * 4 else { return }
            client.pointerShape(data, width: image.width, height: image.height, hotX: Int(hotSpot.x), hotY: Int(hotSpot.y))
        case .pointerHidden:
            client.pointerHidden()
        case let .pointerPosition(point, _):
            client.pointerPosition(x: Int(point.x), y: Int(point.y))
        case let .copied(result):
            let sent = ScreenEngineCodes.code(result)
            client.copied(sent.code, text: sent.text)
        case let .ended(end):
            let sent = ScreenEngineCodes.code(end)
            client.ended(sent.code, detail: sent.detail)
            backend = nil
            // Nothing more to do for this window: the process goes once the message has left.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
        case .size, .image, .sample, .clipboardChanged, .bell, .macStream:
            break   // the size comes with the surface
        }
    }

    func pointer(x: Int, y: Int, buttons: Int) {
        DispatchQueue.main.async { [self] in
            backend?.pointer(at: CGPoint(x: x, y: y), buttons: ScreenButtons(rawValue: UInt8(truncatingIfNeeded: buttons & 7)))
        }
    }

    func scroll(x: Int, y: Int, dx: Double, dy: Double, notch: Double) {
        guard dx.isFinite, dy.isFinite, notch.isFinite, notch > 0 else { return }
        DispatchQueue.main.async { [self] in
            backend?.scroll(at: CGPoint(x: x, y: y), by: CGPoint(x: max(-10_000, min(dx, 10_000)), y: max(-10_000, min(dy, 10_000))), notch: notch)
        }
    }

    func scrollEnded() {
        DispatchQueue.main.async { [self] in backend?.scrollEnded() }
    }

    func key(_ keysym: UInt32, modifiers: Int) {
        DispatchQueue.main.async { [self] in
            backend?.key(keysym, modifiers: ScreenModifiers(rawValue: UInt8(truncatingIfNeeded: modifiers & 0x1F)))
        }
    }

    func text(_ text: String) {
        guard text.utf16.count <= 4096 else { return }
        DispatchQueue.main.async { [self] in backend?.text(text) }
    }

    func paste(_ text: String, reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { [self] in reply(backend?.paste(text) ?? false) }
    }

    func copySelection() {
        DispatchQueue.main.async { [self] in backend?.copySelection() }
    }

    func reshape(width: Int, height: Int, desktopScale: Int, deviceScale: Int) {
        guard ScreenEngineCodes.validSize(width: width, height: height) else { return }
        DispatchQueue.main.async { [self] in
            backend?.reshape(ScreenShape(width: width, height: height, desktopScale: desktopScale, deviceScale: deviceScale))
        }
    }

    func setActive(_ active: Bool) {
        DispatchQueue.main.async { [self] in backend?.setActive(active) }
    }

    func presented(_ sequence: UInt64) {
        painter?.shown(sequence)
    }

    func stop() {
        DispatchQueue.main.async { [self] in close() }
    }

    /// The app asked, or its connection went: the session ends and so does this process.
    func close() {
        guard let backend else { exit(0) }
        self.backend = nil
        backend.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    /// Kept for the life of the process: it serves one window.
    private var session: EngineSession?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // One session a process; and only this app (the same team's signature) may ask for it.
        guard session == nil else { return false }
        if let requirement = ScreenEngineService.sameTeamRequirement() {
            connection.setCodeSigningRequirement(requirement)
        }
        connection.exportedInterface = ScreenEngineService.interface()
        connection.remoteObjectInterface = ScreenEngineService.clientInterface()
        let session = EngineSession(connection: connection)
        self.session = session
        connection.exportedObject = session
        connection.invalidationHandler = { DispatchQueue.main.async { session.close() } }
        connection.interruptionHandler = { DispatchQueue.main.async { session.close() } }
        connection.resume()
        return true
    }
}

extension ServiceDelegate {
    var hasSession: Bool { session != nil }
}

let delegate = ServiceDelegate()
// Nothing here should outlive a window that never asked for anything.
DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
    if !delegate.hasSession { exit(0) }
}
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
