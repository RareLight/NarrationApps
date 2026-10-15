import Pronunciation
import NarrationCore
import Foundation

public enum SpeechTimingStage: String, Sendable {
    case preparation, speech, pronunciation, inference, wavWrite = "WAV write"
    case validation, checkpoint, pcmAssembly = "PCM assembly", encoding, publication, article, queue
}

struct SpeechDiagnostics: Sendable {
    let log: DeliveryDebugLog?
    func measure<T>(_ stage: SpeechTimingStage, chunk: Int? = nil, _ body: () throws -> T) rethrows -> T {
        guard log?.enabled == true else { return try body() }
        let start = ProcessInfo.processInfo.systemUptime
        defer { record(stage, seconds: ProcessInfo.processInfo.systemUptime - start, chunk: chunk) }
        return try body()
    }
    func record(_ stage: SpeechTimingStage, seconds: Double, chunk: Int? = nil) {
        guard seconds.isFinite, seconds >= 0 else { return }
        log?.record(.speechTiming(stage, min(seconds * 1000, 86_400_000), chunk))
    }
    func recordEncoding(seconds: Double, audioDuration: Double) {
        log?.record(.speechEncoding(seconds, audioDuration))
    }
    func beginFinalizerWait(database: URL) -> Double? {
        guard log?.enabled == true else { return nil }
        log?.record(.speechFinalizerWaiting(readyCount(database)))
        return ProcessInfo.processInfo.systemUptime
    }
    func endFinalizerWait(_ start: Double?, database: URL) {
        guard let start else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        log?.record(.speechFinalizerAcquired(elapsed * 1000, readyCount(database)))
    }
    private func readyCount(_ database: URL) -> Int? {
        guard log?.enabled == true else { return nil }
        // Diagnostic reads never make processing fail or expose row identities.
        // Decode only queue metadata: legacy origin recovery must not load snapshots.
        do {
            let rows = try NativeStore(url: database, readOnly: true).query("SELECT record FROM speech_queue")
            return try rows.reduce(0) { count, row in
                count + (try JSONDecoder().decode(SpeechQueueItem.self, from: Data(row[0].utf8)).state.isReady ? 1 : 0)
            }
        } catch { return nil }
    }
}

/// One CPU finalizer; waiters can be cancelled without leaving a lost permit.
actor SpeechFinalizationLane {
    private var available = true
    private var waiters: [(UUID, CheckedContinuation<SpeechFinalizationPermit, any Error>)] = []
    func acquire() async throws -> SpeechFinalizationPermit {
        let id = UUID()
        let permit = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if available {
                    available = false; continuation.resume(returning: SpeechFinalizationPermit(lane: self))
                } else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
        do { try Task.checkCancellation(); return permit }
        catch { permit.release(); throw error }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    func release() {
        if waiters.isEmpty { available = true }
        else { waiters.removeFirst().1.resume(returning: SpeechFinalizationPermit(lane: self)) }
    }
}

final class SpeechFinalizationPermit: @unchecked Sendable {
    private let lane: SpeechFinalizationLane
    private let lock = NSLock()
    private var released = false
    init(lane: SpeechFinalizationLane) { self.lane = lane }
    func release() {
        let shouldRelease = lock.withLock { if released { return false }; released = true; return true }
        let target = lane
        if shouldRelease { Task { await target.release() } }
    }
    deinit { release() }
}

/// Ordered speech handoff. A later article cannot overtake an earlier admission.
actor SpeechTurn {
    private var done = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if done { continuation.resume() } else { waiters[id] = continuation }
            }
            try Task.checkCancellation()
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func finish() {
        guard !done else { return }; done = true
        let pending = waiters.values; waiters = [:]
        for continuation in pending { continuation.resume() }
    }
}

final class SpeechArticleContext: @unchecked Sendable {
    let pipeline: SingleWorkerSpeechPipeline
    let previous: SpeechTurn?
    let turn = SpeechTurn()
    let control: QueueRunControl
    private let lock = NSLock()
    private var finalizing = false
    init(pipeline: SingleWorkerSpeechPipeline, previous: SpeechTurn?, control: QueueRunControl) {
        self.pipeline = pipeline; self.previous = previous; self.control = control
    }
    func beginFinalization() { lock.withLock { finalizing = true } }
    var finishAfterStop: Bool { control.discardInterruptedWork && lock.withLock { finalizing } }
    func finishSpeech() { Task { await turn.finish() } }
}

/// The queue owns one filesystem lease and one resident inference helper. At most
/// two articles exist in flight: one synthesizing and one finalizing on the CPU.
final class SingleWorkerSpeechPipeline: @unchecked Sendable {
    let database: URL
    let finalization = SpeechFinalizationLane()
    let diagnostics: SpeechDiagnostics
    let audioObserver: (@Sendable (SpeechTimingStage, URL) throws -> Void)?
    private let lock = NSLock()
    private var lease: PipelineLease?
    private var active: (any TTSBackend)?
    init(database: URL, debugLog: DeliveryDebugLog?, audioObserver: (@Sendable (SpeechTimingStage, URL) throws -> Void)? = nil) {
        self.audioObserver = audioObserver
        self.database = database; diagnostics = SpeechDiagnostics(log: debugLog)
    }
    func ensureLease(_ database: URL) throws {
        try lock.withLock {
            guard Files.samePath(self.database, database) else { throw RelayError.setup("Speech pipeline library mismatch.") }
            if lease == nil { lease = try PipelineLease(database: database) }
        }
    }
    func provider(_ candidate: any TTSBackend) -> any TTSBackend {
        if let native = candidate as? any PreparedTTSBackend {
            return PreparedPipelineSpeechBackend(pipeline: self, candidate: native)
        }
        return PipelineSpeechBackend(pipeline: self, candidate: candidate)
    }
    fileprivate func prepare(_ candidate: any TTSBackend) throws {
        try lock.withLock {
            if active?.identity.id == candidate.identity.id { return }
            active?.cancel(); active = nil
            do {
                try diagnostics.measure(.preparation) { try candidate.prepare() }
                active = candidate
            } catch { candidate.cancel(); throw error }
        }
    }
    fileprivate func prepareNarration(_ candidate: any PreparedTTSBackend, projection: NarrationPlan) throws -> NarrationPlan {
        try prepare(candidate)
        let worker = try lock.withLock {
            guard let active = active as? any PreparedTTSBackend, active.identity.id == candidate.identity.id else {
                throw RelayError.setup("Prepare the native speech pipeline first.")
            }
            return active
        }
        do { return try worker.prepareNarration(projection) }
        catch { lock.withLock { active?.cancel(); active = nil }; throw error }
    }

    fileprivate func synthesize(_ candidate: any TTSBackend, request: SynthesisRequest,
                               directory: URL, next: SynthesisRequest?) throws -> SynthesisResult {
        let worker = try lock.withLock {
            guard let active, active.identity.id == candidate.identity.id else { throw RelayError.setup("Prepare the speech pipeline first.") }
            return active
        }
        do {
            return try diagnostics.measure(.speech, chunk: request.chunkIndex) {
                if let lookahead = worker as? any LookaheadTTSBackend {
                    return try lookahead.synthesize(request, directory: directory, next: next)
                }
                return try worker.synthesize(request, directory: directory)
            }
        } catch {
            lock.withLock { active?.cancel(); active = nil }
            throw error
        }
    }
    func close() { lock.withLock { active?.cancel(); active = nil; lease?.release(); lease = nil } }
    deinit { close() }
}

private struct PipelineSpeechBackend: LookaheadTTSBackend {
    let pipeline: SingleWorkerSpeechPipeline
    let candidate: any TTSBackend
    var identity: BackendIdentity { candidate.identity }
    var pronunciations: PronunciationDictionary { candidate.pronunciations }
    func prepare() throws { try pipeline.prepare(candidate) }
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        try synthesize(request, directory: directory, next: nil)
    }
    func synthesize(_ request: SynthesisRequest, directory: URL, next: SynthesisRequest?) throws -> SynthesisResult {
        try pipeline.synthesize(candidate, request: request, directory: directory, next: next)
    }
    // The queue owns the helper; an article's CPU failure must not stop a later inference.
    func cancel() {}
}

private struct PreparedPipelineSpeechBackend: PreparedTTSBackend, LookaheadTTSBackend {
    let pipeline: SingleWorkerSpeechPipeline
    let candidate: any PreparedTTSBackend
    var identity: BackendIdentity { candidate.identity }
    var pronunciations: PronunciationDictionary { candidate.pronunciations }
    var speechSettings: SpeechSettings { candidate.speechSettings }
    var narrationVersion: String { candidate.narrationVersion }
    var preparationPurpose: NarrationPlanPurpose { candidate.preparationPurpose }
    func prepareNarration(_ projection: NarrationPlan) throws -> NarrationPlan { try pipeline.prepareNarration(candidate, projection: projection) }
    func prepare() throws { try pipeline.prepare(candidate) }
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        try synthesize(request, directory: directory, next: nil)
    }
    func synthesize(_ request: SynthesisRequest, directory: URL, next: SynthesisRequest?) throws -> SynthesisResult {
        try pipeline.synthesize(candidate, request: request, directory: directory, next: next)
    }
    func cancel() {} // Pipeline retains the sole helper through CPU finalization.
}

/// Serializes progress callbacks across the two CPU/GPU stages, retaining the
/// whole drain's counts until encoding and publication actually complete.
final class SpeechDrainProgress: @unchecked Sendable {
    private struct Item { var total: Int; var done = 0; var complete = false; var prepared = false; let ordinal: Int }
    private let lock = NSLock()
    private var items: [String: Item] = [:]
    private var waiting: [(id: String, chunks: Int)] = []
    private var pending = 0
    private let callback: @Sendable (QueueBatchProgress) -> Void
    init(callback: @escaping @Sendable (QueueBatchProgress) -> Void) { self.callback = callback }
    func observe(_ plans: [(id: String, chunks: Int)], pending: Int) {
        lock.withLock { waiting = plans; self.pending = pending }
    }
    func idle() { lock.withLock { emit(.extracted, current: "") } }
    func start(_ id: String, chunks: Int) {
        lock.withLock { items[id] = Item(total: chunks, ordinal: items.count + 1); emit(.extracted, current: id) }
    }
    func update(_ id: String, _ value: PipelineProgress) {
        lock.withLock {
            guard var item = items[id] else { return }
            if !item.prepared, value.totalChunks > 0 {
                item.total = value.totalChunks; item.prepared = true
            }
            item.done = max(item.done, min(item.total, value.completedChunks))
            items[id] = item; emit(value.stage, current: id)
        }
    }
    func complete(_ id: String, chunks: Int) {
        lock.withLock {
            guard var item = items[id] else { return }
            item.total = chunks; item.done = chunks; item.complete = true; item.prepared = true
            items[id] = item; emit(.published, current: id)
        }
    }
    func finish() -> QueueBatchProgress {
        lock.withLock {
            let value = QueueBatchProgress(stage: .published, completedChunks: items.values.reduce(0) { $0 + $1.done },
                totalChunks: items.values.reduce(0) { $0 + $1.done }, completedArticles: items.values.filter(\.complete).count,
                totalArticles: items.count)
            callback(value); return value
        }
    }
    private func emit(_ stage: Stage, current: String) {
        let ready = waiting.filter { items[$0.id] == nil }
        callback(QueueBatchProgress(stage: stage, completedChunks: items.values.reduce(0) { $0 + $1.done },
            totalChunks: items.values.reduce(0) { $0 + $1.total } + ready.reduce(0) { $0 + $1.chunks },
            completedArticles: items.values.filter(\.complete).count, totalArticles: items.count + ready.count + pending,
            currentArticleIndex: items[current]?.ordinal, pendingPreparations: pending,
            countsAreFinal: ready.isEmpty && pending == 0 && items.values.allSatisfy(\.prepared),
            currentArticleFraction: items[current].flatMap { $0.prepared ? Double($0.done + ($0.complete ? 1 : 0)) / Double($0.total + 1) : nil }))
    }
}

struct SpeechArticleOutcome: Sendable {
    let id: String
    var result: FixtureResult? = nil
    var failure: SpeechQueueItem? = nil
    var interrupted = false
}
