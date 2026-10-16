import Foundation
import Darwin
import NativeSpeech
import Pronunciation

/// Developer-only source asset tool. Neither GUI embeds this executable.
@main
struct VoiceSampleGenerator {
    static func main() async {
        do {
            let text = try SampleGeneration.text(arguments: Array(CommandLine.arguments.dropFirst()))
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard let executable = Bundle.main.executableURL else {
                throw SampleGenerationError.message("Cannot locate the utility executable.")
            }
            let worker = executable.deletingLastPathComponent().appendingPathComponent("NarrationSpeechWorker")
            guard FileManager.default.isExecutableFile(atPath: worker.path) else {
                throw SampleGenerationError.message("Build the companion NarrationSpeechWorker first, or use scripts/regenerate-voice-samples.sh.")
            }
            let pronunciations = try PronunciationStore().load().dictionary
            let override = ProcessInfo.processInfo.environment["NARRATION_SAMPLE_WORKSPACE"].map { URL(fileURLWithPath: $0) }
            let workspaces = try SampleGeneration.workspaces(packageRoot: root, override: override)
            let task = Task {
                try await SampleGeneration.regenerate(text: text, pronunciations: pronunciations,
                    destination: root.appendingPathComponent("Sources/NativeSpeech/Resources/VoiceSamples"),
                    lockFile: root.appendingPathComponent(".build/voice-sample-generator.lock")) { sample, projection, wav in
                    guard let workspace = workspaces[sample.model] else { throw SampleGenerationError.message("Missing model workspace.") }
                    try await SampleGeneration.render(sample: sample, projection: projection, wav: wav, worker: worker, workspace: workspace)
                }
            }
            // Cooperative cancellation reaps the owned helper and removes staging before exit.
            signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            interrupt.setEventHandler { @Sendable in task.cancel() }; terminate.setEventHandler { @Sendable in task.cancel() }
            interrupt.resume(); terminate.resume()
            defer { interrupt.cancel(); terminate.cancel() }
            try await task.value
            print("Replaced all \(VoiceSamples.catalog.count) shared voice samples. Rebuild Libro and VoiceRelay to bundle them.")
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Voice samples unchanged: \(error.localizedDescription)\n".utf8))
            exit(error is CancellationError ? 130 : 1)
        }
    }
}
