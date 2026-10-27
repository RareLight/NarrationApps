import NarrationCore
import DocumentProcessing
import NativeSpeech
import AudioOutput
import Foundation

public struct SpeechProgress: Sendable {
    public enum Phase: Sendable { case started, chunkWritten, publishing }
    public let identity: AttemptIdentity
    public let phase: Phase
    public let completedChunks: Int
    public let totalChunks: Int
}

public struct ChunkScheduler: Sendable {
    private let configuration: WorkerConfiguration
    public init(configuration: WorkerConfiguration) { self.configuration = configuration }

    public func render(projection: NarrationPlan, batchID: UUID, jobID: UUID, workspace: URL,
                       settings: SpeechSettings, destination: URL,
                       outputFormat: AudioOutputFormat = .wav, replaceExisting: Bool = true, session: NativeSpeechSession? = nil, coverArtwork: CoverArtwork? = nil,
                       checkpoint: (@Sendable () async throws -> Void)? = nil,
                       beforePublication: @Sendable () throws -> Void = {},
                       preparationProgress: @Sendable (Int, Int) -> Void = { _, _ in },
                       progress: @Sendable (SpeechProgress) -> Void = { _ in }) async throws {
        let identity = AttemptIdentity(batch: batchID, job: jobID)
        let owned = try session ?? NativeSpeechSession(configuration: configuration, workspace: workspace,
            settings: settings, leaseFile: configuration.inferenceLeaseFile, identity: identity)
        do {
            if let checkpoint { try await checkpoint() }
            try await owned.prepare()
            if let checkpoint { try await checkpoint() }
            let plan = try await owned.prepareSpeech(projection, checkpoint: checkpoint, progress: preparationProgress)
            try await owned.render(plan: plan, destination: destination, outputFormat: outputFormat, replaceExisting: replaceExisting, coverArtwork: coverArtwork,
                identity: identity, checkpoint: checkpoint, beforePublication: beforePublication, progress: progress)
            if session == nil { await owned.close() }
        } catch { await owned.close(); throw error }
    }

    /// One owned helper generates ordered chunks. A caller-owned session can be
    /// reused across compatible documents; failures are never automatically replayed.
    public func render(chunks: [String], batchID: UUID, jobID: UUID, workspace: URL,
                       settings: SpeechSettings, destination: URL,
                       outputFormat: AudioOutputFormat = .wav, replaceExisting: Bool = true, session: NativeSpeechSession? = nil, coverArtwork: CoverArtwork? = nil,
                       beforePublication: @Sendable () throws -> Void = {},
                       progress: @Sendable (SpeechProgress) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        let chunks = chunks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !chunks.isEmpty, chunks.allSatisfy({ $0.unicodeScalars.count <= 1_000 }),
              settings.speed.isFinite, settings.speed > 0 else { throw SpeechFailure(.invalidInput) }
        let resolved = try OutputPaths.resolved(destination)
        do { try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw SpeechFailure(.storage) }
        let identity = AttemptIdentity(batch: batchID, job: jobID)
        let owned = try session ?? NativeSpeechSession(configuration: configuration, workspace: workspace,
                                                      settings: settings, leaseFile: configuration.inferenceLeaseFile, identity: identity)
        progress(.init(identity: identity, phase: .started, completedChunks: 0, totalChunks: chunks.count))
        do {
            try await owned.prepare()
            try await owned.render(chunks: chunks, destination: destination, outputFormat: outputFormat, replaceExisting: replaceExisting, coverArtwork: coverArtwork,
                                   identity: identity, beforePublication: beforePublication, progress: progress)
            if session == nil { await owned.close() }
        } catch {
            await owned.close()
            if let failure = error as? AudioOutputError {
                switch failure {
                case .encoding, .encoderUnavailable: throw failure
                case .riffLimit: throw SpeechFailure(.invalidInput)
                default: throw SpeechFailure(.storage)
                }
            }
            throw error
        }
    }
}
