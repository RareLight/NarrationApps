import Foundation
import Darwin
import Testing
import NarrationCore
import NativeSpeech
import AudioOutput
import ProcessingPipeline
@testable import VoiceRelayCore

@Suite(.serialized) struct CoordinatedCheckpointTests {
    private struct Fixture: Sendable {
        let root: URL
        let models: URL
        let coordinator: SpeechWorkCoordinator
        let configuration: WorkerConfiguration
        static func make() throws -> Self {
            let executable = try #require(ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"])
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("relay-checkpoint-\(UUID())")
            let models = root.appendingPathComponent("models-workspace")
            try Files.directory(models)
            var config = WorkerConfiguration(executable: URL(fileURLWithPath: executable), arguments: ["--handoff-probe"],
                environment: ["NARRATION_FIXTURE_SYNTHETIC_PCM": "1"], inferenceLeaseFile: root.appendingPathComponent("inference.lock"))
            let coordinator = try SpeechWorkCoordinator(owner: .voiceRelay, configuration: config, root: root.appendingPathComponent("admission"))
            config.workCoordinator = coordinator
            return .init(root: root, models: models, coordinator: coordinator, configuration: config)
        }
        func close() async { await coordinator.close(); try? FileManager.default.removeItem(at: root) }
        func job(rank: SpeechWorkRank = .podcast, delivery: SpeechWorkDelivery = .file) async throws -> SpeechWorkJob {
            try await coordinator.openJob(identity: .init(batch: UUID(), job: UUID()), settings: .init(), workspace: models,
                rank: rank, delivery: delivery)
        }
        func generated(_ job: SpeechWorkJob, index: Int, articleID: String = "synthetic") async throws -> (SynthesisRequest, SynthesisResult) {
            let text = "Synthetic checkpoint \(index)."
            let utterance = PreparedUtterance(text: text, phonemes: "a", tokenCount: 1,
                source: .init(blockIndices: [index], location: 0, length: text.utf16.count), boundaryAfter: .sentence,
                acousticIdentity: SpeechAcousticIdentity.make(settings: job.settings, policy: .current))
            let output = try await coordinator.perform(.generate(utterance, .current), job: job)
            guard case .audio(let samples) = output.value else { throw SpeechFailure(.protocolViolation) }
            let file = root.appendingPathComponent("\(UUID()).wav")
            let writer = try AtomicAudioWriter(destination: file, format: .wav)
            defer { writer.abort() }
            try writer.append(samples: samples, sampleRate: 24_000); try writer.publish(replaceExisting: false)
            let receipt = try SpeechCheckpointReceipt(job: job, receipt: output.receipt, file: file)
            return (.init(text: text, language: "en-US", voice: "af_heart", articleID: articleID, chunkIndex: index,
                          blockIndices: [index], settings: [:], preparedUtterance: utterance),
                    .init(artifacts: [.init(url: file, sampleRate: 24_000, channels: 1, format: "wav")], checkpointReceipt: receipt))
        }
        func store() throws -> (PipelineStore, Episode) {
            let profile = try FixtureWorkspace.prepare(root: root.appendingPathComponent("library"), imported: nil)
            let store = try PipelineStore(databaseURL: profile.database)
            return (store, try store.episode(sourceKey: "synthetic", settings: profile))
        }
    }
    @Test func finalDatabaseCommitRejectsRevokedPCMAndPreservesCommittedPrefix() async throws {
        try await withFixture { fixture in
        let job = try await fixture.job(), (store, episode) = try fixture.store()
        let (request0, result0) = try await fixture.generated(job, index: 0, articleID: episode.id)
        let cp0 = try checkpoint(request0, result0)
        #expect(try store.saveChunk(articleID: episode.id, index: 0, fingerprint: "zero", checkpoint: cp0, receipt: result0.checkpointReceipt))
        let original = try Data(contentsOf: result0.artifacts[0].url)
        let (request1, result1) = try await fixture.generated(job, index: 1, articleID: episode.id), cp1 = try checkpoint(request1, result1)
        // Hashing is finished; registration must still reject this final save.
        let api = try await fixture.job(rank: .api, delivery: .streaming)
        #expect(try !store.saveChunk(articleID: episode.id, index: 1, fingerprint: "one", checkpoint: cp1, receipt: result1.checkpointReceipt))
        #expect(try store.chunk(articleID: episode.id, index: 1, fingerprint: "one") == nil)
        result1.checkpointReceipt?.discard(); result0.checkpointReceipt?.discard()
        #expect(!FileManager.default.fileExists(atPath: result1.artifacts[0].url.path))
        #expect(try Data(contentsOf: result0.artifacts[0].url) == original)
        #expect(job.fence.verifiedPrefix == 1)
        let encoded = try Files.json(cp0)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("checkpointReceipt"))
        #expect(try JSONDecoder().decode(ChunkCheckpoint.self, from: encoded).result.checkpointReceipt == nil)
        await fixture.coordinator.closeJob(api)
        let (retryRequest, retryResult) = try await fixture.generated(job, index: 1, articleID: episode.id)
        #expect(try store.saveChunk(articleID: episode.id, index: 1, fingerprint: "one", checkpoint: checkpoint(retryRequest, retryResult), receipt: retryResult.checkpointReceipt))
        #expect(job.fence.verifiedPrefix == 2)
        }
    }
    @Test func failedTransactionAndReplacedFilesArePreservedDuringCleanup() async throws {
        try await withFixture { fixture in
        let job = try await fixture.job()
        let (_, uncertain) = try await fixture.generated(job, index: 0)
        #expect(throws: RelayError.self) {
            _ = try uncertain.checkpointReceipt?.commit(index: 0) { throw RelayError.storage("Synthetic commit failure") }
        }
        uncertain.checkpointReceipt?.discard()
        #expect(FileManager.default.fileExists(atPath: uncertain.artifacts[0].url.path))
        let (_, replaced) = try await fixture.generated(job, index: 1)
        let path = replaced.artifacts[0].url, prior = fixture.root.appendingPathComponent("prior.wav")
        try FileManager.default.moveItem(at: path, to: prior)
        let replacement = Data("New attempt-owned bytes".utf8)
        try replacement.write(to: path)
        replaced.checkpointReceipt?.discard()
        #expect(try Data(contentsOf: path) == replacement)
        #expect(FileManager.default.fileExists(atPath: prior.path))
        }
    }
    @Test func databaseWriterContentionDoesNotHoldTheAdmissionFence() async throws {
        try await withFixture { fixture in
            let job = try await fixture.job(), (_, episode) = try fixture.store(), flags = WriterFlags()
            let store = try PipelineStore(databaseURL: episode.settings.database, onWriterBusy: { flags.waiting = true })
            let (request, result) = try await fixture.generated(job, index: 0, articleID: episode.id), cp = try checkpoint(request, result)
            var writer: NativeStore? = try NativeStore(url: episode.settings.database)
            let pending = Task.detached {
                defer { flags.finished = true }
                return try store.saveChunk(articleID: episode.id, index: 0, fingerprint: "busy", checkpoint: cp, receipt: result.checkpointReceipt)
            }
            do {
                try await wait { flags.waiting }
                let api = try await fixture.job(rank: .api, delivery: .streaming)
                #expect(!flags.finished) // Admission succeeds while the writer is still held.
                withExtendedLifetime(writer) {}; writer = nil
                #expect(try await !pending.value)
                #expect(try store.chunk(articleID: episode.id, index: 0, fingerprint: "busy") == nil)
                result.checkpointReceipt?.discard()
                await fixture.coordinator.closeJob(api)
            } catch { writer = nil; pending.cancel(); _ = await pending.result; throw error }
        }
    }
    @Test func pipelineAutomaticallyRetriesPendingValidationWithoutFailedRowsOrDuplicateCommits() async throws {
        try await withFixture { fixture in
        let audio = fixture.root.appendingPathComponent("audio"); try Files.directory(audio)
        let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: fixture.root.appendingPathComponent("state"),
            temporaryRoot: fixture.root.appendingPathComponent("scratch"))
        let backend = try NativeMLXBackend(configuration: .init(projectRoot: fixture.models, settings: .init()), worker: fixture.configuration)
        defer { backend.cancel() }
        let coordinator = FixtureCoordinator(), barrier = ValidationBarrier()
        await coordinator.setBeforeAudioProcessing { stage, file in
            if stage == .validation, file.deletingLastPathComponent().lastPathComponent == "chunk-1" { try barrier.waitOnce(file: file) }
        }
        let review = try reviewedSource()
        let queued = try await coordinator.enqueue(review, storage: storage, preferences: SpeechPreferences())
        let run = Task { try await coordinator.drainQueue(storage: storage, backend: { _ in backend }) }
        defer { barrier.release(); run.cancel() }
        var acceptedAPI: SpeechWorkJob?
        do {
        try await wait { barrier.entered }
        let pid = await fixture.coordinator.residentProcessIdentifier
        let rowsBefore = try NativeStore(url: storage.profile.database, readOnly: true).query("SELECT chunk_index,checkpoint FROM chunks ORDER BY chunk_index")
        #expect(rowsBefore.count == 1 && rowsBefore[0][0] == "0")
        let api = try await fixture.job(rank: .api, delivery: .streaming)
        acceptedAPI = api
        let (_, apiAudio) = try await fixture.generated(api, index: 0)
        apiAudio.checkpointReceipt?.discard()
        #expect(await fixture.coordinator.residentProcessIdentifier == pid)
        barrier.release()
        try await wait {
            !FileManager.default.fileExists(atPath: barrier.file?.path ?? "")
        }
        #expect(try NativeStore(url: storage.profile.database, readOnly: true).query("SELECT chunk_index,checkpoint FROM chunks ORDER BY chunk_index") == rowsBefore)
        let suspended = try #require(await coordinator.queue(stateRoot: storage.stateRoot).first)
        #expect(suspended.id == queued.id && suspended.state == .running && suspended.attempts == 1 && suspended.lastError == nil)
        await fixture.coordinator.closeJob(api)
        acceptedAPI = nil
        let completed = try await run.value
        #expect(completed.failedItems.isEmpty && completed.progress.completedArticles == 1)
        let final = try #require(completed.lastResult)
        #expect(final.episode.id == queued.id && final.episode.stage == .published)
        #expect(final.synthesizedChunks == final.narration.chunks.count)
        let rows = try NativeStore(url: storage.profile.database, readOnly: true).query("SELECT chunk_index,checkpoint FROM chunks ORDER BY chunk_index")
        #expect(rows.count == final.narration.chunks.count && rows.first == rowsBefore.first)
        #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
        #expect(await fixture.coordinator.residentProcessIdentifier == nil)
        } catch {
            barrier.release(); run.cancel()
            if let acceptedAPI { await fixture.coordinator.closeJob(acceptedAPI) }
            _ = await run.result
            throw error
        }
        }
    }
    @Test func stopWhileAutomaticallySuspendedCannotResurrectPodcastOrCancelAPI() async throws {
        try await withFixture { fixture in
            let audio = fixture.root.appendingPathComponent("audio"); try Files.directory(audio)
            let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: fixture.root.appendingPathComponent("state"),
                temporaryRoot: fixture.root.appendingPathComponent("scratch"))
            let backend = try NativeMLXBackend(configuration: .init(projectRoot: fixture.models, settings: .init()), worker: fixture.configuration)
            defer { backend.cancel() }
            let coordinator = FixtureCoordinator(), barrier = ValidationBarrier(), control = QueueRunControl()
            await coordinator.setBeforeAudioProcessing { stage, file in
                if stage == .validation, file.deletingLastPathComponent().lastPathComponent == "chunk-1" { try barrier.waitOnce(file: file) }
            }
            let item = try await coordinator.enqueue(reviewedSource(), storage: storage, preferences: SpeechPreferences())
            let run = Task { try await coordinator.drainQueue(storage: storage, backend: { _ in backend }, control: control) }
            do {
                try await wait { barrier.entered }
                let api = try await fixture.job(rank: .api, delivery: .streaming)
                let (_, firstResponse) = try await fixture.generated(api, index: 0)
                firstResponse.checkpointReceipt?.discard()
                control.requestStop(); run.cancel(); barrier.release()
                do { _ = try await run.value; Issue.record("Stopped run reported completion") }
                catch { #expect(error is CancellationError) }
                let rows = try await coordinator.queue(stateRoot: storage.stateRoot)
                #expect(rows.count == 1 && rows[0].id == item.id && rows[0].state == .queued && rows[0].lastError == nil)
                #expect(try NativeStore(url: storage.profile.database, readOnly: true).query("SELECT COUNT(*) FROM chunks").first?.first == "0")
                #expect(!FileManager.default.fileExists(atPath: storage.profile.work.appendingPathComponent(item.id).path))
                // Stop owns only the podcast job. Its same-app API context is still usable.
                let (_, secondResponse) = try await fixture.generated(api, index: 1)
                secondResponse.checkpointReceipt?.discard()
                await fixture.coordinator.closeJob(api)
                #expect(try await coordinator.queue(stateRoot: storage.stateRoot).first?.state == .queued)
            } catch { barrier.release(); run.cancel(); _ = await run.result; throw error }
        }
    }
    @Test func realAACFinalizerYieldsToAPIAndKeepsSameAppSpeechOverlap() async throws {
        try await withFixture { fixture in
            let source = try await fixture.job()
            let (_, pcm) = try await fixture.generated(source, index: 0)
            #expect(try pcm.checkpointReceipt?.commit(index: 0) {} == true)
            let pid = await fixture.coordinator.residentProcessIdentifier
            let barrier = ValidationBarrier(), flags = CPUFlags()
            let profile = try FixtureWorkspace.prepare(root: fixture.root.appendingPathComponent("cpu-library"), imported: nil)
            let directory = fixture.root.appendingPathComponent("cpu-finalizer")
            try Files.directory(directory)
            let processor = AudioProcessor(settings: profile, toolDirectory: directory, observer: { stage, file in
                if stage == .encoding { try barrier.waitOnce(file: file) }
            })
            let context = SpeechCPUContext(coordinator: fixture.coordinator, settings: .init(), workspace: fixture.models, rank: .podcast,
                waiting: { flags.report($0) })
            let encode = Task { try await context.run {
                let (file, info) = try processor.encode(pcm.artifacts, in: directory)
                return (file, info, try Files.hash(file))
            } }
            do {
                try await wait { barrier.entered }
                await fixture.coordinator.closeJob(source)
                let next = try await fixture.job()
                let (_, another) = try await fixture.generated(next, index: 1)
                another.checkpointReceipt?.discard()
                #expect(await fixture.coordinator.residentProcessIdentifier == pid)
                await fixture.coordinator.closeJob(next)
                let api = try await fixture.job(rank: .api, delivery: .streaming)
                barrier.release(); try await wait { flags.api }
                let (_, response) = try await fixture.generated(api, index: 0)
                response.checkpointReceipt?.discard()
                #expect(await fixture.coordinator.residentProcessIdentifier == pid)
                await fixture.coordinator.closeJob(api)
                let (file, info, hash) = try await encode.value
                #expect(info.sampleRate == 24_000 && info.channels == 1 && info.duration > 0)
                #expect(try Files.hash(file) == hash)
                try NativeAudio.decode(file)
            } catch { barrier.release(); encode.cancel(); _ = await encode.result; throw error }
        }
    }
    private final class CPUFlags: @unchecked Sendable {
        let lock = NSLock(); private var value = false
        var api: Bool { lock.withLock { value } }
        func report(_ reason: SpeechWorkWait?) { if reason == .api { lock.withLock { value = true } } }
    }
    @Test func decoderPreservesTypedRevocationAndLeavesValidPCMIntact() async throws {
        try await withFixture { fixture in
            let source = try await fixture.job()
            let (_, pcm) = try await fixture.generated(source, index: 0)
            let file = pcm.artifacts[0].url
            let profile = try FixtureWorkspace.prepare(root: fixture.root.appendingPathComponent("decoder-library"), imported: nil)
            let processor = AudioProcessor(settings: profile, toolDirectory: fixture.root)
            let count = DecodeChecks()
            _ = try AudioWorkCheckpoint.$current.withValue({ count.increment() }) { try Files.hash(file) }
            let hashChecks = count.value
            count.reset()
            do {
                try AudioWorkCheckpoint.$current.withValue({
                    count.increment()
                    if count.value > hashChecks { throw SpeechCheckpointSuspension(index: 42) }
                }) { try processor.decode(file) }
                Issue.record("Decoder erased automatic revocation")
            } catch let suspended as SpeechCheckpointSuspension { #expect(suspended.index == 42) }
            try NativeAudio.decode(file)
        }
    }
    private final class DecodeChecks: @unchecked Sendable {
        let lock = NSLock(); private var stored = 0
        var value: Int { lock.withLock { stored } }
        func increment() { lock.withLock { stored += 1 } }
        func reset() { lock.withLock { stored = 0 } }
    }
    private enum PreparationScope { @TaskLocal static var inside = false }
    private final class PreparationExecutor: NarrationCPUExecutor, @unchecked Sendable {
        private let lock = NSLock(); private var calls = 0
        let before: @Sendable () throws -> Void
        init(before: @escaping @Sendable () throws -> Void = {}) { self.before = before }
        var count: Int { lock.withLock { calls } }
        func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
            lock.withLock { calls += 1 }
            let work = Task.detached {
                try self.before()
                return try PreparationScope.$inside.withValue(true, operation: operation)
            }
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        }
    }
    @Test func articleLoaderCarriesCPUAdmissionAcrossDetachedReviewAndKeepsInferenceOutside() async throws {
        let original = try reviewedSource(), executor = PreparationExecutor()
        let weakHTML = original.page.html.replacingOccurrences(of: "Checkpoint proof", with: "Untitled")
        let page = FetchedPage(originalURL: original.page.originalURL, finalURL: original.page.finalURL,
            bytes: Data(weakHTML.utf8), html: weakHTML, contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
        let result = try await ArticleSourceLoader(limits: .init(), fetch: { _ in page }, describeImages: false,
            generateMissingTitles: true, titleGenerator: { _ in
                #expect(!PreparationScope.inside)
                return "A factual synthetic title"
            }, cpuExecutor: executor).load(page.originalURL, chunkLimit: 1800)
        #expect(executor.count >= 4)
        #expect(result.page.bytes == page.bytes)
        #expect(result.document?.article.title == "A factual synthetic title")
        #expect(result.document?.article.blocks.map(\.text) == original.document?.article.blocks.map(\.text).map { $0.replacingOccurrences(of: "Checkpoint proof", with: "Untitled") })
        #expect(result.narration?.chunks.isEmpty == false)
    }
    @Test func removingPendingAdmissionCancelsAndJoinsCPUWaitWithoutHoldingWriterOrCancellingAPI() async throws {
        try await withFixture { fixture in
            let audio = fixture.root.appendingPathComponent("admission-audio"); try Files.directory(audio)
            let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: fixture.root.appendingPathComponent("admission-state"),
                temporaryRoot: fixture.root.appendingPathComponent("admission-scratch"))
            let coordinator = FixtureCoordinator(), control = QueueAdmissionControl(), flags = CPUFlags()
            let api = try await fixture.job(rank: .api, delivery: .streaming)
            let cpu = SpeechCPUContext(coordinator: fixture.coordinator, settings: .init(), workspace: fixture.models,
                rank: .podcast, waiting: { flags.report($0) })
            let review = try reviewedSource()
            let admission = Task { try await coordinator.enqueue(review, storage: storage, preferences: .init(),
                admissionControl: control, cpuExecutor: cpu) }
            do {
                try await wait { flags.api }
                #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
                #expect(!FileManager.default.fileExists(atPath: storage.profile.database.path))
                control.cancel() // No cancellation of the caller task is needed.
                do { _ = try await admission.value; Issue.record("Removed article committed") } catch is CancellationError {}
                #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
                #expect(try await SpeechCPUWork.run(job: api) { 17 } == 17)
                await fixture.coordinator.closeJob(api)
            } catch { control.cancel(); admission.cancel(); await fixture.coordinator.closeJob(api); _ = await admission.result; throw error }
        }
    }
    @Test func admissionRechecksSavedSnapshotAfterCPUPreparationWithoutOverwritingChangedBytes() async throws {
        try await withFixture { fixture in
            let audio = fixture.root.appendingPathComponent("changed-audio"); try Files.directory(audio)
            let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: fixture.root.appendingPathComponent("changed-state"),
                temporaryRoot: fixture.root.appendingPathComponent("changed-scratch"))
            let coordinator = FixtureCoordinator(), review = try reviewedSource()
            let first = try await coordinator.enqueue(review, storage: storage, preferences: .init())
            let saved = try NativeStore(url: storage.profile.database, readOnly: true).snapshot(articleID: first.id)
            let prior = try #require(saved)
            let changed = prior + Data(" ".utf8)
            let executor = PreparationExecutor {
                let writer = try NativeStore(url: storage.profile.database)
                try writer.saveSnapshot(articleID: first.id, data: changed)
            }
            do {
                _ = try await coordinator.enqueue(review, storage: storage, preferences: .init(), cpuExecutor: executor)
                Issue.record("Changed snapshot was silently reused")
            } catch is RelayError {}
            #expect(try NativeStore(url: storage.profile.database, readOnly: true).snapshot(articleID: first.id) == changed)
            let queue = try await coordinator.queue(stateRoot: storage.stateRoot)
            #expect(queue.count == 1 && queue[0].id == first.id && queue[0].attempts == first.attempts)
        }
    }
    private func reviewedSource() throws -> ReviewedSource {
        let url = URL(string: "https://articles.example/checkpoint-proof")!
        let html = "<html><head><title>Checkpoint proof</title></head><body><article><h1>Checkpoint proof</h1><p>The first synthetic paragraph is retained exactly.</p><p>The second synthetic paragraph waits for live work.</p><p>The third synthetic paragraph completes the article.</p></article></body></html>"
        let page = FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html,
            contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
        return try ReviewedSource.prepare(page, chunkLimit: 1800)
    }
    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture.make()
        do { try await body(fixture); await fixture.close() }
        catch { await fixture.close(); throw error }
    }
    private func checkpoint(_ request: SynthesisRequest, _ result: SynthesisResult) throws -> ChunkCheckpoint {
        .init(request: request, result: result, hashes: try result.artifacts.map { try Files.hash($0.url) })
    }
    private func wait(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try !condition() {
            guard ContinuousClock.now < deadline else { throw SpeechFailure(.timeout) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private final class ValidationBarrier: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false, released = false
        private var ownedFile: URL?
        var entered: Bool { lock.withLock { started } }
        var file: URL? { lock.withLock { ownedFile } }
        func waitOnce(file: URL) throws {
            let hold = lock.withLock { if started { return false }; ownedFile = file; started = true; return true }
            if hold {
                while !lock.withLock({ released }) { try Task.checkCancellation(); Thread.sleep(forTimeInterval: 0.005) }
            }
        }
        func release() { lock.withLock { released = true } }
    }
    private final class WriterFlags: @unchecked Sendable {
        private let lock = NSLock(); private var values = [false, false]
        var waiting: Bool { get { lock.withLock { values[0] } } set { lock.withLock { values[0] = newValue } } }
        var finished: Bool { get { lock.withLock { values[1] } } set { lock.withLock { values[1] = newValue } } }
    }
}
