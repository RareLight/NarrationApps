import Foundation
import Pronunciation
import Darwin
import AVFoundation
import AudioToolbox
import NarrationCore
import NativeSpeech
import AudioOutput
import ProcessingPipeline

enum SampleGenerationError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let message): message } }
}

struct SampleManifest: Codable {
    let version: Int
    let inputText: String
    let plannerVersion: String
    let pronunciationOverridesFingerprint: String?
    let pronunciationRevision: String
    let samples: [SampleRecord]
}

struct SampleRecord: Codable {
    let id: String
    let model: String
    let voice: String
    let name: String
    let phrase: String
    let narrationChunks: [String]
    let speed: Float
    let sampleRate: Int
    let bitRate: Int
    let codec: String
    let modelRevision: String
    let sha256: String
    var preparedSpeech: PreparedSpeechPlan? = nil
}

enum SampleGeneration {
    static func text(arguments: [String]) throws -> String {
        guard arguments.count == 1, !arguments[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SampleGenerationError.message("Usage: VoiceSampleGenerator \"Text for every voice to narrate\" (exactly one nonempty argument).")
        }
        return arguments[0]
    }

    static func projection(text: String, sample: VoiceSample, pronunciations: PronunciationDictionary = .empty) throws -> NarrationPlan {
        let document = SemanticDocument(blocks: [.init(kind: .paragraph, text: text, origin: .authored)], extractorVersion: "Foundation-text-1")
        return try NarrationPlanner.prepareForSpeech(document, settings: sample.settings, pronunciations: pronunciations)
    }

    static func chunks(text: String, sample: VoiceSample, pronunciations: PronunciationDictionary = .empty) throws -> [String] {
        try projection(text: text, sample: sample, pronunciations: pronunciations).chunks.map(\.text)
    }

    static func workspaces(packageRoot: URL, override: URL? = nil) throws -> [SpeechModel: URL] {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let candidates = override.map { [$0] } ?? [packageRoot.deletingLastPathComponent().appendingPathComponent("Libro"),
                          support.appendingPathComponent("Libro/SpeechRuntime"),
                          support.appendingPathComponent("VoiceRelayPrototype/SpeechRuntime")]
        var result: [SpeechModel: URL] = [:]
        for model in SpeechModel.allCases {
            for root in candidates {
                do {
                    let workspace = try NativeWorkspace(root: root)
                    try autoreleasepool {
                        // Validate the full present inventory once, then require every
                        // catalog voice. Avoid rehashing the model for each voice.
                        let directory = try workspace.primaryDirectory(for: model)
                        if model == .kokoro {
                            for sample in VoiceSamples.catalog where sample.model == .kokoro {
                                try workspace.validateFile(directory.appendingPathComponent("voices/\(sample.voice).safetensors"))
                            }
                            try NativeG2P.validate(directory: workspace.g2pDirectory, workspace: workspace)
                            try BritishG2P.validate(directory: BritishG2P.directory(in: workspace), workspace: workspace)
                        }
                    }
                    result[model] = workspace.root
                    break
                } catch { continue }
            }
            guard result[model] != nil else {
                throw SampleGenerationError.message("No prepared \(model.rawValue) workspace with all supported voices was found in the selected prepared workspace(s). Prepare it in the app first. No models were downloaded.")
            }
        }
        return result
    }

    static func render(sample: VoiceSample, projection: NarrationPlan, wav: URL, worker: URL, workspace: URL) async throws {
        let configuration = WorkerConfiguration(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: ["-p", "(version 1)(allow default)(deny network*)", worker.path, "--serve"],
            inferencePriority: .background)
        let session = try NativeSpeechSession(configuration: configuration, workspace: workspace, settings: sample.settings)
        do {
            try await session.prepare()
            let plan = try await session.prepareSpeech(projection)
            try await session.render(plan: plan, destination: wav, identity: .init(batch: UUID(), job: UUID()))
            try JSONEncoder().encode(plan).write(to: wav.appendingPathExtension("prepared.json"), options: .atomic)
            await session.close()
        } catch { await session.close(); throw error }
    }

    private static func preparedPlan(beside wav: URL) throws -> PreparedSpeechPlan? {
        let url = wav.appendingPathExtension("prepared.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil } // injected model-free fixtures
        defer { try? FileManager.default.removeItem(at: url) }
        return try JSONDecoder().decode(PreparedSpeechPlan.self, from: Data(contentsOf: url))
    }

    static func regenerate(text: String, pronunciations: PronunciationDictionary = .empty, destination: URL, lockFile: URL,
        render: @Sendable (VoiceSample, NarrationPlan, URL) async throws -> Void) async throws {
        _ = try self.text(arguments: [text])
        // Validate every plan before starting expensive inference.
        let plans = try VoiceSamples.catalog.map { ($0, try projection(text: text, sample: $0, pronunciations: pronunciations)) }
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        guard destination.standardizedFileURL == destination.resolvingSymlinksInPath(),
              (try manager.attributesOfItem(atPath: destination.path)[.type]) as? FileAttributeType == .typeDirectory else {
            throw SampleGenerationError.message("The source sample folder must be an existing directory without symlinks.")
        }
        try manager.createDirectory(at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockFile.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw SampleGenerationError.message("Another voice-sample generator is already running.")
        }
        // Same-volume exclusive staging makes a single atomic directory exchange possible.
        let stage = parent.appendingPathComponent(".voice-samples-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(stage.path, 0o700) == 0 else { throw POSIXError(.EIO) }
        defer { try? manager.removeItem(at: stage) }
        var records: [SampleRecord] = []
        for (sample, projection) in plans {
            let chunks = projection.chunks.map(\.text)
            try Task.checkCancellation()
            let wav = stage.appendingPathComponent("\(sample.id).wav")
            let audio = stage.appendingPathComponent("\(sample.id).m4a")
            try await render(sample, projection, wav)
            try Task.checkCancellation()
            try NativeAudio.encode([wav], destination: audio, profile: .init(sampleRate: 24_000, bitRate: 64_000, gapSeconds: 0))
            let info = try NativeAudio.inspect(audio)
            let file = try AVAudioFile(forReading: audio)
            guard info.codec == "aac", info.sampleRate == 24_000, info.channels == 1, info.duration > 0,
                  file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC else {
                throw SampleGenerationError.message("Invalid AAC sample for \(sample.id).")
            }
            var nonzero = false
            try NativeAudio.decode(audio) { frames in
                guard frames.allSatisfy(\.isFinite) else { throw SampleGenerationError.message("Nonfinite sample audio.") }
                nonzero = nonzero || frames.contains { $0 != 0 }
            }
            guard nonzero else { throw SampleGenerationError.message("Silent sample for \(sample.id).") }
            records.append(.init(id: sample.id, model: sample.model.rawValue, voice: sample.voice, name: sample.name,
                phrase: text, narrationChunks: chunks, speed: sample.settings.speed,
                sampleRate: 24_000, bitRate: 64_000, codec: "AAC-LC",
                modelRevision: NativePrimaryCatalog.specification(for: sample.model).revision,
                sha256: try NativeG2P.sha256(audio), preparedSpeech: try preparedPlan(beside: wav)))
            try manager.removeItem(at: wav)
            try FileHandle.standardOutput.write(contentsOf: Data("Rendered \(records.count)/\(plans.count): \(sample.id)\n".utf8))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(SampleManifest(version: 3, inputText: text, plannerVersion: NarrationPlanner.version,
            pronunciationOverridesFingerprint: pronunciations.fingerprint.isEmpty ? nil : pronunciations.fingerprint, pronunciationRevision: NativeG2P.revision, samples: records))
            .write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
        try Task.checkCancellation()
        guard destination.standardizedFileURL == destination.resolvingSymlinksInPath(),
              (try manager.attributesOfItem(atPath: destination.path)[.type]) as? FileAttributeType == .typeDirectory else {
            throw SampleGenerationError.message("The source sample folder changed during generation.")
        }
        guard renamex_np(stage.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // stage now contains the old assets. Cleanup only after the complete new inventory is visible.
    }
}
