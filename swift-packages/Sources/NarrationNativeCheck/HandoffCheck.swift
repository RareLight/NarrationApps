import Foundation
import AVFoundation
import CryptoKit
import NarrationCore
import NativeSpeech
import ProcessingPipeline
import AudioOutput
import Darwin

/// Explicit installed-assets-only VS00 gate. No listener, app launch, download,
/// player, diagnostic retention or alteration of existing speech jobs/artifacts.
enum HandoffCheck {
    static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 5 || arguments.count == 6,
              let model = SpeechModel(rawValue: arguments[4]),
              let mode = arguments.count == 6 ? SpeechProbeAudioMode(rawValue: arguments[5]) : .paragraphs,
              mode != .qwenIncremental || model == .qwen3 else { throw SpeechFailure(.invalidInput) }
        let executable = URL(fileURLWithPath: arguments[0]).standardizedFileURL
        let workspace = try NativeWorkspace(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
        let output = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
        // Existing artifacts are never replaced by a rerun.
        guard mkdir(output.path, 0o700) == 0 else { throw SpeechFailure(.storage) }
        let staging = try workspace.managed(workspace.nativeRoot.appendingPathComponent("staging/attempt-\(UUID().uuidString)"))
        guard mkdir(staging.path, 0o700) == 0 else { throw SpeechFailure(.storage) }
        var settings = SpeechSettings(model: model, voice: model.defaultVoice)
        settings.seed = 42
        let configuration = WorkerConfiguration(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: ["-p", "(version 1)(allow default)(deny network*)", executable.path, "--handoff-probe"],
            shutdownGrace: 2, terminationGrace: 1, maximumFootprintBytes: SpeechMemoryPolicy.footprintLimit(for: model))
        var receipt: [String: Any] = ["schema": 1, "model": model.rawValue, "voice": settings.voice,
            "modelRevision": NativePrimaryCatalog.specification(for: model).revision,
            "workerSHA256": try NativeG2P.sha256(executable), "outcome": "running", "modelInitializations": 0,
            "audioPath": mode.rawValue, "firstUnitPolicy": mode == .paragraphs ? "ordinary" : LiveSpeechFirstUnit.version,
            "incrementalAdapter": mode == .qwenIncremental ? "owned-qwen-callback-0.5s" : "not-tested",
            "listeningAcceptance": "not-performed"]
        let receiptURL = output.appendingPathComponent("receipt.json")
        func save() throws { try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: receiptURL, options: .atomic) }
        try save()
        let process: SpeechProbeProcess
        do { process = try SpeechProbeProcess(configuration: configuration) }
        catch {
            receipt["outcome"] = "failed"; receipt["failure"] = "launch"
            try? save(); try? FileManager.default.removeItem(at: staging)
            throw error
        }
        // Reap before scratch deletion on success, error, timeout or memory kill.
        defer { try? process.close() }
        var trace: [[String: Any]] = []
        func record(_ event: SpeechProbeEvent) {
            trace.append(["kind": event.kind.rawValue, "job": event.identity.job.uuidString,
                "attempt": event.identity.attempt.uuidString, "worker": event.worker.uuidString,
                "pid": event.pid, "time": event.time, "frame": event.frame?.chunk ?? -1])
        }
        do {
            let initial = AttemptIdentity(batch: UUID(), job: UUID())
            let loadStart = ProcessInfo.processInfo.systemUptime
            try process.send(.initialize, .init(kind: .initialize, identity: initial, workspace: workspace.root,
                settings: settings, spoolDirectory: staging))
            var initialized = try process.next(timeout: 900)
            record(initialized)
            while [.waitingForLease, .leaseAcquired, .loadingModel].contains(initialized.kind) {
                initialized = try process.next(timeout: 900); record(initialized)
            }
            guard initialized.kind == .initialized else { throw SpeechFailure(initialized.failure ?? .generation) }
            receipt["initializationSeconds"] = ProcessInfo.processInfo.systemUptime - loadStart
            receipt["modelInitializations"] = 1; receipt["pid"] = process.pid
            receipt["workerInstance"] = initialized.worker.uuidString
            try save()

            let text = """
            A quiet morning begins beside the river. Three small boats pass under the bridge, and the reader follows their progress from the bank. Each sentence adds one clear detail to the scene.

            Later, the team compares notes from its journey. They keep the original observations, explain uncertain measurements, and check their work before sharing the result. A careful pause separates the next thought.

            The final section returns to the opening question. Clear speech preserves the words and their order. This synthetic passage ends with a complete sentence so that the listener can follow the whole account.
            """
            func complete(_ label: String, using selected: SpeechProbeAudioMode? = nil) throws -> [String: Any] {
                let identity = AttemptIdentity(batch: UUID(), job: UUID())
                let spool = staging.appendingPathComponent("job-\(identity.attempt.uuidString)")
                let accepted = ProcessInfo.processInfo.systemUptime
                try process.send(.generate, .init(kind: .generate, identity: identity, text: text), mode: selected ?? mode)
                var index = 0, firstAudio: Double?, quiescent = false, completed = false
                var hashes: [String] = [], totalFrames = 0
                var units: [String: Int] = [:], firstUnit: String?, previousUnit: String?, previousSample: Float?
                var maximumBoundaryJump: Float = 0
                let rawURL = output.appendingPathComponent(label + ".f32")
                try Data().write(to: rawURL, options: .withoutOverwriting)
                let raw = try FileHandle(forWritingTo: rawURL)
                defer { try? raw.close() }
                while true {
                    let event = try process.next(timeout: 180)
                    record(event)
                    guard event.identity == identity else { throw SpeechFailure(.protocolViolation) }
                    switch event.kind {
                    case .started: break
                    case .frame:
                        let samples = try SpeechProbeProcess.readFrame(event, spool: spool, model: model, index: index)
                        let hasSpeech = samples.contains(where: { $0 != 0 })
                        let wav = output.appendingPathComponent("\(label)-\(index).wav")
                        try ProbeAudio.publish(samples, rate: model.capabilities.sampleRate, to: wav)
                        if firstAudio == nil, hasSpeech { firstAudio = ProcessInfo.processInfo.systemUptime - accepted }
                        try ProbeAudio.verify(samples, rate: model.capabilities.sampleRate, wav: wav)
                        try samples.withUnsafeBytes { try raw.write(contentsOf: Data($0)) }
                        if let source = event.frame?.source {
                            let unit = "\(source.blockIndices)-\(source.location)-\(source.length)"
                            if firstUnit == nil { firstUnit = unit }
                            units[unit, default: 0] += 1
                            if previousUnit == unit, let previousSample, let first = samples.first {
                                maximumBoundaryJump = max(maximumBoundaryJump, abs(first - previousSample))
                            }
                            previousUnit = unit; previousSample = samples.last
                        }
                        hashes.append(samples.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() })
                        totalFrames += samples.count
                        // Only after validation/playable publication do we grant next credit.
                        try process.send(.acknowledge, .init(kind: .generate, identity: identity, chunk: index))
                        index += 1
                    case .quiescent: quiescent = true
                    case .completed: guard quiescent else { throw SpeechFailure(.protocolViolation) }; completed = true
                    case .ready:
                        guard completed, index > 1, let firstAudio else { throw SpeechFailure(.generation) }
                        return ["frames": totalFrames, "chunks": index, "hashes": hashes,
                            "firstPlayableWAVSeconds": firstAudio, "requestSeconds": ProcessInfo.processInfo.systemUptime - accepted,
                            "firstAudioBeforeCompletion": true,
                            "firstUnitFrames": firstUnit.flatMap { units[$0] } ?? 0,
                            "framesPerUnit": units, "maximumIntraUnitBoundaryJump": maximumBoundaryJump]
                    case .failure: throw SpeechFailure(event.failure ?? .generation)
                    default: throw SpeechFailure(.protocolViolation)
                    }
                }
            }
            if mode != .paragraphs {
                receipt["ordinaryParagraphBaseline"] = try complete("ordinary", using: .paragraphs)
                try save()
            }
            receipt["control"] = try complete("control", using: mode == .qwenIncremental ? .firstSentence : mode); try save()
            if mode == .qwenIncremental {
                receipt["incrementalControl"] = try complete("incremental-control")
                let comparison = try ProbeAudio.compare(output.appendingPathComponent("control.f32"), output.appendingPathComponent("incremental-control.f32"))
                receipt["streamVersusDirectPCM"] = comparison
                receipt["directPCMParityPassed"] = comparison["withinDiagnosticTolerance"] as? Bool == true
                guard comparison["sampleCountsEqual"] as? Bool == true else { throw SpeechFailure(.generation) }
                try save()
            }
            let interrupted = AttemptIdentity(batch: UUID(), job: UUID())
            try process.send(.generate, .init(kind: .generate, identity: interrupted, text: text), mode: mode)
            let started = try process.next(timeout: 180)
            record(started)
            guard started.kind == .started else { throw SpeechFailure(.protocolViolation) }
            var discardedFrames = 0
            if mode == .qwenIncremental {
                let first = try process.next(timeout: 180); record(first)
                guard first.kind == .frame else { throw SpeechFailure(first.failure ?? .generation) }
                discardedFrames = 1 // Deliberately do not acknowledge; exercise decoder reset under backpressure.
            }
            Thread.sleep(forTimeInterval: mode == .qwenIncremental ? 0.15 : 0.05)
            let cancelled = ProcessInfo.processInfo.systemUptime
            try process.send(.cancel, .init(kind: .cancel, identity: interrupted))
            var revoked = false, quiescent = false
            while true {
                let event = try process.next(timeout: 30)
                record(event)
                guard event.identity == interrupted else { throw SpeechFailure(.protocolViolation) }
                switch event.kind {
                case .frame: discardedFrames += 1 // Never validate/publish interrupted output.
                case .revoked: revoked = true
                case .quiescent: quiescent = true; receipt["cancelToQuiescentSeconds"] = event.time - cancelled
                case .ready:
                    guard revoked, quiescent else { throw SpeechFailure(.generation) }
                    receipt["cancelToReadySeconds"] = ProcessInfo.processInfo.systemUptime - cancelled
                case .failure: throw SpeechFailure(event.failure ?? .generation)
                default: throw SpeechFailure(.protocolViolation)
                }
                if event.kind == .ready { break }
            }
            receipt["discardedFrames"] = discardedFrames
            let resumed = try complete("resumed")
            receipt["resumed"] = resumed
            if mode == .qwenIncremental {
                guard discardedFrames == 1, (resumed["firstUnitFrames"] as? Int ?? 0) > 1 else { throw SpeechFailure(.protocolViolation) }
                let comparison = try ProbeAudio.compare(output.appendingPathComponent("incremental-control.f32"), output.appendingPathComponent("resumed.f32"))
                receipt["streamAfterResetPCM"] = comparison
                receipt["resetPCMParityPassed"] = comparison["withinDiagnosticTolerance"] as? Bool == true
                guard comparison["sampleCountsEqual"] as? Bool == true else { throw SpeechFailure(.generation) }
            }
            receipt["controlAndResumedHashesMatch"] = (receipt["control"] as? [String: Any])?["hashes"] as? [String] == resumed["hashes"] as? [String]
            receipt["sameWorkerAfterCancellation"] = process.pid == initialized.pid && process.instance == initialized.worker
            receipt["peakFootprintBytes"] = process.peakFootprint
            receipt["trace"] = trace
            receipt["reuseAndCoverageOutcome"] = "passed"
            // Finish cancellation/reset evidence even when direct-versus-stream
            // parity needs review, but never return an overall green gate for it.
            if mode == .qwenIncremental {
                guard receipt["directPCMParityPassed"] as? Bool == true,
                      receipt["resetPCMParityPassed"] as? Bool == true else {
                    receipt["continuityOutcome"] = "blocked-pcm-parity"
                    throw SpeechFailure(.generation)
                }
                receipt["continuityOutcome"] = "numerical-parity-passed-listening-unverified"
            }
            receipt["outcome"] = "passed"
            try process.close()
            try FileManager.default.removeItem(at: staging)
            try save()
            print("PASS \(model.rawValue): one loaded worker, cancelled/joined/reset, reusable; receipt \(receiptURL.path)")
        } catch {
            receipt["outcome"] = "failed"; receipt["failure"] = (error as? SpeechFailure)?.code.rawValue ?? "probe"
            receipt["trace"] = trace; receipt["peakFootprintBytes"] = process.peakFootprint
            try? save()
            try process.close()
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
}
