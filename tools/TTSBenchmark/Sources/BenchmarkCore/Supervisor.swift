import Foundation
import Darwin

public enum Runtime {
    public static var cancelled: sig_atomic_t { interrupted }
    private nonisolated(unsafe) static var interrupted: sig_atomic_t = 0
    public static func requestCancellation() { interrupted = 1 }
    public static func clearCancellation() { interrupted = 0 }
    public static func installSignals() {
        signal(SIGINT) { _ in Runtime.interrupted = 1 }
        signal(SIGTERM) { _ in Runtime.interrupted = 1 }
    }
    public static func footprint(_ pid: pid_t) -> UInt64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? usage.ri_phys_footprint : 0
    }
    public static func descendants(_ pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 128)
        let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [] }
        // proc_listchildpids returns a PID count; proc_listpids returns bytes.
        let children = Array(pids.prefix(Int(count))).filter { $0 > 0 }
        return children + children.flatMap { descendants($0) }
    }
    public static func stop(_ process: Process) {
        let children = descendants(process.processIdentifier)
        children.reversed().forEach { kill($0, SIGKILL) }
        if process.isRunning { process.terminate() }
        let until = ContinuousClock.now.advanced(by: .seconds(1))
        while process.isRunning && ContinuousClock.now < until { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
    public static func seconds(since start: ContinuousClock.Instant) -> Double {
        let c = start.duration(to: .now).components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

public enum Supervisor {
    /// File-backed control output prevents a verbose/crashed worker blocking on a pipe.
    /// Only a bounded JSONL protocol is accepted; diagnostics are a separate local log.
    public static func run(executable: URL, job: WorkerJob, attempt: Attempt, directory: URL,
                           offline: Bool = true, extraArguments: [String] = []) throws -> Attempt {
        var result = attempt
        let jobURL = directory.appendingPathComponent("job.json")
        try Files.write(job, jobURL)
        let events = directory.appendingPathComponent("events.jsonl"), log = directory.appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath: events.path, contents: nil)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: events), diagnostics = try FileHandle(forWritingTo: log)
        defer { try? output.close(); try? diagnostics.close() }
        let process = Process()
        process.executableURL = offline ? URL(fileURLWithPath: "/usr/bin/sandbox-exec") : executable
        process.arguments = offline ? ["-p", "(version 1)(allow default)(deny network*)", executable.path, jobURL.path] + extraArguments : [jobURL.path] + extraArguments
        var environment = ProcessInfo.processInfo.environment
        for name in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACE_TOKEN"] { environment.removeValue(forKey: name) }
        environment["HF_HOME"] = job.workspace + "/cache"
        environment["HF_HUB_CACHE"] = job.workspace + "/cache/hub"
        environment["HF_HUB_OFFLINE"] = offline ? "1" : "0"
        process.environment = environment
        process.standardOutput = output; process.standardError = diagnostics
        let start = ContinuousClock.now
        try process.run()
        var failure: String?
        while process.isRunning {
            let pids = [process.processIdentifier] + Runtime.descendants(process.processIdentifier)
            let footprint = pids.reduce(UInt64(0)) { $0 + Runtime.footprint($1) }
            result.workerPeakBytes = max(result.workerPeakBytes, footprint)
            result.hostPeakBytes = max(result.hostPeakBytes, Runtime.footprint(getpid()))
            let outputSize = (try? events.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if outputSize > 0, result.readySeconds == nil { result.readySeconds = Runtime.seconds(since: start) }
            let logSize = (try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if Runtime.cancelled != 0 { failure = "cancelled" }
            else if Runtime.seconds(since: start) > job.matrix.timeoutSeconds { failure = "timeout" }
            else if footprint > job.matrix.footprintLimitBytes { failure = "memory-limit" }
            else if outputSize > 8_000_000 || logSize > 8_000_000 { failure = "protocol/log-size-limit" }
            if failure != nil { Runtime.stop(process); break }
            usleep(20_000)
        }
        process.waitUntilExit()
        result.processSeconds = Runtime.seconds(since: start)
        let bytes = try Data(contentsOf: events)
        guard bytes.count <= 8_000_000 else { result.outcome = "failed"; result.reason = "protocol-size-limit"; return result }
        var sawFinished = false
        do {
            for line in bytes.split(separator: 10) {
                guard line.count < 131072 else { throw BenchError("Oversized worker record") }
                let event = try JSONDecoder().decode(WorkerEvent.self, from: Data(line))
                switch event.kind {
                case "loaded":
                    guard result.loadSeconds == nil, let seconds = event.seconds, seconds.isFinite, seconds >= 0 else { throw BenchError("Malformed load event") }
                    result.loadSeconds = seconds
                case "measurement":
                    guard !sawFinished, let m = event.measurement, m.profile == job.profile.id else { throw BenchError("Malformed measurement event") }
                    try m.validate()
                    guard let passage = job.matrix.passages.first(where: { $0.id == m.passage }),
                          (0...job.matrix.repetitions).contains(m.repetition),
                          m.chunks.joined() == passage.text,
                          (m.repetition == 0 ? ["cold", "warmup"].contains(m.state) : m.state == "warm"),
                          m.duration <= job.matrix.maximumAudioSeconds else { throw BenchError("Unexpected passage/repetition/coverage") }
                    guard !result.measurements.contains(where: { $0.passage == m.passage && $0.repetition == m.repetition && $0.state == m.state }) else { throw BenchError("Duplicate measurement") }
                    let wav = try Files.child(URL(fileURLWithPath: job.output), m.wav)
                    let info = try Wave.inspect(wav)
                    guard info.frames == m.frames, info.rate == m.sampleRate, try Files.hash(wav) == m.sha256 else { throw BenchError("Artifact mismatch") }
                    result.measurements.append(m)
                case "finished": guard !sawFinished else { throw BenchError("Duplicate finish") }; sawFinished = true
                case "failure": failure = event.message ?? "worker-failure"
                default: throw BenchError("Unknown worker event")
                }
            }
            let expected = job.matrix.passages.count * (job.matrix.repetitions + 1)
            if result.loadSeconds == nil { result.readySeconds = nil }
            if failure == nil && process.terminationStatus == 0 && sawFinished && result.measurements.count == expected {
                result.outcome = "completed"
            } else { result.outcome = failure == "cancelled" ? "cancelled" : "failed"; result.reason = failure ?? "incomplete/crashed-worker" }
        } catch { result.outcome = "failed"; result.reason = "Invalid worker evidence: \(error)" }
        return result
    }
}
