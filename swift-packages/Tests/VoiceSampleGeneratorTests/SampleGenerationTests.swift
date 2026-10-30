import XCTest
import Foundation
import Darwin
import NarrationCore
import NativeSpeech
import Pronunciation
import AudioOutput
@testable import VoiceSampleGenerator

final class SampleGenerationTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (root: URL, destination: URL, lock: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("VoiceSamples")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("original assets".utf8).write(to: destination.appendingPathComponent("original.m4a"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, destination, root.appendingPathComponent("generator.lock"))
    }

    private static func tone(sample: VoiceSample, wav: URL) throws {
        let rate = sample.model.capabilities.sampleRate
        let amplitude = sample.id == VoiceSamples.catalog[0].id ? 0.03 : 0.3
        let samples = (0..<rate).map { Float(sin(2 * Double.pi * 440 * Double($0) / Double(rate)) * amplitude) }
        let writer = try AtomicAudioWriter(destination: wav)
        defer { writer.abort() }
        try writer.append(samples: samples, sampleRate: rate)
        try writer.publish()
    }

    private func assertUnchanged(_ fixture: (root: URL, destination: URL, lock: URL), file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), ["original.m4a"], file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: fixture.destination.appendingPathComponent("original.m4a")), Data("original assets".utf8), file: file, line: line)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".voice-samples-") }, file: file, line: line)
    }

    func testExactlyOneNonemptyTextArgumentAndSharedPlanning() throws {
        for arguments in [[], [""], [" \n"], ["one", "two"]] { XCTAssertThrowsError(try SampleGeneration.text(arguments: arguments)) }
        let text = "Dr. Smith paid $12.50 at 3 p.m.\n\n" + String(repeating: "This is the next sentence. ", count: 80)
        XCTAssertEqual(try SampleGeneration.text(arguments: [text]), text)
        for sample in VoiceSamples.catalog {
            let expected = try NarrationPlanner.prepareForSpeech(.init(blocks: [.init(kind: .paragraph, text: text, origin: .authored)],
                extractorVersion: "Foundation-text-1"), settings: sample.settings).chunks.map(\.text)
            let chunks = try SampleGeneration.chunks(text: text, sample: sample)
            XCTAssertEqual(chunks, expected)
            XCTAssertFalse(chunks.isEmpty)
            // Acoustic packing belongs to the helper, after G2P; projection
            // must not apply the superseded character-size chunking first.
            XCTAssertEqual(chunks.count, 1)
            XCTAssertTrue(chunks[0].hasSuffix("This is the next sentence."))
        }
    }

    func testCompleteCatalogReplacementAndAACPreserveLevels() async throws {
        let fixture = try fixture()
        let text = "Dr. Smith reads a new book for $12.50."
        let pronunciations = try PronunciationDictionary(entries: [.init(word: "book", spelling: "buk"), .init(word: "buk", spelling: "buhk")])
        try await SampleGeneration.regenerate(text: text, pronunciations: pronunciations, destination: fixture.destination, lockFile: fixture.lock) { sample, _, wav in
            try Self.tone(sample: sample, wav: wav)
        }
        let manifest = try JSONDecoder().decode(SampleManifest.self, from: Data(contentsOf: fixture.destination.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.version, 3); XCTAssertEqual(manifest.inputText, text)
        XCTAssertEqual(manifest.plannerVersion, NarrationPlanner.version)
        XCTAssertEqual(manifest.pronunciationOverridesFingerprint, pronunciations.fingerprint)
        XCTAssertEqual(manifest.pronunciationRevision, NativeG2P.revision)
        XCTAssertEqual(manifest.samples.map(\.id), VoiceSamples.catalog.map(\.id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).count, VoiceSamples.catalog.count + 1)
        for (sample, record) in zip(VoiceSamples.catalog, manifest.samples) {
            XCTAssertEqual(record.phrase, text)
            XCTAssertTrue(record.narrationChunks.joined(separator: " ").contains("new buk"))
            XCTAssertEqual(record.narrationChunks, try SampleGeneration.chunks(text: text, sample: sample, pronunciations: pronunciations))
            XCTAssertEqual(record.modelRevision, NativePrimaryCatalog.specification(for: sample.model).revision)
            XCTAssertEqual(record.speed, 1); XCTAssertEqual(record.bitRate, 64_000)
            let audio = fixture.destination.appendingPathComponent("\(sample.id).m4a")
            XCTAssertEqual(record.sha256, try NativeG2P.sha256(audio))
            let info = try NativeAudio.inspect(audio)
            XCTAssertEqual(info.codec, "aac"); XCTAssertEqual(info.sampleRate, 24_000); XCTAssertEqual(info.channels, 1)
        }
        var levels: [Double] = []
        for sample in VoiceSamples.catalog.prefix(2) {
            var frames: [Float] = []
            try NativeAudio.decode(fixture.destination.appendingPathComponent("\(sample.id).m4a")) { frames += $0 }
            let body = frames[8_000..<16_000]
            levels.append(sqrt(body.reduce(0) { $0 + Double($1 * $1) } / Double(body.count)))
        }
        XCTAssertEqual(levels[0], 0.03 / sqrt(2), accuracy: 0.002)
        XCTAssertEqual(levels[1] / levels[0], 10, accuracy: 0.4)
    }

    func testFailureAfterFirstVoiceAndCancellationPreserveExistingAssets() async throws {
        for cancel in [false, true] {
            let fixture = try fixture()
            do {
                try await SampleGeneration.regenerate(text: "A short sample.", destination: fixture.destination, lockFile: fixture.lock) { sample, _, wav in
                    if sample.id != VoiceSamples.catalog[0].id {
                        if cancel { throw CancellationError() }
                        throw SampleGenerationError.message("Injected renderer failure")
                    }
                    try Self.tone(sample: sample, wav: wav)
                }
                XCTFail("Generation should fail")
            } catch { XCTAssertEqual(error is CancellationError, cancel) }
            try assertUnchanged(fixture)
        }
    }

    func testConcurrentWriterAndSymlinkDestinationAreRejected() async throws {
        let fixture = try fixture()
        let descriptor = open(fixture.lock.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        do {
            try await SampleGeneration.regenerate(text: "Sample.", destination: fixture.destination, lockFile: fixture.lock) { _, _, _ in XCTFail("Must not render") }
            XCTFail("Must reject another writer")
        } catch { XCTAssertTrue(error.localizedDescription.contains("already running")) }
        try assertUnchanged(fixture)
        let link = fixture.root.appendingPathComponent("linked-samples")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.destination)
        do {
            try await SampleGeneration.regenerate(text: "Sample.", destination: link, lockFile: fixture.root.appendingPathComponent("second.lock")) { _, _, _ in XCTFail("Must not render") }
            XCTFail("Must reject symlink")
        } catch {}
        try assertUnchanged(fixture)
    }

    func testActualTaskCancellationCleansStagingAndPreservesAssets() async throws {
        let fixture = try fixture()
        let entered = expectation(description: "Renderer entered")
        let task = Task {
            try await SampleGeneration.regenerate(text: "Sample.", destination: fixture.destination, lockFile: fixture.lock) { sample, _, wav in
                try Self.tone(sample: sample, wav: wav)
                entered.fulfill()
                try await Task.sleep(for: .seconds(30))
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try assertUnchanged(fixture)
    }

    func testInvalidRenderedAudioPreservesAssets() async throws {
        let fixture = try fixture()
        do {
            try await SampleGeneration.regenerate(text: "Sample.", destination: fixture.destination, lockFile: fixture.lock) { _, _, wav in
                try Data([0, 1, 2]).write(to: wav)
            }
            XCTFail("Invalid audio must not publish")
        } catch {}
        try assertUnchanged(fixture)
    }

    /// Explicit real-engine gate; never overwrites bundled source assets or downloads models.
    func testNativeCatalogRegenerationWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["VOICE_SAMPLE_NATIVE_CHECK"] == "1" else { throw XCTSkip("Opt-in native generation") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let worker = root.appendingPathComponent(".build/debug/NarrationSpeechWorker")
        let workspaces = try SampleGeneration.workspaces(packageRoot: root)
        let source = root.appendingPathComponent("Sources/NativeSpeech/Resources/VoiceSamples/manifest.json")
        let previous = try Data(contentsOf: source)
        let fixture = try fixture()
        try await SampleGeneration.regenerate(text: "Dr. Smith paid $12.50 for a book. Let's read it together!", destination: fixture.destination, lockFile: fixture.lock) { sample, projection, wav in
            try await SampleGeneration.render(sample: sample, projection: projection, wav: wav, worker: worker, workspace: workspaces[sample.model]!)
        }
        let manifest = try JSONDecoder().decode(SampleManifest.self, from: Data(contentsOf: fixture.destination.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.samples.count, 29)
        XCTAssertEqual(try Data(contentsOf: source), previous)
    }
}

extension SampleGenerationTests {
    func testSampleProjectionIsExactlyTheCommonConsumerPlanWithCapturedRules() throws {
        let sample = try XCTUnwrap(VoiceSamples.catalog.first)
        let rules = try PronunciationDictionary(entries: [.init(word: "SQLite", spelling: "sequel lite")])
        let text = "SQLite can read a new story."
        let document = SemanticDocument(blocks: [.init(kind: .paragraph, text: text, origin: .authored)], extractorVersion: "Foundation-text-1")
        XCTAssertEqual(try SampleGeneration.projection(text: text, sample: sample, pronunciations: rules),
                       try NarrationPlanner.prepareForSpeech(document, settings: sample.settings, pronunciations: rules))
    }
}


extension SampleGenerationTests {
    func testExplicitUnpreparedWorkspaceFailsWithoutFallingBackOrDownloading() throws {
        let fixture = try fixture()
        XCTAssertThrowsError(try SampleGeneration.workspaces(packageRoot: fixture.root,
            override: fixture.root.appendingPathComponent("missing-prepared-models")))
        try assertUnchanged(fixture)
    }
}
