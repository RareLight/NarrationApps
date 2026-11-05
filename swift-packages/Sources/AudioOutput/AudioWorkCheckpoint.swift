import Foundation

/// Typed control flow must survive codec wrappers without becoming an invalid
/// audio error. Scheduling implementations own the concrete interruption type.
public protocol AudioWorkInterruption: Error {}

/// Optional cooperative CPU boundary. AudioOutput owns no scheduling policy;
/// hosts establish this only on a dedicated CPU queue. No audio math changes.
public enum AudioWorkCheckpoint {
    @TaskLocal public static var current: (@Sendable () throws -> Void)?
    public static func check() throws {
        try Task.checkCancellation()
        try current?()
    }
}
