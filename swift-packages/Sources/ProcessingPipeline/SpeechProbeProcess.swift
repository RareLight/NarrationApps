import Foundation
import NarrationCore
import Darwin

/// Single-owner, synchronous transport for the explicit native/fixture probe.
/// Never call from a GUI executor. Diagnostics are drained to /dev/null, not
/// retained across jobs. Existing worker footprint and owned-reap rules apply.
public final class SpeechProbeProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let session = UUID()
    private let state = NSLock()
    private let writer = NSLock()
    private let reader = NSLock()
    private var memoryFailure = false
    private var peak: UInt64 = 0
    private var buffer = Data()
    private var worker: UUID?
    private let timer: DispatchSourceTimer
    private let configuration: WorkerConfiguration
    private var closed = false
    private var launched = false
    private var inputFinished = false
    private let closeCondition = NSCondition()
    private var closeStarted = false
    private var closeResult: Result<Void, Error>?
    private let exited = DispatchSemaphore(value: 0)
    public var pid: Int32 { process.processIdentifier }
    public var peakFootprint: UInt64 { state.withLock { peak } }
    public var currentFootprint: UInt64? { SpeechWorkerProcess.physicalFootprint(of: pid) }
    public var instance: UUID? { worker }

    public init(configuration: WorkerConfiguration) throws {
        self.configuration = configuration
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "org.narration.probe-memory"))
        timer.resume()
        process.executableURL = configuration.executable; process.arguments = configuration.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { _, new in new }
        process.environment?["NARRATION_DEBUG_LOG"] = "0"
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exitSignal = exited
        process.terminationHandler = { _ in exitSignal.signal() }
        guard configuration.maximumFootprintBytes > 0,
              configuration.shutdownGrace.isFinite, configuration.shutdownGrace >= 0,
              configuration.terminationGrace.isFinite, configuration.terminationGrace >= 0,
              fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0,
              fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFL, O_NONBLOCK) == 0 else { throw SpeechFailure(.invalidInput) }
        do { try process.run() } catch { throw SpeechFailure(.workerExited) }
        launched = true
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self, self.process.isRunning,
                  let footprint = SpeechWorkerProcess.physicalFootprint(of: self.process.processIdentifier) else { return }
            self.state.withLock {
                self.peak = max(self.peak, footprint)
                if footprint > self.configuration.maximumFootprintBytes {
                    self.memoryFailure = true
                    if self.process.isRunning { _ = kill(self.process.processIdentifier, SIGKILL) }
                }
            }
        }
    }
    deinit { try? close() }

    public func send(_ kind: SpeechProbeCommand.Kind, _ command: WorkerCommand, mode: SpeechProbeAudioMode? = nil, holdLoadedInitialization: Bool = false, admission: SpeechWorkerAdmission? = nil) throws {
        try writer.withLock {
            guard state.withLock({ !closed }) else { throw SpeechFailure(.workerExited) }
            let data = try SpeechIPC.encode(SpeechProbeCommand(session: session, kind: kind, command: command, audioMode: mode, holdLoadedInitialization: holdLoadedInitialization, admission: admission))
            let fd = input.fileHandleForWriting.fileDescriptor
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    guard state.withLock({ !closed }) else { throw SpeechFailure(.workerExited) }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw SpeechFailure(.timeout) }
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count; continue }
                    if count < 0, errno == EINTR { continue }
                    guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else { throw SpeechFailure(.workerExited) }
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&descriptor, 1, 20)
                    guard ready >= 0 || errno == EINTR else { throw SpeechFailure(.workerExited) }
                }
            }
        }
    }
    public func next(timeout: TimeInterval = 30) throws -> SpeechProbeEvent {
        try reader.withLock { try readNext(timeout: timeout) }
    }
    private func readNext(timeout: TimeInterval) throws -> SpeechProbeEvent {
        guard timeout.isFinite, timeout > 0, state.withLock({ !closed }) else { throw SpeechFailure(.invalidInput) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            guard state.withLock({ !closed }) else { throw SpeechFailure(.workerExited) }
            if state.withLock({ memoryFailure }) { throw SpeechFailure(.memoryLimit) }
            if let newline = buffer.firstIndex(of: 10) {
                guard newline <= SpeechIPC.maximumRecordBytes else { throw SpeechFailure(.protocolViolation) }
                let data = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                let event: SpeechProbeEvent
                do { event = try JSONDecoder().decode(SpeechProbeEvent.self, from: data) }
                catch { throw SpeechFailure(.protocolViolation) }
                guard event.version == SpeechProbeWire.version, event.session == session, event.pid == pid,
                      worker == nil || worker == event.worker else { throw SpeechFailure(.incompatibleWorker) }
                if worker == nil {
                    guard [.waitingForLease, .leaseAcquired, .loadingModel, .initialized, .revoked, .initializationCancelled, .failure].contains(event.kind) else { throw SpeechFailure(.protocolViolation) }
                    worker = event.worker
                }
                return event
            }
            guard buffer.count <= SpeechIPC.maximumRecordBytes else { throw SpeechFailure(.protocolViolation) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SpeechFailure(.timeout) }
            var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fd, 1, 20)
            if ready < 0 { if errno == EINTR { continue }; throw SpeechFailure(.workerExited) }
            if ready == 0 { continue }
            guard let data = try SpeechIPC.readPipe(output.fileHandleForReading) else { throw SpeechFailure(.workerExited) }
            buffer.append(data)
        }
    }
    public func close() throws {
        closeCondition.lock()
        if closeStarted {
            while closeResult == nil { closeCondition.wait() }
            let result = closeResult!
            closeCondition.unlock()
            return try result.get()
        }
        closeStarted = true
        closeCondition.unlock()
        state.withLock { closed = true }
        let result = Result { try reap() }
        closeCondition.lock()
        closeResult = result; closeCondition.broadcast(); closeCondition.unlock()
        try result.get()
    }
    private func reap() throws {
        guard launched else { timer.cancel(); return }
        try? finishInput() // Parent EOF cancels/joins first.
        func wait(_ seconds: TimeInterval) -> Bool {
            exited.wait(timeout: .now() + seconds) == .success
        }
        if !wait(configuration.shutdownGrace) {
            if process.isRunning { process.terminate() }
            if !wait(configuration.terminationGrace) {
                if process.isRunning { _ = kill(pid, SIGKILL) }
                guard wait(5) else { throw SpeechFailure(.timeout) }
            }
        }
        // Keep monitoring until actual exit; no replacement is launched by this
        // transport, and the helper itself retains its kernel protection.
        // Foundation's exit callback observes this owned child's termination.
        // waitUntilExit can strand a cooperative thread in its run loop even
        // after isRunning becomes false; never add an unbounded second wait.
        guard !process.isRunning else { throw SpeechFailure(.timeout) }
        timer.cancel()
        reader.withLock { try? output.fileHandleForReading.close() }
    }

    public func finishInput() throws {
        try writer.withLock {
            try state.withLock {
                if !inputFinished { inputFinished = true; try input.fileHandleForWriting.close() }
            }
        }
    }

    public static func readFrame(_ event: SpeechProbeEvent, spool: URL, model: SpeechModel, index: Int) throws -> [Float] {
        guard event.kind == .frame, let frame = event.frame, frame.identity == event.identity else { throw SpeechFailure(.protocolViolation) }
        return try WorkerPCM.read(frame, index: index, spool: spool, model: model)
    }
}
