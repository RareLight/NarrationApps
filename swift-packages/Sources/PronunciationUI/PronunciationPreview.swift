import Foundation
import Observation
import NarrationCore
import Pronunciation
import NativeSpeech
import ProcessingPipeline
import AudioOutput

public struct PronunciationPreviewConfiguration: Sendable, Equatable {
    public let worker: URL
    public let workspace: URL
    public let settings: SpeechSettings
    public let priority: InferencePriority
    public let documentTitle: String?
    public let workCoordinator: SpeechWorkCoordinator?
    public init(worker: URL, workspace: URL, settings: SpeechSettings, priority: InferencePriority, documentTitle: String? = nil,
                workCoordinator: SpeechWorkCoordinator? = nil) {
        self.worker = worker; self.workspace = workspace; self.settings = settings; self.priority = priority
        self.documentTitle = documentTitle
        self.workCoordinator = workCoordinator
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.worker == rhs.worker && lhs.workspace == rhs.workspace && lhs.settings == rhs.settings &&
        lhs.priority == rhs.priority && lhs.documentTitle == rhs.documentTitle && lhs.workCoordinator === rhs.workCoordinator
    }
    var workerConfiguration: WorkerConfiguration {
        var captured = WorkerConfiguration(executable: worker, inferencePriority: priority)
        captured.workCoordinator = workCoordinator
        return captured
    }
    var cpuWork: SpeechCPUContext? {
        workCoordinator.map { .init(coordinator: $0, settings: settings, workspace: workspace,
            rank: priority == .interactive ? .libro : .podcast) }
    }
}

struct PronunciationPreviewArtifact: Sendable {
    let directory: URL
    var audio: URL { directory.appendingPathComponent("preview.wav") }
    func remove() async { _ = await Task.detached { try? FileManager.default.removeItem(at: directory) }.value }
}

/// App-owned controller: stopAndWait is joined before normal narration/model work
/// starts, so a preview never leaves a second resident model in the same app.
@MainActor @Observable public final class PronunciationPreview {
    public private(set) var renderingID: UUID?
    public private(set) var error: String?
    public let player = AudioPreviewPlayer()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private let render: @Sendable (String, PronunciationDictionary, PronunciationPreviewConfiguration) async throws -> PronunciationPreviewArtifact
    public var playingID: String? { player.playingID }
    private var workID: UUID?
    public var hasOwnedWork: Bool { workID != nil }
    public var isRendering: Bool { renderingID != nil }
    public init() { render = Self.renderNative }
    init(render: @escaping @Sendable (String, PronunciationDictionary, PronunciationPreviewConfiguration) async throws -> PronunciationPreviewArtifact) { self.render = render }

    public func play(entry: PronunciationEntry, dictionary: PronunciationDictionary, configuration: PronunciationPreviewConfiguration, sentence: String = "") {
        if renderingID == entry.id || playingID == entry.id.uuidString { stop(); return }
        let previous = task
        stop()
        let operation = UUID(); token = operation; workID = operation
        renderingID = entry.id; error = nil
        task = Task { [weak self, render] in
            await previous?.value
            guard let self else { return }
            defer {
                if self.workID == operation { self.renderingID = nil; self.workID = nil; self.task = nil }
            }
            guard !Task.isCancelled, self.token == operation else { return }
            do {
                let context = PronunciationPreviewConfiguration(worker: configuration.worker, workspace: configuration.workspace,
                    settings: configuration.settings, priority: configuration.priority, documentTitle: entry.documentTitle,
                    workCoordinator: configuration.workCoordinator)
                let artifact = try await render(sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entry.word : sentence, dictionary, context)
                if Task.isCancelled || self.token != operation { await artifact.remove(); return }
                self.renderingID = nil
                self.player.toggle(url: artifact.audio, id: entry.id.uuidString)
                self.error = self.player.error
                while self.player.playingID == entry.id.uuidString && !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                }
                if self.token == operation { self.player.stop() }
                await artifact.remove()
            } catch is CancellationError {
            } catch { if self.token == operation { self.error = error.localizedDescription } }

        }
    }
    public func stop() {
        token = UUID(); task?.cancel(); player.stop(); renderingID = nil; error = nil
    }
    public func stopAndWait() async { let previous = task; stop(); await previous?.value }

    /// Share the app's existing joined preview ownership with manual review work.
    /// Normal narration/setup cancels and awaits this task before owning a helper.
    public func performReview(_ operation: @escaping @MainActor () async throws -> Void) {
        let previous = task; stop()
        let operationID = UUID(); token = operationID; workID = operationID
        task = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.token == operationID else { return }
            defer { if self.workID == operationID { self.workID = nil; self.task = nil } }
            do { try await operation() }
            catch is CancellationError {}
            catch { if self.token == operationID { self.error = error.localizedDescription } }
        }
    }

    nonisolated static func renderNative(word: String, dictionary: PronunciationDictionary,
        configuration: PronunciationPreviewConfiguration) async throws -> PronunciationPreviewArtifact {
        let accessed = configuration.workspace.startAccessingSecurityScopedResource()
        defer { if accessed { configuration.workspace.stopAccessingSecurityScopedResource() } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftNarration-Pronunciation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let artifact = PronunciationPreviewArtifact(directory: directory)
        do {
            let projection = try await SpeechCPUContext.run(configuration.cpuWork) {
                try NarrationPlanner.prepareForSpeech(.init(title: configuration.documentTitle, blocks: [.init(kind: .paragraph, text: word)], extractorVersion: "pronunciation-preview-1"),
                    settings: configuration.settings, pronunciations: dictionary)
            }
            let worker = configuration.workerConfiguration
            let session = try NativeSpeechSession(configuration: worker, workspace: configuration.workspace,
                settings: configuration.settings, leaseFile: worker.inferenceLeaseFile)
            do {
                try await session.prepare(forTextPreparation: true)
                let plan = try await session.prepareSpeech(projection)
                try await session.render(plan: plan, destination: artifact.audio, identity: .init(batch: UUID(), job: UUID()))
                await session.close() // Release the model before playback begins.
            } catch { await session.close(); throw error }
            return artifact
        } catch { await artifact.remove(); throw error }
    }
}
