import Foundation
import NarrationCore
import NativeSpeech
import ProcessingPipeline
import Darwin

/// Two real helpers, one serialized resident model. The driver orchestrates the
/// acceptance/cancel sequence; this is not production scheduler integration.
enum HandoffReloadCheck {
    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 6, let model = SpeechModel(rawValue: args[4]), model != .soprano else { throw SpeechFailure(.invalidInput) }
        let workspace = try NativeWorkspace(root: URL(fileURLWithPath: args[1]))
        let output = URL(fileURLWithPath: args[2]).standardizedFileURL
        guard mkdir(output.path, 0o700) == 0 else { throw SpeechFailure(.storage) }
        var stages: [URL] = [], clients: [SpeechProbeProcess] = []
        defer { for client in clients { try? client.close() } }
        var trace: [[String: Any]] = []
        var receipt: [String: Any] = ["schema": 1, "outcome": "running", "model": model.rawValue,
            "oldOwner": "Libro", "newOwner": "VoiceRelay", "orchestration": "probe-driver",
            "transport": "private-pipes-network-denied", "listeningAcceptance": "not-performed",
            "oldWorkerSHA256": try NativeG2P.sha256(URL(fileURLWithPath: args[0])),
            "newWorkerSHA256": try NativeG2P.sha256(URL(fileURLWithPath: args[5]))]
        let receiptFile = output.appendingPathComponent("receipt.json")
        func save() throws {
            receipt["trace"] = trace
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: receiptFile, options: .atomic)
        }
        func next(_ client: SpeechProbeProcess, _ owner: String, timeout: Double = 180) throws -> SpeechProbeEvent {
            let event = try client.next(timeout: timeout)
            trace.append(["owner": owner, "kind": event.kind.rawValue, "time": event.time,
                "worker": event.worker.uuidString, "pid": event.pid, "frame": event.frame?.chunk ?? -1])
            if event.kind == .failure { throw SpeechFailure(event.failure ?? .generation) }
            return event
        }
        func client(_ worker: String) throws -> SpeechProbeProcess {
            let value = try SpeechProbeProcess(configuration: .init(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                arguments: ["-p", "(version 1)(allow default)(deny network*)", worker, "--handoff-probe"],
                shutdownGrace: 2, terminationGrace: 1, maximumFootprintBytes: SpeechMemoryPolicy.footprintLimit(for: model)))
            clients.append(value); return value
        }
        func initialize(_ client: SpeechProbeProcess) throws {
            let stage = try workspace.managed(workspace.nativeRoot.appendingPathComponent("staging/attempt-\(UUID().uuidString)"))
            guard mkdir(stage.path, 0o700) == 0 else { throw SpeechFailure(.storage) }
            stages.append(stage)
            var settings = SpeechSettings(model: model, voice: model.defaultVoice); settings.seed = 42
            try client.send(.initialize, .init(kind: .initialize, identity: .init(batch: UUID(), job: UUID()),
                workspace: workspace.root, settings: settings, spoolDirectory: stage))
        }
        let text = "A quiet morning begins beside the river. Three small boats pass under the bridge. The reader follows their progress from the bank."
        try save()
        do {
            let old = try client(args[0]); try initialize(old)
            while try next(old, "Libro", timeout: 900).kind != .initialized {}
            let oldJob = AttemptIdentity(batch: UUID(), job: UUID())
            try old.send(.generate, .init(kind: .generate, identity: oldJob, text: text))
            guard try next(old, "Libro").kind == .started else { throw SpeechFailure(.protocolViolation) }
            let accepted = ProcessInfo.processInfo.systemUptime
            let new = try client(args[5]); try initialize(new)
            let waiting = try next(new, "VoiceRelay")
            guard waiting.kind == .waitingForLease else { throw SpeechFailure(.protocolViolation) }
            do { _ = try new.next(timeout: 0.1); throw SpeechFailure(.protocolViolation) }
            catch let error as SpeechFailure where error.code == .timeout {}
            let cancelTime = ProcessInfo.processInfo.systemUptime
            try old.send(.cancel, .init(kind: .cancel, identity: oldJob))
            var revoked = false, quiescent = false
            var oldReady: Double = 0
            while true {
                let event = try next(old, "Libro", timeout: 30)
                if event.kind == .revoked { revoked = true }
                if event.kind == .quiescent { quiescent = true }
                if event.kind == .ready { oldReady = event.time; break }
            }
            guard revoked, quiescent else { throw SpeechFailure(.generation) }
            let unloadRequested = ProcessInfo.processInfo.systemUptime
            try old.finishInput()
            let unloaded = try next(old, "Libro", timeout: 30)
            guard unloaded.kind == .unloaded else { throw SpeechFailure(.protocolViolation) }
            try old.close()
            let acquired = try next(new, "VoiceRelay", timeout: 900)
            guard acquired.kind == .leaseAcquired, acquired.time >= unloaded.time else { throw SpeechFailure(.protocolViolation) }
            guard try next(new, "VoiceRelay", timeout: 900).kind == .loadingModel else { throw SpeechFailure(.protocolViolation) }
            let initialized = try next(new, "VoiceRelay", timeout: 900)
            guard initialized.kind == .initialized, old.pid != new.pid else { throw SpeechFailure(.protocolViolation) }
            let newJob = AttemptIdentity(batch: UUID(), job: UUID())
            let mode: SpeechProbeAudioMode = model == .qwen3 ? .qwenIncremental : .firstSentence
            try new.send(.generate, .init(kind: .generate, identity: newJob, text: text), mode: mode)
            var firstAudio: Double?, index = 0
            while firstAudio == nil {
                let event = try next(new, "VoiceRelay")
                if event.kind == .started { continue }
                guard event.kind == .frame else { throw SpeechFailure(.protocolViolation) }
                let spool = stages[1].appendingPathComponent("job-\(newJob.attempt.uuidString)")
                let samples = try SpeechProbeProcess.readFrame(event, spool: spool, model: model, index: index)
                if samples.contains(where: { $0 != 0 }) {
                    let wav = output.appendingPathComponent("first.wav")
                    try ProbeAudio.publish(samples, rate: model.capabilities.sampleRate, to: wav)
                    firstAudio = ProcessInfo.processInfo.systemUptime
                    try ProbeAudio.verify(samples, rate: model.capabilities.sampleRate, wav: wav)
                } else {
                    try new.send(.acknowledge, .init(kind: .generate, identity: newJob, chunk: index))
                    index += 1
                }
            }
            // Keep first frame unacknowledged, then verify joined shutdown too.
            try new.send(.cancel, .init(kind: .cancel, identity: newJob))
            while try next(new, "VoiceRelay", timeout: 30).kind != .ready {}
            try new.close()
            receipt["acceptedToFirstPlayableWAVSeconds"] = firstAudio! - accepted
            receipt["cancelToOldReadySeconds"] = oldReady - cancelTime
            receipt["oldUnloadSeconds"] = unloaded.time - unloadRequested
            receipt["newLeaseWaitSeconds"] = acquired.time - waiting.time
            receipt["newModelInitializationSeconds"] = initialized.time - acquired.time
            receipt["unloadBeforeNewLease"] = true
            receipt["modelInitializations"] = 2
            receipt["crossProcessWarmReuse"] = false
            receipt["oldPeakFootprintBytes"] = old.peakFootprint
            receipt["newPeakFootprintBytes"] = new.peakFootprint
            receipt["outcome"] = "passed"
            for stage in stages { try FileManager.default.removeItem(at: stage) }
            try save()
            print("PASS \(model.rawValue): Libro unload before VoiceRelay reload; acceptance-to-first-WAV \(firstAudio! - accepted)s")
        } catch {
            receipt["outcome"] = "failed"; receipt["failure"] = (error as? SpeechFailure)?.code.rawValue ?? "probe"
            try? save()
            for client in clients { try client.close() }
            for stage in stages { try? FileManager.default.removeItem(at: stage) }
            throw error
        }
    }
}
