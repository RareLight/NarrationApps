import Foundation
import NarrationCore
import NativeSpeech
import ProcessingPipeline

/// Pinned lexical conformance plus native fallback smoke, no acoustic quality claim.
enum FrontendCheck {
    struct Case: Codable { let text: String; let us: String?; let gb: String?; let reject: Bool?; let spoken: String?; let compounds: [String]? }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 5 else { throw SpeechFailure(.invalidInput) }
        let workspace = try NativeWorkspace(root: URL(fileURLWithPath: args[1]))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: args[4])))
        let output = URL(fileURLWithPath: args[2]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        for voice in ["af_heart", "bf_emma"] {
            let settings = SpeechSettings(voice: voice, speed: 1)
            let policy = SpeechPreparationPolicy.current
            let configuration = WorkerConfiguration(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                arguments: ["-p", "(version 1)(allow default)(deny network*)", URL(fileURLWithPath: args[0]).standardizedFileURL.path, "--serve"])
            var session = try NativeSpeechSession(configuration: configuration, workspace: workspace.root,
                settings: settings, leaseFile: configuration.inferenceLeaseFile, policy: policy)
            do {
                try await session.prepare()
                for (caseIndex, item) in cases.enumerated() {
                    print("Frontend fixture \(caseIndex + 1)/\(cases.count), \(voice)")
                    let projection = try NarrationPlanner.prepareForSpeech(.init(blocks: [.init(kind: .paragraph, text: item.text, origin: .authored)], extractorVersion: "frontend-regression-1"), settings: settings, policy: policy)
                    let preparationStart = ContinuousClock.now
                    let plan: PreparedSpeechPlan
                    do { plan = try await session.prepareSpeech(projection) }
                    catch let failure as SpeechFailure where item.reject == true && failure.code == .textPreparation {
                        records.append(["voice": voice, "text": item.text, "rejectedBeforeSynthesis": true])
                        // Preparation failures intentionally close their session.
                        // Later fixtures need a fresh, explicitly owned helper.
                        await session.close()
                        if caseIndex + 1 < cases.count {
                            session = try NativeSpeechSession(configuration: configuration, workspace: workspace.root,
                                settings: settings, leaseFile: configuration.inferenceLeaseFile, policy: policy)
                            try await session.prepare()
                        }
                        continue
                    }
                    guard item.reject != true else { throw SpeechFailure(.invalidInput) }
                    let preparationTime = preparationStart.duration(to: .now)
                    let phones = plan.utterances.compactMap(\.phonemes).joined(separator: " ")
                    if let spoken = item.spoken {
                        guard projection.chunks.map(\.text).joined(separator: " ") == spoken else { throw NSError(domain: "FrontendCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "Spoken projection mismatch at fixture \(caseIndex + 1), \(voice)"]) }
                        let reference = try NarrationPlanner.prepareForSpeech(.init(blocks: [.init(kind: .paragraph, text: spoken, origin: .authored)], extractorVersion: "independent-spoken-reference-1"), settings: settings, policy: policy)
                        let control = try await session.prepareSpeech(reference)
                        guard phones == control.utterances.compactMap(\.phonemes).joined(separator: " ") else { throw NSError(domain: "FrontendCheck", code: 3, userInfo: [NSLocalizedDescriptionKey: "Independent phoneme reference mismatch at fixture \(caseIndex + 1), \(voice)"]) }
                    }
                    let expected = voice.hasPrefix("b") ? item.gb : item.us
                    if let compounds = item.compounds {
                        guard plan.policy == .current, !phones.contains("—"), compounds.allSatisfy({ compound in
                            plan.utterances.contains { $0.text.contains(compound) }
                        }) else { throw NSError(domain: "FrontendCheck", code: 4, userInfo: [NSLocalizedDescriptionKey: "Compound gained a dash pause or split at fixture \(caseIndex + 1), \(voice)"]) }
                    }
                    guard !phones.isEmpty, expected == nil || expected == phones else {
                        throw NSError(domain: "FrontendCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pinned lexical conformance failed for \(voice): \(item.text)"])
                    }
                    records.append(["voice": voice, "text": item.text, "phonemes": phones,
                        "expected": expected as Any? ?? NSNull(), "tokens": plan.utterances.map(\.tokenCount),
                        "acousticIdentity": plan.acousticIdentity, "projection": projection.chunks.map(\.text).joined(separator: " "), "policy": policy.rawValue, "frontendSeconds": Double(preparationTime.components.seconds) + Double(preparationTime.components.attoseconds) / 1e18])
                }
                await session.close()
            } catch { await session.close(); throw error }
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "offline": true, "results": records], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("frontend.json"), options: .atomic)
        print("Pinned regional lexical cases and native out-of-dictionary fallback passed offline.")
    }
}
