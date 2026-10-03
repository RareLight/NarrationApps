import SwiftUI
import AppKit
import Observation
import Darwin
import VoiceRelayCore

@MainActor @Observable
final class AppModel {
    var profile: PrototypeProfile?
    var diagnostics: [SetupDiagnostic] = []
    var configurationLabel = "No configuration selected"
    var status = "Ready for an isolated fixture"
    var error: String?
    var progress: PipelineProgress?
    var result: FixtureResult?
    var running = false
    var speechMode = false
    var sourceReview = SourceReviewModel()
    var runtimeProject = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Coding/VoiceRelay")
    var fixtureRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VoiceRelayPrototype/Fixture", isDirectory: true)
    @ObservationIgnored private let coordinator = FixtureCoordinator()
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        if let path = UserDefaults.standard.string(forKey: "selectedConfigurationPath") {
            load(URL(fileURLWithPath: path))
        }
        if let path = UserDefaults.standard.string(forKey: "fixtureRoot") { fixtureRoot = URL(fileURLWithPath: path) }
        if let path = UserDefaults.standard.string(forKey: "runtimeProject") { runtimeProject = URL(fileURLWithPath: path) }
    }
    func load(_ url: URL) {
        do {
            let loaded = try PrototypeProfile.load(url)
            profile = loaded; diagnostics = Diagnostics.inspect(loaded)
            configurationLabel = url.lastPathComponent; error = nil
            UserDefaults.standard.set(url.path, forKey: "selectedConfigurationPath")
        } catch {
            self.error = (error as? RelayError)?.localizedDescription ?? "Cannot read the selected configuration."
        }
    }
    func selectConfiguration() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "Import configuration read-only"
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    func selectFixtureDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.title = "Select a dedicated empty or VoiceRelay fixture folder"
        if panel.runModal() == .OK, let url = panel.url {
            fixtureRoot = url; UserDefaults.standard.set(url.path, forKey: "fixtureRoot")
        }
    }
    func runFixture() {
        guard !running else { return }
        running = true; error = nil; status = "Processing saved synthetic article"
        let root = fixtureRoot; let imported = profile; let speech = speechMode; let project = runtimeProject
        task = Task {
            defer { running = false; task = nil }
            do {
                let progress: @Sendable (PipelineProgress) -> Void = { [weak model = self] update in
                    Task { @MainActor in model?.progress = update }
                }
                if speech {
                    var speed = 1.0
                    if let setting = imported?.backendSettings["speed"] {
                        guard let value = setting.numericValue else { throw RelayError.setup("Speech speed must be a number.") }
                        speed = value
                    }
                    let voice = imported?.voice ?? "af_heart"
                    let backend = try KokoroMLXBackend(configuration: KokoroConfiguration(projectRoot: project, voice: voice, speed: speed))
                    result = try await coordinator.runSpeech(root: root, imported: imported, backend: backend,
                                                            voice: voice, speed: speed, onProgress: progress)
                } else {
                    result = try await coordinator.run(root: root, imported: imported, onProgress: progress)
                }
                status = "Fixture published locally"
            } catch is CancellationError { status = "Paused; completed checkpoints retained" }
            catch {
                self.error = (error as? RelayError)?.localizedDescription ?? "Fixture failed; inspect private artifacts and retry."
                status = "Needs attention"
            }
        }
    }
    func selectRuntimeProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.title = "Select the VoiceRelay project with its local Kokoro runtime"
        if panel.runModal() == .OK, let url = panel.url {
            runtimeProject = url; UserDefaults.standard.set(url.path, forKey: "runtimeProject")
        }
    }
    func pause() { task?.cancel() }
    func quit() {
        // Slice 2 has no background service. Stop owned work before terminating the UI.
        task?.cancel()
        sourceReview.cancel()
        Task {
            if let task { await task.value }
            await sourceReview.stop()
            NSApplication.shared.terminate(nil)
        }
    }
    var panelState: PanelState {
        PanelState(status: status, running: running, error: error,
                   stage: progress?.stage.rawValue ?? "IDLE",
                   completed: progress?.completedChunks ?? 0, total: progress?.totalChunks ?? 0,
                   localEpisode: result == nil ? "None" : "Validated M4A (\(result?.episode.settings.backendSelector == "speech-fixture" ? "speech" : "mock tones"))",
                   localFeed: result == nil ? "Not generated" : "Current — isolated RSS",
                   configuration: configurationLabel,
                   audioDescription: speechMode ? "Saved fixture · Kokoro speech" : "Saved fixture · mock tones, no speech")
    }
}

struct PanelState {
    var status: String
    var running = false
    var error: String?
    var stage = "IDLE"
    var completed = 0
    var total = 0
    var localEpisode = "None"
    var localFeed = "Not generated"
    var configuration = "No configuration selected"
    var audioDescription = "Saved fixture · mock tones, no speech"
}

struct RelayPanel: View {
    let state: PanelState
    let run: () -> Void
    let pause: () -> Void
    let settings: () -> Void
    let inspect: () -> Void
    var articles: () -> Void = {}
    let quit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("VoiceRelay", systemImage: "waveform").font(.headline); Spacer(); Text("Prototype").foregroundStyle(.secondary) }
            Text(state.status).font(.subheadline)
            if state.running {
                ProgressView(value: Double(state.completed), total: Double(max(1, state.total)))
                Text("\(state.stage) · \(state.completed)/\(state.total) chunks").font(.caption).monospacedDigit()
            }
            if let error = state.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption).textSelection(.enabled) }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { Text("Local episode"); Text(state.localEpisode) }
                GridRow { Text("Local feed"); Text(state.localFeed) }
                GridRow { Text("Remote feed"); Text("Disabled") }
                GridRow { Text("Media host"); Text("External; unverified") }
                GridRow { Text("Background worker"); Text("Not enrolled") }
            }.font(.caption)
            Divider()
            Text(state.audioDescription).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Articles…", action: articles)
                Spacer()
            }
            HStack {
                Button("Run / Resume Fixture", action: run).disabled(state.running)
                if state.running { Button("Pause", action: pause) }
            }
            HStack {
                Button("Inspect", action: inspect)
                Button("Settings…", action: settings)
                Spacer(); Button("Quit", action: quit)
            }
            Text("Closing this panel leaves the fixture running. Quit stops owned work; a later slice adds the managed agent.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(16).frame(width: 390)
    }
}

struct ConfigurationView: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("Configuration profile") {
                Text(model.configurationLabel)
                Button("Select config.toml…") { model.selectConfiguration() }.disabled(model.running)
                Text("Imports settings read-only. Python state and the original TOML remain separate.").font(.caption).foregroundStyle(.secondary)
                if let p = model.profile {
                    LabeledContent("Configured backend", value: p.backendSelector)
                    LabeledContent("Audio", value: "Mono AAC-LC · \(p.bitrate) · \(p.sampleRate) Hz")
                    LabeledContent("Media directory", value: p.audio.path)
                    LabeledContent("Feed URL", value: p.feedURL.absoluteString)
                    ForEach(Array(p.compatibilityNotices.enumerated()), id: \.offset) { _, notice in Text(notice).font(.caption) }
                }
            }
            Section("Isolated demonstration") {
                Picker("Fixture audio", selection: $model.speechMode) {
                    Text("Mock tones").tag(false)
                    Text("Kokoro speech").tag(true)
                }.pickerStyle(.segmented).disabled(model.running)
                if model.speechMode {
                    Text(model.runtimeProject.path).font(.caption).textSelection(.enabled)
                    Button("Select runtime project…") { model.selectRuntimeProject() }.disabled(model.running)
                    Text("Requires explicit project-local setup. Choose a separate empty speech fixture folder; this action downloads nothing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(model.fixtureRoot.path).textSelection(.enabled)
                Button("Choose fixture folder…") { model.selectFixtureDirectory() }.disabled(model.running)
                Text("The fixture overrides all writable paths and delivery URLs. It cannot upload or enroll a worker.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Acceptance diagnostics") {
                ForEach(model.diagnostics) { d in Label(d.message, systemImage: d.ready ? "checkmark.circle" : "circle.dashed").font(.caption) }
                if model.diagnostics.isEmpty { Text("Select a configuration to inspect local setup.") }
            }
            if let error = model.error { Text(error).foregroundStyle(.orange) }
        }.formStyle(.grouped).padding().frame(width: 660, height: 650)
    }
}

struct InspectionView: View {
    @Bindable var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let result = model.result {
                    Text(result.article.title).font(.title2)
                    Text("\(result.episode.id) · \(result.narration.chunks.count) chunks · \(result.synthesizedChunks) newly synthesized").font(.caption)
                    Text("Extraction completeness, pronunciation, and listening quality require separate acceptance.").foregroundStyle(.secondary)
                    Button("Show fixture artifacts") { NSWorkspace.shared.open(model.fixtureRoot) }
                    Text("Semantic blocks").font(.headline)
                    ForEach(Array(result.article.blocks.enumerated()), id: \.offset) { index, block in
                        VStack(alignment: .leading) {
                            Text("\(index) · \(block.kind.rawValue)").font(.caption).foregroundStyle(.secondary)
                            Text(block.text).textSelection(.enabled)
                        }
                    }
                    Text("Narration").font(.headline)
                    ForEach(result.narration.chunks, id: \.index) { chunk in
                        Text("Chunk \(chunk.index) · blocks \(chunk.blockIndices.map(String.init).joined(separator: ", "))\n\(chunk.text)").textSelection(.enabled)
                    }
                    ForEach(result.narration.notices, id: \.self) { Text($0).foregroundStyle(.orange) }
                } else { Text("Run the saved fixture to inspect extraction and narration.") }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minWidth: 680, minHeight: 520)
    }
}

@main @MainActor
struct VoiceRelayApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow
    init() { umask(0o077) }
    var body: some Scene {
        MenuBarExtra("VoiceRelay", systemImage: "waveform") {
            PanelContainer(model: model)
        }.menuBarExtraStyle(.window)
        Settings { ConfigurationView(model: model) }
        Window("Fixture inspection", id: "inspection") { InspectionView(model: model) }
        Window("Article review", id: "articles") {
            SourceReviewView(model: model.sourceReview, profile: model.profile, fixtureRoot: model.fixtureRoot)
        }
    }
}

struct PanelContainer: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        RelayPanel(state: model.panelState, run: model.runFixture, pause: model.pause,
                   settings: { NSApp.activate(ignoringOtherApps: true); openSettings() },
                   inspect: { NSApp.activate(ignoringOtherApps: true); openWindow(id: "inspection") },
                   articles: { NSApp.activate(ignoringOtherApps: true); openWindow(id: "articles") }, quit: model.quit)
    }
}

#if DEBUG
#Preview("Idle") { RelayPanel.preview(PanelState(status: "Ready for an isolated fixture")) }
#Preview("Processing") { RelayPanel.preview(PanelState(status: "Synthesizing mock tones", running: true, stage: "SYNTHESIZING", completed: 2, total: 8)) }
#Preview("Paused") { RelayPanel.preview(PanelState(status: "Paused; completed checkpoints retained")) }
#Preview("Permission denied") { RelayPanel.preview(PanelState(status: "Needs attention", error: "Safari permission denied. Grant the actual agent Full Disk Access.")) }
#Preview("Storage missing") { RelayPanel.preview(PanelState(status: "Needs attention", error: "Configured storage is unavailable. Mount it before resuming.")) }
#Preview("Upload pending") { RelayPanel.preview(PanelState(status: "Local episode complete", error: "Synthetic future state: remote feed pending", localEpisode: "Validated M4A", localFeed: "Current")) }
#Preview("Kokoro speech — inert") { RelayPanel.preview(PanelState(status: "Speech fixture published locally", localEpisode: "Validated M4A (speech)", localFeed: "Current — isolated RSS", audioDescription: "Saved fixture · Kokoro speech")) }
extension RelayPanel {
    static func preview(_ state: PanelState) -> some View {
        RelayPanel(state: state, run: {}, pause: {}, settings: {}, inspect: {}, quit: {})
    }
}
#endif
