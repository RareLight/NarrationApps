import Foundation
import Darwin

public struct WorkerConfiguration: Sendable {
    public let executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var requestTimeout: Duration
    public var shutdownGrace: TimeInterval
    public var terminationGrace: TimeInterval
    public var debugLog: DebugLog?
    public var mp3Library: URL?
    public var maximumFootprintBytes: UInt64

    public init(executable: URL, arguments: [String] = ["--serve"],
                environment: [String: String] = [:], requestTimeout: Duration = .seconds(180),
                shutdownGrace: TimeInterval = 0.5, terminationGrace: TimeInterval = 1, debugLog: DebugLog? = nil, mp3Library: URL? = nil,
                maximumFootprintBytes: UInt64 = SpeechMemoryPolicy.workerFootprintLimitBytes) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.requestTimeout = requestTimeout; self.shutdownGrace = shutdownGrace
        self.terminationGrace = terminationGrace
        self.debugLog = debugLog
        self.mp3Library = mp3Library
        self.maximumFootprintBytes = maximumFootprintBytes
    }
}

/// No MLX objects live here. All shared process state is protected by `lock`;
/// one serial writer queue and one reader per pipe own the FileHandles. The
/// annotation describes that synchronization, not concurrent inference safety.
final class SpeechWorkerProcess: @unchecked Sendable {
    private struct Pending {
        let token: UUID
        let command: WorkerCommand
        let continuation: CheckedContinuation<WorkerEvent, Error>
        let progress: (@Sendable (ModelPreparationProgress) -> Void)?
        var timer: Task<Void, Never>?
    }
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let diagnostics = Pipe()
    private let lock = NSLock()
    private let writerQueue = DispatchQueue(label: "org.librotts.worker-input")
    private let exited = DispatchSemaphore(value: 0)
    private let diagnosticsDrained = DispatchSemaphore(value: 0)
    private let configuration: WorkerConfiguration
    private let identity: AttemptIdentity
    private var pending: Pending?
    private var terminalError: (any Error)?
    private var diagnosticTail = Data()
    private var stopStarted = false
    private var stopped = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var memoryMonitor: Task<Void, Never>?
    private var peakFootprintBytes: UInt64 = 0

    init(configuration: WorkerConfiguration, identity: AttemptIdentity) throws {
        guard configuration.requestTimeout > .zero, configuration.shutdownGrace.isFinite,
              configuration.shutdownGrace >= 0, configuration.terminationGrace.isFinite,
              configuration.terminationGrace >= 0, configuration.maximumFootprintBytes > 0 else { throw SpeechFailure(.invalidInput) }
        self.configuration = configuration; self.identity = identity
        // A worker crash during a queued write must report EPIPE, not terminate
        // the GUI through SIGPIPE. This flag belongs only to our pipe descriptor.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw SpeechFailure(.storage)
        }
        process.executableURL = configuration.executable
        process.arguments = configuration.arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { _, new in new }
        process.environment?["LIBRO_DEBUG_LOG"] = configuration.debugLog == nil ? "0" : "1"
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostics
        process.terminationHandler = { [weak self] _ in self?.exited.signal() }
        do { try process.run() }
        catch {
            configuration.debugLog?.record("worker launch failed: \((error as NSError).domain) code=\((error as NSError).code)")
            throw SpeechFailure(.workerExited)
        }
        log("started pid=\(process.processIdentifier) metalValidation=\(process.environment?["MTL_DEBUG_LAYER"] ?? "unset")")
        // Closing our copies of the child's pipe ends makes EOF meaningful.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? diagnostics.fileHandleForWriting.close()
        DispatchQueue(label: "org.librotts.worker-control").async { [self] in readControl() }
        DispatchQueue(label: "org.librotts.worker-diagnostics").async { [self] in drainDiagnostics() }
        memoryMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.process.isRunning else { return }
                if let footprint = Self.physicalFootprint(of: self.process.processIdentifier) {
                    self.lock.withLock { self.peakFootprintBytes = max(self.peakFootprintBytes, footprint) }
                    if footprint > self.configuration.maximumFootprintBytes {
                        self.log("memory limit exceeded pid=\(self.process.processIdentifier) footprintBytes=\(footprint) limitBytes=\(self.configuration.maximumFootprintBytes)")
                        self.fail(SpeechFailure(.memoryLimit))
                        // This is our owned private helper, with no final-publication authority.
                        // Do not allow another shutdown grace interval of runaway allocation.
                        if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
                        return
                    }
                }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
    }

    static func physicalFootprint(of pid: Int32) -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? usage.ri_phys_footprint : nil
    }

    func request(_ command: WorkerCommand, progress: (@Sendable (ModelPreparationProgress) -> Void)? = nil) async throws -> WorkerEvent {
        try Task.checkCancellation()
        let data = try SpeechIPC.encode(command)
        log("request=\(command.kind.rawValue) chunk=\(command.chunk.map(String.init) ?? "none") model=\(command.settings?.model.rawValue ?? "unchanged")")
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let accepted: Bool = lock.withLock {
                    if let terminalError { continuation.resume(throwing: terminalError); return false }
                    guard pending == nil, !stopStarted else {
                        continuation.resume(throwing: SpeechFailure(.protocolViolation)); return false
                    }
                    pending = Pending(token: token, command: command, continuation: continuation, progress: progress)
                    return true
                }
                guard accepted else { return }
                let timer = Task { [self] in
                    do { try await Task.sleep(for: configuration.requestTimeout) }
                    catch { return }
                    fail(SpeechFailure(.timeout), token: token)
                }
                lock.withLock {
                    if pending?.token == token { pending?.timer = timer }
                    else { timer.cancel() }
                }
                // Also covers cancellation between the initial check and registration.
                if Task.isCancelled { fail(CancellationError(), token: token); return }
                writerQueue.async { [self] in
                    guard lock.withLock({ pending?.token == token && !stopStarted }) else { return }
                    do { try input.fileHandleForWriting.write(contentsOf: data) }
                    catch { fail(SpeechFailure(.workerExited), token: token) }
                }
            }
        } onCancel: { [self] in
            fail(CancellationError(), token: token)
        }
    }

    private func readControl() {
        var buffer = Data()
        do {
            while let bytes = try SpeechIPC.readPipe(output.fileHandleForReading) {
                buffer.append(bytes)
                while let newline = buffer.firstIndex(of: 10) {
                    guard newline <= SpeechIPC.maximumRecordBytes else { throw SpeechFailure(.protocolViolation) }
                    let line = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(...newline)
                    let event: WorkerEvent
                    do { event = try JSONDecoder().decode(WorkerEvent.self, from: line) }
                    catch { throw SpeechFailure(.protocolViolation) }
                    consume(event)
                }
                guard buffer.count <= SpeechIPC.maximumRecordBytes else { throw SpeechFailure(.protocolViolation) }
            }
            fail(SpeechFailure(buffer.isEmpty ? .workerExited : .protocolViolation))
        } catch { fail(error is SpeechFailure ? error : SpeechFailure(.workerExited)) }
    }

    private func consume(_ event: WorkerEvent) {
        var update: (ModelPreparationProgress, @Sendable (ModelPreparationProgress) -> Void)?
        let completion: (Pending, Result<WorkerEvent, Error>)? = lock.withLock {
            guard event.protocolVersion == 1 else {
                terminalError = SpeechFailure(.protocolViolation)
                guard let active = pending else { return nil }
                pending = nil; return (active, .failure(SpeechFailure(.protocolViolation)))
            }
            // Events from previous attempts/chunks cannot move current progress.
            guard event.identity == identity, let active = pending,
                  event.chunk == active.command.chunk else { return nil }
            if active.command.kind == .prepare, event.kind == .assetProgress,
               let value = event.preparation, let model = active.command.settings?.model, value.isValid(for: model) {
                if let callback = active.progress { update = (value, callback) }
                return nil
            }
            let result: Result<WorkerEvent, Error>
            if event.kind == .failure, let code = event.failure {
                result = .failure(SpeechFailure(code, operation: active.command.kind, chunk: active.command.chunk))
            } else if (active.command.kind == .initialize && event.kind == .ready) ||
                        (active.command.kind == .generate && event.kind == .chunk) ||
                        (active.command.kind == .prepare && event.kind == .prepared) {
                result = .success(event)
            } else { result = .failure(SpeechFailure(.protocolViolation)) }
            pending = nil; return (active, result)
        }
        if let (value, callback) = update { callback(value) }
        if let (active, result) = completion {
            switch result {
            case .success: log("response=\(event.kind.rawValue) chunk=\(event.chunk.map(String.init) ?? "none")")
            case .failure: log("failure=\(event.failure?.rawValue ?? "protocolViolation") request=\(active.command.kind.rawValue) chunk=\(active.command.chunk.map(String.init) ?? "none")")
            }
            active.timer?.cancel(); active.continuation.resume(with: result)
        }
    }

    private func fail(_ error: any Error, token: UUID? = nil) {
        let active: Pending? = lock.withLock {
            if let token, pending?.token != token { return nil }
            // EOF after a resource-limit kill must not hide the original cause.
            guard terminalError == nil else { return nil }
            terminalError = error
            let active = pending; pending = nil
            return active
        }
        let contextual: any Error
        if let active, let failure = error as? SpeechFailure {
            contextual = SpeechFailure(failure.code, operation: active.command.kind, chunk: active.command.chunk)
        } else { contextual = error }
        active?.timer?.cancel(); active?.continuation.resume(throwing: contextual)
        if let active { log("request failed=\((error as? SpeechFailure)?.code.rawValue ?? (error is CancellationError ? "cancelled" : "unknown")) request=\(active.command.kind.rawValue) chunk=\(active.command.chunk.map(String.init) ?? "none")") }
    }

    private func drainDiagnostics() {
        // Drain even after reaching the limit; never let library logging fill a
        // pipe. Retain an 8 KiB tail; persistence is explicitly opt-in.
        defer { diagnosticsDrained.signal() }
        while let bytes = try? SpeechIPC.readPipe(diagnostics.fileHandleForReading) {
            lock.withLock {
                diagnosticTail.append(bytes)
                if diagnosticTail.count > 8_192 { diagnosticTail.removeFirst(diagnosticTail.count - 8_192) }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            let first: Bool = lock.withLock {
                if stopped { continuation.resume(); return false }
                stopWaiters.append(continuation)
                if stopStarted { return false }
                stopStarted = true; return true
            }
            guard first else { return }
            memoryMonitor?.cancel()
            fail(CancellationError())
            writerQueue.async { [self] in
                if let command = try? SpeechIPC.encode(WorkerCommand(kind: .cancel, identity: identity)) {
                    try? input.fileHandleForWriting.write(contentsOf: command)
                }
                try? input.fileHandleForWriting.close()
            }
            DispatchQueue(label: "org.librotts.worker-reap").async { [self] in
                if process.isRunning, exited.wait(timeout: .now() + configuration.shutdownGrace) == .timedOut {
                    if process.isRunning { process.terminate() }
                    if exited.wait(timeout: .now() + configuration.terminationGrace) == .timedOut, process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                process.waitUntilExit() // Foundation reaps this owned PID.
                _ = diagnosticsDrained.wait(timeout: .now() + 1)
                let tail = lock.withLock { diagnosticTail }
                let peak = lock.withLock { peakFootprintBytes }
                log("stopped pid=\(process.processIdentifier) reason=\(process.terminationReason == .uncaughtSignal ? "signal" : "exit") status=\(process.terminationStatus) peakFootprintBytes=\(peak)")
                if !tail.isEmpty { log("private stderr tail:\n" + String(decoding: tail, as: UTF8.self)) }
                try? output.fileHandleForReading.close()
                try? diagnostics.fileHandleForReading.close()
                let waiters = lock.withLock {
                    stopped = true; diagnosticTail.removeAll()
                    let waiters = stopWaiters; stopWaiters.removeAll(); return waiters
                }
                for waiter in waiters { waiter.resume() }
            }
        }
    }

    private func log(_ message: String) {
        configuration.debugLog?.record("batch=\(identity.batch) job=\(identity.job) attempt=\(identity.attempt) \(message)")
    }
}
