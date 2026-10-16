import Foundation

public struct ModelPreparationProgress: Codable, Sendable {
    public enum Scope: String, Codable, Sendable { case primary, g2p }
    public enum Phase: String, Codable, Sendable { case waiting, checking, reusing, downloading, validating, publishing }
    public let scope: Scope
    public let phase: Phase
    public let completedBytes: Int64
    public let totalBytes: Int64
    public init(scope: Scope, phase: Phase, completedBytes: Int64 = 0, totalBytes: Int64) {
        self.scope = scope; self.phase = phase; self.completedBytes = completedBytes; self.totalBytes = totalBytes
    }
}
