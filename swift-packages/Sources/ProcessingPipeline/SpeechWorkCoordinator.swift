import Foundation
import Darwin
import NarrationCore
import NativeSpeech

public enum SpeechWorkWait: Equatable, Sendable { case api, libro, manualPause, maintenance }
public enum SpeechWorkAvailability: Error, Sendable { case maintenance }
public enum SpeechUnitValue: Sendable { case initialized, prepared([PreparedUtterance]), audio([Float]) }
public struct SpeechUnitResult: Sendable {
    public let id: UUID
    public let token: SpeechAttemptToken
    public let value: SpeechUnitValue
    public var receipt: SpeechUnitReceipt { .init(id: id, token: token) }
}
/// Identifies a completed unit without retaining its PCM during disk validation.
public struct SpeechUnitReceipt: Sendable {
    public let id: UUID
    public let token: SpeechAttemptToken
}
public enum SpeechWorkUnit: Sendable {
    case initialize
    case prepare(SpeechTextWindow, SpeechPreparationPolicy, workers: Int = 1)
    case generate(PreparedUtterance, SpeechPreparationPolicy)
}

/// A captured logical job. Retain through preparation, validation and publication;
/// the coordinator owns inference, while the caller owns its writer/checkpoints.
public final class SpeechWorkJob: @unchecked Sendable {
    public let id = UUID()
    public let identity: AttemptIdentity
    public let settings: SpeechSettings
    public let workspace: URL
    public let rank: SpeechWorkRank
    public let delivery: SpeechWorkDelivery
    public let purpose: SpeechWorkPurpose
    public let fence: SpeechAttemptFence
    fileprivate let eligible: @Sendable () -> Bool
    fileprivate let cancelled: @Sendable () -> Bool
    fileprivate let waiting: @Sendable (SpeechWorkWait?) -> Void
    private let registry: SpeechWorkAdmission
    private let lock = NSLock()
    private var ticket: SpeechWorkTicket?
    private var token: SpeechAttemptToken?
    private var revoked = false
    private var stopped = false
    private var maintenance = false
    private var cpuOperations: Set<UUID> = []
    private var parkedCPU: Set<UUID> = []
    private var awaitingCommit: Set<UUID> = []
    fileprivate var request: UUID?
    fileprivate init(identity: AttemptIdentity, settings: SpeechSettings, workspace: URL, rank: SpeechWorkRank,
        delivery: SpeechWorkDelivery, purpose: SpeechWorkPurpose, registry: SpeechWorkAdmission, ticket: SpeechWorkTicket?,
        lastEpoch: UInt64, verified: Set<Int>, eligible: @escaping @Sendable () -> Bool, cancelled: @escaping @Sendable () -> Bool,
        waiting: @escaping @Sendable (SpeechWorkWait?) -> Void) throws {
        self.identity = identity; self.settings = settings; self.workspace = workspace; self.rank = rank; self.delivery = delivery
        self.registry = registry; self.ticket = ticket; self.eligible = eligible; self.cancelled = cancelled; self.waiting = waiting
        self.purpose = purpose
        fence = try .init(batch: identity.batch, job: identity.job, lastEpoch: lastEpoch, verifiedChunks: verified)
    }
    fileprivate var demand: SpeechWorkDemand? { lock.withLock { ticket?.demand } }
    fileprivate var hasUncommittedResult: Bool { lock.withLock { !awaitingCommit.isEmpty } }
    fileprivate var isStopped: Bool { lock.withLock { stopped } }
    fileprivate var isMaintained: Bool { lock.withLock { maintenance } }
    fileprivate func setMaintenance(_ value: Bool) {
        lock.withLock {
            maintenance = value
            if value, let token { _ = fence.revoke(token); revoked = true }
        }
    }
    fileprivate func setTicket(_ value: SpeechWorkTicket?) throws {
        let old = lock.withLock { let old = ticket; ticket = value; return old }
        try old?.withdraw()
    }
    fileprivate func beginIfNeeded() throws -> SpeechAttemptToken {
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            if let token, !revoked { return token }
            let next = try fence.begin(); token = next; revoked = false; return next
        }
    }
    fileprivate func suspend() {
        lock.withLock { if let token { _ = fence.revoke(token); revoked = true } }
    }
    fileprivate func quiescent() {
        lock.withLock { if let token, revoked { _ = fence.acknowledgeQuiescence(token) } }
    }
    fileprivate func accepts(_ candidate: SpeechAttemptToken) -> Bool {
        lock.withLock { !stopped && !revoked && token == candidate }
    }
    fileprivate func produced(_ id: UUID) { lock.withLock { _ = awaitingCommit.insert(id) } }
    public func discardResult(_ result: SpeechUnitResult) { discardResult(result.receipt) }
    public func discardResult(_ receipt: SpeechUnitReceipt) { lock.withLock { _ = awaitingCommit.remove(receipt.id) } }
    /// Cheap validation liveness check; never hash stale PCM merely to discover
    /// revocation at COMMIT. Stop remains terminal; priority revocation retries.
    public func checkpointIsCurrent(_ receipt: SpeechUnitReceipt) throws -> Bool {
        guard !isStopped else { throw CancellationError() }
        guard lock.withLock({ awaitingCommit.contains(receipt.id) }), accepts(receipt.token) else { return false }
        guard let demand else { return false }
        return try registry.withDecision(for: demand) { decision in
            switch decision {
            case .cancelForStreamingAPI: suspend(); return false
            case .withdrawn: throw CancellationError()
            case .run, .waitForBoundary: return accepts(receipt.token)
            }
        }
    }
    /// Validate/hash outside this call; only the short durable transaction belongs
    /// inside it. False means regenerate after admission, without appending PCM.
    @discardableResult public func commit(_ result: SpeechUnitResult, index: Int, operation: () throws -> Void) throws -> Bool {
        try commit(result.receipt, index: index, operation: operation)
    }
    @discardableResult public func commit(_ receipt: SpeechUnitReceipt, index: Int, operation: () throws -> Void) throws -> Bool {
        defer { discardResult(receipt) }
        guard lock.withLock({ awaitingCommit.contains(receipt.id) }) else { return false }
        guard !isStopped else { throw CancellationError() }
        guard accepts(receipt.token) else { return false }
        guard let demand else { throw CancellationError() }
        return try registry.withDecision(for: demand) { decision in
            switch decision {
            case .withdrawn: throw CancellationError()
            case .cancelForStreamingAPI: suspend(); return false
            case .run, .waitForBoundary: return try fence.commit(receipt.token, index: index, operation: operation)
            }
        }
    }
    fileprivate func stop() throws {
        let old = lock.withLock { stopped = true; fence.stop(); let old = ticket; ticket = nil; return old }
        try old?.withdraw()
    }
    /// Called only on an owned CPU queue. Never hold the registration gate while
    /// waiting, and never block the coordinator/UI/HTTP executor.
    func beginCPU(_ id: UUID) { lock.withLock { _ = cpuOperations.insert(id); _ = parkedCPU.insert(id) } }
    func endCPU(_ id: UUID) { lock.withLock { _ = cpuOperations.remove(id); _ = parkedCPU.remove(id) } }
    fileprivate var cpuQuiescent: Bool { lock.withLock { cpuOperations.isSubset(of: parkedCPU) } }
    fileprivate var hasCPUOperations: Bool { lock.withLock { !cpuOperations.isEmpty } }
    private func allowCPU(_ id: UUID) -> Bool {
        lock.withLock {
            guard !maintenance, !stopped else { return false }
            parkedCPU.remove(id); return true
        }
    }
    func cpuCheckpoint(_ id: UUID, cancelled operationCancelled: @Sendable () -> Bool,
                       interruption: @Sendable () throws -> Void) throws {
        var lastWait: SpeechWorkWait?
        func report(_ value: SpeechWorkWait?) {
            if value != lastWait { lastWait = value; waiting(value) }
        }
        while true {
            lock.withLock { _ = parkedCPU.insert(id) }
            if operationCancelled() || cancelled() || isStopped { throw CancellationError() }
            try interruption()
            if isMaintained { report(.maintenance) }
            else if !eligible() { report(.manualPause) }
            else if let demand {
                let decision = try registry.decision(for: demand)
                switch decision {
                case .run:
                    if allowCPU(id) { report(nil); return }
                case .waitForBoundary(let higher) where higher.rank == rank && rank != .api:
                    if allowCPU(id) { report(nil); return } // Preserve CPU/speech overlap within a rank.
                case .waitForBoundary(let higher): report(higher.rank == .api ? .api : .libro)
                case .cancelForStreamingAPI: suspend(); report(.api)
                case .withdrawn: break
                }
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }
}

/// One instance per app. It owns the one reusable helper, not the podcast store
/// or Libro writer. All pipe waits run on an owned serial queue, outside actors.
public actor SpeechWorkCoordinator {
    public let owner: SpeechWorkOwner
    public let root: URL
    public nonisolated let hostAdmission: SpeechHostAdmission
    public var residentProcessIdentifier: Int32? { channel?.client.pid }
    private let instance = UUID()
    private let registry: SpeechWorkAdmission
    private let configuration: WorkerConfiguration
    private let referenceStore: ReferenceVoiceStore
    private let cancellationGrace: Duration
    private var jobs: [UUID: SpeechWorkJob] = [:]
    private var channel: CoordinatedSpeechChannel?
    private var key: ModelKey?
    private var active: Active?
    private var retiring: Task<Void, Error>?
    private var observer: Task<Void, Never>?
    private var wakeup: SpeechWorkWakeup?
    private var closed = false
    private var unavailable = false
    private var maintenance: UUID?
    private var maintenanceCancel: (@Sendable () -> Void)?
    private var maintenanceJoin: Task<Void, Never>?
    // Internal observation for isolated lifecycle tests; no document/settings data.
    func observation() -> (pid: Int32?, stage: URL?, active: UUID?, loading: Bool, cancelled: Bool, leaseAcquired: Bool, closed: Bool, maintaining: Bool) {
        (channel?.client.pid, channel?.stage, active?.job.id, active?.loading ?? false, active?.cancelled ?? false, channel?.leaseAcquired ?? false, closed, maintenance != nil)
    }
    private struct ModelKey: Equatable {
        let workspace: URL, model: SpeechModel, revision: String, frontend: String, reference: String?
        init(_ job: SpeechWorkJob) {
            workspace = job.workspace; model = job.settings.model
            revision = NativePrimaryCatalog.specification(for: model).revision
            frontend = model == .kokoro && job.settings.voice.hasPrefix("b") ? "en-GB" : "default"
            reference = ReferenceVoiceStore.isIdentifier(job.settings.voice) ? job.settings.voice : nil
        }
    }
    private struct Active {
        let request: UUID, job: SpeechWorkJob, wire: AttemptIdentity, loading: Bool
        var cancelled = false
        var fallback: Task<Void, Never>?
    }
    public init(owner: SpeechWorkOwner, configuration: WorkerConfiguration, root: URL = SpeechWorkAdmission.defaultRoot,
                referenceStore: ReferenceVoiceStore = .init(), cancellationGrace: Duration = .seconds(5)) throws {
        guard cancellationGrace > .zero, cancellationGrace <= .seconds(30) else { throw SpeechFailure(.invalidInput) }
        self.cancellationGrace = cancellationGrace
        self.owner = owner; self.root = root
        var captured = configuration; captured.workCoordinator = nil
        self.configuration = captured; self.referenceStore = referenceStore
        registry = try SpeechWorkAdmission(root: root)
        hostAdmission = try SpeechHostAdmission(owner: owner, root: root, inferenceFile: configuration.inferenceLeaseFile)
    }
    public func openJob(identity: AttemptIdentity, settings: SpeechSettings, workspace: URL, rank: SpeechWorkRank,
        delivery: SpeechWorkDelivery = .file, lastEpoch: UInt64 = 0, verified: Set<Int> = [],
        eligible: @escaping @Sendable () -> Bool = { true }, cancelled: @escaping @Sendable () -> Bool = { false },
        waiting: @escaping @Sendable (SpeechWorkWait?) -> Void = { _ in }, purpose: SpeechWorkPurpose = .speech) throws -> SpeechWorkJob {
        guard !closed, !unavailable, jobs.count < 32, workspace.isFileURL,
              purpose == .cpu || settings.isValid,
              !(purpose == .cpu && rank == .api) else { throw SpeechFailure(.invalidInput) }
        guard maintenance == nil else { throw SpeechWorkAvailability.maintenance }
        var captured = settings; captured.savedChoices = nil
        // CPU-only work must remain available without a valid speech selection
        // or model folder. It never reads/creates runtime assets or loads weights.
        let workspace = purpose == .speech ? try NativeWorkspace(root: workspace).root : workspace.standardizedFileURL
        let ticket = try eligible() ? registry.register(owner: owner, instance: instance, rank: rank, delivery: delivery, purpose: purpose) : nil
        let job = try SpeechWorkJob(identity: identity, settings: captured, workspace: workspace, rank: rank,
            delivery: delivery, purpose: purpose, registry: registry, ticket: ticket, lastEpoch: lastEpoch, verified: verified, eligible: eligible, cancelled: cancelled, waiting: waiting)
        jobs[job.id] = job
        if observer == nil {
            let wakeup = SpeechWorkWakeup(root: root)
            self.wakeup = wakeup
            observer = Task { [weak self] in
                for await _ in wakeup.events {
                    guard !Task.isCancelled, let self else { break }
                    await self.observe()
                }
            }
        }
        return job
    }
    public func perform(_ unit: SpeechWorkUnit, job: SpeechWorkJob) async throws -> SpeechUnitResult {
        if case .prepare(_, _, let workers) = unit, !CPUTextPreparation.validates(workers) { throw SpeechFailure(.invalidInput) }
        guard jobs[job.id] === job, job.request == nil, job.purpose == .speech else { throw SpeechFailure(.invalidInput) }
        let request = UUID(); job.request = request
        defer { job.request = nil }
        return try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                if job.cancelled() { try job.stop(); throw CancellationError() }
                guard !closed, !unavailable, !job.isStopped else { throw CancellationError() }
                if maintenance != nil {
                    job.waiting(.maintenance); try await Task.sleep(for: .milliseconds(25)); continue
                }
                try updateEligibility(job)
                guard job.eligible(), let demand = job.demand else {
                    job.waiting(.manualPause); try await Task.sleep(for: .milliseconds(25)); continue
                }
                guard active == nil, retiring == nil, try registry.highest(for: demand) == demand else {
                    reportWaiting(job); try await Task.sleep(for: .milliseconds(25)); continue
                }
                job.quiescent()
                let token = try job.beginIfNeeded()
                let desired = ModelKey(job)
                if let key, key != desired { try await retire() }
                if channel == nil {
                    let created = try CoordinatedSpeechChannel(configuration: configuration, job: job, referenceStore: referenceStore)
                    channel = created; key = desired
                    let wire = AttemptIdentity(batch: job.identity.batch, job: job.identity.job)
                    active = .init(request: request, job: job, wire: wire, loading: true)
                    do {
                        let preparationOnly: Bool
                        if case .prepare = unit { preparationOnly = true } else { preparationOnly = false }
                        try await created.initialize(wire: wire, job: job, preparationOnly: preparationOnly,
                            admission: .init(demand: demand, root: root, inferenceFile: configuration.inferenceLeaseFile))
                        finishActive(request)
                    } catch {
                        let retry = job.demand != nil && !job.isStopped && !Task.isCancelled
                        finishActive(request); try await retire()
                        job.quiescent()
                        if retry, job.accepts(token) == false { continue }
                        throw error
                    }
                    // Rank must be checked again after asynchronous initialization.
                    continue
                }
                guard let channel else { throw SpeechFailure(.workerExited) }
                if case .initialize = unit, channel.speechReady {
                    job.waiting(nil)
                    return .init(id: UUID(), token: token, value: .initialized)
                }
                let wire = AttemptIdentity(batch: job.identity.batch, job: job.identity.job)
                active = .init(request: request, job: job, wire: wire, loading: false)
                do {
                    let value = try await channel.perform(unit, wire: wire, job: job,
                        admission: .init(demand: demand, root: root, inferenceFile: configuration.inferenceLeaseFile))
                    try Task.checkCancellation()
                    finishActive(request)
                    if !job.accepts(token) { job.quiescent(); continue }
                    job.waiting(nil)
                    let receipt = UUID()
                    if case .audio = value { job.produced(receipt) }
                    return .init(id: receipt, token: token, value: value)
                } catch {
                    let wasPriority = !job.accepts(token) && !job.isStopped && !Task.isCancelled
                    finishActive(request)
                    if error is CancellationError, wasPriority { job.quiescent(); continue }
                    try await retire()
                    job.quiescent()
                    if wasPriority { continue }
                    throw error
                }
            }
        } onCancel: {
            Task { await self.cancel(job: job, request: request) }
        }
    }
    /// Cooperative boundary for host-owned assembly/encoding units. This never
    /// acquires a second inference lease or launches a helper.
    public func waitForAdmission(job: SpeechWorkJob) async throws {
        while true {
            try Task.checkCancellation()
            if job.cancelled() { try job.stop(); throw CancellationError() }
            guard jobs[job.id] === job, !closed, !unavailable, !job.isStopped else { throw CancellationError() }
            if maintenance != nil {
                job.waiting(.maintenance); try await Task.sleep(for: .milliseconds(25)); continue
            }
            try updateEligibility(job)
            if job.eligible(), let demand = job.demand, try registry.highest(for: demand) == demand { job.waiting(nil); return }
            if !job.eligible() { job.waiting(.manualPause) } else { reportWaiting(job) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    private func finishActive(_ request: UUID) {
        guard active?.request == request else { return }
        active?.fallback?.cancel(); active = nil
    }
    private func updateEligibility(_ job: SpeechWorkJob) throws {
        if maintenance != nil { return }
        if !job.eligible(), active?.job !== job, !job.hasUncommittedResult {
            if job.demand != nil { try job.setTicket(nil) }
        } else if job.eligible(), job.demand == nil, !job.isStopped {
            try job.setTicket(registry.register(owner: owner, instance: instance, rank: job.rank, delivery: job.delivery, purpose: job.purpose))
        }
    }
    private func reportWaiting(_ job: SpeechWorkJob) {
        guard let highest = try? registry.highest(), highest != job.demand else { return }
        job.waiting(highest.rank == .api ? .api : .libro)
    }
    private func observe() async {
        guard !closed, !unavailable, maintenance == nil else { return }
        do {
            for job in jobs.values {
                if job.cancelled(), !job.isStopped {
                    try job.stop()
                    if active?.job === job { try issueCancel() }
                }
                try updateEligibility(job)
                if let demand = job.demand, case .cancelForStreamingAPI = try registry.decision(for: demand) {
                    job.suspend(); if active?.job !== job { job.quiescent() }
                }
            }
            let highest: SpeechWorkDemand?
            if let demand = active?.job.demand { highest = try registry.highest(for: demand) }
            else { highest = try registry.highest() }
            if let current = active, let own = current.job.demand, highest != own {
                let streaming = highest?.rank == .api && highest?.delivery == .streaming
                let loading = current.loading || channel?.isLoading == true
                let transferable = loading && channel?.leaseAcquired == true && highest?.instance == instance &&
                    jobs.values.contains { $0.demand == highest && ModelKey($0) == key }
                if (streaming || loading) && !transferable {
                    current.job.suspend()
                    try issueCancel()
                }
            } else if active == nil, channel != nil, retiring == nil, highest?.instance != instance {
                try await retire()
            }
        } catch { unavailable = true; try? await retire() }
    }
    private func issueCancel() throws {
        guard var current = active, !current.cancelled, let channel else { return }
        current.cancelled = true
        let request = current.request
        let grace = cancellationGrace
        current.fallback = Task { [weak self] in
            do { try await Task.sleep(for: grace) } catch { return }
            await self?.fallback(request)
        }
        active = current
        try channel.client.send(.cancel, .init(kind: .cancel, identity: current.wire))
    }
    private func fallback(_ request: UUID) async {
        guard active?.request == request else { return }
        do { try await retire() } catch { unavailable = true }
    }
    private func cancel(job: SpeechWorkJob, request: UUID) async {
        guard job.request == request else { return }
        try? job.stop()
        if active?.request == request { try? issueCancel() }
    }
    public func closeJob(_ job: SpeechWorkJob) async {
        try? job.stop()
        if active?.job === job {
            try? issueCancel()
            while active?.job === job {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.005) { continuation.resume() }
                }
            }
        }
        while job.hasCPUOperations {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.005) { continuation.resume() }
            }
        }
        job.waiting(nil)
        jobs.removeValue(forKey: job.id)
        if jobs.isEmpty, active == nil { try? await retire() }
        if jobs.isEmpty, channel == nil {
            observer?.cancel(); observer = nil; wakeup?.finish(); wakeup = nil
        }
    }
    private func retire() async throws {
        if let retiring { return try await retiring.value }
        guard let owned = channel else { return }
        channel = nil; key = nil
        let task = Task.detached { try owned.close() }; retiring = task
        do { try await task.value; retiring = nil }
        catch { unavailable = true; retiring = nil; throw error }
    }
    /// Explicit operator maintenance only. Refuse new jobs, revoke pending
    /// commits and join owned helper/platform work before invoking the operation.
    /// Other apps remain protected by the existing ModelStorageLease.
    public func withMaintenance<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        guard !closed, !unavailable else { throw CancellationError() }
        guard maintenance == nil else { throw SpeechWorkAvailability.maintenance }
        let token = UUID(); maintenance = token; hostAdmission.pauseAccepting()
        defer { endMaintenance(token) }
        for job in jobs.values {
            if job.rank == .api { try job.stop() }
            else { job.setMaintenance(true); try job.setTicket(nil) }
        }
        if active != nil { try issueCancel() }
        try await retire()
        while active != nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        for job in jobs.values { job.quiescent() }
        while jobs.values.contains(where: { !$0.cpuQuiescent }) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        await hostAdmission.waitForActiveLeases()
        try Task.checkCancellation()
        guard !closed, !unavailable else { throw CancellationError() }
        let task = Task { try await operation() }
        maintenanceCancel = { task.cancel() }
        let join = Task { _ = await task.result }; maintenanceJoin = join
        defer { maintenanceCancel = nil; maintenanceJoin = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func endMaintenance(_ token: UUID) {
        guard maintenance == token else { return }
        maintenance = nil
        guard !closed else { return }
        for job in jobs.values { job.setMaintenance(false) }
        hostAdmission.resumeAccepting()
    }
    public func close() async {
        hostAdmission.stopAccepting()
        closed = true; observer?.cancel(); observer = nil
        wakeup?.finish(); wakeup = nil
        maintenanceCancel?()
        for job in jobs.values { try? job.stop() }
        let ownedJobs = Array(jobs.values)
        if active != nil { try? issueCancel() }
        try? await retire()
        jobs.removeAll()
        await hostAdmission.stopAndWait()
        await maintenanceJoin?.value
        while ownedJobs.contains(where: \.hasCPUOperations) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { continuation.resume() }
            }
        }
        for job in ownedJobs { job.waiting(nil) }
    }
}

private final class CoordinatedSpeechChannel: @unchecked Sendable {
    let client: SpeechProbeProcess
    let stage: URL
    private let scratch: SpeechScratchLease
    private let queue = DispatchQueue(label: "org.narration.coordinated-worker")
    private let lock = NSLock()
    private let timeout: TimeInterval
    private var acquired = false
    private var speech = false
    private var loading = false
    var leaseAcquired: Bool { lock.withLock { acquired } }
    var speechReady: Bool { lock.withLock { speech } }
    var isLoading: Bool { lock.withLock { loading } }
    init(configuration: WorkerConfiguration, job: SpeechWorkJob, referenceStore: ReferenceVoiceStore) throws {
        let workspace = try NativeWorkspace(root: job.workspace)
        let parent = try workspace.managed(workspace.nativeRoot.appendingPathComponent("staging"))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        _ = try? SpeechScratchLease.sweep(parent, prefix: "attempt-")
        stage = try workspace.managed(parent.appendingPathComponent("attempt-\(UUID().uuidString)"))
        guard mkdir(stage.path, 0o700) == 0 else { throw SpeechFailure(.storage) }
        do { scratch = try SpeechScratchLease(directory: stage, create: true) }
        catch { try? FileManager.default.removeItem(at: stage); throw error }
        var selected = configuration
        selected.arguments = configuration.arguments == ["--serve"] ? ["--coordinated-serve"] : configuration.arguments
        selected.debugLog = nil
        if selected.maximumFootprintBytes == SpeechMemoryPolicy.workerFootprintLimitBytes {
            selected.maximumFootprintBytes = SpeechMemoryPolicy.footprintLimit(for: job.settings.model)
        }
        if job.settings.model.isLarge, selected.requestTimeout == .seconds(180) { selected.requestTimeout = .seconds(900) }
        let components = selected.requestTimeout.components
        timeout = Double(components.seconds) + Double(components.attoseconds) / 1e18
        guard timeout.isFinite, timeout > 0 else {
            try? FileManager.default.removeItem(at: stage); throw SpeechFailure(.invalidInput)
        }
        selected.shutdownGrace = max(2, selected.shutdownGrace)
        do {
            if ReferenceVoiceStore.isIdentifier(job.settings.voice) {
                try referenceStore.bytes(for: job.settings.voice).write(to: stage.appendingPathComponent("reference.wav"), options: .withoutOverwriting)
            }
            client = try SpeechProbeProcess(configuration: selected)
        }
        catch { scratch.close(); _ = try? SpeechScratchLease.removeIfUnowned(stage); throw error }
    }
    private func run<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
    }
    private func receiveResources(_ event: SpeechProbeEvent) throws {
        guard let frame = event.frame, frame.kind == .ready, frame.identity == event.identity,
              let preparationOnly = frame.textPreparationOnly, let usesInference = frame.preparationUsesInference,
              preparationOnly || usesInference else { throw SpeechFailure(.protocolViolation) }
        lock.withLock { acquired = usesInference; speech = !preparationOnly; loading = false }
    }
    func initialize(wire: AttemptIdentity, job: SpeechWorkJob, preparationOnly: Bool, admission: SpeechWorkerAdmission) async throws {
        try await run { [self] in
            try client.send(.initialize, .init(kind: .initialize, identity: wire, workspace: job.workspace,
                settings: job.settings, spoolDirectory: stage, textPreparationOnly: preparationOnly), admission: admission)
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while true {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw SpeechFailure(.timeout) }
                let event = try client.next(timeout: remaining)
                guard event.identity == wire else { throw SpeechFailure(.protocolViolation) }
                if event.kind == .leaseAcquired { lock.withLock { acquired = true } }
                if event.kind == .initialized { try receiveResources(event); return }
                if event.kind == .initializationCancelled { throw CancellationError() }
                if event.kind == .failure { throw SpeechFailure(event.failure ?? .generation) }
            }
        }
    }
    func perform(_ unit: SpeechWorkUnit, wire: AttemptIdentity, job: SpeechWorkJob, admission: SpeechWorkerAdmission) async throws -> SpeechUnitValue {
        try await run { [self] in
            let command: WorkerCommand
            switch unit {
            case .initialize:
                command = .init(kind: .loadSpeech, identity: wire, settings: job.settings)
            case .prepare(let window, let policy, let workers):
                guard CPUTextPreparation.validates(workers) else { throw SpeechFailure(.invalidInput) }
                command = .init(kind: .prepareText, identity: wire, chunk: 0, settings: job.settings, policy: policy, textWindow: window, textPreparationWorkers: workers)
            case .generate(let utterance, let policy):
                command = .init(kind: .generatePrepared, identity: wire, chunk: 0, settings: job.settings, policy: policy, utterance: utterance)
            }
            try client.send(.generate, command, admission: admission)
            let spool = stage.appendingPathComponent("job-\(wire.attempt.uuidString)")
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var index = 0, pcm: [Float] = [], prepared: [PreparedUtterance]?, revoked = false, quiescent = false, completed = false
            while true {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw SpeechFailure(.timeout) }
                let event = try client.next(timeout: remaining)
                // A cancel racing completed generation, or an ACK racing cancel,
                // may be ignored after ready. It cannot affect any new attempt.
                if event.kind == .ignored { continue }
                guard event.identity == wire else { throw SpeechFailure(.protocolViolation) }
                switch event.kind {
                case .waitingForLease, .loadingModel: lock.withLock { loading = true }
                case .leaseAcquired: lock.withLock { acquired = true }
                case .started: lock.withLock { loading = false }
                case .frame:
                    guard !revoked, let frame = event.frame else { throw SpeechFailure(.protocolViolation) }
                    if frame.kind == .textPrepared {
                        guard index == 0, case .prepare = unit, let reference = frame.preparedFile else { throw SpeechFailure(.protocolViolation) }
                        prepared = try PreparedSpeechTransfer.read(reference, index: 0, spool: spool)
                    } else {
                        guard case .generate = unit else { throw SpeechFailure(.protocolViolation) }
                        pcm += try SpeechProbeProcess.readFrame(event, spool: spool, model: job.settings.model, index: index)
                        guard pcm.count <= job.settings.model.capabilities.sampleRate * 120 else { throw SpeechFailure(.generation) }
                    }
                    try client.send(.acknowledge, .init(kind: .generate, identity: wire, chunk: index)); index += 1
                case .revoked: revoked = true; job.suspend()
                case .quiescent: quiescent = true
                case .completed: guard quiescent else { throw SpeechFailure(.protocolViolation) }; completed = true
                case .ready:
                    guard quiescent else { throw SpeechFailure(.protocolViolation) }
                    if event.frame != nil { try receiveResources(event) }
                    try? FileManager.default.removeItem(at: spool)
                    if revoked { throw CancellationError() }
                    guard completed else { throw SpeechFailure(.protocolViolation) }
                    if case .initialize = unit {
                        guard speechReady else { throw SpeechFailure(.protocolViolation) }
                        return .initialized
                    }
                    if let prepared { return .prepared(prepared) }
                    guard !pcm.isEmpty else { throw SpeechFailure(.generation) }; return .audio(pcm)
                case .failure: throw SpeechFailure(event.failure ?? .generation)
                default: throw SpeechFailure(.protocolViolation)
                }
            }
        }
    }
    func close() throws {
        try client.close()
        scratch.close()
        guard try SpeechScratchLease.removeIfUnowned(stage) else { throw SpeechFailure(.storage) }
    }
}
