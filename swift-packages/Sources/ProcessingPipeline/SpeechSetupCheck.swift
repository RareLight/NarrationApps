import Foundation
import NarrationCore

/// Offline model initialization only: never invokes model acquisition or generates audio.
public enum SpeechSetupCheck {
    public static func run(configuration: WorkerConfiguration, workspace: URL, settings: SpeechSettings,
                           leaseFile: URL? = nil) async throws {
        if let coordinator = configuration.workCoordinator {
            if let leaseFile, leaseFile.standardizedFileURL != coordinator.hostAdmission.inferenceFile.standardizedFileURL {
                throw SpeechFailure(.invalidInput)
            }
            let job = try await coordinator.openJob(identity: .init(batch: UUID(), job: UUID()), settings: settings,
                workspace: workspace, rank: configuration.inferencePriority == .interactive ? .libro : .podcast)
            do {
                _ = try await coordinator.perform(.initialize, job: job)
                try Task.checkCancellation()
                await coordinator.closeJob(job)
            } catch { await coordinator.closeJob(job); throw error }
            return
        }
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
