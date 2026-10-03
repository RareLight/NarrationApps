import SwiftUI
import AppKit
import Observation
import Darwin
import VoiceRelayCore

@MainActor @Observable
final class AppModel {
    var status = "Choose an article to review"
    var error: String?
    var progress: PipelineProgress?
    var result: FixtureResult?
    var savedEpisodes: [Episode] = []
    var running = false
    var preferences = SpeechPreferences() { didSet { savePreferences() } }
    var preview = false
    var sourceReview = SourceReviewModel(preview: true)
    var runtimeProject = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Coding/VoiceRelay")
    var fixtureRoot = AppStorage.speechFixture
    let libraryRoot = AppStorage.articleLibrary
    @ObservationIgnored private let coordinator = FixtureCoordinator()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pendingReview: ReviewedSource?
    @ObservationIgnored private var pendingEpisode: Episode?

    init(preview: Bool = false) {
        self.preview = preview; sourceReview = SourceReviewModel(preview: preview)
        guard !preview else {
            runtimeProject = URL(fileURLWithPath: "/synthetic/VoiceRelay")
            fixtureRoot = URL(fileURLWithPath: "/synthetic/SpeechFixture")
            return
        }
        if let bytes = UserDefaults.standard.data(forKey: "speechPreferences") {
            do {
                let saved = try JSONDecoder().decode(SpeechPreferences.self, from: bytes)
                try saved.validate(); preferences = saved
            } catch { self.error = "Saved speech preferences could not be read. Default voice and speed are active." }
        }
        if let path = UserDefaults.standard.string(forKey: "speechFixtureRoot") { fixtureRoot = URL(fileURLWithPath: path) }
        if let path = UserDefaults.standard.string(forKey: "runtimeProject") { runtimeProject = URL(fileURLWithPath: path) }
    }
    private func savePreferences() {
        guard !preview, (try? preferences.validate()) != nil,
              let bytes = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(bytes, forKey: "speechPreferences")
    }
    func selectFixtureDirectory() {
        guard !preview, !running else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.title = "Select a dedicated empty or VoiceRelay fixture folder"
        if panel.runModal() == .OK, let url = panel.url {
            fixtureRoot = url; UserDefaults.standard.set(url.path, forKey: "speechFixtureRoot")
        }
    }
    func runFixture() {
        guard !running else { return }
        pendingReview = nil; pendingEpisode = nil; start(review: nil)
    }
    func generate(_ review: ReviewedSource) {
        guard !running else { return }
        pendingReview = review; pendingEpisode = nil; start(review: review)
    }
    func resume() { start(review: pendingReview, saved: pendingEpisode) }
    func resume(_ episode: Episode) {
        guard !running else { return }
        pendingReview = nil; pendingEpisode = episode; start(review: nil, saved: episode)
    }
    func refreshLibrary() {
        guard !preview, !running else { return }
        Task {
            do { savedEpisodes = try await coordinator.library(root: libraryRoot) }
            catch { self.error = (error as? RelayError)?.localizedDescription ?? "The saved article library could not be read." }
        }
    }
    private func start(review: ReviewedSource?, saved: Episode? = nil) {
        guard !preview, !running else { return }
        running = true; error = nil; progress = nil; result = nil
        status = review == nil && saved == nil ? "Generating sample speech…" : "Generating article speech…"
        let root = review == nil && saved == nil ? fixtureRoot : libraryRoot
        let selected = preferences; let project = runtimeProject
        task = Task {
            defer { running = false; task = nil; refreshLibrary() }
            do {
                let progress: @Sendable (PipelineProgress) -> Void = { [weak model = self] update in
                    Task { @MainActor in model?.progress = update }
                }
                try selected.validate()
                let voice = saved?.settings.voice ?? selected.voice.rawValue
                let speed = saved?.settings.backendSettings["speed"]?.numericValue ?? selected.speed
                let backend = try KokoroMLXBackend(configuration: KokoroConfiguration(projectRoot: project, voice: voice, speed: speed))
                if let saved {
                    result = try await coordinator.resumeReviewed(root: root, articleID: saved.id, backend: backend, onProgress: progress)
                } else if let review {
                    result = try await coordinator.runReviewed(root: root, review: review, backend: backend,
                                                               voice: voice, speed: speed, onProgress: progress)
                } else {
                    result = try await coordinator.runSpeech(root: root, backend: backend,
                                                            voice: voice, speed: speed, onProgress: progress)
                }
                status = "Speech saved locally"
            } catch is CancellationError { status = "Paused; completed checkpoints retained" }
            catch {
                self.error = (error as? RelayError)?.localizedDescription ?? "Speech failed; completed progress is retained."
                status = "Needs attention"
            }
        }
    }
    func selectRuntimeProject() {
        guard !preview, !running else { return }
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
                   localEpisode: result == nil ? "None" : "Validated M4A (speech)",
                   localFeed: result == nil ? "Not generated" : "Current — isolated RSS",
                   audioDescription: pendingReview == nil && pendingEpisode == nil ? "Sample article · Kokoro speech" : "Reviewed article · Kokoro speech")
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
    var audioDescription = "Kokoro speech"
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
                Button("Run / Resume Speech", action: run).disabled(state.running)
                if state.running { Button("Pause", action: pause) }
            }
            HStack {
                Button("Inspect", action: inspect)
                Button("Settings…", action: settings)
                Spacer(); Button("Quit", action: quit)
            }
            Text("Closing this panel leaves speech running. Quit stops owned work and preserves progress.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(16).frame(width: 390)
    }
}

struct ConfigurationView: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("Speech") {
                Picker("Voice", selection: $model.preferences.voice) {
                    ForEach(SpeechVoice.allCases) { voice in Text(voice.label).tag(voice) }
                }
                Stepper("Speed: \(model.preferences.speed, specifier: "%.2f")×", value: $model.preferences.speed, in: 0.75...1.5, step: 0.05)
                Text("Voice and speed are saved automatically. New articles use these choices; resumed articles keep their captured settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("English speech · local processing").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.running)
            Section("Storage") {
                Text("VoiceRelay manages private article snapshots and audio automatically. No configuration file or output folder is required.")
                Text("Remote publishing and background scheduling are not enabled.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Prototype development") {
                DisclosureGroup("Runtime and sample diagnostics") {
                    Text(model.runtimeProject.path).font(.caption).textSelection(.enabled)
                    Button("Select runtime project…") { model.selectRuntimeProject() }.disabled(model.running)
                    Text("The development build uses the installed project-local runtime. Selection downloads nothing; runtime packaging is a later step.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Generate sample speech") { model.runFixture() }.disabled(model.running)
                    Button("Choose sample speech folder…") { model.selectFixtureDirectory() }.disabled(model.running)
                }
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
                    Button("Play speech") { NSWorkspace.shared.open(result.audioURL) }
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
                } else { Text("Generate speech from an article review or use the sample in Settings.") }
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
        Window("Speech inspection", id: "inspection") { InspectionView(model: model) }
        Window("Article review", id: "articles") {
            TabView {
                SourceReviewView(model: model.sourceReview, fixtureRoot: model.fixtureRoot,
                                 speechRunning: model.running, generate: model.generate)
                    .tabItem { Label("Review articles", systemImage: "doc.text") }
                LibraryView(model: model).tabItem { Label("Saved speech", systemImage: "waveform") }
            }
        }
    }
}

struct LibraryView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved speech").font(.title)
            Text("Articles and progress stay on this Mac. Resume uses the saved review without fetching again.")
                .foregroundStyle(.secondary)
            Button("Refresh") { model.refreshLibrary() }.disabled(model.running)
            if model.savedEpisodes.isEmpty { Text("Generate speech from a reviewed article to add it here.").foregroundStyle(.secondary) }
            List(model.savedEpisodes, id: \.id) { episode in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.title)
                        Text(episode.stage == .published ? "Speech ready" : "Progress saved · \(episode.stage.rawValue.lowercased())")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(episode.stage == .published ? "Inspect" : "Resume") {
                        model.resume(episode)
                        if episode.stage == .published { openWindow(id: "inspection") }
                    }.disabled(model.running || model.preview)
                    if episode.stage == .published {
                        Button("Play") { NSWorkspace.shared.open(episode.settings.audio.appendingPathComponent(episode.id + ".m4a")) }.disabled(model.preview)
                    }
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(20).frame(minWidth: 820, minHeight: 640).onAppear { model.refreshLibrary() }
    }
}

struct PanelContainer: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        RelayPanel(state: model.panelState, run: model.resume, pause: model.pause,
                   settings: { NSApp.activate(ignoringOtherApps: true); openSettings() },
                   inspect: { NSApp.activate(ignoringOtherApps: true); openWindow(id: "inspection") },
                   articles: { NSApp.activate(ignoringOtherApps: true); openWindow(id: "articles") }, quit: model.quit)
    }
}

#if DEBUG
#Preview("Idle") { RelayPanel.preview(PanelState(status: "Choose an article to review")) }
#Preview("Processing") { RelayPanel.preview(PanelState(status: "Generating speech", running: true, stage: "SYNTHESIZING", completed: 2, total: 8)) }
#Preview("Paused") { RelayPanel.preview(PanelState(status: "Paused; completed checkpoints retained")) }
#Preview("Permission denied") { RelayPanel.preview(PanelState(status: "Needs attention", error: "Safari permission denied. Grant the actual agent Full Disk Access.")) }
#Preview("Storage missing") { RelayPanel.preview(PanelState(status: "Needs attention", error: "Configured storage is unavailable. Mount it before resuming.")) }
#Preview("Upload pending") { RelayPanel.preview(PanelState(status: "Local episode complete", error: "Synthetic future state: remote feed pending", localEpisode: "Validated M4A", localFeed: "Current")) }
#Preview("Kokoro speech — inert") { RelayPanel.preview(PanelState(status: "Speech fixture published locally", localEpisode: "Validated M4A (speech)", localFeed: "Current — isolated RSS", audioDescription: "Saved fixture · Kokoro speech")) }
#Preview("Settings — inert defaults") { ConfigurationView(model: AppModel(preview: true)) }
#Preview("Saved speech — inert empty library") { LibraryView(model: AppModel(preview: true)) }
#Preview("Saved speech — inert ready and paused") {
    let model = AppModel(preview: true)
    let settings = PrototypeProfile.fixture(at: URL(fileURLWithPath: "/synthetic/Articles"))
    if let bytes = try? JSONEncoder().encode(settings), let profile = try? JSONSerialization.jsonObject(with: bytes) {
        for (index, stage) in [Stage.published, .synthesizing].enumerated() {
            let record: [String: Any] = ["id": "00000000-0000-0000-0000-00000000000\(index)",
                "title": index == 0 ? "A synthetic saved article" : "A synthetic paused article", "stage": stage.rawValue, "settings": profile]
            if let data = try? JSONSerialization.data(withJSONObject: record),
               let episode = try? JSONDecoder().decode(Episode.self, from: data) { model.savedEpisodes.append(episode) }
        }
    }
    return LibraryView(model: model)
}
extension RelayPanel {
    static func preview(_ state: PanelState) -> some View {
        RelayPanel(state: state, run: {}, pause: {}, settings: {}, inspect: {}, quit: {})
    }
}
#endif
