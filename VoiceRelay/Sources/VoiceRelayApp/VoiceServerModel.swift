import Foundation
import SwiftUI
import AppKit
import Observation
import Network
import VoiceRelayCore
import ProcessingPipeline
import NarrationCore
import NativeSpeech
import NarrationUI
import AppPresentation

@MainActor
extension AppModel {
    static func production() -> AppModel {
        let owner = try? SpeechWorkCoordinator(owner: .voiceRelay,
            configuration: .init(executable: NativeSpeechSetup.workerExecutable, inferencePriority: .background, pronunciationStore: .init()))
        let model = AppModel(speechWorkCoordinator: owner)
        if let owner {
            let server = VoiceServerModel(coordinator: owner, defaults: .standard) { [weak model] in
                guard let model else { throw VoiceServerError.cancelled }
                let captured = await MainActor.run {
                    (model.preferences.modelSelection, model.runtimeProject, model.preferences.effectiveNarrationOptions,
                     model.speechRuntimeAvailable && !model.runtimeBusy && !model.modelStorage.isBusy && !model.stopping && !model.libraryMaintenanceBusy)
                }
                let dictionary = try await Task.detached(priority: .utility) { try PronunciationStore().load().dictionary }.value
                return .init(settings: captured.0, workspace: captured.1, pronunciations: dictionary,
                             modelReady: captured.3, narrationOptions: captured.2)
            }
            model.voiceServer = server; server.activate()
        }
        return model
    }
}

/// One copyable speech route row in Settings, labeled by access kind.
struct VoiceServerEndpoint: Identifiable, Hashable {
    var id: URL { url }
    let label: String
    let url: URL
}

@MainActor @Observable
final class VoiceServerModel {
    var configuration: VoiceServerConfiguration
    private(set) var running = false
    private(set) var keyConfigured = false
    private(set) var busy = false
    private(set) var message: String?
    private(set) var tailscale = VoiceServerTailscaleStatus.unavailable
    private(set) var localAddresses: [String] = []
    private(set) var endpoints: [VoiceServerEndpoint] = []
    private(set) var active = 0
    private(set) var queued = 0
    /// Everything the listener needs to bind: explicit access, a Keychain key
    /// and, outside loopback, at least one selected private interface.
    var setupReady: Bool {
        guard configuration.access != nil, configuration.modes.isValid, keyConfigured else { return false }
        return configuration.access == .loopback || !configuration.addresses.isEmpty
    }
    @ObservationIgnored private let coordinator: SpeechWorkCoordinator
    @ObservationIgnored private let selection: VoiceServerService.Selection
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keys: any VoiceServerKeyStore
    @ObservationIgnored private let authentication = VoiceServerAuthentication()
    @ObservationIgnored private var server: VoiceServerHTTP?
    @ObservationIgnored private var service: VoiceServerService?
    @ObservationIgnored private var bindings: [VoiceServerBinding] = []
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var manuallyStopped = false
    @ObservationIgnored private var closed = false
    init(coordinator: SpeechWorkCoordinator, defaults: UserDefaults, keys: any VoiceServerKeyStore = VoiceServerKeychain(),
         selection: @escaping VoiceServerService.Selection) {
        self.coordinator = coordinator; self.defaults = defaults; self.keys = keys; self.selection = selection
        configuration = defaults.data(forKey: "voiceServer.configuration.v1").flatMap { try? JSONDecoder().decode(VoiceServerConfiguration.self, from: $0) } ?? .init()
    }
    func activate() {
        guard monitor == nil, !closed else { return }
        let monitor = NWPathMonitor(); self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in Task { @MainActor in self?.refresh() } }
        monitor.start(queue: .global(qos: .utility))
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspended = true; self?.interruptListener(); self?.refresh() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspended = false; self?.refresh() }
        })
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.refresh()
            }
        }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let service = self?.service else { continue }
                let status = await service.status
                guard self?.service === service else { continue }
                self?.active = status.active; self?.queued = status.queued
            }
        }
        refresh()
    }
    func save() {
        if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: "voiceServer.configuration.v1") }
        manuallyStopped = false; refresh(force: true, interactive: true)
    }
    func start() { manuallyStopped = false; configuration.enabled = true; save() }
    func stop() { manuallyStopped = true; interruptListener(); refresh(force: true, interactive: true) }
    private func interruptListener() {
        let owned = server
        Task { await owned?.stop() }
    }
    /// Copyable speech routes for the pane, labeled by access kind. The ::1
    /// listener still binds but is not advertised; its IPv4 twin covers "this Mac".
    private func displayEndpoints(for wanted: [VoiceServerBinding]) -> [VoiceServerEndpoint] {
        var rows = wanted.compactMap { binding -> VoiceServerEndpoint? in
            guard binding.address != "::1", let url = binding.speechURL else { return nil }
            let kind = binding.address == "127.0.0.1" ? "this Mac"
                : tailscale.addresses.contains(binding.address) ? "Tailscale" : "private interface"
            return .init(label: "Speech endpoint (\(kind))", url: url)
        }
        if configuration.access == .tailscale, let dns = tailscale.speechURL(port: configuration.port) {
            rows.append(.init(label: "Speech endpoint (Tailscale MagicDNS)", url: dns))
        }
        return rows
    }
    /// Background monitors refresh passively: only user-invoked work raises
    /// busy, so periodic probes never flash the controls' disabled state.
    func refresh(force: Bool = false, interactive: Bool = false) {
        guard !closed else { return }
        if !force, busy { return }
        if force { interruptListener() }
        let previous = operation; previous?.cancel()
        let id = UUID(); operationID = id
        operation = Task { [weak self] in
            await previous?.value
            guard let self, !closed, !Task.isCancelled else { return }
            if interactive { busy = true }
            defer { if operationID == id { busy = false; operation = nil } }
            if force || suspended || manuallyStopped || !configuration.enabled { await closeListener() }
            guard !Task.isCancelled else { return }
            localAddresses = VoiceServerDiscovery.localAddresses().sorted()
            tailscale = await VoiceServerDiscovery.tailscale()
            guard !Task.isCancelled else { return }
            do {
                let keys = keys
                let secret = try await Task.detached(priority: .utility) { try keys.read() }.value
                guard !Task.isCancelled else { return }
                // Reinstall only when not listening: install changes the grant
                // generation and would revoke all current requests.
                keyConfigured = secret != nil
                guard configuration.enabled, !suspended, !manuallyStopped else { return }
                guard let secret else { message = "Generate an API key before starting VoiceServer."; return }
                let wanted = try configuration.bindings(local: Set(localAddresses), tailscale: tailscale)
                if wanted != bindings {
                    await closeListener(); try Task.checkCancellation()
                    try authentication.install(secret)
                    let created = try VoiceServerService(coordinator: coordinator, authentication: authentication,
                        renderer: NativeVoiceServerRenderer(coordinator: coordinator), modes: configuration.modes, selection: selection)
                    let listener = VoiceServerHTTP(service: created)
                    // Store before awaiting bind so cancellation/shutdown can join it.
                    service = created; server = listener
                    try await listener.start(wanted)
                    if Task.isCancelled { await closeListener(); return }
                    bindings = wanted; endpoints = displayEndpoints(for: wanted)
                    running = true
                }
                if let service { let status = await service.status; active = status.active; queued = status.queued }
                endpoints = displayEndpoints(for: wanted)
                message = nil
            } catch is CancellationError { await closeListener() }
            catch let error as VoiceServerError { await closeListener(); message = error.message }
            catch let error as VoiceServerCredentialFailure { await closeListener(); message = error.localizedDescription; keyConfigured = false }
            catch { await closeListener(); message = "VoiceServer could not start. Check the access mode, address, port and Keychain key." }
        }
    }
    func generateKey() {
        guard !busy, !closed else { return }
        let previous = operation; previous?.cancel()
        let id = UUID(); operationID = id
        operation = Task { [weak self] in
            await previous?.value
            guard let self, !closed, !Task.isCancelled else { return }; busy = true
            await closeListener()
            do {
                let keys = keys
                let secret = try await Task.detached(priority: .utility) {
                    let secret = try VoiceServerAuthentication.generate(); try keys.save(secret); return secret
                }.value
                try authentication.install(secret); keyConfigured = true
                message = "API key saved in Keychain. Copy it to configure your client."
            } catch { message = "The API key could not be saved. Retry using the normally signed VoiceRelay app." }
            if operationID == id {
                busy = false; operation = nil
                if configuration.enabled, !closed { refresh(force: true, interactive: true) }
            }
        }
    }
    func copyKey() {
        guard !busy, !closed else { return }
        let id = UUID(); operationID = id
        operation = Task { [weak self] in
            guard let self, !closed else { return }; busy = true
            defer { if operationID == id { busy = false; operation = nil } }
            do {
                let keys = keys
                let secret = try await Task.detached(priority: .utility) { try keys.read() }.value
                guard let secret else { throw VoiceServerCredentialFailure.unavailable }
                let text = try VoiceServerAuthentication.presentation(secret)
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                message = "API key copied to the clipboard."
            } catch { message = "The API key is unavailable in Keychain. Retry using the normally signed VoiceRelay app." }
        }
    }
    private func closeListener() async {
        let owned = server; server = nil; service = nil
        running = false; endpoints = []; bindings = []; active = 0; queued = 0
        await owned?.stop()
    }
    func shutdown() async {
        closed = true; suspended = true; monitor?.cancel(); monitor = nil
        monitorTask?.cancel(); monitorTask = nil
        statusTask?.cancel(); statusTask = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observers = []
        let owned = operation; operation = nil; owned?.cancel(); await owned?.value
        await closeListener()
    }
}

struct VoiceServerSettingsView: View {
    @Bindable var model: AppModel
    @Bindable var server: VoiceServerModel
    @State private var setup = false
    @State private var rotate = false
    var body: some View {
        Form {
            if server.configuration.access == nil {
                // No explicit access choice yet: show one launcher instead of
                // controls that cannot produce a working listener.
                Section {
                    LabeledContent("Listener", value: "Not set up")
                    Text("VoiceServer serves speech to your private clients while VoiceRelay runs. Setup chooses private access and creates the API key.")
                        .appFont(.secondary).foregroundStyle(.secondary)
                    Button("Set Up VoiceServer…") { setup = true }
                } header: { SectionHelpHeader(title: "VoiceServer", explanation: "Serve speech while VoiceRelay is running. Live requests have priority over Libro and podcasts. Closing Settings keeps the server running; Quit stops it.") }
            } else {
                Section {
                    Toggle("Enable VoiceServer", isOn: $server.configuration.enabled).onChange(of: server.configuration.enabled) { server.save() }
                    LabeledContent("Listener", value: server.running ? "Running" : "Stopped")
                    HStack {
                        Button("Start", action: server.start).disabled(server.running || server.busy)
                        Button("Stop", action: server.stop).disabled(!server.running || server.busy)
                        Button("Refresh", action: { server.refresh(interactive: true) }).disabled(server.busy)
                    }
                    LabeledContent("Live requests", value: "\(server.active) active · \(server.queued) queued")
                    if model.workStatusStates.values.contains(where: { $0.reason == .api }) { Text("Podcast generation is suspended for live API requests.").foregroundStyle(.secondary) }
                    Button("Set Up VoiceServer…") { setup = true }
                } header: { SectionHelpHeader(title: "VoiceServer", explanation: "Serve speech while VoiceRelay is running. Live requests have priority over Libro and podcasts. Closing Settings keeps the server running; Quit stops it.") }
                VoiceServerAccessControls(server: server)
                VoiceServerKeyControls(server: server, rotate: $rotate)
                Section {
                    LabeledContent("Model", value: model.preferences.modelSelection.model.rawValue)
                    LabeledContent("Voice", value: model.preferences.modelSelection.voice)
                    LabeledContent("Model readiness", value: model.speechRuntimeAvailable ? "Available" : "Needs setup")
                    Button("Open Voice Model Settings") { model.settingsSection = .voiceModel }
                    Toggle("Streaming MP3 and PCM", isOn: Binding(get: { server.configuration.modes.streaming }, set: { value in
                        if value || server.configuration.modes.completeFiles { server.configuration.modes.streaming = value; server.save() }
                    }))
                    Toggle("Complete MP3, WAV and PCM files", isOn: Binding(get: { server.configuration.modes.completeFiles }, set: { value in
                        if value || server.configuration.modes.streaming { server.configuration.modes.completeFiles = value; server.save() }
                    }))
                    Text("Use model voicerelay and voice default. MP3 and PCM stream by default; WAV is a complete file. Orpheus currently requires stream: false. Requests capture the current voice and pronunciation settings.")
                        .appFont(.secondary).foregroundStyle(.secondary)
                } header: { SectionHelpHeader(title: "Speech responses", explanation: "API audio is temporary and never enters podcast history, feeds or retained narration review. Missing models return an authenticated setup error; VoiceServer does not download them.") }
            }
            if let message = server.message { Section { Text(message).textSelection(.enabled) } }
        }.formStyle(.grouped)
            .sheet(isPresented: $setup) { VoiceServerSetupSheet(server: server) }
            .confirmationDialog("Rotate the API key?", isPresented: $rotate) {
                Button("Rotate Key", role: .destructive, action: server.generateKey)
            } message: { Text("This revokes the old key and cancels all queued and active API responses. Configure clients with the new key.") }
    }
}

/// The private-access choices shared by the settings pane and the setup sheet.
private struct VoiceServerAccessControls: View {
    @Bindable var server: VoiceServerModel
    var body: some View {
        Section {
            Picker("Access", selection: $server.configuration.access) {
                Text("Choose access…").tag(VoiceServerConfiguration.Access?.none)
                Text("This Mac only").tag(VoiceServerConfiguration.Access?.some(.loopback))
                Text("Tailscale").tag(VoiceServerConfiguration.Access?.some(.tailscale))
                Text("Other private VPN (advanced)").tag(VoiceServerConfiguration.Access?.some(.otherVPN))
            }.onChange(of: server.configuration.access) { server.configuration.addresses = []; server.save() }
            TextField("Port", value: $server.configuration.port, format: .number.grouping(.never))
                .onSubmit { server.save() }
            if server.configuration.access != .loopback, server.configuration.access != nil {
                ForEach(server.configuration.access == .tailscale ? server.tailscale.addresses : server.localAddresses.filter { $0 != "127.0.0.1" && $0 != "::1" }, id: \.self) { address in
                    Toggle(address, isOn: Binding(get: { server.configuration.addresses.contains(address) }, set: { selected in
                        server.configuration.addresses.removeAll { $0 == address }
                        if selected { server.configuration.addresses.append(address) }; server.save()
                    }))
                }
            }
            LabeledContent("Tailscale", value: server.tailscale.connected ? "Connected" : "Unavailable or disconnected")
            if let dns = server.tailscale.magicDNS { LabeledContent("MagicDNS", value: dns).textSelection(.enabled) }
            ForEach(server.endpoints) { endpoint in
                LabeledContent(endpoint.label) {
                    Text(endpoint.url.absoluteString).textSelection(.enabled)
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(endpoint.url.absoluteString, forType: .string) }
                }
            }
            Text("Speech uses /v1/audio/speech on each endpoint; metadata lives at /v1/models and /v1/audio/voices on the same host and port. Private HTTP reachability must be checked from your client.")
                .appFont(.secondary).foregroundStyle(.secondary)
        } header: { SectionHelpHeader(title: "Private access", explanation: "Binds loopback and only the private addresses you select. Removed interfaces close their connections. No wildcard listener, public relay or HTTPS is configured.") }
    }
}

/// Keychain bearer-key status and actions shared by the settings pane and the setup sheet.
private struct VoiceServerKeyControls: View {
    @Bindable var server: VoiceServerModel
    @Binding var rotate: Bool
    var body: some View {
        Section {
            LabeledContent("API key", value: server.keyConfigured ? "Saved in Keychain" : "Not configured")
            HStack {
                Button(server.keyConfigured ? "Rotate Key…" : "Generate Key") { if server.keyConfigured { rotate = true } else { server.generateKey() } }
                Button("Copy Key", action: server.copyKey).disabled(!server.keyConfigured)
            }.disabled(server.busy)
        } header: { SectionHelpHeader(title: "Bearer authentication", explanation: "Every endpoint requires the Keychain key. Copy places the secret on your clipboard. Rotation revokes the old key and cancels queued and active API requests.") }
    }
}

/// One-screen guided setup for first-run and rework: choose access, create the
/// key, then enable. Edits save immediately; Enable finishes and closes.
private struct VoiceServerSetupSheet: View {
    @Bindable var server: VoiceServerModel
    @Environment(\.dismiss) private var dismiss
    @State private var rotate = false
    private var readinessHint: String {
        if server.configuration.access == nil { return "Choose an access mode." }
        if server.configuration.access != .loopback, server.configuration.addresses.isEmpty { return "Select at least one private interface address." }
        if !server.keyConfigured { return "Generate an API key." }
        if !server.configuration.modes.isValid { return "Enable at least one response mode in settings." }
        return "Ready to enable."
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up VoiceServer").font(.title2).bold()
                Text("Choose private access and create an API key. Every endpoint requires the Keychain key.")
                    .appFont(.secondary).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top], 16)
            Form {
                VoiceServerAccessControls(server: server)
                VoiceServerKeyControls(server: server, rotate: $rotate)
                if let message = server.message { Section { Text(message).textSelection(.enabled) } }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Text(readinessHint)
                    .appFont(.secondary).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                Button("Enable VoiceServer") { server.start(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!server.setupReady || server.busy)
            }.padding(12)
        }.frame(minWidth: 560, minHeight: 480)
            .confirmationDialog("Rotate the API key?", isPresented: $rotate) {
                Button("Rotate Key", role: .destructive, action: server.generateKey)
            } message: { Text("This revokes the old key and cancels all queued and active API responses. Configure clients with the new key.") }
    }
}
