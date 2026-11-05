import Foundation
import NarrationCore
import ProcessingPipeline

/// Admission and execution are separate: accepted live jobs publish their rank,
/// while exactly one renderer consumes the FIFO. Bodies never enter persistence.
public actor VoiceServerService {
    public typealias Selection = @Sendable () async throws -> VoiceServerSelection
    public struct Status: Sendable, Equatable { public let active: Int; public let queued: Int }
    public nonisolated let authentication: VoiceServerAuthentication
    public nonisolated let limits: VoiceServerLimits
    private let coordinator: SpeechWorkCoordinator
    private let renderer: any VoiceServerRenderer
    private let selection: Selection
    private let admission = SpeechFinalizationLane()
    private var modes: VoiceServerResponseModes
    private var accepting = true
    private let run = VoiceServerRequestControl()
    private var admitting = 0
    private var records: [Record] = []
    private var task: Task<Void, Never>?
    private var deadlines: [UUID: [Task<Void, Never>]] = [:]
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private final class Record: Sendable {
        let id = UUID()
        let request: VoiceServerSpeechRequest
        let selection: VoiceServerSelection
        let job: SpeechWorkJob
        let control: VoiceServerRequestControl
        let sink: any VoiceServerAudioSink
        let completion: CheckedContinuation<Void, Never>
        init(request: VoiceServerSpeechRequest, selection: VoiceServerSelection, job: SpeechWorkJob,
             control: VoiceServerRequestControl, sink: any VoiceServerAudioSink, completion: CheckedContinuation<Void, Never>) {
            self.request = request; self.selection = selection; self.job = job; self.control = control
            self.sink = sink; self.completion = completion
        }
    }
    public init(coordinator: SpeechWorkCoordinator, authentication: VoiceServerAuthentication,
                renderer: any VoiceServerRenderer, limits: VoiceServerLimits = .init(),
                modes: VoiceServerResponseModes = .init(), selection: @escaping Selection) throws {
        guard limits.isValid, modes.isValid else { throw VoiceServerError.failed }
        self.coordinator = coordinator; self.authentication = authentication; self.renderer = renderer
        self.limits = limits; self.modes = modes; self.selection = selection
    }
    public var status: Status { .init(active: task == nil ? 0 : 1, queued: records.count - (task == nil ? 0 : 1)) }
    public func metadata(voices: Bool, grant: UUID) async throws -> Data {
        guard accepting, authentication.isCurrent(grant) else { throw VoiceServerError.unauthorized }
        let captured = try await selection()
        guard accepting, authentication.isCurrent(grant) else { throw VoiceServerError.unauthorized }
        if voices {
            struct Voice: Encodable { let id = "default"; let selected_voice: String; let model = "voicerelay" }
            struct Body: Encodable { let voices: [Voice]; let ready: Bool }
            return try JSONEncoder().encode(Body(voices: [.init(selected_voice: captured.settings.voice)], ready: captured.modelReady))
        }
        struct Model: Encodable { let id = "voicerelay"; let object = "model"; let owned_by = "local" }
        struct Body: Encodable { let object = "list"; let data = [Model()] }
        return try JSONEncoder().encode(Body())
    }
    public func speech(body: Data, grant: UUID, control: VoiceServerRequestControl, sink: any VoiceServerAudioSink) async {
        admitting += 1
        var admitted = false
        defer { if !admitted { admitting -= 1; finishStop() } }
        do {
            let permit = try await admission.acquire()
            let record: (VoiceServerSpeechRequest, VoiceServerSelection, SpeechWorkJob)
            do { record = try await admit(body: body, grant: grant, control: control) }
            catch { permit.release(); throw error }
            // The admission permit has been released before waiting for execution.
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let item = Record(request: record.0, selection: record.1, job: record.2,
                                      control: control, sink: sink, completion: continuation)
                    records.append(item)
                    admitting -= 1; admitted = true
                    permit.release()
                    let id = item.id
                    control.onCancel { [weak self] in Task { await self?.cancel(id) } }
                    let queueDeadline = limits.queueSeconds
                    let queueTimer = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(queueDeadline)) } catch { return }
                        await self?.expire(id, queuedOnly: true)
                    }
                    let requestDeadline = limits.requestSeconds
                    let requestTimer = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(requestDeadline)) } catch { return }
                        await self?.expire(id, queuedOnly: false)
                    }
                    deadlines[id] = [queueTimer, requestTimer]
                    if control.isCancelled || !accepting || !authentication.isCurrent(grant) { control.cancel() }
                    startNext()
                }
            } onCancel: { control.cancel() }
        } catch let error as VoiceServerError { sink.fail(error) }
        catch is CancellationError { sink.abort() }
        catch { sink.fail(.failed) }
    }
    private func admit(body: Data, grant: UUID, control: VoiceServerRequestControl) async throws -> (VoiceServerSpeechRequest, VoiceServerSelection, SpeechWorkJob) {
        try control.check(); try Task.checkCancellation()
        guard accepting, authentication.isCurrent(grant) else { throw VoiceServerError.unauthorized }
        let captured = try await selection()
        try control.check(); try Task.checkCancellation()
        guard accepting, authentication.isCurrent(grant) else { throw VoiceServerError.unauthorized }
        let request = try VoiceServerSpeechRequest.decode(body, selection: captured, modes: modes, limits: limits)
        guard records.count < limits.maximumQueuedRequests + 1,
              records.reduce(0, { $0 + $1.request.inputBytes }) + request.inputBytes <= limits.maximumAggregateInputBytes else {
            throw VoiceServerError.overloaded
        }
        let auth = authentication, run = run
        let job = try await coordinator.openJob(identity: .init(batch: UUID(), job: UUID()), settings: captured.settings,
            workspace: captured.workspace, rank: .api, delivery: request.delivery,
            cancelled: { control.isCancelled || run.isCancelled || !auth.isCurrent(grant) })
        guard accepting, authentication.isCurrent(grant), !control.isCancelled, !Task.isCancelled else {
            await coordinator.closeJob(job); throw CancellationError()
        }
        return (request, captured, job)
    }
    private func startNext() {
        guard task == nil, let item = records.first else { finishStop(); return }
        let renderer = renderer
        task = Task {
            do {
                try item.control.check()
                try await renderer.render(item.request, selection: item.selection, job: item.job, control: item.control, sink: item.sink)
            } catch is CancellationError { item.sink.abort() }
            catch let error as VoiceServerError { item.sink.fail(error) }
            catch { item.sink.fail(.failed) }
            await coordinator.closeJob(item.job)
            finished(item.id)
        }
    }
    private func finished(_ id: UUID) {
        guard records.first?.id == id else { return }
        let item = records.removeFirst(); item.completion.resume(); task = nil
        removeDeadlines(id)
        startNext()
    }
    private func cancel(_ id: UUID) async {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if index == 0, task != nil { task?.cancel(); return }
        let item = records.remove(at: index)
        removeDeadlines(id)
        await coordinator.closeJob(item.job)
        item.sink.abort(); item.completion.resume()
        finishStop()
    }
    private func removeDeadlines(_ id: UUID) {
        for timer in deadlines.removeValue(forKey: id) ?? [] { timer.cancel() }
    }
    private func expire(_ id: UUID, queuedOnly: Bool) async {
        guard let index = records.firstIndex(where: { $0.id == id }), !queuedOnly || index > 0 else { return }
        let item = records[index]
        item.sink.fail(.deadline); item.control.cancel()
        await cancel(id)
    }
    /// Called after key replacement and before restarting listeners. Revocation
    /// cancels all accepted work; stop waits for actual renderer/helper joins.
    public func stop() async {
        accepting = false; run.cancel()
        let pending = records
        for item in pending { item.control.cancel() }
        task?.cancel()
        for item in pending.dropFirst(task == nil ? 0 : 1) { await cancel(item.id) }
        if !records.isEmpty || admitting > 0 { await withCheckedContinuation { stopWaiters.append($0) } }
    }
    private func finishStop() {
        guard !accepting, records.isEmpty, task == nil, admitting == 0 else { return }
        let waiters = stopWaiters; stopWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

extension VoiceServerLimits {
    var isValid: Bool {
        maximumBodyBytes > 0 && maximumBodyBytes <= 1_048_576 && maximumInputBytes > 0 && maximumInputBytes <= maximumBodyBytes
        && maximumQueuedRequests >= 0 && maximumQueuedRequests <= 16 && maximumAggregateInputBytes >= maximumInputBytes
        && maximumAggregateInputBytes <= 1_048_576 && maximumConnections > 0 && maximumConnections <= 64
        && maximumOutputBytes > 65_536 && maximumOutputBytes <= 1_073_741_824
        && [headerBodySeconds, queueSeconds, requestSeconds, writeSeconds].allSatisfy { $0.isFinite && $0 > 0 && $0 <= 3_600 }
    }
}
