import XCTest
import AudioOutput
import NarrationCore
@testable import NativeSpeech

final class ReferenceVoiceTests: XCTestCase {
    func testExplicitImportIsImmutableSharedAndDetectsChangedBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Synthetic voice.wav")
        let writer = try AtomicAudioWriter(destination: source)
        try writer.append(samples: Array(repeating: 0.25, count: 120_000), sampleRate: 24_000)
        try writer.publish()
        let original = try Data(contentsOf: source)
        let store = ReferenceVoiceStore(root: root.appendingPathComponent("profiles"))
        let voice = try store.importRecording(source)
        XCTAssertTrue(ReferenceVoiceStore.isIdentifier(voice.id))
        XCTAssertTrue(NativePrimaryCatalog.validates(.init(model: .chatterbox, voice: voice.id)))
        XCTAssertEqual(try store.bytes(for: voice.id), original)
        XCTAssertEqual(try ReferenceVoiceStore(root: store.root).profiles().map(\.id), [voice.id])
        XCTAssertEqual(try store.importRecording(source).id, voice.id)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let saved = store.root.appendingPathComponent(String(voice.id.dropFirst(10)) + ".wav")
        try Data("changed bytes".utf8).write(to: saved)
        XCTAssertThrowsError(try store.bytes(for: voice.id))
    }
    func testRejectsUnsafeIdentifiersAndReferenceOnOtherModels() {
        for value in ["reference:../file", "reference:" + String(repeating: "z", count: 64), "default", "reference:"] {
            XCTAssertFalse(ReferenceVoiceStore.isIdentifier(value))
            XCTAssertFalse(NativePrimaryCatalog.validates(.init(model: .chatterbox, voice: value)) && value != "default")
        }
        let id = "reference:" + String(repeating: "a", count: 64)
        XCTAssertFalse(NativePrimaryCatalog.validates(.init(model: .qwen3, voice: id)))
    }
}
