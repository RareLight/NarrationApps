import Foundation
import Darwin
import NarrationCore
import NativeSpeech
import ProcessingPipeline
import AudioOutput

/// Explicit installed-assets check of the opt-in production host/helper seam.
/// It uses isolated demand metadata, global compatibility exclusion and no network.
enum CoordinatorCheck {
    static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 5, let model = SpeechModel(rawValue: arguments[4]) else { throw SpeechFailure(.invalidInput) }
        let executable = URL(fileURLWithPath: arguments[0]).standardizedFileURL
        let workspace = try NativeWorkspace(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
        let output = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard mkdir(output.path, 0o700) == 0 else { throw SpeechFailure(.storage) }
        var settings = SpeechSettings(model: model, voice: model.defaultVoice); settings.seed = 42
        let policy = SpeechPreparationPolicy.selected(settings: settings, requested: .current)
        let configuration = WorkerConfiguration(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: ["-p", "(version 1)(allow default)(deny network*)", executable.path, "--coordinated-serve"],
            requestTimeout: .seconds(900), shutdownGrace: 2, maximumFootprintBytes: SpeechMemoryPolicy.footprintLimit(for: model))
        let coordinator = try SpeechWorkCoordinator(owner: .voiceRelay, configuration: configuration, root: output.appendingPathComponent("admission"))
        var receipt: [String: Any] = ["schema": 1, "outcome": "running", "model": model.rawValue,
            "workerSHA256": try NativeG2P.sha256(executable), "wireVersion": SpeechProbeWire.version,
            "modelRevision": NativePrimaryCatalog.specification(for: model).revision, "listeningAcceptance": "not-performed",
            "generationCancellation": "covered separately by safety gate; not measured here"]
        func save() throws {
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("receipt.json"), options: .atomic)
        }
        try save()
        do {
            let lower = try await coordinator.openJob(identity: .init(batch: UUID(), job: UUID()), settings: settings,
                workspace: workspace.root, rank: .podcast)
            let initialized = try await coordinator.perform(.initialize, job: lower)
            guard case .initialized = initialized.value,
                  await coordinator.residentProcessIdentifier != nil else { throw SpeechFailure(.protocolViolation) }
            receipt["initializeOnlyVerified"] = true
            let text = "A calm voice reads this short synthetic sentence."
            let window = SpeechTextWindow(text: text, source: .init(blockIndices: [0], location: 0, length: text.utf16.count), boundaryAfter: .sentence)
            let preparation = try await coordinator.perform(.prepare(window, policy), job: lower)
            guard case .prepared(let utterances) = preparation.value, !utterances.isEmpty else { throw SpeechFailure(.protocolViolation) }
            try PreparedSpeechCoverage.validate(utterances, window: window)
            for utterance in utterances { try utterance.validate(identity: SpeechAcousticIdentity.make(settings: settings, policy: policy), prepared: policy.usesPreparedPhonemes) }
            let utterance = utterances[0]
            let first = try await coordinator.perform(.generate(utterance, policy), job: lower)
            guard case .audio(let initialPCM) = first.value, try lower.commit(first, index: 0, operation: {}) else { throw SpeechFailure(.generation) }
            let pid = await coordinator.residentProcessIdentifier
            let api = try await coordinator.openJob(identity: .init(batch: UUID(), job: UUID()), settings: settings,
                workspace: workspace.root, rank: .api, delivery: .streaming)
            let live = try await coordinator.perform(.generate(utterance, policy), job: api)
            guard case .audio(let apiPCM) = live.value, try api.commit(live, index: 0, operation: {}),
                  await coordinator.residentProcessIdentifier == pid else { throw SpeechFailure(.generation) }
            let codec = executable.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Frameworks/libmp3lame.0.dylib")
            receipt["codecSHA256"] = try NativeG2P.sha256(codec)
            for format in [AudioStreamFormat.mp3, .pcm] {
                let exported = try await SpeechCPUWork.run(job: api) {
                    try export(apiPCM, rate: model.capabilities.sampleRate, format: format,
                        codec: codec, output: output.appendingPathComponent("api-stream.\(format.rawValue)"))
                }
                receipt["\(format.rawValue)StreamBytes"] = exported.bytes
                receipt["\(format.rawValue)StreamBytesBeforeFlush"] = exported.beforeFlush
                receipt["\(format.rawValue)StreamSampleRate"] = AudioStreamEncoder.outputSampleRate
            }
            await coordinator.closeJob(api)
            let resumed = try await coordinator.perform(.generate(utterance, policy), job: lower)
            guard case .audio(let resumedPCM) = resumed.value, try lower.commit(resumed, index: 1, operation: {}),
                  await coordinator.residentProcessIdentifier == pid else { throw SpeechFailure(.generation) }
            for (name, pcm) in [("before", initialPCM), ("api", apiPCM), ("resumed", resumedPCM)] {
                let writer = try AtomicAudioWriter(destination: output.appendingPathComponent(name + ".wav"), format: .wav)
                defer { writer.abort() }
                try writer.append(samples: pcm, sampleRate: model.capabilities.sampleRate); try writer.publish(replaceExisting: false)
            }
            receipt["sampleCounts"] = [initialPCM.count, apiPCM.count, resumedPCM.count]
            receipt["sameWorkerPID"] = pid
            receipt["epochBefore"] = first.token.epoch; receipt["epochResumed"] = resumed.token.epoch
            receipt["preparedUnits"] = utterances.count; receipt["verifiedPrefix"] = lower.fence.verifiedPrefix
            // Exercise the persistence adapter's actual session boundary too:
            // generation returns owned PCM but cannot advance a checkpoint.
            var deferredConfiguration = configuration
            deferredConfiguration.workCoordinator = coordinator
            let session = try NativeSpeechSession(configuration: deferredConfiguration, workspace: workspace.root, settings: settings)
            try await session.prepare() // Queue its compatible context before releasing the old one.
            await coordinator.closeJob(lower)
            do {
                let generated = try await session.generateForCheckpoint(utterance)
                guard case .audio(let pcm) = generated.result.value, generated.job.fence.verifiedPrefix == 0,
                      await coordinator.residentProcessIdentifier == pid else { throw SpeechFailure(.generation) }
                let file = output.appendingPathComponent("deferred-checkpoint.wav")
                let writer = try AtomicAudioWriter(destination: file, format: .wav)
                defer { writer.abort() }
                try writer.append(samples: pcm, sampleRate: model.capabilities.sampleRate); try writer.publish(replaceExisting: false)
                var decoded: [Float] = []
                try NativeAudio.decode(file) { decoded += $0 }
                guard decoded == pcm, try generated.job.commit(generated.result.receipt, index: 0, operation: {}),
                      generated.job.fence.verifiedPrefix == 1 else { throw SpeechFailure(.generation) }
                receipt["deferredCheckpointFrames"] = pcm.count
                receipt["deferredCheckpointReadbackExact"] = true
                await session.close()
            } catch { await session.close(); throw error }
            await coordinator.close()
            guard let pid, kill(pid, 0) == -1, errno == ESRCH else { throw SpeechFailure(.workerExited) }
            receipt["ownedWorkerReaped"] = true; receipt["outcome"] = "passed"; try save()
            print("Coordinated preparation, API warm reuse, resume and owned reap passed: \(model.rawValue)")
        } catch {
            await coordinator.close(); receipt["outcome"] = "failed"
            receipt["failure"] = (error as? SpeechFailure)?.code.rawValue ?? "coordinator"
            try? save(); throw error
        }
    }

    /// Owned fixture files receive only sequential codec writes. Never seek,
    /// concatenate independently encoded fragments or modify source PCM.
    private static func export(_ pcm: [Float], rate: Int, format: AudioStreamFormat, codec: URL, output: URL) throws -> (bytes: UInt64, beforeFlush: UInt64) {
        let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SpeechFailure(.storage) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: output) } }
        let encoder = try AudioStreamEncoder(format: format, inputSampleRate: rate, mp3Library: codec) { try file.write(contentsOf: $0) }
        defer { encoder.abort() }
        for start in stride(from: 0, to: pcm.count, by: 4_096) {
            try encoder.append(Array(pcm[start..<min(pcm.count, start + 4_096)]))
        }
        let beforeFlush = encoder.outputBytes
        try encoder.finish(); try file.synchronize()
        guard beforeFlush > 0, encoder.outputBytes > 0 else { throw AudioOutputError.encoding }
        succeeded = true
        return (encoder.outputBytes, beforeFlush)
    }
}
