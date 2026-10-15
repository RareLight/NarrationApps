import Foundation
import Darwin
import CryptoKit
import NarrationCore
import NativeSpeech
import ProcessingPipeline
import AudioOutput

/// Explicit developer evaluation only. All inputs/outputs are supplied paths;
/// generation is OS-sandboxed offline and never replaces bundled samples.
enum LongformCheck {
    struct Corpus: Decodable {
        let version: Int
        let id: String
        let provenance: String
        let title: String
        let blocks: [ContentBlock]
    }

    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 5 else { throw CocoaError(.fileReadInvalidFileName) }
        let worker = URL(fileURLWithPath: args[0]).standardizedFileURL
        let workspace = try NativeWorkspace(root: URL(fileURLWithPath: args[1]))
        let output = URL(fileURLWithPath: args[2]).standardizedFileURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let corpusBytes = try Data(contentsOf: URL(fileURLWithPath: args[4]))
        let corpus = try JSONDecoder().decode(Corpus.self, from: corpusBytes)
        guard corpus.version == 1, !corpus.blocks.isEmpty else { throw SpeechFailure(.invalidInput) }
        let selectedPolicy = SpeechPreparationPolicy(rawValue: ProcessInfo.processInfo.environment["NARRATION_CHECK_POLICY"] ?? SpeechPreparationPolicy.current.rawValue)
        guard let policy = selectedPolicy else { throw SpeechFailure(.invalidInput) }
        let document = SemanticDocument(title: corpus.title, blocks: corpus.blocks, extractorVersion: corpus.id)
        let debug = try DebugLog(workspace: output)
        let logOffset = (try? Data(contentsOf: debug.url).count) ?? 0
        let meter = LongformFootprint()
        let sampling = Task.detached {
            while !Task.isCancelled {
                meter.sample()
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
        defer { sampling.cancel() }
        var records: [[String: Any]] = []
        for voice in ["af_heart", "am_michael", "bf_emma"] {
            for speed: Float in [1.0, 1.1] {
                let settings = SpeechSettings(voice: voice, speed: speed)
                let planStart = Date()
                let projection = try NarrationPlanner.prepareForSpeech(document, settings: settings, policy: policy)
                let planningSeconds = Date().timeIntervalSince(planStart)
                for repetition in 1...2 {
                    let name = "\(voice)-\(speed)-\(repetition)"
                    let wav = output.appendingPathComponent(name + ".wav")
                    let aac = output.appendingPathComponent(name + ".m4a")
                    guard !FileManager.default.fileExists(atPath: wav.path), !FileManager.default.fileExists(atPath: aac.path) else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                    var config = WorkerConfiguration(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                        arguments: ["-p", "(version 1)(allow default)(deny network*)", worker.path, "--serve"])
                    config.debugLog = debug
                    let identity = AttemptIdentity(batch: UUID(), job: UUID())
                    let session = try NativeSpeechSession(configuration: config, workspace: workspace.root,
                        settings: settings, leaseFile: config.inferenceLeaseFile, policy: policy, identity: identity)
                    let initializationStart = Date()
                    do {
                        try await session.prepare()
                        let initializationSeconds = Date().timeIntervalSince(initializationStart)
                        let frontendStart = Date()
                        let plan = try await session.prepareSpeech(projection)
                        let frontendSeconds = Date().timeIntervalSince(frontendStart)
                        let renderStart = Date()
                        let firstPCM = FirstPCMLatency()
                        try await session.render(plan: plan, destination: wav, identity: identity, progress: { event in
                            if case .chunkWritten = event.phase, event.completedChunks == 1 {
                                firstPCM.record(Date().timeIntervalSince(renderStart))
                            }
                        })
                        let renderSeconds = Date().timeIntervalSince(renderStart)
                        await session.close()
                        let info = try NativeAudio.inspect(wav)
                        let encodingStart = Date()
                        let encoder = try AtomicAudioWriter(destination: aac, format: .m4a)
                        defer { encoder.abort() }
                        var nonzero = false
                        try NativeAudio.decode(wav) { samples in
                            nonzero = nonzero || samples.contains { abs($0) > 0.0001 }
                            try encoder.append(samples: samples, sampleRate: info.sampleRate)
                        }
                        try encoder.publish()
                        guard nonzero, info.sampleRate == 24_000 else { throw AudioOutputError.invalidPCM }
                        records.append(["voice": voice, "locale": voice.hasPrefix("b") ? "en-GB" : "en-US",
                            "speed": speed, "repetition": repetition, "planner": plan.semanticVersion, "policy": plan.policy.rawValue, "acousticIdentity": plan.acousticIdentity, "frontendSeconds": frontendSeconds, "provenance": plan.provenance ?? [:],
                            "planningSeconds": planningSeconds, "initializationSeconds": initializationSeconds,
                            "firstPCMChunkSeconds": firstPCM.value, "preparationAndFirstPCMSeconds": planningSeconds + initializationSeconds + frontendSeconds + firstPCM.value,
                            "inferenceAndWAVSeconds": renderSeconds, "encodingSeconds": Date().timeIntervalSince(encodingStart),
                            "realTimeFactor": renderSeconds / info.duration, "frames": info.frames, "duration": info.duration,
                            "chunks": plan.utterances.map { ["text": $0.text, "sourceScalars": $0.text.unicodeScalars.count,
                                "phonemes": $0.phonemes as Any? ?? NSNull(), "tokenCount": $0.tokenCount, "fingerprint": $0.fingerprint,
                                "boundaryAfter": $0.boundaryAfter.rawValue, "blockIndices": $0.source.blockIndices] as [String: Any] },
                            "wav": wav.lastPathComponent, "aac": aac.lastPathComponent,
                            "wavSHA256": SHA256.hash(data: try Data(contentsOf: wav)).map { String(format: "%02x", $0) }.joined()])
                        print("Completed \(name): \(plan.utterances.count) utterances, \(info.duration) seconds.")
                        fflush(stdout)
                    } catch { await session.close(); throw error }
                    try save(records, corpusBytes: corpusBytes, output: output, coordinatorPeak: meter.peak,
                             debug: debug.url, logOffset: logOffset)
                }
            }
        }
    }

    private static func save(_ records: [[String: Any]], corpusBytes: Data, output: URL,
                             coordinatorPeak: UInt64, debug: URL, logOffset: Int) throws {
        let bytes = try Data(contentsOf: debug)
        let log = String(decoding: bytes.dropFirst(min(logOffset, bytes.count)), as: UTF8.self)
        let regex = try NSRegularExpression(pattern: "peakFootprintBytes=([0-9]+)")
        let peaks = regex.matches(in: log, range: NSRange(log.startIndex..., in: log)).compactMap {
            Range($0.range(at: 1), in: log).flatMap { UInt64(log[$0]) }
        }
        let manifest: [String: Any] = ["version": 1, "offline": true, "normalization": false,
            "volumeLeveling": false, "randomSeed": NSNull(), "aacBitsPerSecond": 64_000, "aacSampleRate": 24_000,
            "workerSHA256": try NativeG2P.sha256(URL(fileURLWithPath: CommandLine.arguments[1])),
            "corpusSHA256": SHA256.hash(data: corpusBytes).map { String(format: "%02x", $0) }.joined(),
            "coordinatorPeakFootprintBytes": coordinatorPeak, "helperPeakFootprintBytes": peaks,
            "timingNote": "Inference timing includes bounded IPC and Float32 WAV writes. AAC encoding measured separately. No ASR/quality acceptance inferred.",
            "results": records]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("manifest.json"), options: [.atomic])
    }
}

private final class LongformFootprint: @unchecked Sendable {
    private let lock = NSLock()
    private var maximum: UInt64 = 0
    var peak: UInt64 { lock.withLock { maximum } }
    func sample() {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        if result == 0 { lock.withLock { maximum = max(maximum, usage.ri_phys_footprint) } }
    }
}

private final class FirstPCMLatency: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double = 0
    var value: Double { lock.withLock { seconds } }
    func record(_ value: Double) { lock.withLock { if seconds == 0 { seconds = value } } }
}
