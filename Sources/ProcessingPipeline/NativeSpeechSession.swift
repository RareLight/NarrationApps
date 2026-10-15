import Foundation
import Darwin
import NarrationCore
import NativeSpeech
import AudioOutput

public struct NativeSpeechArtifact: Sendable {
    public let url: URL
    public let sampleRate: Int
    public let frames: Int
}

/// A compatible sequence of jobs reuses one engine; each heavy operation acquires the inference lease.
/// Only owned CPU audio crosses IPC; cancellation closes and reaps the helper
/// before deleting the session's exclusively-created spool.
public actor NativeSpeechSession {
    private let configuration: WorkerConfiguration
    private let workspace: NativeWorkspace
    private let settings: SpeechSettings
    private let policy: SpeechPreparationPolicy
    private let leaseFile: URL
    private let identity: AttemptIdentity
    private var worker: SpeechWorkerProcess?
    private var spool: URL?
    private var lease: InferenceLease?
    private var nextChunk = 0
    private var busy = false
    private var ready = false
    private var closed = false

    public init(configuration: WorkerConfiguration, workspace: URL, settings: SpeechSettings,
                leaseFile: URL = InferenceLease.defaultFile, policy: SpeechPreparationPolicy? = nil, identity: AttemptIdentity = .init(batch: UUID(), job: UUID())) throws {
        self.identity = identity
        self.configuration = configuration
        self.workspace = try NativeWorkspace(root: workspace)
        self.settings = settings
        self.policy = settings.model == .soprano ? .legacy : (policy ?? configuration.preparationPolicy)
        self.leaseFile = leaseFile
    }

    public func prepare() async throws {
        try Task.checkCancellation()
        guard !closed, !busy else { throw SpeechFailure(.invalidInput) }
        if ready { return }
        busy = true
        defer { busy = false; lease = nil }
        do {
            let acquired = try await InferenceLease.acquire(at: leaseFile, priority: configuration.inferencePriority)
            guard !closed else { throw CancellationError() }
            lease = acquired
            let parent = try workspace.managed(workspace.nativeRoot.appendingPathComponent("staging"))
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let staging = try workspace.managed(parent.appendingPathComponent("attempt-\(identity.attempt.uuidString)"))
            guard mkdir(staging.path, 0o700) == 0 else { throw SpeechFailure(.storage) }
            spool = staging
            let owned = try SpeechWorkerProcess(configuration: configuration, identity: identity)
            worker = owned
            _ = try await owned.request(.init(kind: .initialize, identity: identity, workspace: workspace.root,
                                             settings: settings, spoolDirectory: staging, policy: policy))
            guard !closed else { throw CancellationError() }
            ready = true
        } catch {
            await close()
            throw error
        }
    }

    /// One authoritative preparation boundary shared by adapters and developer
    /// tools. No model loading/download or global text cache is hidden here.
    public func prepareSpeech(_ projection: NarrationPlan,
        progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> PreparedSpeechPlan {
        try Task.checkCancellation()
        guard ready, !closed, !busy, !projection.chunks.isEmpty else { throw SpeechFailure(.invalidInput) }
        let acousticIdentity = SpeechAcousticIdentity.make(settings: settings, policy: policy)
        if !policy.usesPreparedPhonemes {
            let values = try projection.chunks.map { chunk in
                let utterance = PreparedUtterance(text: chunk.text, phonemes: nil, tokenCount: 0,
                    source: .init(blockIndices: chunk.blockIndices, location: 0, length: chunk.text.utf16.count, origin: chunk.origin),
                    boundaryAfter: chunk.boundaryAfter ?? .continuation, acousticIdentity: acousticIdentity)
                try utterance.validate(identity: acousticIdentity, prepared: false)
                return utterance
            }
            return .init(policy: policy, settings: settings, semanticVersion: projection.version,
                acousticIdentity: acousticIdentity, utterances: values, notices: projection.notices, provenance: SpeechAcousticIdentity.provenance(settings: settings, policy: policy))
        }
        guard policy == .correctnessCandidate || projection.version.hasSuffix("/spoken-projection-1") else {
            throw SpeechFailure(.invalidInput)
        }
        busy = true
        defer { busy = false; lease = nil }
        do {
            let windows = try SpeechTextWindows.make(from: projection)
            var utterances: [PreparedUtterance] = []
            progress(0, windows.count)
            for (index, window) in windows.enumerated() {
                try Task.checkCancellation()
                lease = try await InferenceLease.acquire(at: leaseFile, priority: configuration.inferencePriority)
                guard !closed, let worker else { throw CancellationError() }
                let workerWindow = SpeechTextWindow(text: window.text,
                    source: .init(blockIndices: window.source.blockIndices, location: window.source.location,
                        length: window.source.length, origin: window.source.origin), boundaryAfter: window.boundaryAfter)
                let event = try await worker.request(.init(kind: .prepareText, identity: identity, chunk: index, textWindow: workerWindow))
                guard let reference = event.preparedFile, let spool else { throw SpeechFailure(.protocolViolation) }
                let values = try PreparedSpeechTransfer.read(reference, index: index, spool: spool)
                try FileManager.default.removeItem(at: SpeechIPC.preparationFile(in: spool, index: index))
                for value in values { try value.validate(identity: acousticIdentity, prepared: true) }
                try PreparedSpeechCoverage.validate(values, window: window)
                let mapped = values.map { value in
                    PreparedUtterance(text: value.text, phonemes: value.phonemes, tokenCount: value.tokenCount,
                        source: .init(blockIndices: value.source.blockIndices, location: value.source.location,
                            length: value.source.length, origin: value.source.origin,
                            pronunciationApplications: window.source.pronunciationApplications?.filter {
                                $0.spokenLocation < value.source.location + value.source.length && $0.spokenLocation + $0.spokenLength > value.source.location
                            }), boundaryAfter: value.boundaryAfter, acousticIdentity: value.acousticIdentity)
                }
                utterances.append(contentsOf: mapped)
                lease = nil
                progress(index + 1, windows.count)
            }
            return .init(policy: policy, settings: settings, semanticVersion: projection.version,
                acousticIdentity: acousticIdentity, utterances: utterances, notices: projection.notices, provenance: SpeechAcousticIdentity.provenance(settings: settings, policy: policy))
        } catch { await close(); throw error }
    }

    public func render(plan: PreparedSpeechPlan, destination: URL, outputFormat: AudioOutputFormat = .wav,
                       identity progressIdentity: AttemptIdentity, explicitGap: Double? = nil,
                       beforePublication: @Sendable () throws -> Void = {},
                       progress: @Sendable (SpeechProgress) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        let expected = SpeechAcousticIdentity.make(settings: settings, policy: policy)
        guard ready, !closed, !busy, plan.version == 1, plan.settings == settings, plan.policy == policy,
              plan.acousticIdentity == expected, !plan.utterances.isEmpty,
              explicitGap == nil || (explicitGap!.isFinite && (0...10).contains(explicitGap!)) else { throw SpeechFailure(.invalidInput) }
        for utterance in plan.utterances { try utterance.validate(identity: expected, prepared: policy.usesPreparedPhonemes) }
        busy = true
        defer { busy = false; lease = nil }
        let resolved = try OutputPaths.resolved(destination)
        let writer = try AtomicAudioWriter(destination: resolved, format: outputFormat, mp3Library: configuration.mp3Library)
        defer { writer.abort() }
        let assembler = try ZeroFrameAudioAssembler(writer: writer, sampleRate: settings.model.capabilities.sampleRate)
        progress(.init(identity: progressIdentity, phase: .started, completedChunks: 0, totalChunks: plan.utterances.count))
        do {
            if configuration.inferencePriority == .interactive {
                lease = try await InferenceLease.acquire(at: leaseFile, priority: .interactive)
            }
            for (index, utterance) in plan.utterances.enumerated() {
                if configuration.inferencePriority == .background {
                    lease = try await InferenceLease.acquire(at: leaseFile, priority: .background)
                }
                let samples = try await generateSamples(utterance: utterance)
                let gap = index > 0 && policy.usesStructuralPauses
                    ? NarrationPausePolicy.seconds(after: plan.utterances[index - 1].boundaryAfter, explicitGap: explicitGap) : 0
                try assembler.append(samples: samples, gapBeforeSeconds: gap)
                if configuration.inferencePriority == .background { lease = nil }
                progress(.init(identity: progressIdentity, phase: .chunkWritten,
                    completedChunks: index + 1, totalChunks: plan.utterances.count))
            }
            progress(.init(identity: progressIdentity, phase: .publishing,
                completedChunks: plan.utterances.count, totalChunks: plan.utterances.count))
            try writer.publish {
                try beforePublication()
                guard try OutputPaths.resolved(destination) == resolved,
                      try OutputPaths.resolved(writer.temporary) == writer.temporary else { throw SpeechFailure(.storage) }
                try Task.checkCancellation()
            }
        } catch { await close(); throw error }
    }

    private func generateSamples(utterance: PreparedUtterance) async throws -> [Float] {
        guard policy.usesPreparedPhonemes else { return try await generateSamples(text: utterance.text) }
        try Task.checkCancellation()
        guard !closed, let worker, let spool else { throw CancellationError() }
        let index = nextChunk; nextChunk += 1
        let event = try await worker.request(.init(kind: .generatePrepared, identity: identity, chunk: index, utterance: utterance))
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let samples = try WorkerPCM.read(event, index: index, spool: spool, model: settings.model)
        try FileManager.default.removeItem(at: SpeechIPC.chunkFile(in: spool, index: index))
        return samples
    }

    public func synthesize(text: String, destination: URL) async throws -> NativeSpeechArtifact {
        let projection = try NarrationPlanner.prepareForSpeech(.init(blocks: [.init(kind: .paragraph, text: text)],
            extractorVersion: "direct-speech-1"), settings: settings, policy: policy)
        let plan = try await prepareSpeech(projection)
        try await render(plan: plan, destination: destination, identity: identity)
        let info = try NativeAudio.inspect(destination)
        return NativeSpeechArtifact(url: destination, sampleRate: info.sampleRate, frames: Int(info.frames))
    }

    public func render(chunks: [String], destination: URL, outputFormat: AudioOutputFormat = .wav,
                       identity progressIdentity: AttemptIdentity,
                       beforePublication: @Sendable () throws -> Void = {},
                       progress: @Sendable (SpeechProgress) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        guard ready, !closed, !busy, !policy.usesPreparedPhonemes, !chunks.isEmpty,
              chunks.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.unicodeScalars.count <= 1_000 }) else {
            throw SpeechFailure(.invalidInput)
        }
        // Compatibility for Soprano and archived developer comparisons. There
        // is one rendering/assembly loop; Kokoro's shipping path requires its
        // final prepared plan and cannot bypass G2P or source validation here.
        let projection = NarrationPlan(version: "legacy-direct-chunks-1",
            chunks: chunks.enumerated().map { NarrationChunk(index: $0.offset, text: $0.element, blockIndices: [$0.offset]) }, notices: [])
        let plan = try await prepareSpeech(projection)
        try await render(plan: plan, destination: destination, outputFormat: outputFormat,
            identity: progressIdentity, beforePublication: beforePublication) { value in
                // ChunkScheduler's compatibility API emits started before prepare.
                if value.phase != .started { progress(value) }
            }
    }

    private func generateSamples(text: String) async throws -> [Float] {
        try Task.checkCancellation()
        guard !closed, let worker, let spool else { throw CancellationError() }
        let index = nextChunk
        nextChunk += 1
        let event = try await worker.request(.init(kind: .generate, identity: identity, chunk: index, text: text))
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let samples = try WorkerPCM.read(event, index: index, spool: spool, model: settings.model)
        try FileManager.default.removeItem(at: SpeechIPC.chunkFile(in: spool, index: index))
        return samples
    }

    public func close() async {
        closed = true; ready = false
        // Keeping the reference until stop completes also lets simultaneous
        // close calls join the same reap, before either releases the lease.
        if let worker { await worker.stop() }
        worker = nil
        if let spool { try? FileManager.default.removeItem(at: spool) }
        spool = nil
        lease = nil
    }
}
