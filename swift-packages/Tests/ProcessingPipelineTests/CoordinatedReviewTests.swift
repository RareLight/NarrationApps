import XCTest
import Foundation
import NarrationCore
import NativeSpeech
import AudioOutput
@testable import ProcessingPipeline

final class CoordinatedReviewTests: XCTestCase, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        private var reason: SpeechWorkWait?, closed = false
        var waiting: SpeechWorkWait? { lock.withLock { reason } }
        var isClosed: Bool { lock.withLock { closed } }
        func report(_ value: SpeechWorkWait?) { lock.withLock { reason = value } }
        func didClose() { lock.withLock { closed = true } }
    }
    private struct Fixture {
        let root: URL, store: NarrationReviewStore, coordinator: SpeechWorkCoordinator, session: NativeSpeechSession
        let plan: PreparedSpeechPlan, state: State, artifact: URL
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("coordinated-review-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"])
        var config = WorkerConfiguration(executable: URL(fileURLWithPath: path), arguments: ["--handoff-probe"],
            environment: ["NARRATION_FIXTURE_SYNTHETIC_PCM": "1"], shutdownGrace: 0.1, terminationGrace: 0.1,
            inferenceLeaseFile: root.appendingPathComponent("inference.lock"), inferencePriority: .interactive)
        let owner = try SpeechWorkCoordinator(owner: .libro, configuration: config, root: root.appendingPathComponent("admission"))
        config.workCoordinator = owner
        var settings = SpeechSettings(model: .soprano); settings.retainReview = true
        let store = NarrationReviewStore(root: root.appendingPathComponent("reviews")), state = State()
        let session = try NativeSpeechSession(configuration: config, workspace: root, settings: settings, reviewStore: store)
        addTeardownBlock { await session.close(); await owner.close(); try? FileManager.default.removeItem(at: root) }
        try await session.configureWork(identity: .init(batch: UUID(), job: UUID()), waiting: { state.report($0) })
        try await session.prepare()
        let projection = try NarrationPlanner.prepareForSpeech(.init(blocks: [.init(kind: .paragraph, text: "Synthetic review words remain unchanged.")], extractorVersion: "review-fixture"), settings: settings)
        let plan = try await session.prepareSpeech(projection)
        let artifact = root.appendingPathComponent("committed.wav"), writer = try AtomicAudioWriter(destination: artifact)
        defer { writer.abort() }
        try writer.append(samples: [0.125, -0.5, 1.25], sampleRate: settings.model.capabilities.sampleRate)
        try writer.publish(replaceExisting: false)
        return .init(root: root, store: store, coordinator: owner, session: session, plan: plan, state: state, artifact: artifact)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw SpeechFailure(.timeout) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testConcurrentCommittedReviewCallbacksSerializeWithoutDuplicateOrFailure() async throws {
        let fixture = try await fixture(), utterance = try XCTUnwrap(fixture.plan.utterances.first)
        let original = try Data(contentsOf: fixture.artifact)
        async let first: Void = fixture.session.retainCommittedReview(utterance, artifact: fixture.artifact)
        async let second: Void = fixture.session.retainCommittedReview(utterance, artifact: fixture.artifact)
        _ = await (first, second)
        let records = try fixture.store.records(), id = try XCTUnwrap(records.first?.id)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(try fixture.store.load(id).artifacts.compactMap { $0 }.count, 1)
        XCTAssertEqual(try fixture.store.samples(id, index: 0), [0.125, -0.5, 1.25])
        let issue = await fixture.session.reviewIssue; XCTAssertNil(issue)
        XCTAssertEqual(try Data(contentsOf: fixture.artifact), original)
    }
    func testCloseJoinsReviewWaitingBehindAPIAndPreservesCommittedArtifact() async throws {
        let fixture = try await fixture(), utterance = try XCTUnwrap(fixture.plan.utterances.first)
        let original = try Data(contentsOf: fixture.artifact)
        let registry = try SpeechWorkAdmission(root: fixture.root.appendingPathComponent("admission"))
        let api = try registry.register(owner: .voiceRelay, instance: UUID(), rank: .api, delivery: .streaming)
        defer { try? api.withdraw() }
        let retention = Task { await fixture.session.retainCommittedReview(utterance, artifact: fixture.artifact) }
        var close: Task<Void, Never>?
        do {
            try await wait { fixture.state.waiting == .api }
            let closing = Task { await fixture.session.close(); fixture.state.didClose() }; close = closing
            try await wait { fixture.state.isClosed }
            await closing.value; await retention.value
            XCTAssertEqual(try registry.highest(), api.demand)
            try api.withdraw(); XCTAssertNil(try registry.highest())
            XCTAssertEqual(try Data(contentsOf: fixture.artifact), original)
            let id = try XCTUnwrap(fixture.store.records().first?.id)
            XCTAssertTrue(try fixture.store.load(id).artifacts.allSatisfy { $0 == nil })
        } catch {
            retention.cancel(); try? api.withdraw()
            await retention.value; await close?.value
            throw error
        }
    }
}
