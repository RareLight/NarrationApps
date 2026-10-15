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
    public init(worker: URL, workspace: URL, settings: SpeechSettings, priority: InferencePriority) {
        self.worker = worker; self.workspace = workspace; self.settings = settings; self.priority = priority
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

    public func play(entry: PronunciationEntry, dictionary: PronunciationDictionary, configuration: PronunciationPreviewConfiguration) {
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
                let artifact = try await render(entry.word, dictionary, configuration)
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

    nonisolated static func renderNative(word: String, dictionary: PronunciationDictionary,
        configuration: PronunciationPreviewConfiguration) async throws -> PronunciationPreviewArtifact {
        let accessed = configuration.workspace.startAccessingSecurityScopedResource()
        defer { if accessed { configuration.workspace.stopAccessingSecurityScopedResource() } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftNarration-Pronunciation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let artifact = PronunciationPreviewArtifact(directory: directory)
        do {
            let projection = try NarrationPlanner.prepareForSpeech(.init(blocks: [.init(kind: .paragraph, text: word)], extractorVersion: "pronunciation-preview-1"),
                settings: configuration.settings, pronunciations: dictionary)
            let worker = WorkerConfiguration(executable: configuration.worker, inferencePriority: configuration.priority)
            let session = try NativeSpeechSession(configuration: worker, workspace: configuration.workspace,
                settings: configuration.settings, leaseFile: worker.inferenceLeaseFile)
            do {
                try await session.prepare()
                let plan = try await session.prepareSpeech(projection)
                try await session.render(plan: plan, destination: artifact.audio, identity: .init(batch: UUID(), job: UUID()))
                await session.close() // Release the model before playback begins.
            } catch { await session.close(); throw error }
            return artifact
        } catch { await artifact.remove(); throw error }
    }
}
