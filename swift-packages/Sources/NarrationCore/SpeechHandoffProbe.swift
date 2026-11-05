import Foundation
import Darwin

/// Opt-in VS00 wire contract, independent of the production SpeechIPC version.
/// --handoff-probe and opt-in --coordinated-serve share this private contract.
public enum SpeechProbeAudioMode: String, Codable, Sendable {
    case paragraphs, firstSentence, qwenIncremental
}
// Version 7 reports frontend/speech residency and permits owned promotion.
public enum SpeechProbeWire { public static let version = 7 }

public struct SpeechProbeResources: Sendable {
    public let preparationOnly: Bool, usesInference: Bool
    public init(preparationOnly: Bool, usesInference: Bool) {
        self.preparationOnly = preparationOnly; self.usesInference = usesInference
    }
}
/// A helper finished loading for a demand that is no longer first in line.
/// Retain safe weights, but publish no lower-priority speech after that load.
public struct SpeechProbePriorityYield: Error, Sendable { public init() {} }

/// Internal app-to-helper handshake. Never populated from an HTTP request.
public struct SpeechWorkerAdmission: Codable, Sendable {
    public let demand: SpeechWorkDemand
    public let root: URL
    public let inferenceFile: URL
    public init(demand: SpeechWorkDemand, root: URL, inferenceFile: URL = InferenceLease.defaultFile) {
        self.demand = demand; self.root = root; self.inferenceFile = inferenceFile
    }
    public func acquire() async throws -> InferenceLease {
        let registry = try SpeechWorkAdmission(root: root)
        while true {
            try Task.checkCancellation()
            if let lease = try registry.tryAcquireResidency(for: demand, inferenceFile: inferenceFile) { return lease }
            if try registry.decision(for: demand) == .withdrawn { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

public struct SpeechProbeCommand: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case initialize, generate, cancel, acknowledge, shutdown }
    public var version = SpeechProbeWire.version
    public let session: UUID
    public let kind: Kind
    public let command: WorkerCommand
    public let audioMode: SpeechProbeAudioMode?
    public let holdLoadedInitialization: Bool?
    public let admission: SpeechWorkerAdmission?
    public init(session: UUID, kind: Kind, command: WorkerCommand, audioMode: SpeechProbeAudioMode? = nil, holdLoadedInitialization: Bool? = nil, admission: SpeechWorkerAdmission? = nil) {
        self.session = session; self.kind = kind; self.command = command; self.audioMode = audioMode
        self.holdLoadedInitialization = holdLoadedInitialization
        self.admission = admission
    }
}

public struct SpeechProbeEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case waitingForLease, leaseAcquired, loadingModel, loadedAwaitingAdmission, initialized, initializationCancelled, started, frame, revoked, completed, quiescent, ready, unloaded, ignored, failure }
    public var version = SpeechProbeWire.version
    public let session: UUID
    public let worker: UUID
    public let pid: Int32
    public let identity: AttemptIdentity
    public let kind: Kind
    public let frame: WorkerEvent?
    public let failure: SpeechFailureCode?
    public let time: Double
    public init(session: UUID, worker: UUID, identity: AttemptIdentity, kind: Kind,
                frame: WorkerEvent? = nil, failure: SpeechFailureCode? = nil) {
        self.session = session; self.worker = worker; pid = getpid(); self.identity = identity
        self.kind = kind; self.frame = frame; self.failure = failure
        time = ProcessInfo.processInfo.systemUptime
    }
}

/// Backend methods are strictly serialized: initialize, one owned producer,
/// joined quiescence/reset, then another producer. No tensors cross this seam.
public protocol SpeechProbeBackend: Sendable {
    var resources: SpeechProbeResources { get }
    func initialize(_ command: WorkerCommand, admission: SpeechWorkerAdmission?, report: @escaping @Sendable (SpeechProbeEvent.Kind) throws -> Void) async throws
    func generate(_ command: WorkerCommand, mode: SpeechProbeAudioMode, admission: SpeechWorkerAdmission?,
                  report: @escaping @Sendable (SpeechProbeEvent.Kind) throws -> Void, started: @escaping @Sendable () throws -> Void,
                  emit: @escaping @Sendable (WorkerEvent) throws -> Void) async throws
    func quiesceAndReset() async throws
    func shutdown(report: @escaping @Sendable (SpeechProbeEvent.Kind) -> Void) async
}

/// One outstanding audio frame. Revocation wakes a stalled producer; it cannot
/// publish another frame after the revoke boundary. Timeout is probe policy only.
public final class SpeechProbeCredit: @unchecked Sendable {
    private let condition = NSCondition()
    private var outstanding: Int?
    private var revoked = false
    public init() {}
    public func publish(sequence: Int, operation: () throws -> Void) throws {
        condition.lock(); defer { condition.unlock() }
        try waitForCredit()
        outstanding = sequence
        try operation()
    }
    private func waitForCredit() throws {
        let deadline = Date().addingTimeInterval(10)
        while outstanding != nil && !revoked {
            guard condition.wait(until: deadline) else { throw SpeechFailure(.timeout) }
        }
        guard !revoked else { throw CancellationError() }
        try Task.checkCancellation()
    }
    public func finish() throws {
        condition.lock(); defer { condition.unlock() }
        try waitForCredit() // Last frame must settle before completing the job.
    }
    public func acknowledge(_ sequence: Int) {
        condition.lock(); defer { condition.unlock() }
        guard outstanding == sequence else { return }
        outstanding = nil; condition.broadcast()
    }
    public func revoke() {
        condition.lock(); defer { condition.unlock() }
        revoked = true; condition.broadcast()
    }
    public var isRevoked: Bool { condition.lock(); defer { condition.unlock() }; return revoked }
}

/// Bounded versioned control reader shared by native and synthetic probe modes.
/// One dedicated queue owns reads; no unbounded AsyncStream or detached reader.
public final class SpeechProbeReader: @unchecked Sendable {
    private let input: FileHandle
    private let queue = DispatchQueue(label: "org.narration.probe-reader")
    private var buffer = Data()
    public init(input: FileHandle = .standardInput) { self.input = input }
    public func next<T: Decodable & Sendable>(_ type: T.Type) async throws -> T? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in continuation.resume(with: Result { try read(type) }) }
        }
    }
    private func read<T: Decodable>(_ type: T.Type) throws -> T? {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                guard newline <= SpeechIPC.maximumRecordBytes else { throw SpeechFailure(.protocolViolation) }
                let data = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                do { return try JSONDecoder().decode(type, from: data) }
                catch { throw SpeechFailure(.protocolViolation) }
            }
            guard buffer.count <= SpeechIPC.maximumRecordBytes else { throw SpeechFailure(.protocolViolation) }
            guard let bytes = try SpeechIPC.readPipe(input) else {
                guard buffer.isEmpty else { throw SpeechFailure(.protocolViolation) }
                return nil
            }
            buffer.append(bytes)
        }
    }
}

/// Responsive control with an owned producer plus its joined reset task. Kept
/// separate from normal serving until native feasibility and integration gates.
public final class SpeechProbeServer: @unchecked Sendable {
    private struct Active {
        let identity: AttemptIdentity
        let credit: SpeechProbeCredit
        let producer: Task<Result<Void, Error>, Never>
        let joined: Task<Void, Never>
    }
    private let backend: any SpeechProbeBackend
    private let output: FileHandle
    private let writer = NSLock()
    private let state = NSLock()
    private var active: Active?
    private var finishing = false
    private var usable = true
    private var closed = false
    private var initialization: SpeechProbeCommand?
    private var loading: Task<Void, Never>?
    private var loadCredit: SpeechProbeCredit?
    private var loadFinished = false
    private var loadRevoked = false
    private var loaded = false
    private var shutdownDone = false
    private let instance = UUID()
    public init(backend: any SpeechProbeBackend, output: FileHandle) { self.backend = backend; self.output = output }
    private func resourceEvent(_ identity: AttemptIdentity) -> WorkerEvent {
        let resources = backend.resources
        return .init(kind: .ready, identity: identity, textPreparationOnly: resources.preparationOnly,
            preparationUsesInference: resources.usesInference)
    }
    private func emit(_ kind: SpeechProbeEvent.Kind, session: UUID, identity: AttemptIdentity,
                      frame: WorkerEvent? = nil, failure: SpeechFailureCode? = nil) throws {
        try writer.withLock {
            try output.write(contentsOf: SpeechIPC.encode(SpeechProbeEvent(session: session, worker: instance,
                identity: identity, kind: kind, frame: frame, failure: failure)))
        }
    }
    private func start(_ request: SpeechProbeCommand) throws {
        try state.withLock {
            guard loaded, !closed, active == nil, usable else { throw SpeechFailure(.protocolViolation) }
            finishing = false
            let credit = SpeechProbeCredit()
            let producer = Task.detached { [self] () -> Result<Void, Error> in
                do {
                    try await backend.generate(request.command, mode: request.audioMode ?? .paragraphs, admission: request.admission,
                        report: { [self] kind in try emit(kind, session: request.session, identity: request.command.identity) }, started: { [self] in
                        try emit(.started, session: request.session, identity: request.command.identity)
                    }) { [self] frame in
                        guard let sequence = frame.chunk, frame.identity == request.command.identity else { throw SpeechFailure(.protocolViolation) }
                        try credit.publish(sequence: sequence) {
                            try emit(.frame, session: request.session, identity: request.command.identity, frame: frame)
                        }
                    }
                    try credit.finish()
                    try Task.checkCancellation()
                    return .success(())
                } catch { return .failure(error) }
            }
            let joined = Task.detached { [self] in
                let result = await producer.value // Cancellation alone is not a join.
                state.withLock { finishing = true }
                do {
                    try await backend.quiesceAndReset()
                    try emit(.quiescent, session: request.session, identity: request.command.identity)
                    if case .failure(let error) = result, error is SpeechProbePriorityYield, !credit.isRevoked {
                        credit.revoke()
                        try emit(.revoked, session: request.session, identity: request.command.identity)
                    }
                    if case .failure(let error) = result, !(error is CancellationError) {
                        if !(error is SpeechProbePriorityYield) { throw error }
                    }
                    if !credit.isRevoked { try emit(.completed, session: request.session, identity: request.command.identity) }
                    // Keep state locked through ready so a late old completion
                    // cannot clear a later attempt's ownership.
                    try state.withLock {
                        active = nil
                        try emit(.ready, session: request.session, identity: request.command.identity,
                            frame: resourceEvent(request.command.identity))
                    }
                } catch {
                    state.withLock { usable = false; active = nil }
                    try? emit(.failure, session: request.session, identity: request.command.identity,
                              failure: (error as? SpeechFailure)?.code ?? .generation)
                }
            }
            active = Active(identity: request.command.identity, credit: credit, producer: producer, joined: joined)
        }
    }
    private func initialize(_ request: SpeechProbeCommand) {
        state.withLock {
            initialization = request
            let credit = request.holdLoadedInitialization == true ? SpeechProbeCredit() : nil
            loadCredit = credit
            loading = Task.detached { [self] in
                do {
                    try await backend.initialize(request.command, admission: request.admission) { [self] kind in
                        try state.withLock {
                            guard !closed, !loadRevoked else { throw CancellationError() }
                            try emit(kind, session: request.session, identity: request.command.identity)
                        }
                    }
                    if let credit {
                        // Explicit proof barrier: weights are resident but no
                        // initialized event or generation admission is granted.
                        try credit.publish(sequence: 0) {
                            try emit(.loadedAwaitingAdmission, session: request.session, identity: request.command.identity)
                        }
                        try credit.finish()
                    }
                    try Task.checkCancellation()
                    try state.withLock {
                        guard !closed, !loadRevoked else { throw CancellationError() }
                        try emit(.initialized, session: request.session, identity: request.command.identity,
                            frame: resourceEvent(request.command.identity))
                        loaded = true; loadFinished = true
                    }
                } catch {
                    // Even a loader that ignores cancellation must return before
                    // reset/unload can release its leases or report cancellation.
                    let failure = error
                    state.withLock { usable = false; loaded = false }
                    do { try await backend.quiesceAndReset() }
                    catch { state.withLock { usable = false } }
                    await backend.shutdown { [self] kind in
                        try? emit(kind, session: request.session, identity: request.command.identity)
                    }
                    state.withLock {
                        loadFinished = true; usable = false; shutdownDone = true
                        let cancelled = loadRevoked || closed || failure is CancellationError
                        try? emit(cancelled ? .initializationCancelled : .failure,
                            session: request.session, identity: request.command.identity,
                            failure: cancelled ? nil : (failure as? SpeechFailure)?.code ?? .invalidInput)
                    }
                }
            }
        }
    }
    public func run(input: FileHandle = .standardInput) async throws {
        let reader = SpeechProbeReader(input: input)
        var session: UUID?
        do {
            while let request = try await reader.next(SpeechProbeCommand.self) {
                guard request.version == SpeechProbeWire.version, request.command.protocolVersion == SpeechIPC.protocolVersion else { throw SpeechFailure(.incompatibleWorker) }
                if session == nil {
                    guard request.kind == .initialize else { throw SpeechFailure(.protocolViolation) }
                    session = request.session
                    initialize(request)
                    continue
                }
                guard request.session == session else { throw SpeechFailure(.protocolViolation) }
                switch request.kind {
                case .initialize: throw SpeechFailure(.protocolViolation)
                case .generate:
                    if let initial = initialization?.admission {
                        guard let admission = request.admission, admission.root == initial.root,
                              admission.inferenceFile == initial.inferenceFile,
                              admission.demand.owner == initial.demand.owner,
                              admission.demand.instance == initial.demand.instance else { throw SpeechFailure(.protocolViolation) }
                        let registry = try SpeechWorkAdmission(root: admission.root)
                        let launched = try registry.withHighest(admission.demand) { try start(request); return true }
                        if launched != true {
                            try emit(.revoked, session: request.session, identity: request.command.identity)
                            try emit(.quiescent, session: request.session, identity: request.command.identity)
                            try emit(.ready, session: request.session, identity: request.command.identity)
                        }
                    } else { try start(request) }
                case .cancel, .acknowledge:
                    try state.withLock {
                        if request.kind == .cancel, !loadFinished,
                           initialization?.command.identity == request.command.identity, let loading {
                            loadRevoked = true; loadCredit?.revoke(); loading.cancel()
                            try emit(.revoked, session: request.session, identity: request.command.identity)
                            return
                        }
                        if request.kind == .acknowledge, !loadFinished,
                           initialization?.command.identity == request.command.identity, let chunk = request.command.chunk,
                           let loadCredit {
                            loadCredit.acknowledge(chunk); return
                        }
                        guard let owned = active, owned.identity == request.command.identity,
                              request.kind != .cancel || !finishing else {
                            try emit(.ignored, session: request.session, identity: request.command.identity); return
                        }
                        if request.kind == .cancel {
                            owned.credit.revoke(); owned.producer.cancel()
                            try emit(.revoked, session: request.session, identity: request.command.identity)
                        } else if let sequence = request.command.chunk { owned.credit.acknowledge(sequence) }
                    }
                case .shutdown:
                    await close(); return
                }
            }
            await close() // EOF joins native GPU drain before backend/locks die.
        } catch { await close(); throw error }
    }
    private func close() async {
        let (owned, loader) = state.withLock {
            closed = true
            return (active, loading)
        }
        loader?.cancel()
        loadCredit?.revoke()
        owned?.credit.revoke(); owned?.producer.cancel()
        await loader?.value
        await owned?.joined.value
        // Failed/cancelled initialization already unloads on its joined task.
        let needsShutdown = state.withLock {
            guard !shutdownDone else { return false }
            shutdownDone = true; return true
        }
        if needsShutdown {
            let request = initialization
            await backend.shutdown { [self] kind in
                if let request { try? emit(kind, session: request.session, identity: request.command.identity) }
            }
        }
    }
}
