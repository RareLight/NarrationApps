import XCTest
import Foundation
import NarrationCore
import NativeSpeech
import AudioOutput
import Pronunciation
@testable import ProcessingPipeline

final class NarrationReviewTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func plan() -> PreparedSpeechPlan {
        var settings = SpeechSettings(model: .soprano, voice: "soprano")
        settings.planning = .semanticCandidate
        let identity = SpeechAcousticIdentity.make(settings: settings, policy: .nativeText)
        return .init(policy: .nativeText, settings: settings, semanticVersion: "test", acousticIdentity: identity, utterances: ["First passage.", "Second passage."].enumerated().map {
            .init(text: $0.element, phonemes: nil, tokenCount: 0, source: .init(blockIndices: [$0.offset], location: 0, length: $0.element.utf16.count), boundaryAfter: .paragraph, acousticIdentity: identity)
        }, notices: [])
    }
    func testHistoricalKokoroRepairAndContinuationReprepareOnlyGeneratedPassages() async throws {
        guard let path = ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"] else { throw XCTSkip("Build the model-free fixture worker") }
        let root = try root(), store = NarrationReviewStore(root: root.appendingPathComponent("reviews"))
        let settings = SpeechSettings(), oldIdentity = SpeechAcousticIdentity.make(settings: settings, policy: .longformPausesCandidate)
        let oldPlan = PreparedSpeechPlan(policy: .longformPausesCandidate, settings: settings, semanticVersion: "historical",
            acousticIdentity: oldIdentity, utterances: ["First passage.", "A behind-the-scenes look."].enumerated().map {
                .init(text: $0.element, phonemes: "a", tokenCount: 1, source: .init(blockIndices: [$0.offset], location: 10, length: $0.element.utf16.count), boundaryAfter: .paragraph, acousticIdentity: oldIdentity)
            }, notices: [])
        let id = try store.begin(plan: oldPlan); try store.record(id, index: 0, samples: [0.25])
        let configuration = WorkerConfiguration(executable: URL(fileURLWithPath: path), environment: ["NARRATION_FIXTURE_TRACE": root.path], inferenceLeaseFile: root.appendingPathComponent("lease"))
        let continued = try await NarrationReviewRepair.fillMissing(store: store, id: id, configuration: configuration, workspace: root)
        XCTAssertTrue(try store.load(continued).complete)
        XCTAssertEqual(try store.samples(continued, index: 0), [0.25])
        XCTAssertEqual(try store.load(continued).plan.utterances[0], oldPlan.utterances[0])
        let newIdentity = SpeechAcousticIdentity.make(settings: settings, policy: .current)
        XCTAssertNotEqual(oldIdentity, newIdentity)
        XCTAssertEqual(try store.load(continued).plan.utterances[1].acousticIdentity, newIdentity)
        XCTAssertEqual(try store.load(continued).plan.utterances[1].source.location, 10)
        XCTAssertFalse(try store.load(id).complete)
        let repaired = try await NarrationReviewRepair.regenerate(store: store, id: continued, index: 0, configuration: configuration, workspace: root)
        XCTAssertEqual(try store.load(repaired).plan.utterances[0].acousticIdentity, newIdentity)
        XCTAssertEqual(try store.samples(repaired, index: 1), try store.samples(continued, index: 1))
        XCTAssertEqual(try store.samples(continued, index: 0), [0.25])
    }
    func testRetainedPCMIntegrityExportTimingsAndDeletionIsolation() throws {
        let root = try root(), store = NarrationReviewStore(root: root.appendingPathComponent("reviews"))
        let id = try store.begin(plan: plan()), first: [Float] = [0.1, 0.2, 0], second: [Float] = [0, -0.25, 0.5]
        let manifest = store.root.appendingPathComponent(id.uuidString).appendingPathComponent("review.json")
        let originalPlan = try Data(contentsOf: manifest)
        try store.record(id, index: 0, samples: first)
        XCTAssertFalse(try store.load(id).complete)
        XCTAssertThrowsError(try store.export(id, to: root.appendingPathComponent("incomplete.wav")))
        try store.record(id, index: 1, samples: second)
        XCTAssertEqual(try Data(contentsOf: manifest), originalPlan, "Whole-book plan is immutable; only bounded chunk journals are written")
        XCTAssertEqual(try store.samples(id, index: 0), first)
        let exported = root.appendingPathComponent("new.wav"), cues = try store.export(id, to: exported)
        XCTAssertEqual(cues[0].startFrame, 0); XCTAssertEqual(cues[0].endFrame, 3)
        XCTAssertEqual(cues[1].startFrame, 8961); XCTAssertEqual(cues[1].endFrame, 8964)
        XCTAssertEqual(try NativeAudio.inspect(exported).frames, 8964)
        XCTAssertThrowsError(try store.export(id, to: exported))
        try store.remove(id); XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
        XCTAssertTrue(try store.records().isEmpty)
    }
    func testChangedAndSymlinkedCacheCannotBeReused() throws {
        let root = try root(), store = NarrationReviewStore(root: root.appendingPathComponent("reviews"))
        let id = try store.begin(plan: plan()); try store.record(id, index: 0, samples: [0.5])
        let file = store.root.appendingPathComponent(id.uuidString).appendingPathComponent("0.f32")
        try Data([0, 0, 0, 0]).write(to: file)
        XCTAssertThrowsError(try store.samples(id, index: 0))
        try FileManager.default.removeItem(at: file)
        let external = root.appendingPathComponent("unrelated"); try Data([0, 0, 0, 0]).write(to: external)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        XCTAssertThrowsError(try store.samples(id, index: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }
    func testCorruptFrameMetadataIsRejectedBeforeByteAccounting() throws {
        let root = try root(), store = NarrationReviewStore(root: root.appendingPathComponent("reviews"))
        let id = try store.begin(plan: plan()); try store.record(id, index: 0, samples: [0.1])
        let metadata = store.root.appendingPathComponent(id.uuidString).appendingPathComponent("0.json")
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        value["frames"] = Int.max
        try JSONSerialization.data(withJSONObject: value).write(to: metadata)
        XCTAssertThrowsError(try store.load(id))
        XCTAssertThrowsError(try store.record(id, index: 1, samples: [0.2]))
    }
    func testSelectiveRegenerationKeepsOtherPCMAndOriginalTake() async throws {
        guard let path = ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"] else { throw XCTSkip("Build the model-free fixture worker") }
        let root = try root(), store = NarrationReviewStore(root: root.appendingPathComponent("reviews"))
        let id = try store.begin(plan: plan())
        try store.record(id, index: 0, samples: [0.1]); try store.record(id, index: 1, samples: [0.2])
        let configuration = WorkerConfiguration(executable: URL(fileURLWithPath: path), environment: ["NARRATION_FIXTURE_TRACE": root.path], inferenceLeaseFile: root.appendingPathComponent("lease"))
        let repaired = try await NarrationReviewRepair.regenerate(store: store, id: id, index: 1, configuration: configuration, workspace: root)
        XCTAssertNotEqual(id, repaired); XCTAssertEqual(try store.samples(repaired, index: 0), [0.1])
        XCTAssertEqual(try store.samples(id, index: 1), [0.2]); XCTAssertEqual(try store.samples(repaired, index: 1), [Float](repeating: 0.01, count: 4))
        XCTAssertTrue(try store.load(repaired).complete)
        let dictionary = try PronunciationDictionary(entries: [.init(word: "First", spelling: "initial")])
        let corrected = try await NarrationReviewRepair.regenerate(store: store, id: id, index: 0, configuration: configuration, workspace: root, pronunciations: dictionary)
        XCTAssertEqual(try store.load(corrected).plan.utterances[0].text, "initial passage.")
        XCTAssertEqual(try store.samples(corrected, index: 1), [0.2])
        XCTAssertEqual(try store.load(id).plan.utterances[0].text, "First passage.")
    }

    func testCancelledRepairJoinsHelperAndPreservesTheOnlyOriginalTake() async throws {
        guard let path = ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"] else { throw XCTSkip("Build the model-free fixture worker") }
        let root = try root(), store = NarrationReviewStore(root: root.appendingPathComponent("reviews"))
        let id = try store.begin(plan: plan())
        try store.record(id, index: 0, samples: [0.1]); try store.record(id, index: 1, samples: [0.2])
        let configuration = WorkerConfiguration(executable: URL(fileURLWithPath: path), environment: ["NARRATION_FIXTURE_TRACE": root.path, "NARRATION_FIXTURE_MODE": "stall"], inferenceLeaseFile: root.appendingPathComponent("lease"))
        let task = Task { try await NarrationReviewRepair.regenerate(store: store, id: id, index: 0, configuration: configuration, workspace: root) }
        try await Task.sleep(for: .milliseconds(150)); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled repair completed") } catch {}
        XCTAssertEqual(try store.records().count, 1)
        XCTAssertEqual(try store.samples(id, index: 0), [0.1])
    }
    func testMissingPassagesRequireExplicitContinuationAndReuseVerifiedPCM() async throws {
        guard let path = ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"] else { throw XCTSkip("Build the model-free fixture worker") }
        let root = try root(), store = NarrationReviewStore(root: root.appendingPathComponent("reviews"))
        let id = try store.begin(plan: plan()); try store.record(id, index: 0, samples: [0.25])
        let configuration = WorkerConfiguration(executable: URL(fileURLWithPath: path), environment: ["NARRATION_FIXTURE_TRACE": root.path], inferenceLeaseFile: root.appendingPathComponent("lease"))
        let completed = try await NarrationReviewRepair.fillMissing(store: store, id: id, configuration: configuration, workspace: root)
        XCTAssertTrue(try store.load(completed).complete); XCTAssertFalse(try store.load(id).complete)
        XCTAssertEqual(try store.samples(completed, index: 0), [0.25])
        XCTAssertEqual(try store.samples(completed, index: 1), [Float](repeating: 0.01, count: 4))
    }
}
