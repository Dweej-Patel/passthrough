import SwiftUI
import PassthroughCore
import PassthroughUI

/// What one computer can be given of another, by what each app can open today: a PC opens shells and a
/// Mac's screen (it has no viewer for another PC's: `ComputerRow`); a Mac opens only screens, another Mac's
/// by a screen pass and a PC's by a computer grant (`PCScreensSection`). A kind this build doesn't know
/// gets both, as before. Nothing is offered that the viewer would hold and never be able to use.
struct ShareOffer: Equatable {
    /// Scopes handed over as a computer grant (`ComputerShareModel`).
    var grant: [String] = []
    /// A Mac viewing a Mac: the screen goes as a screen pass (`ScreenShareModel`), exactly as Share Screen sent it.
    var pass = false

    var isEmpty: Bool { grant.isEmpty && !pass }

    /// The viewer can open shells on another computer (a Mac has nothing that does).
    static func takesShell(_ viewer: HostKind) -> Bool { viewer != .mac }

    /// The viewer can show `host`'s screen: everything but a PC's on a PC.
    static func showsScreen(of host: HostKind, on viewer: HostKind) -> Bool { !(host == .windows && viewer == .windows) }

    /// `withShell`: the sheet's choice. A Mac's screen goes to a Mac as a pass whatever was chosen: a Mac takes no shell.
    static func make(host: HostKind, viewer: HostKind, withShell: Bool) -> ShareOffer {
        if host == .mac, viewer == .mac { return ShareOffer(pass: true) }
        var scopes: [String] = []
        if withShell, takesShell(viewer) { scopes.append(Computers.scopeShell) }
        if showsScreen(of: host, on: viewer) { scopes.append(Computers.scopeScreen) }
        return ShareOffer(grant: scopes)
    }
}

/// Lets another of this phone's computers use the one on screen, without this
/// phone (stage 7 a.6): pick what it may do and which computer, confirm with
/// Face ID, and the phone hands it access. Offered only when the computer on
/// screen said this phone may share it (`host.access.share`); without that, a
/// Mac's Share row opens `ShareScreenSheet` instead.
struct ShareComputerSheet: View {
    @ObservedObject var shell: ShellModel
    /// The computer being shared.
    let shared: ShellCredential
    @StateObject private var model = ComputerShareModel()
    /// A Mac shared with another Mac: the screen pass, as `ShareScreenSheet` hands it over.
    @StateObject private var passes = ScreenShareModel()
    /// What the computer being shared says has access (nil until it answers; an older one never does).
    @StateObject private var hosted = HostComputersModel()
    /// Access the user asked to take back: confirmed first.
    @State private var removal: ComputerAccess?
    @State private var withShell = false
    /// `withShell` was set to suit the computers on offer (once, as the sheet opens).
    @State private var choseDefault = false
    /// A computer that already has access was tapped: asked before it is shared again.
    @State private var again: ShellCredential?
    /// The last hand-over was a screen pass: its outcome is the one shown.
    @State private var passing = false
    @Environment(\.dismiss) private var dismiss

    private var others: [ShellCredential] { shell.macs.filter { $0.macID != shared.macID } }
    private var hostKind: HostKind { shell.kind(of: shared.macID) }
    private var isWorking: Bool { model.isWorking || passes.isWorking }

    private func offer(for viewer: ShellCredential) -> ShareOffer {
        ShareOffer.make(host: hostKind, viewer: shell.kind(of: viewer.macID), withShell: withShell)
    }

    /// Screen only, the lesser access, unless it leaves every computer on offer with nothing to get (a PC
    /// shared with other PCs, which can't show its screen): then Shell and screen, so the rows can be used.
    static func startsWithShell(host: HostKind, viewers: [HostKind]) -> Bool {
        let usable = { (withShell: Bool) in viewers.filter { !ShareOffer.make(host: host, viewer: $0, withShell: withShell).isEmpty }.count }
        return usable(false) == 0 && usable(true) > 0
    }

    /// Shell is worth choosing only when one of the others can open shells.
    private var offersShell: Bool { others.contains { ShareOffer.takesShell(shell.kind(of: $0.macID)) } }
    private var anyPass: Bool { others.contains { offer(for: $0).pass } }

    /// The outcome of the last hand-over, whichever kind it was.
    private var phase: ComputerShareModel.Phase {
        guard passing else { return model.phase }
        switch passes.phase {
        case .idle: return .idle
        case let .working(step): return .working(step)
        case let .done(message): return .done(message)
        case let .failed(message): return .failed(message)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if offersShell { accessSection }
                viewersSection
                if let list = hosted.list, !list.isEmpty { withAccessSection(list) }
                phaseSection
            }
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .confirmationDialog(again.map { "\($0.macName) already has access to \(shared.macName)" } ?? "",
                            isPresented: Binding(get: { again != nil }, set: { if !$0 { again = nil } }), titleVisibility: .visible) {
            Button("Share Again") {
                if let viewer = again { grant(to: viewer) }
                again = nil
            }
            Button("Cancel", role: .cancel) { again = nil }
        } message: {
            Text("Sharing again replaces what it has with \(again.map { Self.describe(offer(for: $0).grant) } ?? "screen only"). If you removed its access on \(shared.macName), this gives it back.")
        }
        .confirmationDialog(removal.map { "Remove \($0.name)'s access to \(shared.macName)?" } ?? "",
                            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Remove Access", role: .destructive) {
                if let computer = removal { hosted.remove(computer) }
                removal = nil
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text("It can't use \(shared.macName) until you share it again, and anything it has open there ends.")
        }
        .sensoryFeedback(.success, trigger: phase) { _, new in if case .done = new { true } else { false } }
        .sensoryFeedback(.error, trigger: phase) { _, new in if case .failed = new { true } else { false } }
        .onAppear {
            if !choseDefault {
                choseDefault = true
                withShell = Self.startsWithShell(host: hostKind, viewers: others.map { shell.kind(of: $0.macID) })
            }
            hosted.watch(shared, shell: shell)
        }
        .onDisappear {
            model.reset()
            passes.reset()
            hosted.stop()
        }
    }

    // MARK: Sections

    private var accessSection: some View {
        Section {
            Picker("Access", selection: $withShell) {
                Text("Screen only").tag(false)
                Text("Shell and screen").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(isWorking)
        } footer: {
            if withShell { Text("It can run commands as you on \(shared.macName).") }
        }
    }

    private var viewersSection: some View {
        Section {
            ForEach(others, id: \.macID) { viewer in viewerRow(viewer) }
        } header: {
            Text("Which computer should use \(shared.macName)?")
        } footer: {
            Text(viewersFooter)
        }
    }

    private var viewersFooter: String {
        let h = shared.macName
        var text = "That computer gets its own access to \(h), from anywhere, without this \(ThisDevice.name). It stops working if this \(ThisDevice.name) loses access to \(h)."
            + (hosted.list == nil ? "" : " Remove it any time below.")
        if anyPass {
            // Said as Share Screen said it: what a pass lets a Mac do, and where it's taken back.
            text += " A Mac gets a pass to \(h)'s screen instead: controlling it means it can type into any app on \(h), Terminal included; it can't open Passthrough's shells or change its settings, and opening it asks for Touch ID or the password on that Mac. Remove a pass in Passthrough's Remote Shell settings on \(h)."
        }
        return text
    }

    private func viewerRow(_ viewer: ShellCredential) -> some View {
        // The shared computer's own word when it gave it, else this phone's memory.
        let listed = hosted.list?.first { $0.viewer == viewer.macID }
        let had = hosted.list == nil ? SharedComputers.entry(shared: shared.macID, viewer: viewer.macID)
            : listed.map { SharedComputers.Entry(shell: ($0.scopes + ($0.pending ?? [])).contains(Computers.scopeShell),
                                                 at: Date(timeIntervalSince1970: TimeInterval($0.grantedAt))) }
        let offer = offer(for: viewer)
        let kind = shell.kind(of: viewer.macID)
        return Button {
            if offer.pass {
                // A pass was never asked about before being sent again; it isn't now either.
                passing = true
                passes.share(shared, with: viewer, shell: shell)
            } else if had != nil {
                // One that already has access isn't given it again by a stray tap.
                again = viewer
            } else {
                grant(to: viewer)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: kind == .windows ? "pc" : "desktopcomputer")
                    .font(.title3)
                    .foregroundStyle(PTColor.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewer.macName).foregroundStyle(.primary)
                    Text(caption(viewer, kind: kind, listed: listed, had: had, offer: offer))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: had != nil ? "checkmark.circle.fill" : "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(had != nil ? AnyShapeStyle(PTColor.tintText) : AnyShapeStyle(.tertiary))
            }
            .frame(minHeight: 44)
        }
        .disabled(isWorking || offer.isEmpty)
    }

    private func withAccessSection(_ list: [ComputerAccess]) -> some View {
        Section {
            ForEach(list, id: \.phoneID) { computer in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(computer.name)
                        Text(Self.caption(computer, on: shared.macName)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if hosted.removing == computer.phoneID {
                        ProgressView()
                    } else {
                        // "Remove Access", as its confirmation says: on the computers, "Remove…" only forgets one there.
                        Button("Remove Access", role: .destructive) { removal = computer }
                            .buttonStyle(.borderless)
                            .disabled(hosted.removing != nil || isWorking)
                            .accessibilityLabel("Remove \(computer.name)'s access")
                    }
                }
            }
        } header: {
            Text("With access to \(shared.macName)")
        } footer: {
            if let error = hosted.error { Text(error).foregroundStyle(PTColor.attentionText) }
        }
    }

    @ViewBuilder private var phaseSection: some View {
        switch phase {
        case .idle:
            EmptyView()
        case let .working(step):
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(step).foregroundStyle(.secondary)
                }
            }
        case let .done(message):
            Section {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(PTColor.tintText)
            }
        case let .failed(message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(PTColor.attentionText)
            }
        }
    }

    // MARK: Doing it

    private func grant(to viewer: ShellCredential) {
        let scopes = offer(for: viewer).grant
        guard !scopes.isEmpty else { return }
        passing = false
        model.share(shared, with: viewer, scopes: scopes, shell: shell)
    }

    // MARK: Words

    /// Under a computer's name: what it has (the host's word, else this phone's memory), else what it would get.
    private func caption(_ viewer: ShellCredential, kind: HostKind, listed: ComputerAccess?, had: SharedComputers.Entry?,
                         offer: ShareOffer) -> String {
        if let listed { return Self.caption(listed, on: shared.macName) }
        if let had {
            let what = had.shell ? (ShareOffer.showsScreen(of: hostKind, on: kind) ? "shell and screen" : "shell") : "screen only"
            return "Has access (\(what)), shared \(had.at.formatted(.relative(presentation: .named)))"
        }
        let noun = HostWords(kind: kind, name: nil, device: ThisDevice.name).Noun
        return noun + " · " + gets(offer, viewer: kind)
    }

    /// What tapping it would hand over, and why that's all when it's less than was chosen.
    private func gets(_ offer: ShareOffer, viewer: HostKind) -> String {
        if offer.pass { return "Gets a pass to see and control the screen" }
        let shell = offer.grant.contains(Computers.scopeShell), screen = offer.grant.contains(Computers.scopeScreen)
        switch (shell, screen) {
        case (true, true): return "Gets shell and screen"
        case (true, false): return "Gets the shell; a PC can't show another PC's screen"
        case (false, true): return withShell && viewer == .mac ? "Gets the screen; a Mac can't open other computers' shells" : "Gets the screen"
        case (false, false): return "A PC can't show another PC's screen. Choose Shell and screen to share the shell."
        }
    }

    /// "shell and screen", "the shell", "screen only": what a grant of `scopes` gives.
    static func describe(_ scopes: [String]) -> String {
        switch (scopes.contains(Computers.scopeShell), scopes.contains(Computers.scopeScreen)) {
        case (true, true): "shell and screen"
        case (true, false): "the shell"
        default: "screen only"
        }
    }

    /// "Shell and screen · connected now", "Shell · the screen waits for you on Office-PC", "Screen only".
    static func caption(_ computer: ComputerAccess, on host: String) -> String {
        let shell = computer.scopes.contains(Computers.scopeShell), screen = computer.scopes.contains(Computers.scopeScreen)
        var parts: [String] = []
        switch (shell, screen) {
        case (true, true): parts.append("Shell and screen")
        case (true, false): parts.append("Shell")
        case (false, true): parts.append("Screen only")
        case (false, false): parts.append("Nothing yet")
        }
        if computer.pending?.contains(Computers.scopeScreen) == true { parts.append("the screen waits for you to allow it on \(host)") }
        if computer.connected { parts.append("connected now") }
        return parts.joined(separator: " · ")
    }
}
