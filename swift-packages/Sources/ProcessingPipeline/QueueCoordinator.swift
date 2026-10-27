import NarrationCore
import DocumentProcessing
import NativeSpeech
import AudioOutput
import Foundation
import Pronunciation

public struct DocumentOutcome: Sendable {
    public enum State: Sendable { case published, failed, cancelled, skipped }
    public let id: UUID
    public let state: State
    public let destination: URL
    public let message: String?
    public init(id: UUID, state: State, destination: URL, message: String? = nil) {
        self.id = id; self.state = state; self.destination = destination; self.message = message
    }
}

public struct BatchSummary: Sendable {
    public let id: UUID
    public let documents: [DocumentOutcome]
    public let cancelled: Bool
    public init(id: UUID, documents: [DocumentOutcome], cancelled: Bool) {
        self.id = id; self.documents = documents; self.cancelled = cancelled
    }
    public var successfulCount: Int { documents.filter { $0.state == .published }.count }
    public var failedCount: Int { documents.filter { $0.state == .failed }.count }
    public var skippedCount: Int { documents.filter { $0.state == .skipped }.count }
}

public enum BatchEvent: Sendable {
    case preparing(batch: UUID, job: UUID)
    case textPreparation(TextPreparationProgress)
    case speech(SpeechProgress)
    case document(batch: UUID, DocumentOutcome)
    case control(BatchQueueState)
    case finished(BatchSummary)
}

public enum CoordinatorError: Error, LocalizedError {
    case busy
    public var errorDescription: String? { "A batch is already processing." }
}

/// One coordinator owns the global execution budget. Actor reentrancy permits
/// cancellation while its task is awaiting workers; another run is rejected.
public actor QueueCoordinator {
    private let configuration: WorkerConfiguration
    private var active: Task<BatchSummary, Never>?
    public init(configuration: WorkerConfiguration) { self.configuration = configuration }

    public func run(_ request: BatchRequest, debugLog: DebugLog? = nil, control: BatchQueueControl? = nil, events: @escaping @Sendable (BatchEvent) -> Void = { _ in }) async throws -> BatchSummary {
        guard active == nil else { throw CoordinatorError.busy }
        try Task.checkCancellation()
        if let control {
            let state = control.state
            guard state.batch == request.id, state.current == nil,
                  state.pending.count == request.documents.count,
                  Set(state.pending) == Set(request.documents.map(\.id)) else { throw SpeechFailure(.invalidInput) }
        }
        // Whole-batch preflight happens before any document/model is opened.
        let validation = try BatchPlanner.ValidationContext(request)
        var selected = configuration
        if let debugLog { selected.debugLog = debugLog }
        let scheduler = ChunkScheduler(configuration: selected)
        let sessionConfiguration = selected
        let queue = control ?? BatchQueueControl(batch: request.id, jobs: request.documents.map(\.id))
        queue.observe { events(.control($0)) }
        let task = Task {
            do {
                let pronunciations = try sessionConfiguration.pronunciationStore?.load().dictionary ?? request.pronunciations
                if control != nil {
                    // Controlled Libro batches release interactive admission while
                    // paused. Individual extraction/model operations own their leases.
                    return await self.execute(request, queue: queue, cooperative: true, validation: validation, scheduler: scheduler, sessionConfiguration: sessionConfiguration, pronunciations: pronunciations, debugLog: sessionConfiguration.debugLog, events: events)
                }
                return try await InferenceLease.withPriority(sessionConfiguration.inferencePriority, at: sessionConfiguration.inferenceLeaseFile) {
                    await self.execute(request, queue: queue, cooperative: false, validation: validation, scheduler: scheduler, sessionConfiguration: sessionConfiguration, pronunciations: pronunciations, debugLog: sessionConfiguration.debugLog, events: events)
                }
            } catch {
                let cancelled = error is CancellationError
                let outcomes = request.documents.map { DocumentOutcome(id: $0.id, state: cancelled ? .cancelled : .failed,
                    destination: $0.destination, message: cancelled ? nil : ((error as? PronunciationError)?.localizedDescription ?? SpeechFailure(.storage).localizedDescription)) }
                let summary = BatchSummary(id: request.id, documents: outcomes, cancelled: cancelled)
                events(.finished(summary))
                return summary
            }
        }
        active = task
        defer { active = nil }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    public func cancel() { active?.cancel() }

    public func cancelAndWait() async {
        let task = active
        task?.cancel()
        _ = await task?.value
    }

    private func execute(_ request: BatchRequest, queue: BatchQueueControl, cooperative: Bool, validation: BatchPlanner.ValidationContext, scheduler: ChunkScheduler, sessionConfiguration: WorkerConfiguration, pronunciations: PronunciationDictionary, debugLog: DebugLog?,
                         events: @escaping @Sendable (BatchEvent) -> Void) async -> BatchSummary {
        var outcomes: [DocumentOutcome] = []
        var session: NativeSpeechSession?
        let documents = Dictionary(uniqueKeysWithValues: request.documents.map { ($0.id, $0) })
        while !Task.isCancelled {
            let next: UUID?
            do { next = try await queue.next() } catch { break }
            guard let next, let document = documents[next] else { break }
            if Task.isCancelled { break }
            events(.preparing(batch: request.id, job: document.id))
            debugLog?.record("batch=\(request.id) job=\(document.id) preparing type=\(document.input.kind.rawValue)")
            let outcome: DocumentOutcome
            do {
                let updates = TextPreparationReporter(batch: request.id, job: document.id, events: events)
                let preparation = Task.detached(priority: .userInitiated) {
                    let semantic = try await InferenceLease.withPriority(sessionConfiguration.inferencePriority, at: sessionConfiguration.inferenceLeaseFile) {
                        try await DocumentReader.readSemantic(document.input, describeImages: request.describeImages, progress: { updates.report($0) })
                    }
                    updates.report(.init(stage: .planningNarration))
                    return try NarrationPlanner.prepareForSpeech(semantic, settings: request.settings, pronunciations: pronunciations, policy: sessionConfiguration.preparationPolicy, options: request.narrationOptions)
                }
                let projection = try await withTaskCancellationHandler { try await preparation.value }
                    onCancel: { preparation.cancel() }
                try Task.checkCancellation()
                try await queue.checkpoint(job: document.id)
                try validation.validate(document)
                if session == nil {
                    session = try NativeSpeechSession(configuration: sessionConfiguration, workspace: request.workspace,
                                                      settings: request.settings, leaseFile: sessionConfiguration.inferenceLeaseFile)
                }
                let checkpoint: (@Sendable () async throws -> Void)?
                if cooperative { checkpoint = { try await queue.checkpoint(job: document.id) } }
                else { checkpoint = nil }
                try await scheduler.render(projection: projection, batchID: request.id, jobID: document.id,
                                           workspace: request.workspace, settings: request.settings,
                                           destination: document.destination,
                                           outputFormat: request.outputFormat, replaceExisting: request.approvedReplacements.contains(document.id), session: session, coverArtwork: request.coverArtwork[document.id],
                                           checkpoint: checkpoint,
                                           beforePublication: {
                                               try validation.validate(document)
                                               do { try queue.authorizePublication(job: document.id) }
                                               catch is BatchItemSkipped { throw CancellationError() }
                                           },
                                           preparationProgress: { completed, total in updates.report(.init(stage: .phonemizing, completed: completed, total: total, unit: .passages)) },
                                           progress: { events(.speech($0)) })
                outcome = .init(id: document.id, state: .published, destination: document.destination, message: nil)
            } catch is BatchItemSkipped {
                if Task.isCancelled { break }
                await session?.close(); session = nil
                outcome = .init(id: document.id, state: .skipped, destination: document.destination)
            } catch is CancellationError {
                guard !Task.isCancelled, queue.state.current == document.id, queue.state.phase == .skipping else { break }
                await session?.close(); session = nil
                outcome = .init(id: document.id, state: .skipped, destination: document.destination)
            }
            catch {
                await session?.close(); session = nil
                debugLog?.record("batch=\(request.id) job=\(document.id) document failed: \(error.localizedDescription)")
                // File read errors can include the selected source path, but
                // never extracted text. Worker errors are controlled above.
                outcome = .init(id: document.id, state: .failed, destination: document.destination,
                                message: error.localizedDescription)
            }
            outcomes.append(outcome); events(.document(batch: request.id, outcome))
            queue.finish(job: document.id)
        }
        await session?.close()
        let cancelled = Task.isCancelled
        if cancelled {
            let finished = Set(outcomes.map(\.id))
            for document in request.documents where !finished.contains(document.id) {
                let outcome = DocumentOutcome(id: document.id, state: .cancelled,
                                              destination: document.destination, message: nil)
                outcomes.append(outcome); events(.document(batch: request.id, outcome))
            }
        }
        let summary = BatchSummary(id: request.id, documents: outcomes, cancelled: cancelled)
        events(.finished(summary))
        return summary
    }

}
