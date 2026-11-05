import Foundation
import ProcessingPipeline
import NarrationCore
import NativeSpeech
import Darwin

/// Model-free process fixture. It uses the production control records and
/// spools, but emits four known samples per chunk and deliberate fault modes.
@main
struct FixtureWorker {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--probe-version-five"] {
            var data = Data()
            while !data.contains(10) {
                guard let bytes = try SpeechIPC.readPipe(.standardInput), data.count + bytes.count <= SpeechIPC.maximumRecordBytes else { return }
                data.append(bytes)
            }
            let command = try JSONDecoder().decode(SpeechProbeCommand.self, from: data)
            var event = SpeechProbeEvent(session: command.session, worker: UUID(), identity: command.command.identity, kind: .initialized)
            event.version = 5
            try FileHandle.standardOutput.write(contentsOf: SpeechIPC.encode(event))
            _ = try FileHandle.standardInput.read(upToCount: 1)
            return
        }
        if arguments.first == "--work-admission" {
            guard arguments.count == 4, let value = Int(arguments[2]), let rank = SpeechWorkRank(rawValue: value),
                  let delivery = SpeechWorkDelivery(rawValue: arguments[3]) else { exit(2) }
            let root = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            guard root.lastPathComponent.hasPrefix("admission-") else { exit(2) }
            let registry = try SpeechWorkAdmission(root: root)
            let ticket = try registry.register(owner: rank == .libro ? .libro : .voiceRelay,
                instance: UUID(), rank: rank, delivery: delivery)
            try FileHandle.standardOutput.write(contentsOf: SpeechIPC.encode(ticket.demand))
            while try SpeechIPC.readPipe(.standardInput) != nil {}
            try ticket.withdraw()
            return
        }
        if arguments == ["--handoff-probe"] {
            try await SpeechProbeServer(backend: HandoffProbeFixture(), output: .standardOutput).run()
            return
        }
        if arguments.first == "--priority-proof" {
            try await PriorityProof.run(Array(arguments.dropFirst()))
            return
        }
        if arguments.first == "--lease" {
            guard arguments.count == 5, let milliseconds = Int(arguments[3]), milliseconds >= 0,
                  ["interactive", "background"].contains(arguments[2]) else { exit(2) }
            let trace = URL(fileURLWithPath: arguments[4])
            func recordLease(_ event: String) throws {
                let fd = open(trace.path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC, 0o600)
                guard fd >= 0 else { exit(3) }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                try handle.write(contentsOf: JSONSerialization.data(withJSONObject: ["event": event,
                    "time": ProcessInfo.processInfo.systemUptime, "pid": getpid()]) + Data([10]))
                try handle.close()
            }
            try recordLease("requested")
            var lease: InferenceLease? = try await InferenceLease.acquire(at: URL(fileURLWithPath: arguments[1]),
                priority: arguments[2] == "interactive" ? .interactive : .background)
            try recordLease("acquired")
            try await Task.sleep(for: .milliseconds(milliseconds))
            withExtendedLifetime(lease) {}
            lease = nil
            try recordLease("released")
            return
        }
        let environment = ProcessInfo.processInfo.environment
        guard let tracePath = environment["NARRATION_FIXTURE_TRACE"] else { exit(2) }
        let traceRoot = URL(fileURLWithPath: tracePath)
        let trace = traceRoot.appendingPathComponent("\(getpid()).jsonl")
        let mode = environment["NARRATION_FIXTURE_MODE"] ?? "success"
        func record(_ name: String, _ command: WorkerCommand? = nil) throws {
            var item: [String: Any] = ["event": name, "pid": getpid(), "time": ProcessInfo.processInfo.systemUptime]
            if let command {
                item["attempt"] = command.identity.attempt.uuidString
                item["job"] = command.identity.job.uuidString
                item["chunk"] = command.chunk
                item["textPreparationOnly"] = command.textPreparationOnly
                item["textPreparationWorkers"] = command.textPreparationWorkers
                if let settings = command.settings {
                    item["model"] = settings.model.rawValue; item["voice"] = settings.voice; item["speed"] = settings.speed
                }
                if environment["NARRATION_FIXTURE_CAPTURE_TEXT"] == "1" { item["text"] = command.utterance?.text ?? command.text }
            }
            let descriptor = open(trace.path, O_CREAT | O_WRONLY | O_APPEND, 0o600)
            guard descriptor >= 0 else { exit(3) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: item) + Data([10]))
            try handle.close()
        }
        try record("launch")
        if mode == "diagnosticCrash" {
            try FileHandle.standardError.write(contentsOf: Data(repeating: 120, count: 40_000))
            try FileHandle.standardError.write(contentsOf: Data("\nPublic diagnostic crash tail.\n".utf8))
            exit(7)
        }
        defer { try? record("exit") }
        let reader = WorkerCommandReader()
        var initial: WorkerCommand?
        var preparationOnly = false, preparationLoaded = true
        while let command = try reader.next() {
            try record(command.kind.rawValue, command)
            if command.kind == .cancel || command.kind == .shutdown {
                if mode == "delayShutdown" { try await Task.sleep(for: .milliseconds(200)) }
                return
            }
            if command.kind == .prepare {
                if mode == "assetStall" { signal(SIGTERM, SIG_IGN); try await Task.sleep(for: .seconds(30)) }
                let total = NativePrimaryCatalog.specification(for: command.settings!.model).files.reduce(Int64(0)) { $0 + Int64($1.bytes) }
                for identity in [AttemptIdentity(batch: UUID(), job: UUID()), command.identity] {
                    let value = ModelPreparationProgress(scope: .primary, phase: .downloading,
                        completedBytes: mode == "assetInvalid" ? -1 : 10, totalBytes: total)
                    try FileHandle.standardOutput.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .assetProgress, identity: identity, preparation: value)))
                }
                try FileHandle.standardOutput.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .prepared, identity: command.identity)))
                continue
            }
            if command.kind == .initialize {
                initial = command
                preparationOnly = command.textPreparationOnly == true; preparationLoaded = true
                if mode == "initializeFailure" {
                    try FileHandle.standardOutput.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .failure,
                        identity: command.identity, failure: .invalidInput)))
                    return
                }
                if mode == "prepareStall" { signal(SIGTERM, SIG_IGN); try await Task.sleep(for: .seconds(30)) }
                try FileHandle.standardOutput.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .ready, identity: command.identity,
                    textPreparationOnly: mode == "cpuReadyMissing" ? nil : preparationOnly,
                    preparationUsesInference: mode == "cpuReadyMissing" ? nil : (!preparationOnly || command.settings?.model == .kokoro))))
                continue
            }
            if [.loadPreparation, .releasePreparation, .loadSpeech].contains(command.kind) {
                guard let initial, initial.identity == command.identity else { exit(4) }
                if command.kind == .loadSpeech && mode == "speechLoadFailure" {
                    try FileHandle.standardOutput.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .failure, identity: command.identity, failure: .invalidInput)))
                    return
                }
                preparationOnly = command.kind != .loadSpeech
                preparationLoaded = command.kind != .releasePreparation
                try FileHandle.standardOutput.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .ready, identity: command.identity,
                    textPreparationOnly: preparationOnly,
                    preparationUsesInference: !preparationOnly || (preparationLoaded && initial.settings?.model == .kokoro),
                    preparationReleased: command.kind == .releasePreparation && mode != "releaseReadyMissing" ? true : nil)))
                continue
            }
            guard let initial, let spool = initial.spoolDirectory, let index = command.chunk else { exit(4) }
            if command.kind == .prepareText {
                guard preparationLoaded, let window = command.textWindow, let settings = initial.settings else { exit(4) }
                if mode == "cpuPreparationStall", preparationOnly {
                    signal(SIGTERM, SIG_IGN); try await Task.sleep(for: .seconds(30))
                }
                let prepared = (initial.policy ?? .legacy).usesPreparedPhonemes
                let utterance = PreparedUtterance(text: window.text, phonemes: prepared ? "a" : nil, tokenCount: prepared ? 1 : 0,
                    source: window.source, boundaryAfter: window.boundaryAfter,
                    acousticIdentity: SpeechAcousticIdentity.make(settings: settings, policy: initial.policy ?? .legacy))
                let reference = try PreparedSpeechTransfer.write([utterance], index: index, spool: spool)
                try FileHandle.standardOutput.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .textPrepared,
                    identity: command.identity, chunk: index, preparedFile: reference)))
                continue
            }
            if preparationOnly {
                try FileHandle.standardOutput.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .failure, identity: command.identity, chunk: index, failure: .invalidInput)))
                return
            }
            if mode == "slowFirst", index == 0 { try await Task.sleep(for: .milliseconds(250)) }
            if (mode == "stall" && index == 0) || (mode == "secondDocumentStall" && index == 1) { signal(SIGTERM, SIG_IGN); try await Task.sleep(for: .seconds(30)) }
            if mode == "flood" {
                try FileHandle.standardError.write(contentsOf: Data(repeating: 120, count: 524_288))
            }
            if mode == "generationFailure", index == 3 {
                try FileHandle.standardOutput.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .failure,
                    identity: command.identity, chunk: index, failure: .generation)))
                return
            }
            if index == 1 {
                switch mode {
                case "crash": exit(7)
                case "malformed": try FileHandle.standardOutput.write(contentsOf: Data("{broken\n".utf8)); return
                case "oversized": try FileHandle.standardOutput.write(contentsOf: Data(repeating: 123, count: 70_000)); return
                case "storage", "invalidInput":
                    try FileHandle.standardOutput.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .failure,
                        identity: command.identity, chunk: index, failure: mode == "storage" ? .storage : .invalidInput)))
                    return
                default: break
                }
            }
            let samples: [Float] = Array(repeating: mode == "nan" && index == 1 ? .nan : Float(index + 1) / 100, count: 4)
            let file = SpeechIPC.chunkFile(in: spool, index: index)
            try samples.withUnsafeBytes { try Data($0).write(to: file, options: .withoutOverwriting) }
            if mode == "shortPCM", index == 1 { try Data([0]).write(to: file) }
            if mode == "symlinkPCM", index == 1 {
                let target = traceRoot.appendingPathComponent("external.f32")
                try samples.withUnsafeBytes { try Data($0).write(to: target) }
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            }
            if mode == "stale" {
                try FileHandle.standardOutput.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .failure,
                    identity: .init(batch: command.identity.batch, job: command.identity.job), chunk: index, failure: .storage)))
                try FileHandle.standardOutput.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .failure,
                    identity: command.identity, chunk: index - 1, failure: .storage)))
            }
            let event = WorkerEvent(kind: .chunk, identity: command.identity, chunk: index,
                sampleRate: mode == "rate" && index == 1 ? 44_100 : initial.settings!.model.capabilities.sampleRate,
                frames: mode == "frames" && index == 1 ? Int.max : 4,
                channels: mode == "channels" && index == 1 ? 2 : 1,
                pcmFile: mode == "path" && index == 1 ? trace.path : file.path)
            try record("result", command)
            try FileHandle.standardOutput.write(contentsOf: SpeechIPC.encode(event))
        }
    }
}
