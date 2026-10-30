import Foundation
import Darwin
import BenchmarkCore
import NarrationCore
import NativeSpeech
import ProcessingPipeline
import AudioOutput
import Pronunciation

@main struct NarrationQualityCommand {
    static func main() async {
        Runtime.installSignals()
        let operation = Task { try await run() }
        let cancellation = Task {
            while !Task.isCancelled {
                if Runtime.cancelled != 0 { operation.cancel(); return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        defer { cancellation.cancel() }
        do { try await operation.value }
        catch is CancellationError { exit(130) }
        catch { fputs("Narration comparison: \((error as? BenchError)?.description ?? error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--pronunciation-check" {
            guard args.count == 4 else { throw BenchError("--pronunciation-check WORKSPACE NEW_OUTPUT PRODUCT_WORKER") }
            try await checkPronunciation(workspace: URL(fileURLWithPath: args[1]), output: URL(fileURLWithPath: args[2]), worker: URL(fileURLWithPath: args[3])); return
        }
        guard args.count >= 3, !args.contains("--help") else {
            print("tts-narration-quality WORKSPACE NEW_OUTPUT PRODUCT_WORKER [soprano qwen3 chatterbox orpheus]\nKokoro always uses semantic phrasing and is excluded from experimental pairs. Uses installed product assets only; run under the documented offline wrapper. No model downloads or settings changes. Identities stay hidden in comparison.html.")
            return
        }
        let workspace = URL(fileURLWithPath: args[0]).standardizedFileURL
        let output = URL(fileURLWithPath: args[1]).standardizedFileURL
        let worker = URL(fileURLWithPath: args[2]).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: output.path), FileManager.default.isExecutableFile(atPath: worker.path) else { throw BenchError("Use a new output directory and a complete validation helper") }
        let models = args.count == 3 ? SpeechModel.allCases.filter { $0 != .kokoro } : try args.dropFirst(3).map { name in
            guard let model = SpeechModel(rawValue: name) else { throw BenchError("Unknown product model") }; return model
        }
        guard !models.isEmpty, Set(models).count == models.count else { throw BenchError("Choose distinct models") }
        guard !models.contains(.kokoro) else { throw BenchError("Kokoro always uses semantic phrasing; choose another model for experimental pairs. Existing Kokoro comparisons remain unchanged.") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let audio = output.appendingPathComponent("audio"), evidence = output.appendingPathComponent("private-evidence")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let runID = Files.hash(UUID().uuidString)
        let document = SemanticDocument(title: "The field station", blocks: QualityComparison.paragraphs.enumerated().map {
            .init(kind: $0.offset == 1 ? .quote : .paragraph, text: $0.element, origin: .authored)
        }, extractorVersion: "quality-original-corpus-1")
        let reviewStore = NarrationReviewStore(root: output.appendingPathComponent("reviews"))
        var pairs: [QualityComparison.Pair] = [], identities: [[String: String]] = []
        var failedTakes = 0
        var rng = SplitMix(seed: 20261030)
        for (modelIndex, model) in models.enumerated() {
            try Task.checkCancellation()
            let pairID = modelIndex + 1
            let names = (0..<2).map { _ in UUID().uuidString.lowercased() + ".wav" }
            let order = [false, true].shuffled(using: &rng)
            var labels: [String] = []
            for (position, candidate) in order.enumerated() {
                var settings = SpeechSettings(model: model, voice: model.defaultVoice)
                settings.seed = 20261030; settings.retainReview = true
                settings.planning = candidate ? .semanticCandidate : nil
                let configuration = WorkerConfiguration(executable: worker, debugLog: try DebugLog(workspace: evidence), inferencePriority: .background)
                let session = try NativeSpeechSession(configuration: configuration, workspace: workspace, settings: settings, reviewStore: reviewStore)
                let started = ContinuousClock.now
                do {
                    try await session.prepare()
                    let projection = try NarrationPlanner.prepareForSpeech(document, settings: settings)
                    let plan = try await session.prepareSpeech(projection)
                    let receipt = evidence.appendingPathComponent("\(pairID)-\(position).json")
                    try Files.write(plan, receipt)
                    try await session.render(plan: plan, destination: audio.appendingPathComponent(names[position]), identity: .init(batch: UUID(), job: UUID()), progress: { _ in })
                    await session.close()
                    let info = try NativeAudio.inspect(audio.appendingPathComponent(names[position]))
                    let data: [String: String] = ["helperSHA256": try Files.hash(worker), "hostSHA256": try Files.hash(URL(fileURLWithPath: CommandLine.arguments[0])), "planSHA256": try Files.hash(receipt),
                        "audioSHA256": try Files.hash(audio.appendingPathComponent(names[position])), "frames": String(info.frames),
                        "sampleRate": String(info.sampleRate), "elapsedSeconds": String(Runtime.seconds(since: started)),
                        "audioPolicy": "raw-native; exact-zero structural gaps; no gain or fades", "seed": "20261030; reproducibility limited to pinned implementation/environment"]
                    try Files.write(data, evidence.appendingPathComponent("\(pairID)-\(position)-receipt.json"))
                    labels.append(model.label + " / " + model.defaultVoice + (candidate ? " / semantic phrasing" : " / accepted baseline"))
                    print("Completed comparison \(pairID), take \(position + 1).")
                } catch {
                    await session.close(); failedTakes += 1
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    try Files.write(["model": model.rawValue, "candidate": String(candidate), "error": error.localizedDescription,
                        "helperSHA256": try Files.hash(worker)], evidence.appendingPathComponent("\(pairID)-\(position)-failure.json"))
                    print("Comparison \(pairID), take \(position + 1) failed; private diagnostics retained. No replay or incomplete audio published.")
                }
            }
            guard labels.count == 2 else { continue }
            pairs.append(.init(id: pairID, text: QualityComparison.paragraphs.joined(separator: "\n\n"), a: "audio/" + names[0], b: "audio/" + names[1]))
            identities.append(["pair": String(pairID), "a": labels[0], "b": labels[1]])
        }
        struct IdentityFile: Encodable { let run: String; let identities: [[String: String]] }
        try Files.write(IdentityFile(run: runID, identities: identities), output.appendingPathComponent("identities.json"))
        try Files.write(["completedPairs": pairs.count, "failedTakes": failedTakes], output.appendingPathComponent("completion.json"))
        guard !pairs.isEmpty else { throw BenchError("No complete listening pairs. Private failure receipts retained.") }
        try Data(QualityComparison.page(pairs: pairs, identity: runID).utf8).write(to: output.appendingPathComponent("comparison.html"), options: .withoutOverwriting)
        print("Comparison ready: \(output.appendingPathComponent("comparison.html").path). Avoid private-evidence and identities.json until you finish listening.")
        if failedTakes > 0 { throw BenchError("Some takes failed; only complete pairs are included. Inspect private receipts before another explicit run.") }
    }

    static func checkPronunciation(workspace: URL, output: URL, worker: URL) async throws {
        guard !FileManager.default.fileExists(atPath: output.path) else { throw BenchError("Use a new pronunciation-check output directory") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let text = "Mina gives a behind-the-scenes look at a well-known, state-of-the-art workshop."
        let document = SemanticDocument(title: "The station", blocks: [.init(kind: .paragraph, text: text, origin: .authored)], extractorVersion: "phone-override-fixture-1")
        let dictionary = try PronunciationDictionary(entries: [.init(word: "Mina", spelling: "", documentTitle: "The station", model: "kokoro", phonemes: "zˈɛd")])
        for (index, voice) in ["af_heart", "bf_emma"].enumerated() {
            let settings = SpeechSettings(voice: voice)
            let session = try NativeSpeechSession(configuration: .init(executable: worker), workspace: workspace, settings: settings)
            do {
                try await session.prepare()
                let projection = try NarrationPlanner.prepareForSpeech(document, settings: settings, pronunciations: dictionary)
                let plan = try await session.prepareSpeech(projection)
                guard projection.chunks.map(\.text).joined(separator: " ") == text,
                      plan.policy == .current,
                      plan.utterances.first?.phonemes?.hasPrefix("zˈɛd") == true,
                      !plan.utterances.contains(where: { $0.phonemes?.contains("—") == true }),
                      ["behind-the-scenes", "well-known", "state-of-the-art"].allSatisfy({ compound in plan.utterances.contains { $0.text.contains(compound) } }) else { throw BenchError("Native aligned phone override or compound preparation failed") }
                try Files.write(plan, output.appendingPathComponent("\(index)-prepared.json"))
                let audio = output.appendingPathComponent("\(index).wav")
                try await session.render(plan: plan, destination: audio, identity: .init(batch: UUID(), job: UUID()))
                await session.close()
                let info = try NativeAudio.inspect(audio)
                guard info.frames > 0 else { throw BenchError("Native phone override produced empty audio") }
                try Files.write(["frames": String(info.frames), "sha256": try Files.hash(audio), "sourcePreserved": "true", "exactPhonesValidated": "zˈɛd"], output.appendingPathComponent("\(index)-receipt.json"))
            } catch { await session.close(); throw error }
        }
        print("Native US/GB aligned phone override preparation and rendering passed. Listening remains unassessed.")
    }
}
