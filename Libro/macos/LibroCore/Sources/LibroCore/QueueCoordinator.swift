import Foundation

public struct DocumentOutcome: Sendable {
    public enum State: Sendable { case published, failed, cancelled }
    public let id: UUID
    public let state: State
    public let destination: URL
    public let message: String?
}

public struct BatchSummary: Sendable {
    public let id: UUID
    public let documents: [DocumentOutcome]
    public let cancelled: Bool
    public var successfulCount: Int { documents.filter { $0.state == .published }.count }
    public var failedCount: Int { documents.filter { $0.state == .failed }.count }
}

public enum BatchEvent: Sendable {
    case preparing(batch: UUID, job: UUID)
    case speech(SpeechProgress)
    case document(batch: UUID, DocumentOutcome)
    case finished(BatchSummary)
}

public enum CoordinatorError: Error, LocalizedError {
    case busy
    public var errorDescription: String? { "A Libro batch is already processing." }
}

/// One coordinator owns the global execution budget. Actor reentrancy permits
/// cancellation while its task is awaiting workers; another run is rejected.
public actor QueueCoordinator {
    private let scheduler: ChunkScheduler
    private var active: Task<BatchSummary, Never>?
    public init(configuration: WorkerConfiguration) { scheduler = ChunkScheduler(configuration: configuration) }

    public func run(_ request: BatchRequest, events: @escaping @Sendable (BatchEvent) -> Void = { _ in }) async throws -> BatchSummary {
        guard active == nil else { throw CoordinatorError.busy }
        try Task.checkCancellation()
        // Whole-batch preflight happens before any document/model is opened.
        let bindings = try Dictionary(uniqueKeysWithValues: Self.revalidate(request).map {
            ($0.id, try OutputPaths.resolved($0.destination))
        })
        let task = Task { await execute(request, bindings: bindings, events: events) }
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

    private func execute(_ request: BatchRequest, bindings: [UUID: URL],
                         events: @escaping @Sendable (BatchEvent) -> Void) async -> BatchSummary {
        var outcomes: [DocumentOutcome] = []
        for document in request.documents {
            if Task.isCancelled { break }
            events(.preparing(batch: request.id, job: document.id))
            let outcome: DocumentOutcome
            do {
                let preparation = Task.detached(priority: .userInitiated) {
                    let text = try DocumentReader.read(document.input)
                    return try NarrationText.chunks(text, settings: request.settings)
                }
                let chunks = try await withTaskCancellationHandler { try await preparation.value }
                    onCancel: { preparation.cancel() }
                try Task.checkCancellation()
                _ = try Self.revalidate(request, bindings: bindings)
                try await scheduler.render(chunks: chunks, batchID: request.id, jobID: document.id,
                                           workspace: request.workspace, settings: request.settings,
                                           serial: request.serial, destination: document.destination,
                                           beforePublication: { _ = try Self.revalidate(request, bindings: bindings) },
                                           progress: { events(.speech($0)) })
                outcome = .init(id: document.id, state: .published, destination: document.destination, message: nil)
            } catch is CancellationError { break }
            catch {
                // File read errors can include the selected source path, but
                // never extracted text. Worker errors are controlled above.
                outcome = .init(id: document.id, state: .failed, destination: document.destination,
                                message: error.localizedDescription)
            }
            outcomes.append(outcome); events(.document(batch: request.id, outcome))
        }
        let cancelled = Task.isCancelled
        if cancelled {
            for document in request.documents.dropFirst(outcomes.count) {
                let outcome = DocumentOutcome(id: document.id, state: .cancelled,
                                              destination: document.destination, message: nil)
                outcomes.append(outcome); events(.document(batch: request.id, outcome))
            }
        }
        let summary = BatchSummary(id: request.id, documents: outcomes, cancelled: cancelled)
        events(.finished(summary))
        return summary
    }

    private static func revalidate(_ request: BatchRequest, bindings: [UUID: URL]? = nil) throws -> [PlannedDocument] {
        let names = Dictionary(uniqueKeysWithValues: request.documents.map { ($0.id, $0.relativeOutput) })
        let plans = try BatchPlanner.plan(request.documents.map(\.input), output: request.outputDirectory, names: names)
        for (current, original) in zip(plans, request.documents) {
            guard try OutputPaths.resolved(current.destination) == OutputPaths.resolved(original.destination) else {
                throw PlanningError.invalidDestination
            }
            if let binding = bindings?[current.id], try OutputPaths.resolved(current.destination) != binding {
                throw PlanningError.invalidDestination
            }
        }
        return plans
    }
}
