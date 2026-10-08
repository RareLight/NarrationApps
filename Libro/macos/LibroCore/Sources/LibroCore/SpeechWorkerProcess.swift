import Foundation
import Darwin

public struct WorkerConfiguration: Sendable {
    public let executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var requestTimeout: Duration
    public var shutdownGrace: TimeInterval
    public var terminationGrace: TimeInterval

    public init(executable: URL, arguments: [String] = ["--serve"],
                environment: [String: String] = [:], requestTimeout: Duration = .seconds(180),
                shutdownGrace: TimeInterval = 0.5, terminationGrace: TimeInterval = 1) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.requestTimeout = requestTimeout; self.shutdownGrace = shutdownGrace
        self.terminationGrace = terminationGrace
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
    private let configuration: WorkerConfiguration
    private let identity: AttemptIdentity
    private var pending: Pending?
    private var terminalError: (any Error)?
    private var diagnosticTail = Data()
    private var stopStarted = false
    private var stopped = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    init(configuration: WorkerConfiguration, identity: AttemptIdentity) throws {
        guard configuration.requestTimeout > .zero, configuration.shutdownGrace.isFinite,
              configuration.shutdownGrace >= 0, configuration.terminationGrace.isFinite,
              configuration.terminationGrace >= 0 else { throw SpeechFailure(.invalidInput) }
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
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostics
        process.terminationHandler = { [weak self] _ in self?.exited.signal() }
        do { try process.run() }
        catch { throw SpeechFailure(.workerExited) }
        // Closing our copies of the child's pipe ends makes EOF meaningful.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? diagnostics.fileHandleForWriting.close()
        DispatchQueue(label: "org.librotts.worker-control").async { [self] in readControl() }
        DispatchQueue(label: "org.librotts.worker-diagnostics").async { [self] in drainDiagnostics() }
    }

    func request(_ command: WorkerCommand, progress: (@Sendable (ModelPreparationProgress) -> Void)? = nil) async throws -> WorkerEvent {
        try Task.checkCancellation()
        let data = try SpeechIPC.encode(command)
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
                result = .failure(SpeechFailure(code))
            } else if (active.command.kind == .initialize && event.kind == .ready) ||
                        (active.command.kind == .generate && event.kind == .chunk) ||
                        (active.command.kind == .prepare && event.kind == .prepared) {
                result = .success(event)
            } else { result = .failure(SpeechFailure(.protocolViolation)) }
            pending = nil; return (active, result)
        }
        if let (value, callback) = update { callback(value) }
        if let (active, result) = completion {
            active.timer?.cancel(); active.continuation.resume(with: result)
        }
    }

    private func fail(_ error: any Error, token: UUID? = nil) {
        let active: Pending? = lock.withLock {
            if let token, pending?.token != token { return nil }
            terminalError = error
            let active = pending; pending = nil
            return active
        }
        active?.timer?.cancel(); active?.continuation.resume(throwing: error)
    }

    private func drainDiagnostics() {
        // Drain even after reaching the limit; never let library logging fill a
        // pipe. Keep only a private 8 KiB tail, without persistence or UI echo.
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
}
