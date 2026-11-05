import Foundation

/// Optional host checkpoint for synchronous text preparation and read-only audio
/// diagnostics. The core owns no scheduling policy or AudioOutput dependency.
public enum NarrationWorkCheckpoint {
    @TaskLocal public static var current: (@Sendable () throws -> Void)?
    public static func check() throws {
        try Task.checkCancellation()
        try current?()
    }
}
