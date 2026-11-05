import Foundation
import CryptoKit
import Darwin

struct ProofCommand: Codable {
    var action: String
    var id: String = ""
    var rank: ProofRank = .podcast
    var delivery: ProofDelivery = .streaming
    var epoch: Int = 0
    var delayed: Bool = false
}
struct ProofReply: Codable {
    var event: String
    var epoch: Int = 0
    var chunks: [Int] = []
    var pid: Int32 = getpid()
    var loads: Int = 0
    var hash: String = ""
}

// Bounded line transport for synthetic records, also used by the test driver.
// poll makes failed fixtures time out instead of hanging the full test gate.
final class ProofChannel {
    let process: Process
    let input: FileHandle
    let output: FileHandle
    init(root: URL, role: String, app: String) throws {
        process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--priority-proof", role, root.path, app]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        try process.run()
        try stdin.fileHandleForReading.close(); try stdout.fileHandleForWriting.close()
    }
    func send(_ command: ProofCommand) throws -> ProofReply {
        try input.write(contentsOf: JSONEncoder().encode(command) + Data([10]))
        return try Self.read(output)
    }
    static func read(_ handle: FileHandle) throws -> ProofReply {
        var bytes = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while bytes.count < 4096 {
            guard ContinuousClock.now < deadline else { throw ProofError.timeout }
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 50)
            guard result >= 0 else { throw ProofError.invalid }
            if result == 0 { continue }
            guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else { throw ProofError.invalid }
            if byte[0] == 10 { return try JSONDecoder().decode(ProofReply.self, from: bytes) }
            bytes += byte
        }
        throw ProofError.invalid
    }
    func close() throws {
        try input.close()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning {
            guard ContinuousClock.now < deadline else { throw ProofError.timeout }
            Thread.sleep(forTimeInterval: 0.005)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProofError.invalid }
    }
}

enum ProofSuspension { case priority(ProofDemand), manualPause, stopped }

struct ProofJournal {
    struct Chunk: Codable { let index: Int; let hash: String; let pcm: Data }
    let url: URL
    var epoch = 0
    var revoked = false
    var chunks: [Chunk] = []
    init(root: URL, id: String) throws {
        url = root.appendingPathComponent("checkpoint-\(id).json")
        if FileManager.default.fileExists(atPath: url.path) {
            chunks = try JSONDecoder().decode([Chunk].self, from: Data(contentsOf: url))
            guard chunks.enumerated().allSatisfy({ $0.offset + 1 == $0.element.index &&
                Self.hash($0.element.pcm) == $0.element.hash }) else { throw ProofError.invalid }
        }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    mutating func begin() -> Int { epoch += 1; revoked = false; return epoch }
    mutating func revoke() { revoked = true }
    mutating func commit(epoch candidate: Int) throws -> Bool {
        guard candidate == epoch, !revoked else { return false }
        let index = chunks.count + 1
        let pcm = [Float(index) / 100, -Float(index) / 100, 0, Float(index) / 200]
            .withUnsafeBytes { Data($0) }
        let chunk = Chunk(index: index, hash: Self.hash(pcm), pcm: pcm)
        let next = chunks + [chunk]
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize(); try handle.close()
        // Verify the persisted descriptor/PCM before advancing the safe cursor.
        let verified = try JSONDecoder().decode([Chunk].self, from: Data(contentsOf: url))
        guard verified.count == index, verified.allSatisfy({ Self.hash($0.pcm) == $0.hash }) else { throw ProofError.invalid }
        chunks = verified
        revoked = true // One durable commit per attempt, including late callbacks.
        return true
    }
}

struct ProofTrace {
    let root: URL
    let app: String
    func record(_ event: String) throws {
        try ProofAdmission(root: root).gated {
            let fd = open(root.appendingPathComponent("trace.txt").path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ProofError.invalid }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: Data("\(app) \(event)\n".utf8)); try handle.close()
        }
    }
}

// Fake model execution is independently cancellable from the serial command
// reader. The drain task represents GPU work that Swift cancellation cannot stop.
final class ProofWorker {
    let admission: ProofAdmission
    let trace: ProofTrace
    let app: String
    var residency: ProofLock?
    var generation: Task<Void, Never>?
    var drain: Task<Void, Never>?
    var epoch = 0
    var loads = 0
    var requestState: String?
    init(root: URL, app: String) {
        self.app = app; admission = ProofAdmission(root: root); trace = ProofTrace(root: root, app: app)
    }
    var barrier: URL { admission.root.appendingPathComponent("drain-\(app)") }
    func cancel(delayed: Bool) throws {
        guard let generation else { return }
        generation.cancel()
        let barrier = barrier
        drain = Task.detached {
            await generation.value
            if delayed {
                while !FileManager.default.fileExists(atPath: barrier.path) {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
        }
        try trace.record("cancel epoch=\(epoch)")
    }
    func quiesce() async throws {
        if let drain { await drain.value }
        else if let generation { generation.cancel(); await generation.value }
        generation = nil; drain = nil
        try trace.record("quiescent epoch=\(epoch)")
        requestState = nil
        try trace.record("reset epoch=\(epoch)")
    }
    func run() async throws {
        while let line = readLine() {
            guard line.utf8.count < 4096 else { throw ProofError.invalid }
            let command = try JSONDecoder().decode(ProofCommand.self, from: Data(line.utf8))
            var reply = ProofReply(event: "ok", loads: loads)
            switch command.action {
            case "start":
                guard generation == nil, requestState == nil else { throw ProofError.invalid }
                if residency == nil {
                    residency = try admission.acquireResidency(for: command.id)
                    guard residency != nil else { try PriorityProof.reply(.init(event: "waiting")); continue }
                    loads += 1; try trace.record("load count=\(loads)")
                } else {
                    guard try admission.highest()?.id == command.id else { try PriorityProof.reply(.init(event: "waiting")); continue }
                }
                epoch = command.epoch; requestState = command.id
                if FileManager.default.fileExists(atPath: barrier.path) { try FileManager.default.removeItem(at: barrier) }
                generation = Task { do { try await Task.sleep(for: .seconds(3600)) } catch {} }
                try trace.record("start \(command.id) epoch=\(epoch)")
                reply.event = "started"
            case "cancel":
                if command.id != requestState || command.epoch != epoch { reply.event = "stale" }
                else { try cancel(delayed: command.delayed); reply.event = "cancelling" }
            case "drain":
                try Data().write(to: barrier); try await quiesce(); reply.event = "ready"
            case "finish":
                guard command.id == requestState, command.epoch == epoch, generation != nil, drain == nil else { throw ProofError.invalid }
                try await quiesce(); reply.event = "finished"
            case "unload":
                guard generation == nil, drain == nil else { throw ProofError.invalid }
                if residency != nil { try trace.record("unload"); residency = nil }
                reply.event = "unloaded"
            default: throw ProofError.invalid
            }
            reply.loads = loads; reply.epoch = epoch
            try PriorityProof.reply(reply)
        }
        // Parent death does not release residency: EOF first cancels and joins
        // the producer and the synthetic GPU drain, then unloads owned weights.
        if generation != nil {
            try trace.record("parent-eof")
            try cancel(delayed: true)
            try await quiesce()
        }
        if residency != nil { try trace.record("unload"); residency = nil }
        try trace.record("exit")
    }
}

final class ProofJob {
    let id: String
    let rank: ProofRank
    let delivery: ProofDelivery
    var ticket: ProofTicket?
    var journal: ProofJournal
    var suspension: ProofSuspension?
    var complete = false
    init(_ command: ProofCommand, root: URL, app: String) throws {
        id = command.id; rank = command.rank; delivery = command.delivery
        journal = try ProofJournal(root: root, id: id)
        ticket = try ProofAdmission(root: root).register(id: id, app: app, rank: rank, delivery: delivery)
    }
}

final class ProofClient {
    let admission: ProofAdmission
    let app: String
    let trace: ProofTrace
    let worker: ProofChannel
    var jobs: [String: ProofJob] = [:]
    var active: ProofJob?
    var draining: ProofJob?
    init(root: URL, app: String) throws {
        admission = ProofAdmission(root: root); self.app = app
        trace = ProofTrace(root: root, app: app)
        worker = try ProofChannel(root: root, role: "helper", app: app)
    }
    // One controlled observation tick replaces a clock/wakeup in VS00. Demand
    // selection, revocation and automatic resumption are decisions of the client,
    // not commands from the test driver. Production observers are still future work.
    func observe(delayed: Bool) throws -> ProofReply {
        let highest = try admission.highest()
        if let active {
            if let highest, highest.rank.rawValue < active.rank.rawValue {
                active.suspension = .priority(highest)
                if highest.rank == .api && highest.delivery == .streaming {
                    active.journal.revoke()
                    try trace.record("revoke \(active.id) epoch=\(active.journal.epoch)")
                    _ = try worker.send(.init(action: "cancel", id: active.id, epoch: active.journal.epoch, delayed: delayed))
                    draining = active; self.active = nil
                    return .init(event: "suspended", epoch: active.journal.epoch)
                }
                return .init(event: "yield-at-boundary")
            }
            return .init(event: "active", epoch: active.journal.epoch)
        }
        guard draining == nil else { return .init(event: "draining") }
        guard let highest else { _ = try worker.send(.init(action: "unload")); return .init(event: "idle") }
        guard highest.app == app else {
            _ = try worker.send(.init(action: "unload")); return .init(event: "waiting")
        }
        guard let job = jobs[highest.id], !job.complete else { throw ProofError.invalid }
        if let suspension = job.suspension {
            switch suspension {
            case .manualPause, .stopped: throw ProofError.invalid
            case .priority: break
            }
        }
        let epoch = job.journal.epoch + 1
        let result = try worker.send(.init(action: "start", id: job.id, epoch: epoch))
        guard result.event == "started" else { return result }
        _ = job.journal.begin(); job.suspension = nil; active = job
        return .init(event: "started", epoch: epoch, chunks: job.journal.chunks.map(\.index), pid: result.pid, loads: result.loads)
    }
    func run() throws {
        while let line = readLine() {
            guard line.utf8.count < 4096 else { throw ProofError.invalid }
            let command = try JSONDecoder().decode(ProofCommand.self, from: Data(line.utf8))
            var reply = ProofReply(event: "ok")
            switch command.action {
            case "register":
                guard !command.id.isEmpty, command.id.allSatisfy({ $0.isLetter || $0.isNumber }), jobs[command.id] == nil else { throw ProofError.invalid }
                jobs[command.id] = try ProofJob(command, root: admission.root, app: app)
                try trace.record("request \(command.id)")
            case "observe": reply = try observe(delayed: command.delayed)
            case "drain":
                guard draining != nil else { throw ProofError.invalid }
                reply = try worker.send(.init(action: "drain")); draining = nil
            case "finish":
                guard let active else { throw ProofError.invalid }
                _ = try worker.send(.init(action: "finish", id: active.id, epoch: active.journal.epoch))
                guard try active.journal.commit(epoch: active.journal.epoch) else { throw ProofError.invalid }
                try trace.record("commit \(active.id) chunk=\(active.journal.chunks.count)")
                self.active = nil
                reply = .init(event: "committed", chunks: active.journal.chunks.map(\.index), hash: active.journal.chunks[0].hash)
            case "late":
                guard let job = jobs[command.id] else { throw ProofError.invalid }
                reply.event = try job.journal.commit(epoch: command.epoch) ? "committed" : "stale"
            case "done", "pause", "stop", "disconnect":
                guard let job = jobs[command.id] else { throw ProofError.invalid }
                if active === job {
                    guard command.action == "disconnect" else { throw ProofError.invalid }
                    job.journal.revoke()
                    _ = try worker.send(.init(action: "cancel", id: job.id, epoch: job.journal.epoch, delayed: command.delayed))
                    draining = job; active = nil
                }
                job.ticket = nil
                switch command.action {
                case "pause": job.suspension = .manualPause
                case "stop": job.suspension = .stopped; job.journal.revoke()
                default: job.complete = true
                }
                try trace.record("\(command.action) \(job.id)")
            case "resume":
                guard let job = jobs[command.id], case .manualPause = job.suspension else { throw ProofError.invalid }
                job.ticket = try admission.register(id: job.id, app: app, rank: job.rank, delivery: job.delivery)
                job.suspension = nil
            case "status":
                guard let job = jobs[command.id] else { throw ProofError.invalid }
                reply = .init(event: "status", epoch: job.journal.epoch, chunks: job.journal.chunks.map(\.index), hash: job.journal.chunks.first?.hash ?? "")
            case "stale-cancel": reply = try worker.send(.init(action: "cancel", id: command.id, epoch: command.epoch))
            default: throw ProofError.invalid
            }
            try PriorityProof.reply(reply)
        }
        guard active == nil, draining == nil else { throw ProofError.invalid }
        jobs.removeAll()
        try worker.close()
    }
}

enum PriorityProof {
    static func reply(_ reply: ProofReply) throws {
        try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(reply) + Data([10]))
    }
    static func run(_ arguments: [String]) async throws {
        guard arguments.count == 3, ["client", "helper"].contains(arguments[0]),
              ["Libro", "VoiceRelay"].contains(arguments[2]) else { throw ProofError.invalid }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        // Explicit fixture root must already exist; this mode never creates a
        // production directory or supplies a default coordination location.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw ProofError.invalid }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ProofError.invalid }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw ProofError.invalid }
        if arguments[0] == "helper" { try await ProofWorker(root: root, app: arguments[2]).run() }
        else { try ProofClient(root: root, app: arguments[2]).run() }
    }
}
