import Foundation

/// Async document readers delegate synchronous CPU-only units to their host.
/// No model/platform inference, async bridge or network wait belongs in a unit.
public protocol NarrationCPUExecutor: Sendable {
    func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value
}

public enum NarrationPreparationWork {
    @TaskLocal public static var executor: (any NarrationCPUExecutor)?
    public static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if let executor { return try await executor.perform(operation) }
        // Legacy callers retain their existing background executor/ownership.
        return try operation()
    }
}
