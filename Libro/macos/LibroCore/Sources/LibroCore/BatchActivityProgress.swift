import Foundation

/// Reject delayed updates from earlier documents, phases or batches.
public struct BatchActivityProgress {
    private let batch: UUID
    private var positions: [UUID: Int] = [:]
    private var position = -1
    private var speechStarted = false
    public private(set) var preparation: TextPreparationProgress?

    public init(batch: UUID, jobs: [UUID]) {
        self.batch = batch
        for (index, id) in jobs.enumerated() { positions[id] = index }
    }
    private mutating func select(_ job: UUID) -> Bool {
        guard let incoming = positions[job], incoming >= position else { return false }
        if incoming > position {
            position = incoming; preparation = nil; speechStarted = false
        }
        return true
    }
    public mutating func beginPreparation(job: UUID) -> Bool {
        select(job) && !speechStarted && preparation == nil
    }
    public mutating func receive(_ value: TextPreparationProgress) -> Bool {
        guard value.batch == batch, value.sequence > 0, select(value.job), !speechStarted,
              value.sequence > (preparation?.sequence ?? 0) else { return false }
        preparation = value
        return true
    }
    public mutating func beginSpeech(job: UUID) -> Bool {
        guard select(job) else { return false }
        speechStarted = true; preparation = nil
        return true
    }
    public mutating func reorderPending(jobs: [UUID]) {
        let previous = positions.sorted { $0.value < $1.value }.map(\.key)
        guard Set(jobs) == Set(previous), jobs.count == previous.count,
              Array(jobs.prefix(position + 1)) == Array(previous.prefix(position + 1)) else { return }
        positions = Dictionary(uniqueKeysWithValues: jobs.enumerated().map { ($0.element, $0.offset) })
    }
}
