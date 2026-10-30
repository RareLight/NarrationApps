import Foundation
import NarrationCore
import NativeSpeech
import ProcessingPipeline
import AudioOutput

/// Isolated catalog smoke, including explicit Soprano legacy parity routing.
enum CatalogCheck {
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 4 else { throw SpeechFailure(.invalidInput) }
        let workspace = try NativeWorkspace(root: URL(fileURLWithPath: args[1]))
        let output = URL(fileURLWithPath: args[2]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        for sample in VoiceSamples.catalog {
            let file = output.appendingPathComponent(sample.id + ".wav")
            guard !FileManager.default.fileExists(atPath: file.path) else { throw CocoaError(.fileWriteFileExists) }
            let configuration = WorkerConfiguration(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                arguments: ["-p", "(version 1)(allow default)(deny network*)", URL(fileURLWithPath: args[0]).standardizedFileURL.path, "--serve"])
            let policy = SpeechPreparationPolicy.selected(settings: sample.settings, requested: .current)
            let session = try NativeSpeechSession(configuration: configuration, workspace: workspace.root, settings: sample.settings,
                leaseFile: configuration.inferenceLeaseFile, policy: policy)
            do {
                try await session.prepare()
                let projection = try NarrationPlanner.prepareForSpeech(.init(blocks: [.init(kind: .paragraph,
                    text: "A careful reader follows the story, pauses at the river, and continues to the final page.")], extractorVersion: "catalog-smoke-1"), settings: sample.settings, policy: policy)
                let plan = try await session.prepareSpeech(projection)
                try await session.render(plan: plan, destination: file, identity: .init(batch: UUID(), job: UUID()))
                await session.close()
                let info = try NativeAudio.inspect(file)
                var nonzero = false
                try NativeAudio.decode(file) { samples in nonzero = nonzero || samples.contains { abs($0) > 0.0001 } }
                guard nonzero, info.sampleRate == sample.model.capabilities.sampleRate,
                      sample.model != .soprano || (plan.policy == .legacy && plan.utterances.allSatisfy { $0.phonemes == nil }) else {
                    throw AudioOutputError.invalidPCM
                }
                records.append(["id": sample.id, "frames": info.frames, "sampleRate": info.sampleRate,
                    "policy": plan.policy.rawValue, "acousticIdentity": plan.acousticIdentity, "sha256": try NativeG2P.sha256(file)])
                try JSONSerialization.data(withJSONObject: ["version": 1, "offline": true, "results": records], options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("catalog.json"), options: .atomic)
                print("Catalog smoke \(records.count)/\(VoiceSamples.catalog.count): \(sample.id)"); fflush(stdout)
            } catch { await session.close(); throw error }
        }
    }
}
