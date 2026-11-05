import Foundation

/// Ranked admission for host-side Vision/Foundation Models operations. An
/// already-issued platform call is cooperative: its lease survives cancellation
/// until the caller has joined it. No new call may bypass accepted API demand.
public final class SpeechHostAdmission: @unchecked Sendable {
    public let inferenceFile: URL
    private let owner: SpeechWorkOwner
    private let registry: SpeechWorkAdmission
    // Distinct from the speech helper instance: even an idle same-app helper
    // must release residency before a platform operation can acquire exclusion.
    private let instance = UUID()
    private let lock = NSLock()
    private var closed = false
    private var paused = false
    private var outstanding = 0
    private var registered = 0
    private var active = 0
    var observation: (closed: Bool, outstanding: Int, registered: Int, paused: Bool, active: Int) {
        lock.withLock { (closed, outstanding, registered, paused, active) }
    }

    public init(owner: SpeechWorkOwner, root: URL = SpeechWorkAdmission.defaultRoot,
                inferenceFile: URL = InferenceLease.defaultFile) throws {
        guard inferenceFile.isFileURL else { throw SpeechFailure(.invalidInput) }
        self.owner = owner; self.inferenceFile = inferenceFile
        registry = try SpeechWorkAdmission(root: root)
    }
    /// Establish explicitly at an app-owned task boundary; detached tasks must
    /// capture/re-establish this context. It never changes normal app defaults.
    public nonisolated(nonsending) func withContext<Value: Sendable>(
        operation: nonisolated(nonsending) () async throws -> Value) async throws -> Value {
        try checkOpen()
        return try await InferenceLease.$hostAdmission.withValue(self, operation: operation)
    }
    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !lock.withLock({ closed }) else { throw CancellationError() }
    }
    func acquire() async throws -> InferenceLease {
        try checkOpen()
        try lock.withLock {
            guard !closed else { throw CancellationError() }
            outstanding += 1
        }
        var transferred = false
        var ticket: SpeechWorkTicket?
        defer {
            if !transferred {
                try? ticket?.withdraw()
                finish(registered: ticket != nil, active: false)
            }
        }
        while true {
            try checkOpen()
            if lock.withLock({ paused }) {
                if let owned = ticket {
                    try owned.withdraw(); ticket = nil
                    lock.withLock { registered -= 1 }
                }
                try await Task.sleep(for: .milliseconds(25)); continue
            }
            if ticket == nil {
                ticket = try registry.register(owner: owner, instance: instance,
                    rank: owner == .libro ? .libro : .podcast, delivery: .file)
                lock.withLock { registered += 1 }
            }
            guard let owned = ticket else { continue }
            if let lease = try registry.tryAcquireResidency(for: owned.demand, inferenceFile: inferenceFile) {
                // Registration and kernel acquisition were one fenced decision.
                // Check cancellation/quit again before returning a platform grant.
                try checkOpen()
                let granted = lock.withLock {
                    guard !paused, !closed else { return false }
                    active += 1; return true
                }
                guard granted else { continue }
                lease.coordinatedRelease = { [self, owned] in
                    try? owned.withdraw(); finish(registered: true, active: true)
                }
                transferred = true
                return lease
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    private func finish(registered hadTicket: Bool, active wasActive: Bool) {
        lock.withLock { outstanding -= 1; if hadTicket { registered -= 1 }; if wasActive { active -= 1 } }
    }
    public func pauseAccepting() { lock.withLock { paused = true } }
    public func resumeAccepting() { lock.withLock { if !closed { paused = false } } }
    public func waitForActiveLeases() async {
        while lock.withLock({ active > 0 }) { await poll() }
    }
    private func poll() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { continuation.resume() }
        }
    }
    public func stopAccepting() { lock.withLock { closed = true } }
    /// Never withdraw an active platform ticket to simulate quiescence. The
    /// actual lease owner releases it after its work has completed/joined.
    public func stopAndWait() async {
        stopAccepting()
        while lock.withLock({ outstanding > 0 }) {
            await poll()
        }
    }
}
