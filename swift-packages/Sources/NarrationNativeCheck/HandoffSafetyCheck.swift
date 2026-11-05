import Foundation
import CryptoKit
import NarrationCore
import NativeSpeech
import ProcessingPipeline
import Darwin

/// Installed-assets-only safety/stability gate. All clients and scratch are
/// exclusively owned; no app launch, listener, download or retained input text.
enum HandoffSafetyCheck {
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 5, let model = SpeechModel(rawValue: args[4]) else { throw SpeechFailure(.invalidInput) }
        let workspace = try NativeWorkspace(root: URL(fileURLWithPath: args[1]))
        let output = URL(fileURLWithPath: args[2]).standardizedFileURL
        guard mkdir(output.path, 0o700) == 0 else { throw SpeechFailure(.storage) }
        var settings = SpeechSettings(model: model, voice: model.defaultVoice); settings.seed = 42
        let mode: SpeechProbeAudioMode = model == .qwen3 ? .qwenIncremental : .firstSentence
        var clients: [SpeechProbeProcess] = [], stages: [URL] = []
        defer { for client in clients { try? client.close() } }
        var trace: [[String: Any]] = [], phases: [[String: Any]] = []
        var receipt: [String: Any] = ["schema": 1, "outcome": "running", "model": model.rawValue,
            "workerSHA256": try NativeG2P.sha256(URL(fileURLWithPath: args[0])),
            "network": "OS denied", "listeningAcceptance": "not-performed"]
        func save() throws {
            receipt["trace"] = trace; receipt["initializationPhases"] = phases
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("receipt.json"), options: .atomic)
        }
        func openClient(holdLoaded: Bool = false) throws -> (SpeechProbeProcess, URL, AttemptIdentity) {
            let stage = try workspace.managed(workspace.nativeRoot.appendingPathComponent("staging/attempt-\(UUID().uuidString)"))
            guard mkdir(stage.path, 0o700) == 0 else { throw SpeechFailure(.storage) }; stages.append(stage)
            let client = try SpeechProbeProcess(configuration: .init(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                arguments: ["-p", "(version 1)(allow default)(deny network*)", args[0], "--handoff-probe"],
                shutdownGrace: 5, terminationGrace: 1, maximumFootprintBytes: SpeechMemoryPolicy.footprintLimit(for: model)))
            clients.append(client)
            let id = AttemptIdentity(batch: UUID(), job: UUID())
            try client.send(.initialize, .init(kind: .initialize, identity: id, workspace: workspace.root,
                settings: settings, spoolDirectory: stage), holdLoadedInitialization: holdLoaded)
            return (client, stage, id)
        }
        func next(_ client: SpeechProbeProcess, _ phase: String, timeout: Double = 180) throws -> SpeechProbeEvent {
            let event = try client.next(timeout: timeout)
            trace.append(["phase": phase, "kind": event.kind.rawValue, "time": event.time,
                "pid": event.pid, "worker": event.worker.uuidString, "attempt": event.identity.attempt.uuidString,
                "frame": event.frame?.chunk ?? -1])
            if event.kind == .failure { throw SpeechFailure(event.failure ?? .generation) }
            return event
        }
        func verifyLeaseAvailable() async throws {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    let lease = try await InferenceLease.acquire(priority: .background)
                    withExtendedLifetime(lease) {}; return true
                }
                group.addTask { try await Task.sleep(for: .seconds(3)); throw SpeechFailure(.timeout) }
                defer { group.cancelAll() }
                guard try await group.next() == true else { throw SpeechFailure(.protocolViolation) }
            }
        }
        try save()
        do {
            for phase in ["lease-cancel", "lease-eof", "load-entry-cancel", "load-entry-eof", "loaded-cancel", "loaded-eof", "idle-eof"] {
                // Deliberately hold the real compatibility locks only for the
                // waiting test; no model is loaded by this host.
                var blocker: InferenceLease? = phase.hasPrefix("lease-") ? try await InferenceLease.acquire(priority: .background) : nil
                let (client, _, identity) = try openClient(holdLoaded: phase.hasPrefix("loaded-"))
                let target: SpeechProbeEvent.Kind = phase.hasPrefix("lease-") ? .waitingForLease :
                    phase.hasPrefix("loaded-") ? .loadedAwaitingAdmission : phase == "idle-eof" ? .initialized : .loadingModel
                while try next(client, phase, timeout: 900).kind != target {}
                let preCancellationFootprint = client.currentFootprint ?? 0
                let start = ProcessInfo.processInfo.systemUptime
                if phase.hasSuffix("cancel") { try client.send(.cancel, .init(kind: .cancel, identity: identity)) }
                else { try client.finishInput() }
                var revoked = false, unloaded = false
                while true {
                    let event = try next(client, phase, timeout: 60)
                    guard event.kind != .initialized, event.kind != .ready, event.kind != .frame else { throw SpeechFailure(.protocolViolation) }
                    if event.kind == .revoked { revoked = true }
                    if event.kind == .unloaded { unloaded = true }
                    if event.kind == .initializationCancelled || (phase == "idle-eof" && unloaded) { break }
                }
                guard !phase.hasSuffix("cancel") || revoked else { throw SpeechFailure(.protocolViolation) }
                guard !phase.hasPrefix("loaded-") || unloaded else { throw SpeechFailure(.protocolViolation) }
                let settled = ProcessInfo.processInfo.systemUptime - start
                try client.close()
                withExtendedLifetime(blocker) {}; blocker = nil
                try await verifyLeaseAvailable()
                phases.append(["phase": phase, "settleSeconds": settled, "unloadedEvent": unloaded,
                    "pid": client.pid, "preCancellationFootprintBytes": preCancellationFootprint,
                    "peakFootprintBytes": client.peakFootprint, "reaped": kill(client.pid, 0) == -1])
                try save()
            }

            let (client, stage, _) = try openClient()
            while try next(client, "stress-load", timeout: 900).kind != .initialized {}
            let pid = client.pid, instance = client.instance
            let text = "A quiet morning begins. The river flows."
            func complete(_ label: String, _ selected: SpeechSettings) throws -> [String: Any] {
                let id = AttemptIdentity(batch: UUID(), job: UUID()), accepted = ProcessInfo.processInfo.systemUptime
                try client.send(.generate, .init(kind: .generate, identity: id, settings: selected, text: text), mode: mode)
                let spool = stage.appendingPathComponent("job-\(id.attempt.uuidString)")
                var index = 0, frames = 0, hash = SHA256(), first: Double?, quiescent = false, completed = false
                while true {
                    let event = try next(client, label)
                    guard event.identity == id else { throw SpeechFailure(.protocolViolation) }
                    switch event.kind {
                    case .started: break
                    case .frame:
                        let samples = try SpeechProbeProcess.readFrame(event, spool: spool, model: model, index: index)
                        if first == nil, samples.contains(where: { $0 != 0 }) {
                            let wav = output.appendingPathComponent(label + ".wav")
                            try ProbeAudio.publish(samples, rate: model.capabilities.sampleRate, to: wav)
                            first = ProcessInfo.processInfo.systemUptime - accepted
                            try ProbeAudio.verify(samples, rate: model.capabilities.sampleRate, wav: wav)
                        }
                        samples.withUnsafeBytes { hash.update(data: Data($0)) }; frames += samples.count
                        try client.send(.acknowledge, .init(kind: .generate, identity: id, chunk: index)); index += 1
                    case .quiescent: quiescent = true
                    case .completed: guard quiescent else { throw SpeechFailure(.protocolViolation) }; completed = true
                    case .ready:
                        guard completed, let first, frames > 0 else { throw SpeechFailure(.generation) }
                        return ["label": label, "voice": selected.voice, "speed": selected.speed,
                            "firstWAVSeconds": first, "frames": frames, "chunks": index,
                            "hash": hash.finalize().map { String(format: "%02x", $0) }.joined(),
                            "readyFootprintBytes": client.currentFootprint ?? 0]
                    default: throw SpeechFailure(.protocolViolation)
                    }
                }
            }
            var completions = [try complete("control", settings)], cancellations: [[String: Any]] = []
            for cycle in 0..<9 {
                let boundary = ["immediate", "started", "frame"][cycle % 3]
                let id = AttemptIdentity(batch: UUID(), job: UUID())
                try client.send(.generate, .init(kind: .generate, identity: id, text: text), mode: mode)
                var discarded = 0
                if boundary != "immediate" {
                    while true {
                        let event = try next(client, boundary)
                        if event.kind == .frame { discarded += 1 }
                        if (boundary == "started" && event.kind == .started) || (boundary == "frame" && event.kind == .frame) { break }
                        guard event.kind == .started || event.kind == .frame else { throw SpeechFailure(.protocolViolation) }
                    }
                }
                let cancelled = ProcessInfo.processInfo.systemUptime
                try client.send(.cancel, .init(kind: .cancel, identity: id))
                var revoked = false, quiescent = false
                while true {
                    let event = try next(client, boundary, timeout: 60)
                    guard event.identity == id else { throw SpeechFailure(.protocolViolation) }
                    if event.kind == .frame { guard !revoked else { throw SpeechFailure(.protocolViolation) }; discarded += 1 }
                    if event.kind == .revoked { revoked = true }
                    if event.kind == .quiescent { quiescent = true }
                    guard event.kind != .completed else { throw SpeechFailure(.protocolViolation) }
                    if event.kind == .ready { break }
                }
                guard revoked, quiescent, discarded <= 1 else { throw SpeechFailure(.protocolViolation) }
                cancellations.append(["boundary": boundary, "cancelToReadySeconds": ProcessInfo.processInfo.systemUptime - cancelled,
                    "discardedFrames": discarded])
                var selected = settings
                if cycle == 4 {
                    if model == .qwen3 { selected.voice = "Aiden" }
                    if model == .orpheus { selected.voice = "leo" }
                    if model == .kokoro { selected.speed = 1.15 }
                }
                completions.append(try complete("resumed-\(cycle)", selected))
            }
            let restored = completions.first?["hash"] as? String == completions.last?["hash"] as? String
            guard model == .chatterbox || restored else { throw SpeechFailure(.generation) }
            guard pid == client.pid, instance == client.instance else { throw SpeechFailure(.protocolViolation) }
            receipt["completions"] = completions; receipt["cancellations"] = cancellations
            receipt["restoredDefaultHashesMatch"] = restored; receipt["stressModelInitializations"] = 1
            receipt["sameWorkerThroughoutStress"] = true; receipt["peakStressFootprintBytes"] = client.peakFootprint
            let footprints = completions.compactMap { $0["readyFootprintBytes"] as? UInt64 }
            guard footprints.count == 10, footprints.allSatisfy({ $0 > 0 && $0 <= SpeechMemoryPolicy.footprintLimit(for: model) }) else { throw SpeechFailure(.memoryLimit) }
            let tail = Array(footprints.dropFirst(2))
            receipt["readyFootprintTailSpreadBytes"] = (tail.max() ?? 0) - (tail.min() ?? 0)
            receipt["memoryAcceptance"] = "bounded sampled budget; short repeated-run evidence only"
            try client.close(); try await verifyLeaseAvailable()
            for stage in stages { try FileManager.default.removeItem(at: stage) }
            receipt["outcome"] = "passed"; try save()
            print("PASS \(model.rawValue): initialization cancellation/EOF, reaped recovery and repeated same-worker stress")
        } catch {
            receipt["outcome"] = "failed"; receipt["failure"] = (error as? SpeechFailure)?.code.rawValue ?? "probe"
            try? save()
            for client in clients { try client.close() }
            for stage in stages { try? FileManager.default.removeItem(at: stage) }
            throw error
        }
    }
}
