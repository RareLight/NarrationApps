import Foundation
import NarrationCore
import NativeSpeech
import ProcessingPipeline

/// Pinned lexical conformance plus native fallback smoke, no acoustic quality claim.
enum FrontendCheck {
    struct Case: Codable { let text: String; let us: String?; let gb: String?; let reject: Bool? }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 5 else { throw SpeechFailure(.invalidInput) }
        let workspace = try NativeWorkspace(root: URL(fileURLWithPath: args[1]))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: args[4])))
        let output = URL(fileURLWithPath: args[2]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        for voice in ["af_heart", "bf_emma"] {
            let settings = SpeechSettings(voice: voice, speed: 1)
            let policy = SpeechPreparationPolicy.longformCandidate
            let configuration = WorkerConfiguration(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                arguments: ["-p", "(version 1)(allow default)(deny network*)", URL(fileURLWithPath: args[0]).standardizedFileURL.path, "--serve"])
            let session = try NativeSpeechSession(configuration: configuration, workspace: workspace.root,
                settings: settings, leaseFile: configuration.inferenceLeaseFile, policy: policy)
            do {
                try await session.prepare()
                for item in cases {
                    let projection = try NarrationPlanner.prepareForSpeech(.init(blocks: [.init(kind: .paragraph, text: item.text)], extractorVersion: "frontend-regression-1"), settings: settings, policy: policy)
                    let plan: PreparedSpeechPlan
                    do { plan = try await session.prepareSpeech(projection) }
                    catch let failure as SpeechFailure where item.reject == true && failure.code == .textPreparation {
                        records.append(["voice": voice, "text": item.text, "rejectedBeforeSynthesis": true])
                        continue
                    }
                    guard item.reject != true else { throw SpeechFailure(.invalidInput) }
                    let phones = plan.utterances.compactMap(\.phonemes).joined(separator: " ")
                    let expected = voice.hasPrefix("b") ? item.gb : item.us
                    guard !phones.isEmpty, expected == nil || expected == phones else {
                        throw NSError(domain: "FrontendCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pinned lexical conformance failed for \(voice): \(item.text)"])
                    }
                    records.append(["voice": voice, "text": item.text, "phonemes": phones,
                        "expected": expected as Any? ?? NSNull(), "tokens": plan.utterances.map(\.tokenCount),
                        "acousticIdentity": plan.acousticIdentity])
                }
                await session.close()
            } catch { await session.close(); throw error }
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "offline": true, "results": records], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("frontend.json"), options: .atomic)
        print("Pinned regional lexical cases and native out-of-dictionary fallback passed offline.")
    }
}
