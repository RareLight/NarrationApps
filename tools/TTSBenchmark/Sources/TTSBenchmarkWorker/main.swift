import Foundation
import Darwin
import BenchmarkCore
import NarrationCore
import HuggingFace
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioTTS
import MLXLMCommon

@main struct ModelWorker {
    static func main() async {
        // Upstream diagnostics must never be interpreted as control records.
        let control = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        func emit(_ event: BenchmarkCore.WorkerEvent) throws {
            try control.write(contentsOf: JSONEncoder().encode(event) + Data([10]))
        }
        do {
            guard CommandLine.arguments.count == 2 else { throw BenchError("Worker requires a job file") }
            let job = try Files.read(WorkerJob.self, URL(fileURLWithPath: CommandLine.arguments[1]))
            try job.matrix.validate()
            Memory.cacheLimit = 64 * 1_024 * 1_024
            Memory.memoryLimit = Int(job.matrix.footprintLimitBytes * 3 / 4)
            let folder = URL(fileURLWithPath: job.assetDirectory), workspace = URL(fileURLWithPath: job.workspace)
            if job.profile.family == "qwen3_tts", let voice = job.profile.voice {
                let config = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("config.json"))) as? [String: Any]
                let talker = config?["talker_config"] as? [String: Any]
                let voices = talker?["spk_id"] as? [String: Any]
                let speaker = voice.split(separator: ",", maxSplits: 1).first!.trimmingCharacters(in: .whitespaces).lowercased()
                guard voices?[speaker] != nil else { throw BenchError("Requested Qwen speaker is absent; no default substitution") }
            }
            let loadWait = ContinuousClock.now
            var lease: InferenceLease? = try await InferenceLease.acquire(priority: .background)
            var admission = Runtime.seconds(since: loadWait)
            let loadStart = ContinuousClock.now
            let model: any SpeechGenerationModel
            if job.profile.family == "kokoro" {
                guard let path = job.g2pDirectory else { throw BenchError("Missing pinned G2P") }
                let processor = MisakiTextProcessor(resourceDirectory: URL(fileURLWithPath: path))
                model = try await KokoroModel.fromModelDirectory(folder, textProcessor: processor)
            } else if job.profile.family == "soprano" {
                model = try await SopranoModel.fromModelDirectory(folder, repo: job.profile.repository)
            } else {
                model = try await TTS.loadModel(modelRepo: folder.path, modelType: job.profile.family)
            }
            let loadSeconds = Runtime.seconds(since: loadStart)
            withExtendedLifetime(lease) {}
            lease = nil
            // Reading reference samples does not change their amplitude. Model-specific
            // reference encoding remains part of generation unless the implementation caches it.
            var reference: MLXArray?
            if let path = job.profile.referenceAudio {
                let (_, audio) = try loadAudioArray(from: Files.child(workspace, path), sampleRate: model.sampleRate)
                reference = audio
            }
            if let chatterbox = model as? ChatterboxModel {
                chatterbox.preserveNarrationPCM = true
                guard job.profile.voice == nil, job.profile.maxTokens == chatterbox.config.t3Config.maxSpeechTokens else {
                    throw BenchError("Pinned Chatterbox uses its config token cap and reference conditioning; named-voice/budget overrides are unsupported")
                }
                if reference == nil, (chatterbox.defaultConditioning?.condPromptSpeechTokens.size ?? 0) == 0 {
                    throw BenchError("Chatterbox default conditioning failed to load")
                }
            }
            try emit(.init("loaded", seconds: loadSeconds))
            var parameters = model.defaultGenerationParameters
            parameters.maxTokens = job.profile.maxTokens
            let parameterDescription = "maxTokens=\(job.profile.maxTokens), temperature=\(parameters.temperature), topP=\(parameters.topP), repetitionPenalty=\(String(describing: parameters.repetitionPenalty)); global MLX seed recorded per repetition; native defaults otherwise; reference encode may be cached by model; outputPCM=raw-native-no-application-gain; Chatterbox peak-normalization/fade disabled (policy 20261027-1)"
            var firstCall = true
            for passage in job.matrix.passages {
                let chunks = try TextChunks.make(passage.text, limit: job.profile.maxCharacters)
                for repetition in 0...job.matrix.repetitions {
                    Memory.peakMemory = 0
                    let requestStart = ContinuousClock.now
                    let seed = job.matrix.seed &+ UInt64(repetition)
                    MLXRandom.seed(seed)
                    parameters.seed = seed
                    var samples: [Float] = [], generationSeconds: Double = 0, firstPCM: Double?, tokens = 0
                    var tokenMetricAvailable = false
                    let state = repetition == 0 ? (firstCall ? "cold" : "warmup") : "warm"
                    for chunk in chunks {
                        let wait = ContinuousClock.now
                        lease = try await InferenceLease.acquire(priority: .background)
                        admission += Runtime.seconds(since: wait)
                        let callStart = ContinuousClock.now
                        var chunkSamples: [Float] = [], tokenEvents = 0, infoTokenCount: Int?
                        // Some models return only one final audio event. Its latency is
                        // recorded as first PCM, never advertised as acoustic streaming.
                        for try await event in model.generateStream(text: chunk, voice: job.profile.voice,
                            refAudio: reference, refText: job.profile.referenceText, language: job.profile.language,
                            generationParameters: parameters) {
                            switch event {
                            case .audio(let audio):
                                let materialized = audio.reshaped([-1]).asArray(Float.self)
                                guard materialized.allSatisfy(\.isFinite) else { throw BenchError("Non-finite generated PCM") }
                                if !materialized.isEmpty, firstPCM == nil { firstPCM = Runtime.seconds(since: requestStart) }
                                guard Double(samples.count + chunkSamples.count + materialized.count) / Double(model.sampleRate) <= job.matrix.maximumAudioSeconds else { throw BenchError("Output-duration limit reached") }
                                chunkSamples.append(contentsOf: materialized)
                            case .token: tokenEvents += 1
                            case .info(let info): infoTokenCount = info.generationTokenCount
                            case .progress: break
                            }
                        }
                        generationSeconds += Runtime.seconds(since: callStart)
                        let count = GenerationEvidence.tokenCount(family: job.profile.family, info: infoTokenCount, events: tokenEvents)
                        if let count { tokenMetricAvailable = true; tokens += count }
                        try GenerationEvidence.verifyCeiling(family: job.profile.family, count: count, maximum: job.profile.maxTokens)
                        guard !chunkSamples.isEmpty else { throw BenchError("Model returned no audio") }
                        samples.append(contentsOf: chunkSamples)
                        withExtendedLifetime(lease) {}
                        lease = nil
                    }
                    firstCall = false
                    let name = "\(passage.id)-\(state)-\(repetition).wav"
                    let target = URL(fileURLWithPath: job.output).appendingPathComponent(name)
                    let info = try Wave.write(samples, rate: model.sampleRate, to: target)
                    let measurement = Measurement(profile: job.profile.id, passage: passage.id,
                        repetition: repetition, state: state, seconds: generationSeconds,
                        requestSeconds: Runtime.seconds(since: requestStart), firstPCMSeconds: firstPCM,
                        admissionSeconds: admission, duration: info.duration, frames: info.frames, sampleRate: info.rate,
                        tokenCount: tokenMetricAvailable ? tokens : nil, mlxPeakBytes: Memory.peakMemory,
                        chunks: chunks, wav: name, sha256: try Files.hash(target), peakAmplitude: info.peak,
                        clippedSamples: info.clipped, generationParameters: parameterDescription + "; seed=\(seed); token ceiling verified only when true generated-token counts are exposed; unavailable counts/EOS are not inferred from PCM length")
                    try emit(.init("measurement", measurement: measurement))
                    admission = 0
                }
            }
            withExtendedLifetime(lease) {}
            try emit(.init("finished"))
        } catch {
            try? emit(.init("failure", message: String(describing: error).prefix(2000).description))
            exit(1)
        }
    }
}
