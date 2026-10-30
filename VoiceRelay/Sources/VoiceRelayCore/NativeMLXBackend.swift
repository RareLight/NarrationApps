import Foundation
import Pronunciation
import NarrationCore
import NativeSpeech
import ProcessingPipeline

/// The retained VoiceRelay queue contract is synchronous and runs off the UI
/// actor. This adapter joins a detached async operation while preserving caller
/// cancellation; model loading, IPC, artifacts and supervision are shared.
final class NativeOperationBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var tasks: [UUID: Task<Void, Never>] = [:]

    private final class ResultBox<Value: Sendable>: @unchecked Sendable {
        let lock = NSLock()
        var result: Result<Value, any Error>?
        func set(_ value: Result<Value, any Error>) { lock.withLock { result = value } }
        func get() throws -> Value { try lock.withLock { try result!.get() } }
    }

    func run<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) throws -> Value {
        try Task.checkCancellation()
        let box = ResultBox<Value>(), done = DispatchSemaphore(value: 0), token = UUID()
        let task = try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            let task = Task.detached {
                do { box.set(.success(try await operation())) }
                catch { box.set(.failure(error)) }
                done.signal()
            }
            tasks[token] = task
            return task
        }
        defer { _ = lock.withLock { tasks.removeValue(forKey: token) } }
        while done.wait(timeout: .now() + 0.02) == .timedOut {
            if Task.isCancelled { task.cancel() }
        }
        try Task.checkCancellation()
        return try box.get()
    }

    func cancel() { lock.withLock { cancelled = true; tasks.values.forEach { $0.cancel() } } }
}

public final class NativeMLXBackend: PreparedTTSBackend, Sendable {
    public let pronunciations: PronunciationDictionary
    public let identity: BackendIdentity
    private let session: NativeSpeechSession
    private let bridge = NativeOperationBridge()
    private let voice: String
    private let speed: Double
    public let speechSettings: SpeechSettings
    private let policy: SpeechPreparationPolicy
    public var preparationPurpose: NarrationPlanPurpose { .speechPreparation }
    public let narrationVersion: String
    private let gapSeconds: Double?

    public convenience init(configuration: KokoroConfiguration, worker: WorkerConfiguration? = nil, pronunciations: PronunciationDictionary = .empty, policy: SpeechPreparationPolicy = .current, gapSeconds: Double? = nil, narrationOptions: NarrationOptions = .init()) throws {
        try self.init(configuration: NativeSpeechConfiguration(projectRoot: configuration.projectRoot,
            settings: .init(voice: configuration.voice, speed: Float(configuration.speed)), synthesisTimeout: configuration.synthesisTimeout),
            worker: worker, pronunciations: pronunciations, policy: policy, gapSeconds: gapSeconds, narrationOptions: narrationOptions)
    }

    public init(configuration: NativeSpeechConfiguration, worker: WorkerConfiguration? = nil, pronunciations: PronunciationDictionary = .empty, policy requestedPolicy: SpeechPreparationPolicy = .current, gapSeconds: Double? = nil, narrationOptions: NarrationOptions = .init()) throws {
        let settings = configuration.settings
        let policy = SpeechPreparationPolicy.selected(settings: settings, requested: requestedPolicy)
        self.pronunciations = pronunciations; voice = settings.voice; speed = Double(settings.speed)
        speechSettings = settings; self.policy = policy; self.gapSeconds = gapSeconds
        narrationVersion = Narration.version(settings: settings, pronunciations: pronunciations, options: narrationOptions) + "/native-preparation-1/" + SpeechAcousticIdentity.make(settings: settings, policy: policy)
        let selected = worker ?? WorkerConfiguration(executable: NativeSpeechSetup.workerExecutable,
                                                      requestTimeout: .seconds(configuration.synthesisTimeout), inferencePriority: .background)
        session = try NativeSpeechSession(configuration: selected, workspace: configuration.projectRoot,
                                          settings: settings, leaseFile: selected.inferenceLeaseFile, policy: policy)
        let catalog = NativePrimaryCatalog.specification(for: settings.model)
        let fingerprint = ([settings.model == .kokoro ? "swift-mlx-kokoro-v2" : "swift-mlx-" + settings.model.rawValue + "-v1", catalog.revision, NarrationOptions.acousticCompatibleVersion(narrationVersion)] + (pronunciations.fingerprint.isEmpty ? [] : [pronunciations.fingerprint])).joined(separator: "\n")
        identity = BackendIdentity(id: (settings.model == .kokoro ? "native-kokoro-v2-" : "native-" + settings.model.rawValue + "-v1-") + Files.hash(Data(fingerprint.utf8)),
                                   displayName: settings.model.label + " via native Swift MLX", isMock: false)
    }

    public func prepare() throws { try bridge.run { [session] in try await session.prepare() } }
    public func prepareNarration(_ projection: NarrationPlan) throws -> NarrationPlan {
        let plan = try bridge.run { [session] in
            try await session.prepare()
            return try await session.prepareSpeech(projection)
        }
        return NarrationPlan(version: narrationVersion, chunks: plan.utterances.enumerated().map {
            .init(index: $0.offset, text: $0.element.text, blockIndices: $0.element.source.blockIndices,
                boundaryAfter: $0.element.boundaryAfter, origin: $0.element.source.origin, preparedUtterance: $0.element, sourceMappings: $0.element.source.sourceMappings)
        }, notices: plan.notices, omissions: projection.omissions, documentTitle: projection.documentTitle)
    }

    public func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        guard (request.voice ?? voice) == voice, (speechSettings.model == .kokoro ? ["en-US", "en-GB"].contains(request.language) : request.language == speechSettings.languageCode),
              request.settings["speed"] == nil || request.settings["speed"]?.numericValue.map({ Float($0) == Float(speed) }) == true else {
            throw RelayError.setup("The speech request does not match its prepared native voice and speed.")
        }
        try Files.directory(directory)
        let destination = directory.appendingPathComponent("\(UUID().uuidString).wav")
        guard let utterance = request.preparedUtterance else {
            throw RelayError.setup("This unfinished narration needs preparation with the current speech engine before it can resume.")
        }
        let identity = SpeechAcousticIdentity.make(settings: speechSettings, policy: policy)
        try utterance.validate(identity: identity, prepared: policy.usesPreparedPhonemes)
        guard utterance.text == request.text, utterance.source.blockIndices == request.blockIndices else {
            throw RelayError.setup("The saved speech chunk does not match its prepared source.")
        }
        let plan = PreparedSpeechPlan(policy: policy, settings: speechSettings, semanticVersion: narrationVersion,
            acousticIdentity: identity, utterances: [utterance], notices: [], provenance: SpeechAcousticIdentity.provenance(settings: speechSettings, policy: policy))
        try bridge.run { [session] in
            try await session.render(plan: plan, destination: destination, identity: .init(batch: UUID(), job: UUID()))
        }
        let gap = policy.usesStructuralPauses ? NarrationPausePolicy.seconds(after: utterance.boundaryAfter, explicitGap: gapSeconds) : nil
        return SynthesisResult(artifacts: [.init(url: destination, sampleRate: speechSettings.model.capabilities.sampleRate, channels: 1,
            format: "wav", gapAfterSeconds: gap, assemblyPolicy: policy.usesStructuralPauses ? NarrationPausePolicy.candidateVersion : nil)])
    }

    /// Assembly belongs to the captured episode, independently of the reused
    /// helper and lossless chunk checkpoints. Only prepared structural results
    /// carry enough evidence to reconstruct their request-final boundary.
    static func assemblyArtifacts(for request: SynthesisRequest, result: SynthesisResult,
                                  gapSeconds: Double) -> [LosslessArtifact] {
        guard let utterance = request.preparedUtterance, !result.artifacts.isEmpty,
              result.artifacts.allSatisfy({ $0.assemblyPolicy == NarrationPausePolicy.candidateVersion &&
                  $0.gapAfterSeconds?.isFinite == true && (0...10).contains($0.gapAfterSeconds!) }) else {
            return result.artifacts
        }
        return result.artifacts.enumerated().map { index, original in
            var artifact = original
            if gapSeconds == 0 {
                artifact.gapAfterSeconds = 0
            } else if index == result.artifacts.count - 1 {
                artifact.gapAfterSeconds = NarrationPausePolicy.seconds(after: utterance.boundaryAfter, explicitGap: gapSeconds)
            } else {
                // Interior artifact boundaries have no separate source evidence;
                // retain their structural schedule and the episode's minimum gap.
                artifact.gapAfterSeconds = max(original.gapAfterSeconds!, gapSeconds)
            }
            return artifact
        }
    }

    public func cancel() {
        bridge.cancel()
        // This joins the owned helper even when the queue task is cancelled.
        let joined = DispatchSemaphore(value: 0)
        Task.detached { [session] in await session.close(); joined.signal() }
        joined.wait()
    }
    deinit {
        bridge.cancel()
        Task.detached { [session] in await session.close() }
    }
}
