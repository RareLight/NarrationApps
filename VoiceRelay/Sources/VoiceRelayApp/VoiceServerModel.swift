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

@MainActor @Observable
final class VoiceServerModel {
    var configuration: VoiceServerConfiguration
    private(set) var running = false
    private(set) var keyConfigured = false
    private(set) var busy = false
    private(set) var message: String?
    private(set) var tailscale = VoiceServerTailscaleStatus.unavailable
    private(set) var localAddresses: [String] = []
    private(set) var urls: [URL] = []
    private(set) var active = 0
    private(set) var queued = 0
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
        manuallyStopped = false; refresh(force: true)
    }
    func start() { manuallyStopped = false; configuration.enabled = true; save() }
    func stop() { manuallyStopped = true; interruptListener(); refresh(force: true) }
    private func interruptListener() {
        let owned = server
        Task { await owned?.stop() }
    }
    func refresh(force: Bool = false) {
        guard !closed else { return }
        if !force, busy { return }
        if force { interruptListener() }
        let previous = operation; previous?.cancel()
        let id = UUID(); operationID = id
        operation = Task { [weak self] in
            await previous?.value
            guard let self, !closed, !Task.isCancelled else { return }
            busy = true; defer { if operationID == id { busy = false; operation = nil } }
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
                    bindings = wanted; urls = wanted.compactMap(\.baseURL)
                    if configuration.access == .tailscale, let dns = tailscale.baseURL(port: configuration.port) { urls.append(dns) }
                    running = true
                }
                if let service { let status = await service.status; active = status.active; queued = status.queued }
                urls = wanted.compactMap(\.baseURL)
                if configuration.access == .tailscale, let dns = tailscale.baseURL(port: configuration.port) { urls.append(dns) }
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
                if configuration.enabled, !closed { refresh(force: true) }
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
        running = false; urls = []; bindings = []; active = 0; queued = 0
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
    @State private var rotate = false
    var body: some View {
        Form {
            Section {
                Toggle("Enable VoiceServer", isOn: $server.configuration.enabled).onChange(of: server.configuration.enabled) { server.save() }
                LabeledContent("Listener", value: server.running ? "Running" : "Stopped")
                HStack {
                    Button("Start", action: server.start).disabled(server.running || server.busy)
                    Button("Stop", action: server.stop).disabled(!server.running || server.busy)
                    Button("Refresh", action: { server.refresh() }).disabled(server.busy)
                }
                LabeledContent("Live requests", value: "\(server.active) active · \(server.queued) queued")
                if model.workStatusStates.values.contains(where: { $0.reason == .api }) { Text("Podcast generation is suspended for live API requests.").foregroundStyle(.secondary) }
            } header: { SectionHelpHeader(title: "VoiceServer", explanation: "Serve speech while VoiceRelay is running. Live requests have priority over Libro and podcasts. Closing Settings keeps the server running; Quit stops it.") }
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
                ForEach(server.urls, id: \.self) { url in
                    LabeledContent("API base URL") {
                        Text(url.absoluteString).textSelection(.enabled)
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
                    }
                }
                Text("The base URL ends in /v1; speech uses /v1/audio/speech. Private HTTP reachability must be checked from your client.")
                    .appFont(.secondary).foregroundStyle(.secondary)
            } header: { SectionHelpHeader(title: "Private access", explanation: "Binds loopback and only the private addresses you select. Removed interfaces close their connections. No wildcard listener, public relay or HTTPS is configured.") }
            Section {
                LabeledContent("API key", value: server.keyConfigured ? "Saved in Keychain" : "Not configured")
                HStack {
                    Button(server.keyConfigured ? "Rotate Key…" : "Generate Key") { if server.keyConfigured { rotate = true } else { server.generateKey() } }
                    Button("Copy Key", action: server.copyKey).disabled(!server.keyConfigured)
                }.disabled(server.busy)
            } header: { SectionHelpHeader(title: "Bearer authentication", explanation: "Every endpoint requires the Keychain key. Copy places the secret on your clipboard. Rotation revokes the old key and cancels queued and active API requests.") }
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
            if let message = server.message { Section { Text(message).textSelection(.enabled) } }
        }.formStyle(.grouped)
            .confirmationDialog("Rotate the API key?", isPresented: $rotate) {
                Button("Rotate Key", role: .destructive, action: server.generateKey)
            } message: { Text("This revokes the old key and cancels all queued and active API responses. Configure clients with the new key.") }
    }
}
