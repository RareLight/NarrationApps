import XCTest
import Foundation
import Darwin
import NarrationCore
import NativeSpeech
import DocumentProcessing
import AudioOutput
import Pronunciation
@testable import ProcessingPipeline

final class LibroBatchRecoveryTests: XCTestCase, @unchecked Sendable {
    func testDiscoveryDoesNotHashOutputAndDiscardPreservesOriginalFiles() throws {
        let fixture = try Fixture.make(count: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.request.documents[0].input.source, destination = fixture.request.documents[0].destination
        let original = try Data(contentsOf: source), audio = Data("Completed recording".utf8)
        let recovery = try LibroBatchRecovery(directory: fixture.directory, request: fixture.request)
        try audio.write(to: destination); try recovery.markPublished(fixture.request.documents[0].id)
        try Data("Changed recording".utf8).write(to: destination)
        XCTAssertEqual(try recovery.summary().completedCount, 1)
        XCTAssertThrowsError(try recovery.resumeRequest())
        XCTAssertEqual(Set(recovery.requiredAccess), Set([source, fixture.request.workspace, fixture.request.outputDirectory]))
        try recovery.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: destination), Data("Changed recording".utf8))
    }
    private struct Fixture {
        let root: URL, request: BatchRequest
        static func make(count: Int = 2, replacing: Bool = false) throws -> Self {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("libro-batch-recovery-\(UUID())")
            let output = root.appendingPathComponent("output"), models = root.appendingPathComponent("models-workspace")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
            var inputs: [InputDocument] = []
            for index in 0..<count {
                let file = root.appendingPathComponent("book-\(index).txt")
                try Data("Anna reads the first synthetic paragraph.\n\nAnother synthetic paragraph follows.\n\nThe final synthetic paragraph is preserved.".utf8).write(to: file)
                inputs.append(.init(source: file, kind: .text, relativePath: file.lastPathComponent, textEncoding: .utf8))
                if replacing { try Data("Original user recording \(index)".utf8).write(to: output.appendingPathComponent("book-\(index).wav")) }
            }
            let docs = try BatchPlanner.plan(inputs, output: output, format: .wav)
            let dictionary = try PronunciationDictionary(entries: [.init(word: "Anna", spelling: "Annah")])
            return .init(root: root, request: .init(documents: docs, outputDirectory: output, workspace: models,
                settings: .init(model: .soprano), replaceExisting: replacing, outputFormat: .wav, pronunciations: dictionary))
        }
        var directory: URL { root.appendingPathComponent("recovery") }
        func configuration(failPreparation: Bool = false, owner: SpeechWorkOwner = .libro) throws -> WorkerConfiguration {
            let executable = try XCTUnwrap(ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"])
            var config = WorkerConfiguration(executable: URL(fileURLWithPath: executable), arguments: ["--handoff-probe"],
                environment: ["NARRATION_FIXTURE_SYNTHETIC_PCM": "1", "NARRATION_FIXTURE_FAIL_PREPARATION": failPreparation ? "1" : "0"],
                inferenceLeaseFile: root.appendingPathComponent("inference.lock"), inferencePriority: owner == .libro ? .interactive : .background)
            config.workCoordinator = try .init(owner: owner, configuration: config, root: root.appendingPathComponent("admission"))
            return config
        }
    }
    func testCapturedOrderPauseSettingsAndDictionarySurviveReopen() async throws {
        let fixture = try Fixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        var recovery: LibroBatchRecovery? = try .init(directory: fixture.directory, request: fixture.request)
        let control = BatchQueueControl(batch: fixture.request.id, jobs: fixture.request.documents.map(\.id))
        control.observe { [owned = recovery!] in owned.recordQueue($0) }
        XCTAssertTrue(control.reorderPending(fixture.request.documents.map(\.id).reversed()))
        control.setPaused(true)
        try await recovery!.flush()
        control.observe { _ in }; recovery = nil
        let reopened = try LibroBatchRecovery(reopening: fixture.directory), restored = try reopened.resumeRequest()
        XCTAssertTrue(try reopened.wasManuallyPaused)
        XCTAssertEqual(restored.id, fixture.request.id)
        XCTAssertEqual(restored.documents.map(\.id), fixture.request.documents.map(\.id).reversed())
        XCTAssertEqual(restored.documents.map(\.input.textEncoding), [.utf8, .utf8])
        XCTAssertEqual(restored.settings, fixture.request.settings)
        XCTAssertEqual(restored.pronunciations.fingerprint, fixture.request.pronunciations.fingerprint)
        try reopened.validateBinding(restored)
        XCTAssertThrowsError(try LibroBatchRecovery(reopening: fixture.directory))
    }
    func testChangedSourceOrReplacementConsentCannotBeAdopted() throws {
        let fixture = try Fixture.make(replacing: true); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = try LibroBatchRecovery(directory: fixture.directory, request: fixture.request)
        try recovery.validateBinding(fixture.request)
        var mismatched = fixture.request.settings; mismatched.speed = 1.25
        let identity = SpeechAcousticIdentity.make(settings: mismatched, policy: .nativeText)
        let wrongPlan = PreparedSpeechPlan(policy: .nativeText, settings: mismatched, semanticVersion: "fixture", acousticIdentity: identity,
            utterances: [.init(text: "Test", phonemes: nil, tokenCount: 0,
                source: .init(blockIndices: [0], location: 0, length: 4), boundaryAfter: .sentence, acousticIdentity: identity)], notices: [])
        XCTAssertThrowsError(try recovery.journal(document: fixture.request.documents[0].id, plan: wrongPlan))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(fixture.request.documents[0].id.uuidString).path))
        let source = fixture.request.documents[0].input.source, original = try Data(contentsOf: source)
        try Data("Changed input".utf8).write(to: source)
        XCTAssertThrowsError(try recovery.validateBinding(fixture.request))
        try original.write(to: source)
        let target = fixture.request.documents[0].destination, changed = Data("Changed user recording".utf8)
        try changed.write(to: target)
        XCTAssertThrowsError(try recovery.validateSourceAndDestination(document: fixture.request.documents[0].id))
        XCTAssertEqual(try Data(contentsOf: target), changed)
    }
    func testCompletedOutputsAndSkippedDocumentsNeverReplay() throws {
        let fixture = try Fixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        var recovery: LibroBatchRecovery? = try .init(directory: fixture.directory, request: fixture.request)
        let first = fixture.request.documents[0], second = fixture.request.documents[1]
        let audio = Data("Synthetic completed recording".utf8)
        try audio.write(to: first.destination); try recovery!.markPublished(first.id); try recovery!.markSkipped(second.id)
        recovery = nil
        let reopened = try LibroBatchRecovery(reopening: fixture.directory)
        XCTAssertTrue(try reopened.resumeRequest().documents.isEmpty)
        XCTAssertEqual(try Data(contentsOf: first.destination), audio)
        try Data("External replacement".utf8).write(to: first.destination)
        XCTAssertThrowsError(try reopened.resumeRequest())
    }
    func testLinkedQueueMetadataFailsClosed() throws {
        let fixture = try Fixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = try LibroBatchRecovery(directory: fixture.directory, request: fixture.request)
        try FileManager.default.createSymbolicLink(at: fixture.directory.appendingPathComponent("queue.json"), withDestinationURL: fixture.request.documents[0].input.source)
        XCTAssertThrowsError(try recovery.resumeRequest())
        XCTAssertThrowsError(try recovery.wasManuallyPaused)
    }
    func testInterruptedBatchResumesSavedPlanAndPCMWithoutRepeatingPreparation() async throws {
        let fixture = try Fixture.make(count: 1); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configuration = try fixture.configuration(), engine = try XCTUnwrap(configuration.workCoordinator)
        let coordinator = QueueCoordinator(configuration: configuration)
        let control = BatchQueueControl(batch: fixture.request.id, jobs: fixture.request.documents.map(\.id))
        var recovery: LibroBatchRecovery? = try .init(directory: fixture.directory, request: fixture.request)
        let task = Task { [owned = recovery!] in
            try await coordinator.run(fixture.request, control: control, recovery: owned) { event in
                if case .speech(let value) = event, value.phase == .chunkWritten, value.completedChunks == 1 { control.setPaused(true) }
            }
        }
        do {
            try await wait { control.state.phase == .paused }
            await coordinator.cancelAndWait()
            let interrupted = try await task.value
            XCTAssertTrue(interrupted.cancelled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.request.documents[0].destination.path))
        } catch { task.cancel(); await coordinator.cancelAndWait(); _ = await task.result; await engine.close(); throw error }
        await engine.close()
        var partial = try recovery!.journal(document: fixture.request.documents[0].id)
        let prefix = try XCTUnwrap(partial?.samples(index: 0)), plan = try XCTUnwrap(partial?.request.plan)
        XCTAssertEqual(partial?.recovery.indices, [0]); XCTAssertTrue(plan.utterances.contains { $0.text.contains("Annah") })
        partial = nil; recovery = nil
        let reopened = try LibroBatchRecovery(reopening: fixture.directory), resumedRequest = try reopened.resumeRequest()
        let resumedConfiguration = try fixture.configuration(failPreparation: true)
        let resumedEngine = try XCTUnwrap(resumedConfiguration.workCoordinator)
        let resumed = try await QueueCoordinator(configuration: resumedConfiguration).run(resumedRequest, recovery: reopened)
        await resumedEngine.close()
        XCTAssertEqual(resumed.successfulCount, 1); XCTAssertFalse(resumed.cancelled); XCTAssertNil(resumed.recoveryIssue)
        var decoded: [Float] = []
        try NativeAudio.decode(fixture.request.documents[0].destination) { decoded += $0 }
        XCTAssertEqual(Array(decoded.prefix(prefix.count)), prefix)
        XCTAssertTrue(try reopened.resumeRequest().documents.isEmpty)
    }
    func testManualPauseWithdrawsAndSkipFinishesWhileAPIStillOwnsPriority() async throws {
        let fixture = try Fixture.make(count: 1); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configuration = try fixture.configuration(), engine = try XCTUnwrap(configuration.workCoordinator)
        let relayConfig = try fixture.configuration(owner: .voiceRelay), relay = try XCTUnwrap(relayConfig.workCoordinator)
        let registry = try SpeechWorkAdmission(root: fixture.root.appendingPathComponent("admission"))
        let api = PreparationDemand(registry: registry)
        let recovery = try LibroBatchRecovery(directory: fixture.directory, request: fixture.request)
        let control = BatchQueueControl(batch: fixture.request.id, jobs: fixture.request.documents.map(\.id)), flags = Flags()
        let queue = QueueCoordinator(configuration: configuration)
        let run = Task {
            let summary = try await queue.run(fixture.request, control: control, recovery: recovery) { event in
                // Accept API demand after whole-batch preflight, at the first
                // document boundary, so this exercises per-document CPU pause.
                if case .preparing = event { api.begin() }
                if case .waiting(_, _, .some(.api)) = event { flags.waiting = true }
            }
            flags.finished = true; return summary
        }
        do {
            try await wait { flags.waiting }
            control.setPaused(true)
            try await wait { control.state.phase == .paused }
            let podcast = try await relay.openJob(identity: .init(batch: UUID(), job: UUID()), settings: .init(), workspace: fixture.request.workspace, rank: .podcast)
            try api.withdraw()
            try await wait { try registry.highest()?.rank == .podcast }
            XCTAssertTrue(control.skip(job: fixture.request.documents[0].id))
            try await wait { flags.finished }
            let summary = try await run.value
            XCTAssertEqual(summary.skippedCount, 1); XCTAssertFalse(summary.cancelled)
            XCTAssertEqual(summary.failedCount, 0); XCTAssertNil(summary.recoveryIssue)
            XCTAssertTrue(try recovery.resumeRequest().documents.isEmpty)
            await relay.closeJob(podcast)
        } catch { run.cancel(); await queue.cancelAndWait(); _ = await run.result; await relay.close(); await engine.close(); throw error }
        await relay.close(); await engine.close()
    }
    func testCoordinatedMultiDocumentBatchReleasesHelperBeforeNextExtraction() async throws {
        let fixture = try Fixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configuration = try fixture.configuration(), engine = try XCTUnwrap(configuration.workCoordinator)
        let recovery = try LibroBatchRecovery(directory: fixture.directory, request: fixture.request)
        let summary = try await QueueCoordinator(configuration: configuration).run(fixture.request, recovery: recovery)
        await engine.close()
        XCTAssertEqual(summary.successfulCount, 2, "\(summary.documents.map { $0.message ?? String(describing: $0.state) })"); XCTAssertFalse(summary.cancelled); XCTAssertNil(summary.recoveryIssue)
        XCTAssertEqual(summary.documents.map(\.id), fixture.request.documents.map(\.id))
        XCTAssertTrue(try recovery.resumeRequest().documents.isEmpty)
        for doc in fixture.request.documents { XCTAssertGreaterThan(try NativeAudio.inspect(doc.destination).frames, 0) }
    }
    func testStopJoinsPreflightWaitingForAPIAndKeepsBatchExclusive() async throws {
        let fixture = try Fixture.make(count: 1); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configuration = try fixture.configuration(), engine = try XCTUnwrap(configuration.workCoordinator)
        let registry = try SpeechWorkAdmission(root: fixture.root.appendingPathComponent("admission"))
        let api = try registry.register(owner: .voiceRelay, instance: UUID(), rank: .api, delivery: .streaming)
        defer { try? api.withdraw() }
        let queue = QueueCoordinator(configuration: configuration), recovery = try LibroBatchRecovery(directory: fixture.directory, request: fixture.request)
        let source = try Data(contentsOf: fixture.request.documents[0].input.source)
        let flags = Flags()
        let run = Task { try await queue.run(fixture.request, recovery: recovery) { event in
            if case .waiting(_, _, .some(.api)) = event { flags.waiting = true }
        } }
        do {
            try await wait { flags.waiting }
            do { _ = try await queue.run(fixture.request, recovery: recovery); XCTFail("Preflight admitted a second batch") }
            catch CoordinatorError.busy {}
            await queue.cancelAndWait()
            do { _ = try await run.value; XCTFail("Stopped preflight continued") } catch is CancellationError {}
            let observed = await engine.observation(); XCTAssertNil(observed.pid)
            try api.withdraw(); XCTAssertNil(try registry.highest())
            XCTAssertEqual(try Data(contentsOf: fixture.request.documents[0].input.source), source)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.request.documents[0].destination.path))
        } catch { run.cancel(); await queue.cancelAndWait(); _ = await run.result; await engine.close(); throw error }
        await engine.close()
    }
    func testSourceAndPublishedProofsHonorCPUInterruptionWithoutChangingFiles() throws {
        struct Interrupted: AudioWorkInterruption {}
        let fixture = try Fixture.make(count: 1); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = try LibroBatchRecovery(directory: fixture.directory, request: fixture.request), doc = fixture.request.documents[0]
        let source = try Data(contentsOf: doc.input.source), output = Data(repeating: 0x53, count: 2_100_000)
        try output.write(to: doc.destination)
        try AudioWorkCheckpoint.$current.withValue({ throw Interrupted() }) {
            XCTAssertThrowsError(try recovery.validateSourceAndDestination(document: doc.id)) { XCTAssertTrue($0 is Interrupted) }
            // Even the post-publication receipt yields; its failure must not
            // remove the already-published file or claim a completed proof.
            XCTAssertThrowsError(try recovery.markPublished(doc.id)) { XCTAssertTrue($0 is Interrupted) }
        }
        XCTAssertEqual(try Data(contentsOf: doc.input.source), source)
        XCTAssertEqual(try Data(contentsOf: doc.destination), output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("done-\(doc.id).json").path))
        try recovery.markPublished(doc.id)
        XCTAssertTrue(try recovery.resumeRequest().documents.isEmpty)
    }
    func testStopJoinsPublishedReceiptWhileAPIStillOwnsPriority() async throws {
        let fixture = try Fixture.make(count: 1); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configuration = try fixture.configuration(), engine = try XCTUnwrap(configuration.workCoordinator)
        let registry = try SpeechWorkAdmission(root: fixture.root.appendingPathComponent("admission"))
        let api = try registry.register(owner: .voiceRelay, instance: UUID(), rank: .api, delivery: .streaming)
        defer { try? api.withdraw() }
        let recovery = try LibroBatchRecovery(directory: fixture.directory, request: fixture.request), doc = fixture.request.documents[0]
        let published = Data(repeating: 0x53, count: 2_100_000); try published.write(to: doc.destination)
        let flags = Flags()
        let cpu = SpeechCPUContext(coordinator: engine, settings: fixture.request.settings, workspace: fixture.request.workspace,
            rank: .libro, waiting: { if $0 == .api { flags.waiting = true } })
        let receipt = Task {
            defer { flags.finished = true }
            try await QueueCoordinator.recordPublished(doc.id, recovery: recovery, cpu: cpu)
        }
        do {
            try await wait { flags.waiting }
            receipt.cancel()
            try await wait { flags.finished }
            do { try await receipt.value; XCTFail("Stopped receipt continued") } catch is CancellationError {}
            XCTAssertEqual(try registry.highest(), api.demand, "Stop must not cancel the accepted API")
            XCTAssertEqual(try Data(contentsOf: doc.destination), published)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("done-\(doc.id).json").path))
            let resumed = try recovery.resumeRequest()
            XCTAssertThrowsError(try recovery.validateBinding(resumed), "An existing unrecorded output must never replay")
            try api.withdraw(); XCTAssertNil(try registry.highest())
            let observed = await engine.observation(); XCTAssertNil(observed.pid)
        } catch { receipt.cancel(); try? api.withdraw(); _ = await receipt.result; await engine.close(); throw error }
        await engine.close()
    }
    private func wait(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try !condition() {
            guard ContinuousClock.now < deadline else { throw SpeechFailure(.timeout) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private final class Flags: @unchecked Sendable {
        private let lock = NSLock(); private var values = [false, false]
        var waiting: Bool { get { lock.withLock { values[0] } } set { lock.withLock { values[0] = newValue } } }
        var finished: Bool { get { lock.withLock { values[1] } } set { lock.withLock { values[1] = newValue } } }
    }
    private final class PreparationDemand: @unchecked Sendable {
        let registry: SpeechWorkAdmission
        private let lock = NSLock()
        private var result: Result<SpeechWorkTicket, Error>?
        init(registry: SpeechWorkAdmission) { self.registry = registry }
        func begin() {
            lock.withLock { result = Result { try registry.register(owner: .voiceRelay, instance: UUID(), rank: .api, delivery: .streaming) } }
        }
        func withdraw() throws { try lock.withLock { try result?.get().withdraw() } }
    }
    func testCPUWorkerLimitIsCapturedAndOlderManifestsRestoreSerialDefault() throws {
        let fixture = try Fixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let old = fixture.request
        let request = BatchRequest(documents: old.documents, outputDirectory: old.outputDirectory, workspace: old.workspace,
            settings: old.settings, describeImages: old.describeImages, outputFormat: old.outputFormat,
            pronunciations: old.pronunciations, coverArtwork: old.coverArtwork, narrationOptions: old.narrationOptions,
            id: old.id, approvedReplacements: old.approvedReplacements, textPreparationWorkers: 12)
        do {
            let recovery = try LibroBatchRecovery(directory: fixture.directory, request: request)
            XCTAssertEqual(try recovery.resumeRequest().textPreparationWorkers, 12)
            try recovery.validateBinding(request)
        }
        let file = fixture.directory.appendingPathComponent("batch.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json.removeValue(forKey: "textPreparationWorkers")
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let recovery = try LibroBatchRecovery(reopening: fixture.directory)
        XCTAssertEqual(try recovery.resumeRequest().textPreparationWorkers, 1)
    }

}
