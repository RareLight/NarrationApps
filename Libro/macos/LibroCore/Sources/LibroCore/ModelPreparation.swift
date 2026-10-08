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
    public func isValid(for model: SpeechModel) -> Bool {
        let expected = scope == .primary ? NativePrimaryCatalog.specification(for: model).files.reduce(Int64(0)) { $0 + Int64($1.bytes) }
            : NativeG2P.requiredFiles.values.reduce(Int64(0)) { $0 + Int64($1) }
        return (scope != .g2p || model == .kokoro) && totalBytes == expected && completedBytes >= 0 && completedBytes <= totalBytes
    }
}

/// Explicit preparation owns one helper and awaits its reaping on every exit.
/// Downloads and validation never execute in the GUI or load an MLX model.
public enum ModelPreparation {
    public static func run(configuration: WorkerConfiguration, workspace: URL, settings: SpeechSettings,
                           progress: @escaping @Sendable (ModelPreparationProgress) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        _ = try NativeWorkspace(root: workspace)
        let identity = AttemptIdentity(batch: UUID(), job: UUID())
        let worker = try SpeechWorkerProcess(configuration: configuration, identity: identity)
        do {
            _ = try await worker.request(.init(kind: .prepare, identity: identity, workspace: workspace, settings: settings), progress: progress)
            try Task.checkCancellation()
            await worker.stop()
        } catch {
            await worker.stop()
            throw error
        }
    }
}
