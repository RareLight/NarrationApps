import Foundation

public struct SpeechAttemptToken: Codable, Equatable, Sendable {
    public let identity: AttemptIdentity
    public let epoch: UInt64
}
public enum SpeechAttemptFailure: Error, Equatable, Sendable { case invalidState, invalidCheckpoint, epochExhausted }

/// Typed automatic suspension is distinct from user cancellation/failure.
/// Queue adapters must catch it before aborting a writer or reporting completion.
public struct SpeechPrioritySuspension: Error, Sendable {
    public let attempt: SpeechAttemptToken
    public let demand: SpeechWorkDemand
    public init(attempt: SpeechAttemptToken, demand: SpeechWorkDemand) { self.attempt = attempt; self.demand = demand }
}

/// A per-job publication fence shared by persistence adapters. Hash/PCM validation
/// must finish outside this lock. Only a short final durable commit belongs in
/// `commit`; revocation linearizes against that commit, never pending validation.
/// This type does not cancel/join workers or validate checkpoint bytes itself.
public final class SpeechAttemptFence: @unchecked Sendable {
    public static let maximumChunks = 100_000
    private enum Phase { case idle, active, revoked, quiescent }
    private let lock = NSLock()
    private let batch: UUID, job: UUID
    private var epoch: UInt64
    private var current: SpeechAttemptToken?
    private var phase: Phase = .idle
    private var stopped = false
    private var committed: Set<Int>
    private var cursor: Int
    public init(batch: UUID, job: UUID, lastEpoch: UInt64 = 0, verifiedChunks: Set<Int> = []) throws {
        guard verifiedChunks.count <= Self.maximumChunks,
              verifiedChunks.allSatisfy({ (0..<Self.maximumChunks).contains($0) }) else { throw SpeechAttemptFailure.invalidCheckpoint }
        self.batch = batch; self.job = job; epoch = lastEpoch; committed = verifiedChunks
        var firstMissing = 0
        while verifiedChunks.contains(firstMissing) { firstMissing += 1 }
        cursor = firstMissing
    }
    public var verifiedPrefix: Int { lock.withLock { cursor } }
    public var verifiedChunks: Set<Int> { lock.withLock { committed } }
    public func begin() throws -> SpeechAttemptToken {
        try lock.withLock {
            guard !stopped, phase == .idle || phase == .quiescent else { throw SpeechAttemptFailure.invalidState }
            guard epoch < UInt64.max else { throw SpeechAttemptFailure.epochExhausted }
            epoch += 1
            let token = SpeechAttemptToken(identity: .init(batch: batch, job: job), epoch: epoch)
            current = token; phase = .active; return token
        }
    }
    @discardableResult public func revoke(_ token: SpeechAttemptToken) -> Bool {
        lock.withLock {
            guard current == token, phase == .active else { return false }
            phase = .revoked; return true
        }
    }
    /// Called only after correlated reset/quiescence or verified owned reap.
    /// A stale acknowledgement must not unlock a newer attempt.
    @discardableResult public func acknowledgeQuiescence(_ token: SpeechAttemptToken) -> Bool {
        lock.withLock {
            guard current == token, phase == .revoked else { return false }
            phase = .quiescent; return true
        }
    }
    public func stop() {
        lock.withLock { stopped = true; if phase == .active { phase = .revoked } }
    }
    /// Returns false for revoked/stale/duplicate commits without running their
    /// operation. A throwing operation leaves the cursor unchanged for recovery.
    @discardableResult public func commit(_ token: SpeechAttemptToken, index: Int, operation: () throws -> Void) throws -> Bool {
        try lock.withLock {
            guard (0..<Self.maximumChunks).contains(index) else { throw SpeechAttemptFailure.invalidCheckpoint }
            guard !stopped, current == token, phase == .active, !committed.contains(index) else { return false }
            try operation()
            committed.insert(index)
            while committed.contains(cursor) { cursor += 1 }
            return true
        }
    }
}
