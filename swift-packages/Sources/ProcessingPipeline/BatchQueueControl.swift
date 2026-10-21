import Foundation

public struct BatchQueueState: Sendable {
    public enum Phase: Sendable { case running, pausing, paused, skipping }
    public let batch: UUID
    public let sequence: Int
    public let current: UUID?
    public let pending: [UUID]
    public let phase: Phase
    public let pauseRequested: Bool
    public let canSkip: Bool
}

public struct BatchItemSkipped: Error, Sendable {}

/// Cooperative control at operation boundaries, never by suspending a process
/// or interrupting a GPU request. Only the pending order is mutable.
public final class BatchQueueControl: @unchecked Sendable {
    private let lock = NSLock()
    private let batch: UUID
    private var pending: [UUID]
    private var current: UUID?
    private var pauseRequested = false
    private var paused = false
    private var skipRequested = false
    private var committed = false
    private var sequence = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var observer: (@Sendable (BatchQueueState) -> Void)?

    public init(batch: UUID, jobs: [UUID]) { self.batch = batch; pending = jobs }

    private func snapshot() -> BatchQueueState {
        .init(batch: batch, sequence: sequence, current: current, pending: pending,
            phase: skipRequested ? .skipping : (paused ? .paused : (pauseRequested ? .pausing : .running)),
            pauseRequested: pauseRequested, canSkip: current != nil && !committed && !skipRequested)
    }
    public var state: BatchQueueState { lock.withLock { snapshot() } }
    private func emit() {
        let value = lock.withLock { (observer, snapshot()) }
        value.0?(value.1)
    }
    public func observe(_ action: @escaping @Sendable (BatchQueueState) -> Void) {
        lock.withLock { observer = action; sequence += 1 }; emit()
    }
    public func setPaused(_ value: Bool) {
        let wake = lock.withLock {
            pauseRequested = value
            if !value { paused = false }
            sequence += 1
            let wake = value ? [] : Array(waiters.values)
            if !value { waiters.removeAll() }
            return wake
        }
        wake.forEach { $0.resume() }; emit()
    }
    @discardableResult public func skip(job: UUID) -> Bool {
        let wake: [CheckedContinuation<Void, Error>]? = lock.withLock {
            guard current == job, !committed, !skipRequested else { return nil }
            skipRequested = true; paused = false; sequence += 1
            let wake = Array(waiters.values); waiters.removeAll(); return wake
        }
        guard let wake else { return false }
        wake.forEach { $0.resume() }; emit(); return true
    }
    @discardableResult public func reorderPending(_ jobs: [UUID]) -> Bool {
        let accepted = lock.withLock {
            guard jobs.count == pending.count, Set(jobs) == Set(pending) else { return false }
            pending = jobs; sequence += 1; return true
        }
        if accepted { emit() }; return accepted
    }
    public func next() async throws -> UUID? {
        guard lock.withLock({ !pending.isEmpty }) else { return nil }
        try await checkpoint()
        let job = lock.withLock {
            let job = pending.removeFirst()
            current = job; committed = false; skipRequested = false; sequence += 1
            return job
        }
        emit(); return job
    }
    public func finish(job: UUID) {
        lock.withLock {
            guard current == job else { return }
            current = nil; committed = false; skipRequested = false; paused = false; sequence += 1
        }
        emit()
    }
    /// Called immediately before the atomic publication boundary. A stale Skip
    /// confirmation cannot target the next job or relabel a committed output.
    public func authorizePublication(job: UUID) throws {
        try Task.checkCancellation()
        try lock.withLock {
            guard current == job else { throw CancellationError() }
            if skipRequested { throw BatchItemSkipped() }
            committed = true; sequence += 1
        }
        emit()
    }
    public func checkpoint(job: UUID? = nil) async throws {
        while true {
        try Task.checkCancellation()
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let result: Result<Void, Error>? = lock.withLock {
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if let job, current != job { return .failure(CancellationError()) }
                    if job != nil && skipRequested { return .failure(BatchItemSkipped()) }
                    if pauseRequested {
                        paused = true; sequence += 1; waiters[token] = continuation; return nil
                    }
                    return .success(())
                }
                if let result { continuation.resume(with: result) } else { emit() }
            }
        } onCancel: {
            let waiter = self.lock.withLock { self.waiters.removeValue(forKey: token) }
            waiter?.resume(throwing: CancellationError())
        }
        try Task.checkCancellation()
        // Resume and Skip can wake the same suspended boundary.
        let shouldWait = try lock.withLock {
            if job != nil && skipRequested { throw BatchItemSkipped() }
            return pauseRequested
        }
        if !shouldWait { return }
        }
    }
}
