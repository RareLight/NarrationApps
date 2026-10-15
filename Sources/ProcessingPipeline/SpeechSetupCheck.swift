import Foundation
import NarrationCore

/// Offline model initialization only: never invokes model acquisition or generates audio.
public enum SpeechSetupCheck {
    public static func run(configuration: WorkerConfiguration, workspace: URL, settings: SpeechSettings,
                           leaseFile: URL? = nil) async throws {
        let session = try NativeSpeechSession(configuration: configuration, workspace: workspace, settings: settings, leaseFile: leaseFile ?? configuration.inferenceLeaseFile)
        do {
            try await session.prepare()
            try Task.checkCancellation()
            await session.close()
        } catch {
            await session.close()
            throw error
        }
    }
}
