import Foundation
import NarrationCore

public struct TextPreparationProgress: Sendable {
    public let batch: UUID
    public let job: UUID
    public let sequence: Int
    public let progress: DocumentPreparationProgress
    public init(batch: UUID, job: UUID, sequence: Int, progress: DocumentPreparationProgress) {
        self.batch = batch; self.job = job; self.sequence = sequence; self.progress = progress
    }
}

/// Assign event order at emission, before a UI coalesces or dispatches callbacks.
final class TextPreparationReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence = 0
    private let batch: UUID, job: UUID
    private let events: @Sendable (BatchEvent) -> Void
    init(batch: UUID, job: UUID, events: @escaping @Sendable (BatchEvent) -> Void) {
        self.batch = batch; self.job = job; self.events = events
    }
    func report(_ value: DocumentPreparationProgress) {
        lock.withLock {
            sequence += 1
            events(.textPreparation(.init(batch: batch, job: job, sequence: sequence, progress: value)))
        }
    }
}
