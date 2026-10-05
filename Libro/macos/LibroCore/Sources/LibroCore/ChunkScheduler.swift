import Foundation
import Darwin

public struct SpeechProgress: Sendable {
    public enum Phase: Sendable { case attemptStarted, chunkWritten, publishing }
    public let identity: AttemptIdentity
    public let phase: Phase
    public let attemptNumber: Int
    public let workerCount: Int
    public let completedChunks: Int
    public let totalChunks: Int
}

public struct ChunkScheduler: Sendable {
    private let configuration: WorkerConfiguration
    public init(configuration: WorkerConfiguration) { self.configuration = configuration }

    /// The caller supplies one prepared document, immutable settings and a final
    /// preflight. No reread/rechunking occurs when the entire attempt is retried.
    public func render(chunks: [String], batchID: UUID, jobID: UUID, workspace: URL,
                       settings: SpeechSettings, serial: Bool, destination: URL,
                       beforePublication: @Sendable () throws -> Void = {},
                       progress: @Sendable (SpeechProgress) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        let chunks = chunks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !chunks.isEmpty, chunks.allSatisfy({ $0.unicodeScalars.count <= 1_000 }),
              settings.speed.isFinite, settings.speed > 0 else { throw SpeechFailure(.invalidInput) }
        let store = try NativeWorkspace(root: workspace)
        let parallel = !serial && settings.model.capabilities.supportsParallel && chunks.count >= SchedulingPolicy.parallelThreshold
        do {
            try await attempt(chunks: chunks, identity: .init(batch: batchID, job: jobID), number: 1,
                              workerCount: parallel ? SchedulingPolicy.workerCount : 1, workspace: store,
                              settings: settings, destination: destination,
                              beforePublication: beforePublication, progress: progress)
        } catch let failure as SpeechFailure where parallel && failure.code.permitsSerialRetry {
            try Task.checkCancellation()
            try await attempt(chunks: chunks, identity: .init(batch: batchID, job: jobID), number: 2,
                              workerCount: 1, workspace: store, settings: settings, destination: destination,
                              beforePublication: beforePublication, progress: progress)
        }
    }

    private func attempt(chunks: [String], identity: AttemptIdentity, number: Int, workerCount: Int,
                         workspace: NativeWorkspace, settings: SpeechSettings, destination: URL,
                         beforePublication: @Sendable () throws -> Void,
                         progress: @Sendable (SpeechProgress) -> Void) async throws {
        try Task.checkCancellation()
        let parent = try workspace.contained(workspace.nativeRoot.appendingPathComponent("staging"))
        do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        catch { throw SpeechFailure(.storage) }
        let spool = try workspace.contained(parent.appendingPathComponent("attempt-\(identity.attempt.uuidString)"))
        guard mkdir(spool.path, 0o700) == 0 else { throw SpeechFailure(.storage) }
        // This UUID directory is exclusively created by this attempt. Helpers
        // are reaped before cleanup; no shared models/cache/staging is removed.
        defer { try? FileManager.default.removeItem(at: spool) }
        let resolvedDestination = try OutputPaths.resolved(destination)
        let writer: AtomicWavWriter
        do { writer = try AtomicWavWriter(destination: resolvedDestination) }
        catch { throw SpeechFailure(.storage) }
        defer { writer.abort() }
        var workers: [SpeechWorkerProcess] = []
        var completed = 0
        func report(_ phase: SpeechProgress.Phase) {
            progress(.init(identity: identity, phase: phase, attemptNumber: number, workerCount: workerCount,
                           completedChunks: completed, totalChunks: chunks.count))
        }
        report(.attemptStarted)
        do {
            for _ in 0..<workerCount {
                try Task.checkCancellation()
                workers.append(try SpeechWorkerProcess(configuration: configuration, identity: identity))
            }
            let initialize = WorkerCommand(kind: .initialize, identity: identity, workspace: workspace.root,
                                           settings: settings, spoolDirectory: spool)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for worker in workers { group.addTask { _ = try await worker.request(initialize) } }
                // Surface the first initialization failure immediately. Waiting
                // for all results can otherwise hold a failed attempt behind
                // a second worker that is still loading or unresponsive.
                while try await group.next() != nil {}
            }
            // A slow first chunk can accumulate at most this scheduling batch.
            // Results hold paths/metadata only; decode and write one PCM at a time.
            for lower in stride(from: 0, to: chunks.count, by: SchedulingPolicy.batchSize) {
                let upper = min(lower + SchedulingPolicy.batchSize, chunks.count)
                try await withThrowingTaskGroup(of: Completion.self) { group in
                    var nextDispatch = lower
                    var nextWrite = lower
                    var results: [Int: WorkerEvent] = [:]
                    func dispatch(to workerIndex: Int) throws {
                        try Task.checkCancellation()
                        guard nextDispatch < upper else { return }
                        let index = nextDispatch; nextDispatch += 1
                        let worker = workers[workerIndex]
                        let command = WorkerCommand(kind: .generate, identity: identity, chunk: index, text: chunks[index])
                        group.addTask {
                            Completion(worker: workerIndex, index: index, event: try await worker.request(command))
                        }
                    }
                    for index in workers.indices { try dispatch(to: index) }
                    while let result = try await group.next() {
                        try Task.checkCancellation()
                        results[result.index] = result.event
                        while let event = results.removeValue(forKey: nextWrite) {
                            let samples = try readPCM(event, index: nextWrite, spool: spool, model: settings.model)
                            try Task.checkCancellation()
                            do { try writer.append(samples: samples, sampleRate: settings.model.capabilities.sampleRate) }
                            catch let error as AudioOutputError {
                                throw SpeechFailure(error == .riffLimit ? .invalidInput : .storage)
                            }
                            do { try FileManager.default.removeItem(at: SpeechIPC.chunkFile(in: spool, index: nextWrite)) }
                            catch { throw SpeechFailure(.storage) }
                            nextWrite += 1; completed += 1; report(.chunkWritten)
                        }
                        try dispatch(to: result.worker)
                    }
                    guard nextWrite == upper else { throw SpeechFailure(.protocolViolation) }
                }
            }
            await stop(workers)
            try Task.checkCancellation()
            report(.publishing)
            do {
                try writer.publish {
                    try beforePublication()
                    // Refuse a late alias even if a caller forgot its preflight.
                    guard try OutputPaths.resolved(destination) == resolvedDestination,
                          try OutputPaths.resolved(writer.temporary) == writer.temporary else {
                        throw SpeechFailure(.storage)
                    }
                    try Task.checkCancellation()
                }
            } catch is CancellationError { throw CancellationError() }
            catch AudioOutputError.riffLimit { throw SpeechFailure(.invalidInput) }
            catch { throw SpeechFailure(.storage) }
        } catch {
            await stop(workers)
            throw error
        }
    }

    private struct Completion: Sendable {
        let worker: Int
        let index: Int
        let event: WorkerEvent
    }

    private func stop(_ workers: [SpeechWorkerProcess]) async {
        await withTaskGroup(of: Void.self) { group in
            for worker in workers { group.addTask { await worker.stop() } }
        }
    }

    private func readPCM(_ event: WorkerEvent, index: Int, spool: URL, model: SpeechModel) throws -> [Float] {
        let expected = SpeechIPC.chunkFile(in: spool, index: index)
        let rate = model.capabilities.sampleRate
        guard event.kind == .chunk, event.chunk == index, event.channels == 1, event.sampleRate == rate,
              let frames = event.frames, frames > 0, frames <= rate * 120,
              event.pcmFile == expected.path else { throw SpeechFailure(.generation) }
        var info = stat()
        guard lstat(expected.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_size == frames * MemoryLayout<Float>.size,
              try OutputPaths.resolved(expected) == expected else { throw SpeechFailure(.generation) }
        let data: Data
        do { data = try Data(contentsOf: expected) }
        catch { throw SpeechFailure(.storage) }
        var after = stat()
        guard lstat(expected.path, &after) == 0, info.st_dev == after.st_dev, info.st_ino == after.st_ino,
              info.st_size == after.st_size, data.count == frames * MemoryLayout<Float>.size else {
            throw SpeechFailure(.generation)
        }
        let samples = data.withUnsafeBytes { bytes in
            (0..<frames).map { bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self) }
        }
        guard samples.allSatisfy(\.isFinite) else { throw SpeechFailure(.generation) }
        return samples
    }
}
