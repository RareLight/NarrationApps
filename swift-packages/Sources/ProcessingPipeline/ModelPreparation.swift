import NarrationCore
import DocumentProcessing
import NativeSpeech
import AudioOutput
import Foundation

/// Explicit preparation owns one helper and awaits its reaping on every exit.
/// Downloads and validation never execute in the GUI or load an MLX model.
public enum ModelPreparation {
    public static func run(configuration: WorkerConfiguration, workspace: URL, settings: SpeechSettings,
                           progress: @escaping @Sendable (ModelPreparationProgress) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        guard SpeechMemoryPolicy.canLoad(settings.model) else { throw SpeechFailure(.memoryLimit) }
        let storageLease = try ModelStorageLease(workspace: NativeWorkspace(root: workspace))
        defer { withExtendedLifetime(storageLease) {} }
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
