import SwiftUI
import Network
import NetworkExtension

@main
struct LinkProbeApp: App {
    @StateObject private var model = ProbeModel()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(model) }
    }
}

@MainActor
final class ProbeModel: ObservableObject {
    @Published var role: String = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "phone"
    @Published var guardMode = false
    @Published var fixedPeers: String = UIDevice.current.userInterfaceIdiom == .pad ? "172.20.10.1" : ""
    @Published var keepScreenOn = false { didSet { UIApplication.shared.isIdleTimerDisabled = keepScreenOn } }
    @Published var tunnelStatus: NEVPNStatus = .invalid
    @Published var ext: ProbeSnapshot?
    @Published var app: ProbeSnapshot?
    @Published var logSource = "ext"
    @Published var logText = ""
    @Published var error: String?

    private var manager: NETunnelProviderManager?
    private var appProbe: Probe?
    private var timer: Timer?
    private var permissionBrowser: NWBrowser?

    var appRunning: Bool { appProbe != nil }

    init() {
        ProbeFiles.moveOldFiles()
        Task {
            await loadManager()
            await autostart()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        internetTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkInternet() }
        }
        NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.tunnelStatus = self.manager?.connection.status ?? .invalid
                self.uiLog("tunnel status: \(self.tunnelStatus.rawValue) (0 invalid, 1 off, 2 starting, 3 on, 4 reasserting, 5 stopping)")
                if self.tunnelStatus == .disconnected, let manager = self.manager {
                    manager.connection.fetchLastDisconnectError { error in
                        if let error { Task { @MainActor in self.uiLog("last disconnect error: \(error)") } }
                    }
                }
            }
        }
        // Only the app can raise the Local Network prompt; the extension needs the answer.
        let browser = NWBrowser(for: .bonjour(type: "_ptprobe._tcp", domain: nil), using: .tcp)
        browser.start(queue: .main)
        permissionBrowser = browser
    }

    private func config(host: String) -> ProbeConfig {
        let peers = fixedPeers.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        return ProbeConfig(role: role, host: host, fixedPeers: peers)
    }

    private var internetTimer: Timer?
    private var internetOK: Bool?
    private var internetChecks = 0

    /// `devicectl device process launch … -- -autostart light|guard|stop`
    /// drives the tunnel from the Mac (launch arguments land in UserDefaults).
    private func autostart() async {
        guard let mode = UserDefaults.standard.string(forKey: "autostart") else { return }
        uiLog("autostart \(mode) from launch arguments")
        switch mode {
        case "light", "guard":
            if tunnelStatus == .connected || tunnelStatus == .connecting {
                stopExtension()
                for _ in 0..<50 where manager?.connection.status != .disconnected {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            guardMode = mode == "guard"
            await startExtension()
        case "stop":
            stopExtension()
        default: break
        }
    }

    /// What the iPad's own apps see: this app's traffic is subject to the
    /// tunnel's routes (and, in guard mode, includeAllNetworks).
    private func checkInternet() async {
        internetChecks += 1
        var request = URLRequest(url: URL(string: "https://www.apple.com/library/test/success.html")!)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: .ephemeral)
        let result: String
        let ok: Bool
        do {
            let (_, response) = try await session.data(for: request)
            ok = true
            result = "ok (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))"
        } catch {
            ok = false
            result = "FAILED (\((error as NSError).code) \(error.localizedDescription))"
        }
        session.invalidateAndCancel()
        if ok != internetOK || internetChecks % 6 == 0 {
            uiLog("internet from this app: \(result); tunnel status \(tunnelStatus.rawValue), guard \(guardMode)")
        }
        internetOK = ok
    }

    private func loadManager() async {
        let id = (Bundle.main.bundleIdentifier ?? "") + ".tunnel"
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == id }
        tunnelStatus = manager?.connection.status ?? .invalid
    }

    func uiLog(_ text: String) { ProbeFiles.append("\(role)-ui", text) }

    func startExtension() async {
        error = nil
        uiLog("start tunnel requested: guard \(guardMode), fixed peers \(fixedPeers), status now \(tunnelStatus.rawValue)")
        // A Stop still in progress swallows the next start: wait for it to finish.
        for _ in 0..<50 where manager?.connection.status == .disconnecting {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        do {
            let id = (Bundle.main.bundleIdentifier ?? "") + ".tunnel"
            let manager = self.manager ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = id
            proto.serverAddress = "Link probe"
            proto.providerConfiguration = ["config": try JSONEncoder().encode(config(host: "ext")), "guard": guardMode]
            proto.disconnectOnSleep = false
            proto.includeAllNetworks = guardMode
            proto.excludeLocalNetworks = false
            manager.protocolConfiguration = proto
            manager.localizedDescription = "Link Probe"
            manager.isEnabled = true
            manager.isOnDemandEnabled = false
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            self.manager = manager
            try manager.connection.startVPNTunnel()
            uiLog("startVPNTunnel called")
        } catch {
            self.error = "\(error.localizedDescription)"
            uiLog("✗ start failed: \(error)")
        }
    }

    func stopExtension() {
        uiLog("stop tunnel requested")
        manager?.connection.stopVPNTunnel()
    }

    func startApp() {
        guard appProbe == nil else { return }
        let probe = Probe(config: config(host: "app"))
        probe.start()
        appProbe = probe
        objectWillChange.send()
    }

    func stopApp() {
        appProbe?.stop()
        appProbe = nil
        objectWillChange.send()
    }

    func clearLogs() {
        for host in ["ui", "ext", "app"] {
            let me = "\(role)-\(host)"
            if let url = ProbeFiles.log(me) { try? FileManager.default.removeItem(at: url) }
        }
        refresh()
    }

    func refresh() {
        func load(_ host: String) -> ProbeSnapshot? {
            guard let url = ProbeFiles.status("\(role)-\(host)"), let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(ProbeSnapshot.self, from: data)
        }
        ext = load("ext")
        app = load("app")
        if let url = ProbeFiles.log("\(role)-\(logSource)"), let text = try? String(contentsOf: url, encoding: .utf8) {
            logText = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(300).joined(separator: "\n")
        } else {
            logText = ""
        }
    }

    var fullLog: String {
        ["ui", "ext", "app"].compactMap { host in
            ProbeFiles.log("\(role)-\(host)").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }.joined(separator: "\n\n")
    }
}

struct ContentView: View {
    @EnvironmentObject var model: ProbeModel

    var body: some View {
        NavigationStack {
            Form {
                Section("This device") {
                    Picker("Role", selection: $model.role) {
                        Text("iPhone").tag("phone")
                        Text("iPad").tag("ipad")
                    }
                    .pickerStyle(.segmented)
                    TextField("Fixed peers (iPad: 172.20.10.1)", text: $model.fixedPeers)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("Guard mode (tunnel takes every route)", isOn: $model.guardMode)
                    Toggle("Keep this screen on", isOn: $model.keepScreenOn)
                }

                Section {
                    HStack {
                        Text("Tunnel: \(statusText(model.tunnelStatus))")
                        Spacer()
                        if model.tunnelStatus == .connected || model.tunnelStatus == .connecting {
                            Button("Stop", role: .destructive) { model.stopExtension() }
                        } else {
                            Button("Start") { Task { await model.startExtension() } }
                        }
                    }
                    if let error = model.error { Text(error).foregroundStyle(.red).font(.footnote) }
                    paths(model.ext)
                } header: { Text("Probe in the tunnel extension") }

                Section {
                    HStack {
                        Text(model.appRunning ? "Running in the app" : "Not running")
                        Spacer()
                        if model.appRunning {
                            Button("Stop", role: .destructive) { model.stopApp() }
                        } else {
                            Button("Start") { model.startApp() }
                        }
                    }
                    paths(model.appRunning ? model.app : nil)
                } header: { Text("Probe in the app (fallback)") }

                Section {
                    Picker("Log", selection: $model.logSource) {
                        Text("Extension").tag("ext")
                        Text("App").tag("app")
                    }
                    .pickerStyle(.segmented)
                    ScrollView(.horizontal) {
                        Text(model.logText.isEmpty ? "No log yet" : model.logText)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 200)
                    HStack {
                        ShareLink(item: model.fullLog) { Label("Share full log", systemImage: "square.and.arrow.up") }
                        Spacer()
                        Button("Clear logs", role: .destructive) { model.clearLogs() }
                    }
                } header: { Text("Timeline") }
            }
            .navigationTitle("Link Probe")
        }
    }

    @ViewBuilder
    private func paths(_ snapshot: ProbeSnapshot?) -> some View {
        if let snapshot, snapshot.running {
            if snapshot.captured > 0 { Text("Tunnel captured \(snapshot.captured) packets").font(.footnote) }
            Text(snapshot.interfaces).font(.caption2).foregroundStyle(.secondary)
            if snapshot.paths.isEmpty { Text("No paths yet").foregroundStyle(.secondary) }
            ForEach(snapshot.paths) { path in
                HStack(alignment: .firstTextBaseline) {
                    Circle().fill(color(path)).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(path.kind) \(path.peer)").font(.subheadline.monospaced())
                        Text("\(path.origin) · \(path.via) · \(path.state) · heard \(path.received) · longest gap \(Int(path.longestGap)) s")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func color(_ path: PathStatus) -> Color {
        guard let ago = path.lastHeardAgo else { return .gray }
        return ago < 3 ? .green : ago < 10 ? .orange : .red
    }

    private func statusText(_ status: NEVPNStatus) -> String {
        switch status {
        case .connected: "on"
        case .connecting: "starting"
        case .disconnecting: "stopping"
        case .disconnected: "off"
        case .reasserting: "reasserting"
        case .invalid: "not set up"
        @unknown default: "?"
        }
    }
}
