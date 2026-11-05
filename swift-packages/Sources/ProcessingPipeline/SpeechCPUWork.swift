import Foundation
import NarrationCore
import NativeSpeech
import AudioOutput

/// One owned CPU queue per operation, so a suspended background encoder cannot
/// block a live response's encoder or occupy the Swift/UI/HTTP executor.
public enum SpeechCPUWork {
    private final class Cancellation: @unchecked Sendable {
        let lock = NSLock(); private var value = false
        var cancelled: Bool { lock.withLock { value } }
        func cancel() { lock.withLock { value = true } }
    }
    public static func run<Value: Sendable>(job: SpeechWorkJob,
        interruption: @escaping @Sendable () throws -> Void = {},
        operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let cancellation = Cancellation()
        let id = UUID(); job.beginCPU(id)
        defer { job.endCPU(id) }
        let queue = DispatchQueue(label: "org.narration.cpu-unit", qos: .utility)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        let checkpoint: @Sendable () throws -> Void = { try job.cpuCheckpoint(id, cancelled: { cancellation.cancelled }, interruption: interruption) }
                        return try NarrationWorkCheckpoint.$current.withValue(checkpoint) {
                            try AudioWorkCheckpoint.$current.withValue(checkpoint) {
                                try AudioWorkCheckpoint.check()
                                let value = try operation()
                                if cancellation.cancelled { throw CancellationError() }
                                return value
                            }
                        }
                    })
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}

/// Captured CPU-only demand. It uses no model host or inference lease. API CPU
/// work instead borrows its accepted request's existing FIFO job directly.
public struct SpeechCPUContext: NarrationCPUExecutor {
    public let coordinator: SpeechWorkCoordinator
    public let settings: SpeechSettings
    public let workspace: URL
    public let rank: SpeechWorkRank
    public var waiting: @Sendable (SpeechWorkWait?) -> Void
    public var status: @Sendable (SpeechWorkStatus) -> Void
    public var eligible: @Sendable () -> Bool = { true }
    public var cancelled: @Sendable () -> Bool = { false }
    public init(coordinator: SpeechWorkCoordinator, settings: SpeechSettings, workspace: URL, rank: SpeechWorkRank,
                waiting: @escaping @Sendable (SpeechWorkWait?) -> Void = { _ in },
                status: @escaping @Sendable (SpeechWorkStatus) -> Void = { _ in }) {
        self.coordinator = coordinator; self.settings = settings; self.workspace = workspace; self.rank = rank
        self.waiting = waiting
        self.status = status
    }
    public func run<Value: Sendable>(interruption: @escaping @Sendable () throws -> Void = {},
                                    _ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let job: SpeechWorkJob
        let reporter = SpeechWorkStatusReporter(deliver: status)
        let waiting = self.waiting
        defer { waiting(nil); reporter.update(nil) }
        while true {
            try Task.checkCancellation()
            if cancelled() { throw CancellationError() }
            try interruption()
            do {
                job = try await coordinator.openJob(identity: .init(batch: UUID(), job: UUID()), settings: settings,
                    workspace: workspace, rank: rank, eligible: eligible, cancelled: cancelled,
                    waiting: { waiting($0); reporter.update($0) }, purpose: .cpu)
                break
            } catch SpeechWorkAvailability.maintenance {
                let reason: SpeechWorkWait = eligible() ? .maintenance : .manualPause
                waiting(reason); reporter.update(reason)
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        do {
            let result = try await SpeechCPUWork.run(job: job, interruption: interruption, operation: operation)
            await coordinator.closeJob(job); return result
        } catch { await coordinator.closeJob(job); throw error }
    }
    public static func run<Value: Sendable>(_ context: Self?, interruption: @escaping @Sendable () throws -> Void = {},
                                            operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        if let context { return try await context.run(interruption: interruption, operation) }
        try interruption()
        return try operation()
    }
    public func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await run(operation)
    }
}
