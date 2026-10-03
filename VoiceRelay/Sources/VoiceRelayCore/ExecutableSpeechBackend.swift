import Foundation
import Darwin

// Synchronous contract calls serialize on requestLock; cancel uses stateLock only.
// The helper establishes an owned process group before its hello response.
final class ExecutableSpeechBackend: TTSBackend, @unchecked Sendable {
    let identity: BackendIdentity
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let prepareTimeout: TimeInterval
    private let synthesisTimeout: TimeInterval
    private let voice: String
    private let speed: Double
    private let requestLock = NSLock()
    private let stateLock = NSLock()
    private var session: Session?
    private var sequence = 0

    private enum Operation: String { case startup, preparation, synthesis }

    private final class Session {
        let process: Process
        let input: Pipe
        let output: Pipe
        var buffer = Data()
        var isolated = false
        var stopped = false
        init(process: Process, input: Pipe, output: Pipe) { self.process = process; self.input = input; self.output = output }
    }

    init(identity: BackendIdentity, executable: URL, arguments: [String], environment: [String: String],
         voice: String, speed: Double, prepareTimeout: TimeInterval = 180, synthesisTimeout: TimeInterval = 600) {
        self.identity = identity; self.executable = executable; self.arguments = arguments; self.environment = environment
        self.voice = voice; self.speed = speed; self.prepareTimeout = prepareTimeout; self.synthesisTimeout = synthesisTimeout
    }
    deinit { cancel() }

    func prepare() throws {
        requestLock.lock(); defer { requestLock.unlock() }
        try Task.checkCancellation()
        if stateLock.withLock({ session != nil }) { return }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RelayError.setup("Project-local speech runtime is missing. Run explicit Kokoro setup first.")
        }
        let p = Process(); let input = Pipe(); let output = Pipe()
        p.executableURL = executable; p.arguments = arguments; p.environment = environment
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        let owned = Session(process: p, input: input, output: output)
        stateLock.lock()
        do { try p.run(); session = owned; stateLock.unlock() }
        catch { stateLock.unlock(); throw RelayError.setup("Speech helper could not start.") }
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        let readFD = output.fileHandleForReading.fileDescriptor
        let writeFD = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + prepareTimeout
            let hello = try receive(owned, deadline: deadline, operation: .startup)
            guard hello["protocol"] as? Int == 1, hello["id"] as? Int == 0,
                  hello["kind"] as? String == "hello", hello["pid"] as? Int32 == p.processIdentifier,
                  getpgid(p.processIdentifier) == p.processIdentifier else {
                throw RelayError.setup("Speech helper protocol or process ownership is incompatible.")
            }
            stateLock.withLock { owned.isolated = true }
            let result = try exchange(["command": "prepare"], owned: owned, deadline: deadline, operation: .preparation)
            guard result["kind"] as? String == "ready" else { throw RelayError.setup("Speech helper did not prepare.") }
        } catch { stop(owned); throw error }
    }

    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        requestLock.lock(); defer { requestLock.unlock() }
        guard let owned = stateLock.withLock({ session }) else { throw RelayError.setup("Prepare the speech backend first.") }
        var selectedSpeed = speed
        if let setting = request.settings["speed"] {
            guard let value = setting.numericValue else { throw RelayError.setup("Speech speed must be a number.") }
            selectedSpeed = value
        }
        guard selectedSpeed.isFinite, (0.25...4).contains(selectedSpeed), !request.text.isEmpty,
              request.text.utf8.count <= 800_000 else { throw RelayError.setup("Speech request exceeds supported bounds.") }
        do {
            let result = try exchange(["command": "synthesize", "text": request.text,
                "voice": request.voice ?? voice, "speed": selectedSpeed, "language": request.language,
                "article_id": request.articleID, "chunk_index": request.chunkIndex,
                "block_indices": request.blockIndices, "directory": directory.path], owned: owned,
                deadline: ProcessInfo.processInfo.systemUptime + synthesisTimeout, operation: .synthesis)
            guard result["kind"] as? String == "result", result["article_id"] as? String == request.articleID,
                  result["chunk_index"] as? Int == request.chunkIndex,
                  result["block_indices"] as? [Int] == request.blockIndices,
                  let values = result["artifacts"] as? [[String: Any]], !values.isEmpty else {
                throw RelayError.artifact("Speech response provenance or ordering is invalid.")
            }
            let artifacts = try values.map { value -> LosslessArtifact in
                guard let file = value["file"] as? String, file == URL(fileURLWithPath: file).lastPathComponent,
                      file.hasSuffix(".wav"), let rate = value["sample_rate"] as? Int, rate > 0,
                      let channels = value["channels"] as? Int, channels > 0,
                      value["format"] as? String == "wav" else {
                    throw RelayError.artifact("Speech helper returned invalid audio metadata or paths.")
                }
                let url = directory.appendingPathComponent(file)
                guard Files.contains(directory, url), !Files.hasSymlink(url, below: directory),
                      FileManager.default.fileExists(atPath: url.path) else { throw RelayError.artifact("Speech output is missing or escaped its chunk directory.") }
                return LosslessArtifact(url: url, sampleRate: rate, channels: channels, format: "wav")
            }
            guard Set(artifacts.map(\.url)).count == artifacts.count else { throw RelayError.artifact("Speech output contains duplicate artifacts.") }
            return SynthesisResult(artifacts: artifacts)
        } catch { stop(owned); throw error }
    }

    func cancel() { if let owned = stateLock.withLock({ session }) { stop(owned) } }

    private func check(_ owned: Session, deadline: TimeInterval) throws {
        if Task.isCancelled || stateLock.withLock({ owned.stopped }) { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw RelayError.tool("Speech helper exceeded its deadline; completed checkpoints are retained.") }
    }
    private func exchange(_ body: [String: Any], owned: Session, deadline: TimeInterval, operation: Operation) throws -> [String: Any] {
        sequence += 1; let id = sequence
        var body = body; body["protocol"] = 1; body["id"] = id
        var bytes = try JSONSerialization.data(withJSONObject: body); bytes.append(10)
        guard bytes.count <= 1_048_576 else { throw RelayError.setup("Speech protocol request exceeds its limit.") }
        var offset = 0
        while offset < bytes.count {
            try check(owned, deadline: deadline)
            let written = bytes.withUnsafeBytes { ptr in Darwin.write(owned.input.fileHandleForWriting.fileDescriptor, ptr.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if written > 0 { offset += written }
            else if written < 0 && errno != EAGAIN && errno != EINTR {
                let error = try connectionFailure(owned, deadline: deadline, operation: operation); throw error
            }
            else { Thread.sleep(forTimeInterval: 0.01) }
        }
        let value = try receive(owned, deadline: deadline, operation: operation)
        guard value["protocol"] as? Int == 1, value["id"] as? Int == id else { throw RelayError.artifact("Speech helper protocol response is incompatible.") }
        if value["kind"] as? String == "error" {
            switch value["code"] as? String {
            case "missing_assets", "setup_failed": throw RelayError.setup("Speech model/runtime/G2P assets are missing or incompatible. Run explicit project-local setup.")
            case "invalid_voice": throw RelayError.setup("Speech voice is unsupported or unavailable locally.")
            case "invalid_request": throw RelayError.setup("Speech language, speed, or request is unsupported.")
            default: throw RelayError.artifact("Speech helper failed; completed chunks are retained.")
            }
        }
        return value
    }
    private func receive(_ owned: Session, deadline: TimeInterval, operation: Operation) throws -> [String: Any] {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            try check(owned, deadline: deadline)
            if let end = owned.buffer.firstIndex(of: 10) {
                let line = owned.buffer.prefix(upTo: end); owned.buffer.removeSubrange(...end)
                guard let value = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    throw RelayError.artifact("Speech helper emitted an invalid control response.")
                }
                return value
            }
            let count = Darwin.read(owned.output.fileHandleForReading.fileDescriptor, &chunk, chunk.count)
            if count > 0 {
                owned.buffer.append(contentsOf: chunk.prefix(count))
                guard owned.buffer.count <= 1_048_576 else { throw RelayError.artifact("Speech helper response exceeds its inspection limit.") }
            } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                let error = try connectionFailure(owned, deadline: deadline, operation: operation); throw error
            } else { Thread.sleep(forTimeInterval: 0.01) }
        }
    }
    private func connectionFailure(_ owned: Session, deadline: TimeInterval, operation: Operation) throws -> RelayError {
        // EOF can precede Foundation's termination notification. Allow a short,
        // bounded wait, without waiting indefinitely for a live process that closed stdout.
        let exitDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.1)
        while owned.process.isRunning && ProcessInfo.processInfo.systemUptime < exitDeadline {
            try check(owned, deadline: deadline)
            Thread.sleep(forTimeInterval: 0.01)
        }
        try check(owned, deadline: deadline)
        guard !owned.process.isRunning else {
            return RelayError.tool("Speech helper closed its control connection during \(operation.rawValue).")
        }
        owned.process.waitUntilExit()
        let status = owned.process.terminationStatus
        if owned.process.terminationReason == .uncaughtSignal {
            return RelayError.tool("Speech helper terminated by signal \(status) during \(operation.rawValue). Check macOS crash reports for the native failure.")
        }
        return RelayError.tool("Speech helper exited with status \(status) during \(operation.rawValue).")
    }
    private func stop(_ owned: Session) {
        let shouldStop = stateLock.withLock { () -> Bool in
            if owned.stopped { return false }
            owned.stopped = true
            if session === owned { session = nil }
            return true
        }
        guard shouldStop else { return }
        let pid = owned.process.processIdentifier
        let grouped = stateLock.withLock { owned.isolated } || getpgid(pid) == pid
        if grouped { kill(-pid, SIGTERM) } else if owned.process.isRunning { kill(pid, SIGTERM) }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        while owned.process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if grouped { kill(-pid, SIGKILL) } else if owned.process.isRunning { kill(pid, SIGKILL) }
        owned.process.waitUntilExit()
        // Pipes stay alive while an in-flight request unwinds; Session owns them.
    }
}
