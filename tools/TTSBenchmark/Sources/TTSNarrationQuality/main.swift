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
        if args.isEmpty || args.contains("--help") {
            print("All product models now always use semantic phrasing. New baseline-versus-semantic comparisons are retired; existing comparison pages and choices remain unchanged.\nPronunciation check: tts-narration-quality --pronunciation-check WORKSPACE NEW_OUTPUT PRODUCT_WORKER")
            return
        }
        throw BenchError("All product models now always use semantic phrasing; new baseline-versus-semantic comparisons are unavailable. Existing comparisons remain unchanged.")
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
