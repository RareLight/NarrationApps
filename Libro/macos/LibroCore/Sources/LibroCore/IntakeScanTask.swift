import Foundation

/// Replacements keep the complete scanner chain owned. Native filesystem/cover
/// calls may finish after cancellation, so a new scan waits for the old one.
public enum IntakeScanTask {
    public typealias Result = (intake: IntakeResult, covers: [String: String])
    public static func start(replacing previous: Task<Result, Error>?, after reader: Task<Void, Error>?,
                             coverWork: Task<Void, Never>?,
                             operation: @escaping @Sendable () async throws -> Result) -> Task<Result, Error> {
        previous?.cancel(); reader?.cancel()
        return Task.detached(priority: .userInitiated) {
            _ = await previous?.result
            _ = await reader?.result
            await coverWork?.value
            try Task.checkCancellation()
            return try await operation()
        }
    }
}
