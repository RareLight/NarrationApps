import Foundation
import NarrationCore
import NativeSpeech
import ProcessingPipeline
import AudioOutput

/// Explicit offline native gate. Writes synthetic speech and receipts only to
/// the chosen output directory; never installs assets or changes product defaults.
enum ExpandedModelCheck {
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 4 || args.count == 5 else { throw SpeechFailure(.invalidInput) }
        let worker = URL(fileURLWithPath: args[0]), workspace = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
        let languages = args.count == 5 && args[4] == "languages"
        let reference = args.count == 5 && args[4] == "reference"
        let longform = args.count == 5 && (args[4] == "longform" || args[4].hasPrefix("longform-"))
        let longformModels: [SpeechModel]? = args.count == 5 && args[4].hasPrefix("longform-") ? SpeechModel(rawValue: String(args[4].dropFirst(9))).map { [$0] } : [.qwen3, .chatterbox, .orpheus]
        let selected: [SpeechModel]? = longform ? longformModels : languages ? [.qwen3] : reference ? [.chatterbox] : args.count == 5 ? SpeechModel(rawValue: args[4]).map { [$0] } : [.qwen3, .chatterbox, .orpheus]
        guard let models = selected, models.allSatisfy(\.isLarge) else { throw SpeechFailure(.invalidInput) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let phrase = "Hello, I can narrate everything from short articles to entire ebooks. Let's get started on a new read together!"
        let log = try DebugLog(workspace: workspace)
        let referenceStore = ReferenceVoiceStore(root: output.appendingPathComponent("profiles"))
        var referenceVoice: String?
        if reference {
            let input = output.deletingLastPathComponent().appendingPathComponent("native-voices-chatterbox/chatterbox-default.wav")
            referenceVoice = try referenceStore.importRecording(input).id
        }
        var records: [[String: Any]] = []
        for model in models {
            let choices: [(String, String)] = longform ? [(model.defaultVoice, "English")] : reference ? [(referenceVoice!, "English")] : languages ? model.languages.map { language in
                let voice = language == "Chinese" ? "Vivian" : language == "Japanese" ? "Ono_Anna" : language == "Korean" ? "Sohee" : "Ryan"
                return (voice, language)
            } : model.presetVoices.map { ($0, "English") }
            for (voice, language) in choices {
                try Task.checkCancellation()
                let settings = SpeechSettings(model: model, voice: voice, language: language == "English" ? nil : language)
                let phrase = longform ? """
                Chapter one. Dr. Rivera opened the notebook at 3 p.m. The first observation described a river, a bridge, and twelve small boats. Each sentence adds another detail, so the listener can follow the scene without seeing the page. At the end of the paragraph, she paused before continuing.

                Chapter two. On the following morning, the group compared measurements from three locations. The temperature was 18 degrees, and the distance was 4.5 kilometers. A repeated experiment does not guarantee an identical result. Instead, the team records its methods, checks the evidence, and explains the uncertainty.

                The final section returns to the original question. A careful reader distinguishes an observation from an assumption, keeps the source intact, and notices where the evidence ends. There is no need to hurry the last sentence. This is the end of the synthetic narration check.
                """ : languages ? NarrationSampleText.text(language: language) : phrase
                let blocks = phrase.components(separatedBy: "\n\n").map { ContentBlock(kind: .paragraph, text: $0, origin: .authored) }
                let projection = try NarrationPlanner.prepareForSpeech(.init(blocks: blocks, extractorVersion: "synthetic-model-check-1"), settings: settings)
                let config = WorkerConfiguration(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                    arguments: ["-p", "(version 1)(allow default)(deny network*)", worker.path, "--serve"],
                    environment: ["NARRATION_DEBUG_LOG": "1"], debugLog: log, inferencePriority: .background)
                let session = try NativeSpeechSession(configuration: config, workspace: workspace, settings: settings, referenceStore: referenceStore)
                let id = model.rawValue + "-" + (reference ? "reference" : voice) + (languages ? "-" + language : "")
                let wav = output.appendingPathComponent(id + ".wav")
                let aac = output.appendingPathComponent(id + ".m4a")
                let start = ContinuousClock.now
                do {
                    try await session.prepare()
                    let plan = try await session.prepareSpeech(projection)
                    if longform { guard plan.utterances.count >= 3 else { throw SpeechFailure(.protocolViolation) } }
                    try await session.render(plan: plan, destination: wav, identity: .init(batch: UUID(), job: UUID()))
                    await session.close()
                    let info = try NativeAudio.inspect(wav)
                    guard info.sampleRate == settings.model.capabilities.sampleRate, info.duration > 0 else { throw SpeechFailure(.generation) }
                    try NativeAudio.encode([wav], destination: aac, profile: .init(sampleRate: 24_000, bitRate: 64_000, gapSeconds: 0))
                    let record: [String: Any] = ["id": id, "workerSHA256": try NativeG2P.sha256(worker), "model": model.rawValue, "voice": voice, "name": voice.capitalized,
                        "phrase": phrase, "narrationChunks": plan.utterances.map(\.text), "speed": 1.0,
                        "sampleRate": 24000, "bitRate": 64000, "codec": "AAC-LC",
                        "modelRevision": NativePrimaryCatalog.specification(for: model).revision,
                        "sha256": try NativeG2P.sha256(aac), "preparedSpeech": try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))]
                    records.append(record)
                    try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("samples.json"), options: .atomic)
                    print("PASS \(id): \(info.duration)s audio; \(start.duration(to: .now)) including model lifecycle and encoding")
                    fflush(stdout)
                } catch { await session.close(); throw error }
            }
        }
    }
}
