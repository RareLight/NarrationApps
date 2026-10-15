import XCTest
import Foundation
import Pronunciation
import NarrationCore

final class PronunciationTests: XCTestCase {
    private func rules(_ values: [(String, String)]) throws -> PronunciationDictionary {
        try .init(entries: values.map { .init(word: $0.0, spelling: $0.1) })
    }
    func testWholeWordsCaseUnicodeLiteralKeysAndNonrecursiveReplacement() throws {
        let dictionary = try rules([("read", "reed"), ("reed", "red"), ("New York", "noo york"), ("New", "noo"),
                                    ("C++", "see plus plus"), ("café", "cafay"), ("Straße", "strass uh")])
        XCTAssertEqual(try dictionary.applying(to: "READ reed reader bread New York New C++ café CAFE\u{301} STRASSE."),
                       "reed red reader bread noo york noo see plus plus cafay cafay strass uh.")
        XCTAssertEqual(try PronunciationDictionary.empty.applying(to: "Original text [12]."), "Original text [12].")
    }
    func testValidationAndStableFingerprint() throws {
        for (word, spelling) in [("", "test"), ("word", ""), ("word", "tɛst"), ("word", "123"), ("word", "test!"), ("a\nb", "test"), ("...", "test")] {
            XCTAssertThrowsError(try rules([(word, spelling)]))
        }
        XCTAssertThrowsError(try rules([("Read", "reed"), ("read", "red")]))
        XCTAssertThrowsError(try .init(entries: (0...500).map { PronunciationEntry(word: "word\($0)", spelling: "word") }) as PronunciationDictionary)
        let first = try rules([(" Read ", " reed "), ("book", "buk")])
        let second = try rules([("BOOK", "buk"), ("read", "reed")])
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertNotEqual(first.fingerprint, try rules([("read", "red"), ("book", "buk")]).fingerprint)
        XCTAssertEqual(PronunciationDictionary.empty.fingerprint, "")
    }
    func testPlannerAppliesOverridesBeforeChunkingAndRetainsOriginalProvenance() throws {
        let text = String(repeating: "SQLite ", count: 70)
        let document = SemanticDocument(blocks: [.init(kind: .paragraph, text: text)], extractorVersion: "fixture")
        let dictionary = try rules([("SQLite", "sequel lite")])
        let plan = try NarrationPlanner.prepare(document, pronunciations: dictionary)
        XCTAssertEqual(document.blocks[0].text, text)
        XCTAssertTrue(plan.chunks.allSatisfy { $0.text.unicodeScalars.count <= 480 && $0.blockIndices == [0] })
        XCTAssertFalse(plan.chunks.contains { $0.text.contains("SQLite") })
        XCTAssertEqual(plan.chunks.map(\.text).joined(separator: " ").split(separator: " ").count, 140)
        XCTAssertNotEqual(plan.version, NarrationPlanner.version)
        XCTAssertEqual(try NarrationPlanner.prepare(document).version, NarrationPlanner.version)
    }
    func testAtomicSharedStoreConflictsAndCorruptFilesPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = PronunciationStore(file: root.appendingPathComponent("overrides.json"))
        let second = PronunciationStore(file: first.file)
        XCTAssertNil(try first.load().revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let saved = try first.save(entries: [.init(word: "SQLite", spelling: "sequel lite")], expectedRevision: nil)
        XCTAssertEqual(try second.load().dictionary.fingerprint, saved.dictionary.fingerprint)
        XCTAssertThrowsError(try second.save(entries: [], expectedRevision: nil)) { XCTAssertEqual($0 as? PronunciationError, .conflict) }
        XCTAssertEqual(try first.load().dictionary.entries.count, 1)
        _ = try second.save(entries: [], expectedRevision: saved.revision)
        XCTAssertTrue(try first.load().dictionary.entries.isEmpty)
        let invalid = Data("not a dictionary".utf8)
        try invalid.write(to: first.file)
        XCTAssertThrowsError(try first.load())
        XCTAssertThrowsError(try second.save(entries: [], expectedRevision: nil))
        XCTAssertEqual(try Data(contentsOf: first.file), invalid)
    }
    func testStoreBoundsAndRepeatedReadsDoNotUseStaleFileSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PronunciationStore(file: root.appendingPathComponent("overrides.json"))
        _ = try store.save(entries: [], expectedRevision: nil)
        _ = try store.load()
        try Data(repeating: 32, count: 1_048_577).write(to: store.file)
        XCTAssertThrowsError(try store.load())
    }
}
