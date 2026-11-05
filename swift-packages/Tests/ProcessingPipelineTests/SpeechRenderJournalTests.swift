import XCTest
import Foundation
import Darwin
import NarrationCore
import NativeSpeech
import AudioOutput
@testable import ProcessingPipeline

final class SpeechRenderJournalTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (URL, SpeechRenderJournal.Request) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("render-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let settings = SpeechSettings(model: .soprano), identity = AttemptIdentity(batch: UUID(), job: UUID())
        let acoustic = SpeechAcousticIdentity.make(settings: settings, policy: .nativeText)
        let utterances = (0..<3).map { index in
            let text = "Synthetic sentence \(index)."
            return PreparedUtterance(text: text, phonemes: nil, tokenCount: 0,
                source: .init(blockIndices: [index], location: index * 30, length: text.utf16.count),
                boundaryAfter: .paragraph, acousticIdentity: acoustic)
        }
        let plan = PreparedSpeechPlan(policy: .nativeText, settings: settings, semanticVersion: "fixture-1",
            acousticIdentity: acoustic, utterances: utterances, notices: [])
        return (root, .init(identity: identity, plan: plan, destination: root.appendingPathComponent("complete.wav"),
            format: .wav, replaceExisting: false, sourceFingerprint: "synthetic-source-1", documentOrder: [identity.job], explicitGap: 0))
    }
    private func token(_ request: SpeechRenderJournal.Request, epoch: UInt64 = 1) throws -> SpeechAttemptToken {
        try SpeechAttemptFence(batch: request.identity.batch, job: request.identity.job, lastEpoch: epoch - 1).begin()
    }
    func testReopenPreservesSparseVerifiedPCMAndUncommittedScratchIsNotACommit() throws {
        let (root, request) = try fixture(), directory = root.appendingPathComponent("job")
        var journal: SpeechRenderJournal? = try .init(directory: directory, request: request)
        for index in [0, 2] {
            let staged = try journal!.stage(index: index, samples: [Float(index), -0.25, 0.5], token: token(request, epoch: 4))
            try journal!.commit(staged)
        }
        _ = try journal!.stage(index: 1, samples: [0.125], token: token(request, epoch: 5))
        journal = nil
        let reopened = try SpeechRenderJournal(reopening: directory)
        XCTAssertEqual(reopened.request, request)
        XCTAssertEqual(reopened.recovery.indices, [0, 2]); XCTAssertEqual(reopened.recovery.lastEpoch, 4)
        XCTAssertEqual(try reopened.samples(index: 2), [2, -0.25, 0.5]); XCTAssertNil(try reopened.samples(index: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.destination.path))
    }
    func testWrongPlanConsentAndConcurrentWriterCannotAdoptJournal() throws {
        let (root, request) = try fixture(), directory = root.appendingPathComponent("job")
        var journal: SpeechRenderJournal? = try .init(directory: directory, request: request)
        XCTAssertThrowsError(try SpeechRenderJournal(directory: directory, request: request))
        journal = nil
        let changed = SpeechRenderJournal.Request(identity: request.identity, plan: request.plan, destination: request.destination,
            format: request.format, replaceExisting: true, sourceFingerprint: request.sourceFingerprint, documentOrder: request.documentOrder,
            explicitGap: request.explicitGap)
        XCTAssertThrowsError(try SpeechRenderJournal(directory: directory, request: changed))
        let changedGap = SpeechRenderJournal.Request(identity: request.identity, plan: request.plan, destination: request.destination,
            format: request.format, replaceExisting: request.replaceExisting, sourceFingerprint: request.sourceFingerprint,
            documentOrder: request.documentOrder, explicitGap: 0.5)
        XCTAssertThrowsError(try SpeechRenderJournal(directory: directory, request: changedGap))
        journal = try .init(directory: directory, request: request)
        XCTAssertTrue(journal!.recovery.indices.isEmpty)
    }
    func testCorruptedPCMAndLinkedMetadataFailClosed() throws {
        let (root, request) = try fixture(), directory = root.appendingPathComponent("job")
        var journal: SpeechRenderJournal? = try .init(directory: directory, request: request)
        let staged = try journal!.stage(index: 0, samples: [0.1, -0.2], token: token(request))
        try journal!.commit(staged); journal = nil
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let pcm = try XCTUnwrap(files.first { $0.pathExtension == "f32" })
        try Data(repeating: 0, count: 8).write(to: pcm)
        XCTAssertThrowsError(try SpeechRenderJournal(directory: directory, request: request))
        let metadata = directory.appendingPathComponent("0.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: directory.appendingPathComponent("job.json"))
        XCTAssertThrowsError(try SpeechRenderJournal(directory: directory, request: request))
    }
    func testBoundsAndRevokedStagingPreserveExistingCheckpoints() throws {
        let (root, request) = try fixture()
        let journal = try SpeechRenderJournal(directory: root.appendingPathComponent("job"), request: request, maximumBytes: 16)
        XCTAssertThrowsError(try journal.stage(index: 0, samples: [.nan], token: token(request)))
        let first = try journal.stage(index: 0, samples: [1, 2], token: token(request))
        try journal.commit(first)
        let revoked = try journal.stage(index: 1, samples: [3, 4], token: token(request, epoch: 2))
        journal.discard(revoked)
        XCTAssertEqual(try journal.samples(index: 0), [1, 2]); XCTAssertNil(try journal.samples(index: 1))
        XCTAssertThrowsError(try journal.stage(index: 1, samples: [3, 4, 5], token: token(request)))
        let foreign = try SpeechAttemptFence(batch: UUID(), job: UUID())
        XCTAssertThrowsError(try journal.stage(index: 1, samples: [3], token: foreign.begin()))
    }
    func testRenderKeepsWriterAndVerifiedPrefixThroughStreamingPreemption() async throws {
        let (root, request) = try fixture()
        let executable = try XCTUnwrap(ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"])
        var configuration = WorkerConfiguration(executable: URL(fileURLWithPath: executable), arguments: ["--handoff-probe"],
            inferenceLeaseFile: root.appendingPathComponent("inference.lock"))
        let coordinator = try SpeechWorkCoordinator(owner: .voiceRelay, configuration: configuration, root: root.appendingPathComponent("admission"))
        configuration.workCoordinator = coordinator
        let session = try NativeSpeechSession(configuration: configuration, workspace: root, settings: request.plan.settings)
        addTeardownBlock { await session.close(); await coordinator.close() }
        try await session.prepare()
        let projection = try NarrationPlanner.prepareForSpeech(.init(blocks: [.init(kind: .paragraph, text: "Warm synthetic preparation.", origin: .authored)], extractorVersion: "fixture-1"), settings: request.plan.settings)
        _ = try await session.prepareSpeech(projection)
        let before = await coordinator.observation(), stage = try XCTUnwrap(before.stage)
        try FileManager.default.removeItem(at: stage.appendingPathComponent("generation-started"))
        let journal = try SpeechRenderJournal(directory: root.appendingPathComponent("job"), request: request)
        let render = Task {
            try await session.render(plan: request.plan, destination: request.destination, replaceExisting: false,
                identity: request.identity, explicitGap: 0, recovery: journal, progress: { value in
                    if value.phase == .chunkWritten, value.completedChunks == 1 {
                        try? FileManager.default.removeItem(at: stage.appendingPathComponent("generation-started"))
                        try? Data().write(to: stage.appendingPathComponent("hold-generation"))
                    }
                })
        }
        defer { render.cancel() }
        try await wait("second unit started") {
            journal.recovery.indices == [0] && FileManager.default.fileExists(atPath: stage.appendingPathComponent("hold-generation").path) &&
                FileManager.default.fileExists(atPath: stage.appendingPathComponent("generation-started").path)
        }
        let prefix = try journal.samples(index: 0)
        let api = try await coordinator.openJob(identity: .init(batch: UUID(), job: UUID()), settings: request.plan.settings,
            workspace: root, rank: .api, delivery: .streaming)
        try await wait("second unit cancelled") { FileManager.default.fileExists(atPath: stage.appendingPathComponent("generation-cancelled").path) }
        XCTAssertEqual(journal.recovery.indices, [0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.destination.path))
        try FileManager.default.removeItem(at: stage.appendingPathComponent("hold-generation"))
        let response = try await coordinator.perform(.generate(request.plan.utterances[0], .nativeText), job: api)
        api.discardResult(response)
        await coordinator.closeJob(api)
        try await render.value
        XCTAssertEqual(try journal.samples(index: 0), prefix)
        XCTAssertEqual(journal.recovery.indices, [0, 1, 2])
        let after = await coordinator.observation()
        XCTAssertEqual(after.pid, before.pid)
        let info = try NativeAudio.inspect(request.destination)
        XCTAssertEqual(info.frames, 12); XCTAssertEqual(info.sampleRate, request.plan.settings.model.capabilities.sampleRate)
    }
    func testReopenedVerifiedPCMReconstructsOutputWithoutLaunchingHelper() async throws {
        let (root, request) = try fixture(), directory = root.appendingPathComponent("job")
        var original: SpeechRenderJournal? = try .init(directory: directory, request: request)
        for index in request.plan.utterances.indices {
            let staged = try original!.stage(index: index, samples: [0.125, -0.25, 0.5], token: token(request, epoch: 3))
            try original!.commit(staged)
        }
        original = nil
        let reopened = try SpeechRenderJournal(reopening: directory)
        // A nonexistent executable makes any accidental model/helper launch fail.
        var configuration = WorkerConfiguration(executable: root.appendingPathComponent("must-not-launch"),
            inferenceLeaseFile: root.appendingPathComponent("inference.lock"))
        let coordinator = try SpeechWorkCoordinator(owner: .voiceRelay, configuration: configuration, root: root.appendingPathComponent("admission"))
        configuration.workCoordinator = coordinator
        let session = try NativeSpeechSession(configuration: configuration, workspace: root, settings: request.plan.settings)
        addTeardownBlock { await session.close(); await coordinator.close() }
        try await session.prepare()
        try await session.render(plan: reopened.request.plan, destination: request.destination, replaceExisting: false,
            identity: request.identity, explicitGap: 0, recovery: reopened)
        let state = await coordinator.observation()
        XCTAssertNil(state.pid)
        let info = try NativeAudio.inspect(request.destination)
        XCTAssertEqual(info.frames, 9)
        XCTAssertEqual(try reopened.samples(index: 1), [0.125, -0.25, 0.5])
    }
    func testCloseDuringCoordinatedRegistrationDoesNotLeakDemand() async throws {
        let (root, request) = try fixture()
        var configuration = WorkerConfiguration(executable: root.appendingPathComponent("must-not-launch"))
        let coordinator = try SpeechWorkCoordinator(owner: .voiceRelay, configuration: configuration, root: root.appendingPathComponent("admission"))
        configuration.workCoordinator = coordinator
        addTeardownBlock { await coordinator.close() }
        let registry = try SpeechWorkAdmission(root: root.appendingPathComponent("admission"))
        for _ in 0..<20 {
            let session = try NativeSpeechSession(configuration: configuration, workspace: root, settings: request.plan.settings)
            let registration = Task { try await session.configureWork(identity: request.identity) }
            await Task.yield()
            await session.close()
            _ = await registration.result
            XCTAssertNil(try registry.highest())
        }
    }
    private func wait(_ label: String, _ predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while try !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Missing render barrier: \(label)"); throw SpeechFailure(.timeout) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
