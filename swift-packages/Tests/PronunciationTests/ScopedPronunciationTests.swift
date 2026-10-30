import XCTest
@testable import Pronunciation

final class ScopedPronunciationTests: XCTestCase {
    func testScopePrecedenceLanguageAndModelIsolation() throws {
        let entries: [PronunciationEntry] = [
            .init(word: "Mina", spelling: "mee nah"),
            .init(word: "Mina", spelling: "my nah", documentTitle: "The station"),
            .init(word: "Mina", spelling: "mee na", language: "fr"),
            .init(word: "Mina", spelling: "mee naw", model: "qwen3")]
        let dictionary = try PronunciationDictionary(entries: entries)
        XCTAssertEqual(try dictionary.resolving(language: "en-US", documentTitle: "THE STATION", model: "qwen3").applying(to: "Mina"), "my nah")
        XCTAssertEqual(try dictionary.resolving(language: "en-US", documentTitle: nil, model: "qwen3").applying(to: "Mina"), "mee naw")
        XCTAssertEqual(try dictionary.resolving(language: "fr", documentTitle: nil, model: "qwen3").applying(to: "Mina"), "mee na")
        XCTAssertEqual(try dictionary.resolving(language: "ja", documentTitle: nil, model: "qwen3").applying(to: "Mina"), "Mina")
        XCTAssertEqual(try PronunciationDictionary(entries: entries.reversed()).fingerprint, dictionary.fingerprint)
        XCTAssertThrowsError(try PronunciationDictionary(entries: entries + [.init(word: "MINA", spelling: "other")]))
    }
    func testStoreMigrationAndPhonesRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PronunciationStore(file: root.appendingPathComponent("rules.json"))
        let legacy = try store.save(entries: [.init(word: "Mina", spelling: "mee nah")], expectedRevision: nil)
        let updated = try store.save(entries: [.init(word: "Mina", spelling: "", documentTitle: "Book", model: "kokoro", phonemes: "mina")], expectedRevision: legacy.revision)
        XCTAssertEqual(try store.load().dictionary.entries.first?.phonemes, "mina")
        XCTAssertThrowsError(try store.save(entries: [], expectedRevision: legacy.revision))
        XCTAssertNotEqual(updated.dictionary.fingerprint, legacy.dictionary.fingerprint)
        let decoded = try JSONDecoder().decode(PronunciationEntry.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","word":"Mina","spelling":"mee nah"}"#.utf8))
        XCTAssertNil(decoded.language); XCTAssertNil(decoded.phonemes)
        XCTAssertThrowsError(try PronunciationDictionary(entries: [.init(word: "Mina", spelling: "", model: "qwen3", phonemes: "mina")]))
    }
}
