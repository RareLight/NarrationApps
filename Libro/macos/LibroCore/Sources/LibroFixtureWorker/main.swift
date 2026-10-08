import Foundation
import LibroCore
import Darwin

/// Model-free process fixture. It uses the production control records and
/// spools, but emits four known samples per chunk and deliberate fault modes.
@main
struct FixtureWorker {
    static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let tracePath = environment["LIBRO_FIXTURE_TRACE"] else { exit(2) }
        let traceRoot = URL(fileURLWithPath: tracePath)
        let trace = traceRoot.appendingPathComponent("\(getpid()).jsonl")
        let mode = environment["LIBRO_FIXTURE_MODE"] ?? "success"
        func record(_ name: String, _ command: WorkerCommand? = nil) throws {
            var item: [String: Any] = ["event": name, "pid": getpid(), "time": ProcessInfo.processInfo.systemUptime]
            if let command {
                item["attempt"] = command.identity.attempt.uuidString
                item["job"] = command.identity.job.uuidString
                item["chunk"] = command.chunk
            }
            let descriptor = open(trace.path, O_CREAT | O_WRONLY | O_APPEND, 0o600)
            guard descriptor >= 0 else { exit(3) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: item) + Data([10]))
            try handle.close()
        }
        try record("launch")
        defer { try? record("exit") }
        let reader = WorkerCommandReader()
        var initial: WorkerCommand?
        while let command = try reader.next() {
            try record(command.kind.rawValue, command)
            if command.kind == .cancel || command.kind == .shutdown { return }
            if command.kind == .prepare {
                if mode == "assetStall" { signal(SIGTERM, SIG_IGN); Thread.sleep(forTimeInterval: 30) }
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
                if mode == "initializeFailureAndStall" {
                    let marker = open(traceRoot.appendingPathComponent("initialization-failure").path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
                    if marker >= 0 {
                        close(marker)
                        try FileHandle.standardOutput.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .failure,
                            identity: command.identity, failure: .invalidInput)))
                        return
                    }
                    signal(SIGTERM, SIG_IGN); Thread.sleep(forTimeInterval: 30)
                }
                if mode == "secondPrepareStall" {
                    let marker = open(traceRoot.appendingPathComponent("first-job").path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
                    if marker >= 0 { close(marker) }
                    else { signal(SIGTERM, SIG_IGN); Thread.sleep(forTimeInterval: 30) }
                }
                if mode == "prepareStall" { signal(SIGTERM, SIG_IGN); Thread.sleep(forTimeInterval: 30) }
                try FileHandle.standardOutput.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .ready, identity: command.identity)))
                continue
            }
            guard let initial, let spool = initial.spoolDirectory, let index = command.chunk else { exit(4) }
            if mode == "slowFirst", index == 0 { Thread.sleep(forTimeInterval: 0.25) }
            if mode == "stall", index == 0 { signal(SIGTERM, SIG_IGN); Thread.sleep(forTimeInterval: 30) }
            if mode == "flood" {
                try FileHandle.standardError.write(contentsOf: Data(repeating: 120, count: 524_288))
            }
            if mode == "fallback", index == 3 {
                let marker = open(traceRoot.appendingPathComponent("failed-once").path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
                if marker >= 0 {
                    close(marker)
                    try FileHandle.standardOutput.write(contentsOf: SpeechIPC.encode(WorkerEvent(kind: .failure,
                        identity: command.identity, chunk: index, failure: .generation)))
                    return
                }
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
