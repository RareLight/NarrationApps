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
    /// The actor transfers sole writer/encoder use to an owned CPU queue and
    /// awaits it before touching the state again. It never escapes this render.
    private final class RenderCPUState: @unchecked Sendable {
        let writer: AtomicAudioWriter
        let assembler: ZeroFrameAudioAssembler
        init(writer: AtomicAudioWriter, assembler: ZeroFrameAudioAssembler) { self.writer = writer; self.assembler = assembler }
    }
    private let configuration: WorkerConfiguration
    private let workspace: NativeWorkspace
    private let settings: SpeechSettings
    private let referenceStore: ReferenceVoiceStore
    private let policy: SpeechPreparationPolicy
    private let leaseFile: URL
    private let identity: AttemptIdentity
    private var worker: SpeechWorkerProcess?
    private enum WorkerResources { case speech, preparation(usesInference: Bool), unloaded }
    private var workerResources: WorkerResources?
    private var releasingPreparationAtCheckpoint = false
    private var workerIsPreparationOnly: Bool {
        switch workerResources { case .preparation?, .unloaded?: true; default: false }
    }
    private var workerPreparationUsesInference: Bool {
        if case .preparation(let usesInference)? = workerResources { return usesInference }; return false
    }
    private var storageLease: ModelStorageLease?
    private var spool: URL?
    private var lease: InferenceLease?
    private var nextChunk = 0
    private var busy = false
    private var ready = false
    private var closed = false
    private var workJob: SpeechWorkJob?
    private var workEligible: @Sendable () -> Bool = { true }
    private var workCancelled: @Sendable () -> Bool = { false }
    private var workWaiting: @Sendable (SpeechWorkWait?) -> Void = { _ in }
    private var reviewID: UUID?
    private var reviewPlan: PreparedSpeechPlan?
    private var reviewWritten: Set<Int> = []
    private var reviewBytes: Int64 = 0
    private var reviewTargets: [String: [Int]] = [:]
    private let reviewStore: NarrationReviewStore
    private enum ReviewInput: Sendable { case samples([Float]), artifact(URL) }
    private var reviewTail: (id: UUID, work: Task<Void, Never>)?
    private var reviewWrites: [UUID: Task<Void, Never>] = [:]
    public private(set) var reviewIssue: String?

    public init(configuration: WorkerConfiguration, workspace: URL, settings: SpeechSettings,
                leaseFile: URL = InferenceLease.defaultFile, policy: SpeechPreparationPolicy? = nil, identity: AttemptIdentity = .init(batch: UUID(), job: UUID()), referenceStore: ReferenceVoiceStore = .init(), reviewStore: NarrationReviewStore = .init()) throws {
        guard CPUTextPreparation.validates(configuration.textPreparationWorkers) else { throw SpeechFailure(.invalidInput) }
        self.identity = identity
        self.referenceStore = referenceStore
        self.reviewStore = reviewStore
        var selected = configuration
        if settings.model.isLarge {
            guard settings.isValid else { throw SpeechFailure(.invalidInput) }
            guard SpeechMemoryPolicy.canLoad(settings.model) else { throw SpeechFailure(.memoryLimit) }
            if selected.maximumFootprintBytes == SpeechMemoryPolicy.workerFootprintLimitBytes { selected.maximumFootprintBytes = SpeechMemoryPolicy.footprintLimit(for: settings.model) }
            if selected.requestTimeout == .seconds(180) { selected.requestTimeout = .seconds(900) }
        }
        self.configuration = selected
        self.workspace = try NativeWorkspace(root: workspace)
        var captured = settings; captured.savedChoices = nil
        self.settings = captured
        self.policy = .selected(settings: settings, requested: policy ?? configuration.preparationPolicy)
        self.leaseFile = leaseFile
    }

    /// Batches can prepare storage without loading a helper or speech weights.
    /// Their frontend starts on demand; standalone setup still initializes the
    /// speech model through the default path.
    public func prepare(forTextPreparation: Bool = false) async throws {
        try Task.checkCancellation()
        guard !closed, !busy else { throw SpeechFailure(.invalidInput) }
        if ready { return }
        if configuration.workCoordinator != nil {
            _ = try await coordinatedJob()
            guard !closed else { throw CancellationError() }
            ready = true; return
        }
        busy = true
        defer { busy = false; lease = nil }
        do {
            storageLease = try ModelStorageLease(workspace: workspace)
            let parent = try workspace.managed(workspace.nativeRoot.appendingPathComponent("staging"))
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let staging = try workspace.managed(parent.appendingPathComponent("attempt-\(identity.attempt.uuidString)"))
            guard mkdir(staging.path, 0o700) == 0 else { throw SpeechFailure(.storage) }
            spool = staging
            if settings.model == .chatterbox, ReferenceVoiceStore.isIdentifier(settings.voice) {
                try referenceStore.bytes(for: settings.voice).write(to: staging.appendingPathComponent("reference.wav"), options: [.withoutOverwriting])
            }
            if forTextPreparation {
                ready = true
                return
            }
            lease = try await InferenceLease.acquire(at: leaseFile, priority: configuration.inferencePriority)
            guard !closed else { throw CancellationError() }
            let owned = try SpeechWorkerProcess(configuration: configuration, identity: identity)
            worker = owned
            _ = try await owned.request(.init(kind: .initialize, identity: identity, workspace: workspace.root,
                settings: settings, spoolDirectory: staging, policy: policy))
            guard !closed else { throw CancellationError() }
            workerResources = .speech
            ready = true
            if settings.model.isLarge { await releaseLargeWorker() }
            guard !closed else { throw CancellationError() }
        } catch {
            await close()
            throw error
        }
    }

    /// New logical document, same app-owned model host. Call before preparation.
    public func configureWork(identity: AttemptIdentity, recovery: SpeechRenderJournal.Recovery? = nil,
                              eligible: @escaping @Sendable () -> Bool = { true },
                              cancelled: @escaping @Sendable () -> Bool = { false },
                              waiting: @escaping @Sendable (SpeechWorkWait?) -> Void = { _ in }) async throws {
        guard !closed, !busy else { throw SpeechFailure(.invalidInput) }
        guard let coordinator = configuration.workCoordinator else { return }
        busy = true
        defer { busy = false }
        await reviewTail?.work.value
        guard !closed, !Task.isCancelled else { throw CancellationError() }
        workEligible = eligible; workCancelled = cancelled; workWaiting = waiting
        nextChunk = 0
        let old = workJob
        let opened = try await coordinator.openJob(identity: identity, settings: settings, workspace: workspace.root,
            rank: configuration.inferencePriority == .interactive ? .libro : .podcast,
            lastEpoch: recovery?.lastEpoch ?? 0, verified: recovery?.indices ?? [], eligible: eligible, cancelled: cancelled, waiting: waiting)
        guard !closed, !Task.isCancelled else { await coordinator.closeJob(opened); throw CancellationError() }
        workJob = opened
        if let old { await coordinator.closeJob(old) }
        guard !closed else { throw CancellationError() }
    }
    private func coordinatedJob() async throws -> SpeechWorkJob {
        if let workJob { return workJob }
        try await configureWork(identity: identity, eligible: workEligible, cancelled: workCancelled, waiting: workWaiting)
        guard let workJob else { throw SpeechFailure(.invalidInput) }
        return workJob
    }

    /// The caller validates/persists the returned artifact, then commits its
    /// receipt. Generation alone must not advance a durable podcast checkpoint.
    public func generateForCheckpoint(_ utterance: PreparedUtterance) async throws -> (job: SpeechWorkJob, result: SpeechUnitResult) {
        try Task.checkCancellation()
        guard ready, !closed, !busy, let coordinator = configuration.workCoordinator else { throw SpeechFailure(.invalidInput) }
        try utterance.validate(identity: SpeechAcousticIdentity.make(settings: settings, policy: policy), prepared: policy.usesPreparedPhonemes)
        let job = try await coordinatedJob()
        busy = true; defer { busy = false }
        let payload = PreparedUtterance(text: utterance.text, phonemes: utterance.phonemes, tokenCount: utterance.tokenCount,
            source: .init(blockIndices: utterance.source.blockIndices, location: utterance.source.location,
                length: utterance.source.length, origin: utterance.source.origin),
            boundaryAfter: utterance.boundaryAfter, acousticIdentity: utterance.acousticIdentity)
        let result = try await coordinator.perform(.generate(payload, policy), job: job)
        guard !closed, !Task.isCancelled else { job.discardResult(result); throw CancellationError() }
        return (job, result)
    }
    /// Release this article's demand after all validation has joined. A late end
    /// cannot close a different article that has already acquired the session.
    public func finishWork(identity: AttemptIdentity) async {
        guard let owned = workJob, owned.identity == identity else { return }
        await configuration.workCoordinator?.closeJob(owned)
        if workJob === owned { workJob = nil }
    }
    /// Called only after the owning store commits a validated, closed artifact.
    /// Optional review material never serves as the durable checkpoint itself.
    public func retainCommittedReview(_ utterance: PreparedUtterance, artifact: URL) async {
        guard !closed, settings.retainReview == true, reviewID != nil, reviewPlan != nil else { return }
        await retainReview(utterance, input: .artifact(artifact))
    }
    private func retainReviewSamples(_ utterance: PreparedUtterance, samples: [Float]) async {
        await retainReview(utterance, input: .samples(samples))
    }
    private func retainReview(_ utterance: PreparedUtterance, input: ReviewInput) async {
        guard !closed, reviewID != nil else { return }
        let previous = reviewTail?.work, id = UUID()
        // Serialize optional writes without blocking a queue/actor behind a
        // paused writer. Generation and cancellation remain independently owned.
        let work = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await persistReview(utterance, input: input)
        }
        reviewTail = (id, work); reviewWrites[id] = work
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        reviewWrites.removeValue(forKey: id)
        if reviewTail?.id == id { reviewTail = nil }
    }
    private func persistReview(_ utterance: PreparedUtterance, input: ReviewInput) async {
        guard !closed, let id = reviewID, let plan = reviewPlan,
              let target = reviewTargets[utterance.fingerprint]?.first(where: { !reviewWritten.contains($0) }) else { return }
        let store = reviewStore, existingBytes = reviewBytes
        do {
            let frames = try await ownedCPU {
                let samples: [Float]
                switch input {
                case .samples(let values): samples = values
                case .artifact(let artifact):
                    var values: [Float] = []
                    try NativeAudio.decode(artifact) { values.append(contentsOf: $0) }
                    samples = values
                }
                try store.record(id, index: target, samples: samples, plan: plan, existingBytes: existingBytes)
                return samples.count
            }
            guard !closed, reviewID == id else { return }
            reviewWritten.insert(target); reviewBytes += Int64(frames) * 4
        } catch {
            if !closed, reviewID == id { reviewIssue = "Some review chunks could not be retained. Generated audio is unchanged." }
        }
    }
    private func ownedCPU<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        if let workJob { return try await SpeechCPUWork.run(job: workJob, operation: operation) }
        guard configuration.workCoordinator == nil, !closed else { throw CancellationError() }
        return try operation()
    }

    /// One authoritative preparation boundary shared by adapters and developer
    /// tools. Only the lightweight frontend is loaded for a cold session;
    /// downloading and global text caching are never implicit.
    public func prepareSpeech(_ projection: NarrationPlan,
        checkpoint: (@Sendable () async throws -> Void)? = nil,
        progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> PreparedSpeechPlan {
        try Task.checkCancellation()
        guard ready, !closed, !busy, !projection.chunks.isEmpty else { throw SpeechFailure(.invalidInput) }
        let acousticIdentity = SpeechAcousticIdentity.make(settings: settings, policy: policy)
        guard projection.version.hasSuffix("/spoken-projection-1") else {
            throw SpeechFailure(.invalidInput)
        }
        if configuration.workCoordinator != nil { _ = try await coordinatedJob() }
        guard !closed, !busy, !Task.isCancelled else { throw CancellationError() }
        busy = true
        defer { busy = false; lease = nil }
        do {
            let windows = try await ownedCPU { try SpeechTextWindows.boundedForControl(SpeechTextWindows.make(from: projection)) }
            var utterances: [PreparedUtterance] = []
            progress(0, windows.count)
            for (index, window) in windows.enumerated() {
                try Task.checkCancellation()
                if workerPreparationUsesInference,
                   try InferenceLease.shouldYield(at: leaseFile, priority: configuration.inferencePriority) {
                    try await releasePreparationResources(); lease = nil
                }
                try await preparationCheckpoint(checkpoint)
                let needsInference = settings.model == .kokoro || (worker != nil && !workerIsPreparationOnly)
                if configuration.workCoordinator == nil, needsInference, lease == nil {
                    lease = try await InferenceLease.acquire(at: leaseFile, priority: configuration.inferencePriority)
                    guard !closed else { throw CancellationError() }
                }
                if configuration.workCoordinator == nil, worker == nil {
                    guard let spool else { throw SpeechFailure(.storage) }
                    let owned = try SpeechWorkerProcess(configuration: configuration, identity: identity)
                    worker = owned
                    let ready = try await owned.request(.init(kind: .initialize, identity: identity, workspace: workspace.root,
                        settings: settings, spoolDirectory: spool, policy: policy, textPreparationOnly: true))
                    try acceptPreparation(ready)
                }
                if case .unloaded? = workerResources, let worker {
                    try acceptPreparation(try await worker.request(.init(kind: .loadPreparation, identity: identity)))
                }
                let workerWindow = SpeechTextWindow(text: window.text,
                    source: .init(blockIndices: window.source.blockIndices, location: window.source.location,
                        length: window.source.length, origin: window.source.origin,
                        pronunciationApplications: window.source.pronunciationApplications?.filter { $0.phonemes != nil }), boundaryAfter: window.boundaryAfter)
                let values: [PreparedUtterance]
                if let coordinator = configuration.workCoordinator {
                    let job = try await coordinatedJob()
                    let result = try await coordinator.perform(.prepare(workerWindow, policy, workers: configuration.textPreparationWorkers), job: job)
                    guard case .prepared(let prepared) = result.value else { throw SpeechFailure(.protocolViolation) }
                    values = prepared
                } else {
                    guard let worker else { throw CancellationError() }
                    let event = try await worker.request(.init(kind: .prepareText, identity: identity, chunk: index, textWindow: workerWindow, textPreparationWorkers: configuration.textPreparationWorkers))
                    guard let reference = event.preparedFile, let spool else { throw SpeechFailure(.protocolViolation) }
                    values = try PreparedSpeechTransfer.read(reference, index: index, spool: spool)
                    try FileManager.default.removeItem(at: SpeechIPC.preparationFile(in: spool, index: index))
                }
                let usesPreparedPhonemes = policy.usesPreparedPhonemes
                let mapped = try await ownedCPU {
                    try PreparedSpeechCoverage.validate(values, window: window)
                    return try values.map { value in
                        try NarrationWorkCheckpoint.check()
                        try value.validate(identity: acousticIdentity, prepared: usesPreparedPhonemes)
                        return PreparedUtterance(text: value.text, phonemes: value.phonemes, tokenCount: value.tokenCount,
                            source: .init(blockIndices: value.source.blockIndices, location: value.source.location,
                                length: value.source.length, origin: value.source.origin,
                                pronunciationApplications: window.source.pronunciationApplications?.filter {
                                    $0.spokenLocation < value.source.location + value.source.length && $0.spokenLocation + $0.spokenLength > value.source.location
                                }, sourceMappings: ProjectionMapping.intersecting(window.source.sourceMappings, location: value.source.location, length: value.source.length)), boundaryAfter: value.boundaryAfter, acousticIdentity: value.acousticIdentity)
                    }
                }
                utterances.append(contentsOf: mapped)
                if settings.model.isLarge && !workerIsPreparationOnly { await releaseLargeWorker() }
                guard !closed else { throw CancellationError() }
                if !workerPreparationUsesInference { lease = nil }
                progress(index + 1, windows.count)
            }
            if workerPreparationUsesInference { try await releasePreparationResources(); lease = nil }
            guard !closed, !Task.isCancelled else { throw CancellationError() }
            return try await captureReview(.init(policy: policy, settings: settings, semanticVersion: projection.version,
                acousticIdentity: acousticIdentity, utterances: utterances, notices: projection.notices, provenance: SpeechAcousticIdentity.provenance(settings: settings, policy: policy), documentTitle: projection.documentTitle))
        } catch { await close(); throw error }
    }

    public func render(plan: PreparedSpeechPlan, destination: URL, outputFormat: AudioOutputFormat = .wav, replaceExisting: Bool = true, coverArtwork: CoverArtwork? = nil,
                       identity progressIdentity: AttemptIdentity, explicitGap: Double? = nil,
                       recovery: SpeechRenderJournal? = nil,
                       checkpoint: (@Sendable () async throws -> Void)? = nil,
                       beforePublication: @escaping @Sendable () throws -> Void = {},
                       progress: @Sendable (SpeechProgress) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        let expected = SpeechAcousticIdentity.make(settings: settings, policy: policy)
        guard ready, !closed, !busy, plan.version == 1, plan.settings == settings, plan.policy == policy,
              plan.acousticIdentity == expected, !plan.utterances.isEmpty,
              explicitGap == nil || (explicitGap!.isFinite && (0...10).contains(explicitGap!)) else { throw SpeechFailure(.invalidInput) }
        for utterance in plan.utterances { try utterance.validate(identity: expected, prepared: policy.usesPreparedPhonemes) }
        if let recovery {
            guard configuration.workCoordinator != nil, recovery.request.plan == plan,
                  recovery.request.destination == destination, recovery.request.format == outputFormat,
                  recovery.request.replaceExisting == replaceExisting, recovery.request.explicitGap == explicitGap,
                  recovery.request.artworkDigest == coverArtwork?.digest else { throw SpeechFailure(.invalidInput) }
            try await configureWork(identity: recovery.request.identity, recovery: recovery.recovery,
                eligible: workEligible, cancelled: workCancelled, waiting: workWaiting)
        }
        if configuration.workCoordinator != nil { _ = try await coordinatedJob() }
        try Task.checkCancellation()
        guard !closed, !busy else { throw CancellationError() }
        busy = true
        defer { busy = false; lease = nil }
        if recovery != nil, reviewPlan == nil { _ = try await captureReview(plan) }
        guard !closed, !Task.isCancelled else { throw CancellationError() }
        let commitBase = nextChunk
        if configuration.workCoordinator != nil { nextChunk += plan.utterances.count }
        let resolved = try OutputPaths.resolved(destination)
        let writer = try AtomicAudioWriter(destination: resolved, format: outputFormat, mp3Library: configuration.mp3Library, coverArtwork: coverArtwork)
        defer { writer.abort() }
        let assembler = try ZeroFrameAudioAssembler(writer: writer, sampleRate: settings.model.capabilities.sampleRate)
        let cpuState = RenderCPUState(writer: writer, assembler: assembler)
        progress(.init(identity: progressIdentity, phase: .started, completedChunks: 0, totalChunks: plan.utterances.count))
        do {
            if configuration.workCoordinator == nil, configuration.inferencePriority == .interactive {
                lease = try await InferenceLease.acquire(at: leaseFile, priority: .interactive)
            }
            for (index, utterance) in plan.utterances.enumerated() {
                if let checkpoint {
                    lease = nil
                    try await checkpoint()
                    if configuration.workCoordinator == nil, configuration.inferencePriority == .interactive {
                        lease = try await InferenceLease.acquire(at: leaseFile, priority: .interactive)
                    }
                }
                if configuration.workCoordinator == nil, configuration.inferencePriority == .background {
                    lease = try await InferenceLease.acquire(at: leaseFile, priority: .background)
                }
                let samples: [Float]
                let restored: [Float]?
                if let workJob {
                    restored = try await SpeechCPUWork.run(job: workJob) { try recovery?.samples(index: index) }
                } else { restored = try recovery?.samples(index: index) }
                if let restored { samples = restored }
                else if let coordinator = configuration.workCoordinator {
                    let job = try await coordinatedJob()
                    samples = try await coordinatedSamples(utterance, index: recovery == nil ? commitBase + index : index,
                        coordinator: coordinator, job: job, recovery: recovery)
                } else { samples = try await generateSamples(utterance: utterance) }
                if let coordinator = configuration.workCoordinator, let workJob {
                    try await coordinator.waitForAdmission(job: workJob)
                }
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                await retainReviewSamples(utterance, samples: samples)
                let gap = index > 0 && policy.usesStructuralPauses
                    ? NarrationPausePolicy.seconds(after: plan.utterances[index - 1].boundaryAfter, explicitGap: explicitGap) : 0
                if let workJob {
                    try await SpeechCPUWork.run(job: workJob) { try cpuState.assembler.append(samples: samples, gapBeforeSeconds: gap) }
                } else { try assembler.append(samples: samples, gapBeforeSeconds: gap) }
                if configuration.inferencePriority == .background { lease = nil }
                progress(.init(identity: progressIdentity, phase: .chunkWritten,
                    completedChunks: index + 1, totalChunks: plan.utterances.count))
            }
            lease = nil
            if let checkpoint { try await checkpoint() }
            if let coordinator = configuration.workCoordinator, let workJob {
                try await coordinator.waitForAdmission(job: workJob)
            }
            progress(.init(identity: progressIdentity, phase: .publishing,
                completedChunks: plan.utterances.count, totalChunks: plan.utterances.count))
            lease = nil
            try await writer.prepareArtwork()
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            let publish: @Sendable () throws -> Void = {
                try cpuState.writer.publish(replaceExisting: replaceExisting) {
                    try beforePublication()
                    guard try OutputPaths.resolved(destination) == resolved,
                          try OutputPaths.resolved(cpuState.writer.temporary) == cpuState.writer.temporary else { throw SpeechFailure(.storage) }
                    try AudioWorkCheckpoint.check()
                }
            }
            if let workJob { try await SpeechCPUWork.run(job: workJob, operation: publish) }
            else { try publish() }
        } catch { await close(); throw error }
    }

    private func coordinatedSamples(_ utterance: PreparedUtterance, index: Int, coordinator: SpeechWorkCoordinator,
                                    job: SpeechWorkJob, recovery: SpeechRenderJournal?) async throws -> [Float] {
        // Keep rich projection maps on the host, just as normal serving does.
        let payload = PreparedUtterance(text: utterance.text, phonemes: utterance.phonemes, tokenCount: utterance.tokenCount,
            source: .init(blockIndices: utterance.source.blockIndices, location: utterance.source.location,
                length: utterance.source.length, origin: utterance.source.origin),
            boundaryAfter: utterance.boundaryAfter, acousticIdentity: utterance.acousticIdentity)
        while true {
            try Task.checkCancellation()
            let result = try await coordinator.perform(.generate(payload, policy), job: job)
            defer { job.discardResult(result) }
            guard !closed, case .audio(let samples) = result.value else { throw CancellationError() }
            let staged = try await SpeechCPUWork.run(job: job) {
                try recovery?.stage(index: index, samples: samples, token: result.token)
            }
            defer { if let staged { recovery?.discard(staged) } }
            if try job.commit(result, index: index, operation: { if let staged { try recovery?.commit(staged) } }) {
                return samples
            }
        }
    }

    private func generateSamples(utterance: PreparedUtterance) async throws -> [Float] {
        guard policy.usesPreparedPhonemes else { return try await generateSamples(text: utterance.text) }
        try Task.checkCancellation()
        guard !closed, let spool else { throw CancellationError() }
        let worker = try await speechWorker()
        let index = nextChunk; nextChunk += 1
        // Projection/dictionary maps belong to host checkpoints and previews.
        // The helper consumes exact validated phonemes, not presentation metadata.
        // Keep the control record bounded even for densely mapped Unicode text.
        let payload = PreparedUtterance(text: utterance.text, phonemes: utterance.phonemes, tokenCount: utterance.tokenCount,
            source: .init(blockIndices: utterance.source.blockIndices, location: utterance.source.location,
                length: utterance.source.length, origin: utterance.source.origin),
            boundaryAfter: utterance.boundaryAfter, acousticIdentity: utterance.acousticIdentity)
        let event = try await worker.request(.init(kind: .generatePrepared, identity: identity, chunk: index, utterance: payload))
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let samples = try WorkerPCM.read(event, index: index, spool: spool, model: settings.model)
        try FileManager.default.removeItem(at: SpeechIPC.chunkFile(in: spool, index: index))
        return samples
    }

    private func captureReview(_ plan: PreparedSpeechPlan) async throws -> PreparedSpeechPlan {
        await reviewTail?.work.value
        guard !closed, !Task.isCancelled else { throw CancellationError() }
        reviewID = nil; reviewPlan = nil; reviewWritten = []; reviewBytes = 0; reviewTargets = [:]; reviewIssue = nil
        if settings.retainReview == true {
            do {
                let store = reviewStore
                let captured = try await ownedCPU {
                    let targets = try Dictionary(grouping: plan.utterances.indices, by: { index in
                        try NarrationWorkCheckpoint.check(); return plan.utterances[index].fingerprint
                    })
                    return (try store.begin(plan: plan), targets)
                }
                guard !closed else { throw CancellationError() }
                reviewID = captured.0; reviewPlan = plan; reviewTargets = captured.1
            }
            catch is CancellationError { throw CancellationError() }
            catch { reviewIssue = "Narration review could not be retained. Generated audio is unchanged." }
        }
        return plan
    }

    /// Explicit selective repair. The session's captured model/voice and validated
    /// preparation identity still apply; no fallback or automatic retry occurs.
    public func renderReviewChunk(_ utterance: PreparedUtterance) async throws -> [Float] {
        try Task.checkCancellation()
        guard ready, !closed, !busy else { throw SpeechFailure(.invalidInput) }
        try utterance.validate(identity: SpeechAcousticIdentity.make(settings: settings, policy: policy), prepared: policy.usesPreparedPhonemes)
        if configuration.workCoordinator != nil { _ = try await coordinatedJob() }
        guard !closed, !busy, !Task.isCancelled else { throw CancellationError() }
        busy = true
        defer { busy = false; lease = nil }
        if let coordinator = configuration.workCoordinator {
            let job = try await coordinatedJob()
            let index = nextChunk; nextChunk += 1
            do { return try await coordinatedSamples(utterance, index: index, coordinator: coordinator, job: job, recovery: nil) }
            catch { await close(); throw error }
        }
        lease = try await InferenceLease.acquire(at: leaseFile, priority: configuration.inferencePriority)
        do { return try await generateSamples(utterance: utterance) }
        catch { await close(); throw error }
    }

    public func synthesize(text: String, destination: URL) async throws -> NativeSpeechArtifact {
        try Task.checkCancellation()
        guard ready, !closed, !busy else { throw SpeechFailure(.invalidInput) }
        if configuration.workCoordinator != nil { _ = try await coordinatedJob() }
        let settings = self.settings, policy = self.policy
        let projection = try await ownedCPU {
            try NarrationPlanner.prepareForSpeech(.init(blocks: [.init(kind: .paragraph, text: text, origin: .authored)],
                extractorVersion: "direct-speech-1"), settings: settings, policy: policy)
        }
        let plan = try await prepareSpeech(projection)
        try await render(plan: plan, destination: destination, identity: identity)
        let info = try await ownedCPU { try NativeAudio.inspect(destination) }
        return NativeSpeechArtifact(url: destination, sampleRate: info.sampleRate, frames: Int(info.frames))
    }

    public func render(chunks: [String], destination: URL, outputFormat: AudioOutputFormat = .wav, replaceExisting: Bool = true, coverArtwork: CoverArtwork? = nil,
                       identity progressIdentity: AttemptIdentity,
                       beforePublication: @escaping @Sendable () throws -> Void = {},
                       progress: @Sendable (SpeechProgress) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        guard ready, !closed, !busy, !policy.usesPreparedPhonemes, !chunks.isEmpty,
              chunks.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.unicodeScalars.count <= 1_000 }) else {
            throw SpeechFailure(.invalidInput)
        }
        // Compatibility for Soprano and archived developer comparisons. There
        // is one rendering/assembly loop; Kokoro's shipping path requires its
        // final prepared plan and cannot bypass G2P or source validation here.
        if configuration.workCoordinator != nil { _ = try await coordinatedJob() }
        let settings = self.settings, policy = self.policy
        let projection = try await ownedCPU {
            try NarrationPlanner.prepareForSpeech(.init(blocks: chunks.map {
                .init(kind: .paragraph, text: $0, origin: .authored)
            }, extractorVersion: "direct-chunks-1"), settings: settings, policy: policy)
        }
        let plan = try await prepareSpeech(projection)
        try await render(plan: plan, destination: destination, outputFormat: outputFormat, replaceExisting: replaceExisting, coverArtwork: coverArtwork,
            identity: progressIdentity, beforePublication: beforePublication) { value in
                // ChunkScheduler's compatibility API emits started before prepare.
                if value.phase != .started { progress(value) }
            }
    }

    private func acceptPreparation(_ event: WorkerEvent) throws {
        guard event.textPreparationOnly == true, event.preparationReleased != true,
              let usesInference = event.preparationUsesInference,
              usesInference == (settings.model == .kokoro) else { throw SpeechFailure(.incompatibleWorker) }
        workerResources = .preparation(usesInference: usesInference)
        configuration.debugLog?.record("Text preparation: speech weights deferred; model=\(settings.model.rawValue) neuralFrontend=\(usesInference) maximumCPUWorkers=\(configuration.textPreparationWorkers)")
    }
    private func releasePreparationResources() async throws {
        guard let worker, workerIsPreparationOnly else { return }
        let released = try await worker.request(.init(kind: .releasePreparation, identity: identity))
        guard released.preparationReleased == true, released.textPreparationOnly == true,
              released.preparationUsesInference == false else { throw SpeechFailure(.incompatibleWorker) }
        workerResources = .unloaded
    }
    private func preparationCheckpoint(_ checkpoint: (@Sendable () async throws -> Void)?) async throws {
        guard let checkpoint else { return }
        guard workerPreparationUsesInference else { try await checkpoint(); return }
        // Immediate checkpoints keep the small G2P frontend warm. A checkpoint
        // that actually waits (Pause or another gate) drops neural resources
        // before releasing inference exclusion, while retaining the helper PID.
        let monitor = Task<Void, Error> { [self] in
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            guard !Task.isCancelled, !closed else { return }
            releasingPreparationAtCheckpoint = true
            defer { releasingPreparationAtCheckpoint = false }
            try await releasePreparationResources(); lease = nil
        }
        do {
            try await checkpoint()
            if !releasingPreparationAtCheckpoint { monitor.cancel() }
            try await withTaskCancellationHandler { try await monitor.value } onCancel: { monitor.cancel() }
        } catch {
            monitor.cancel(); _ = await monitor.result; throw error
        }
    }
    private func speechWorker() async throws -> SpeechWorkerProcess {
        try Task.checkCancellation()
        guard !closed, let spool else { throw CancellationError() }
        if let worker, workerIsPreparationOnly {
            let loaded = try await worker.request(.init(kind: .loadSpeech, identity: identity))
            guard loaded.textPreparationOnly == false, loaded.preparationUsesInference == true else { throw SpeechFailure(.incompatibleWorker) }
            workerResources = .speech
        } else if worker == nil {
            let owned = try SpeechWorkerProcess(configuration: configuration, identity: identity)
            worker = owned
            _ = try await owned.request(.init(kind: .initialize, identity: identity, workspace: workspace.root,
                settings: settings, spoolDirectory: spool, policy: policy))
            workerResources = .speech
        }
        guard !closed, let worker else { throw CancellationError() }
        return worker
    }

    private func releaseLargeWorker() async {
        // Keep the worker visible during the await so concurrent close calls
        // join this same reap before removing scratch or releasing admission.
        let owned = worker
        await owned?.stop()
        worker = nil; workerResources = nil
    }

    private func generateSamples(text: String) async throws -> [Float] {
        try Task.checkCancellation()
        guard !closed, let spool else { throw CancellationError() }
        let worker = try await speechWorker()
        let index = nextChunk
        nextChunk += 1
        let event = try await worker.request(.init(kind: .generate, identity: identity, chunk: index, text: text))
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let samples = try WorkerPCM.read(event, index: index, spool: spool, model: settings.model)
        try FileManager.default.removeItem(at: SpeechIPC.chunkFile(in: spool, index: index))
        if settings.model.isLarge { await releaseLargeWorker() }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        return samples
    }

    public func close() async {
        closed = true; ready = false
        reviewWrites.values.forEach { $0.cancel() }
        await reviewTail?.work.value
        reviewWrites.removeAll(); reviewTail = nil
        if let workJob { await configuration.workCoordinator?.closeJob(workJob) }
        workJob = nil
        // Keeping the reference until stop completes also lets simultaneous
        // close calls join the same reap, before either releases the lease.
        if let worker { await worker.stop() }
        worker = nil; workerResources = nil
        if let spool { try? FileManager.default.removeItem(at: spool) }
        spool = nil
        lease = nil
        storageLease = nil
    }
}
