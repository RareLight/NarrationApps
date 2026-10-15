import XCTest
import Pronunciation
@testable import NarrationCore

final class PreparedSpeechTests: XCTestCase {
    private func window(_ text: String, boundary: SpeechBoundary = .paragraph) -> SpeechTextWindow {
        .init(text: text, source: .init(blockIndices: [2], location: 40, length: text.utf16.count, origin: .ocr), boundaryAfter: boundary)
    }
    private func tokens(_ text: String, phones: (String) -> String = { $0 }) -> [AlignedPhonemeToken] {
        let ns = text as NSString
        return text.split(separator: " ").map(String.init).reduce(into: (result: [AlignedPhonemeToken](), offset: 0)) { state, word in
            let range = ns.range(of: word, range: NSRange(location: state.offset, length: ns.length - state.offset))
            state.result.append(.init(range: range, phonemes: phones(word), whitespace: NSMaxRange(range) == ns.length ? "" : " "))
            state.offset = NSMaxRange(range)
        }.result
    }
    func testActualTokenCountsAndSourceCoverageIgnoreSpeed() throws {
        let text = Array(repeating: "read", count: 80).joined(separator: " ")
        let pack = try PhonemeUtterancePacker.pack(window: window(text), tokens: tokens(text) { _ in "ɹˈid" }, vocabulary: Set(["ɹ", "ˈ", "i", "d", " "]), identity: "test")
        XCTAssertEqual(pack.map(\.text).joined(separator: " "), text)
        XCTAssertEqual(pack.count, 2)
        XCTAssertTrue(pack.allSatisfy { $0.tokenCount <= 200 })
        XCTAssertEqual(pack.last?.boundaryAfter, .paragraph)
        XCTAssertEqual(pack.first?.source.origin, .ocr)
        XCTAssertEqual(pack.first?.source.location, 40)
        for utterance in pack { try utterance.validate(identity: "test", prepared: true) }
    }
    func testUnsupportedSymbolsAndMissingAlignmentAreExplicitFailures() {
        let w = window("hello world")
        XCTAssertThrowsError(try PhonemeUtterancePacker.pack(window: w, tokens: tokens(w.text) { _ in "❓" }, vocabulary: ["h"], identity: "test"))
        XCTAssertThrowsError(try PhonemeUtterancePacker.pack(window: w, tokens: Array(tokens(w.text).dropLast()), vocabulary: Set(w.text.map(String.init)), identity: "test"))
    }
    func testIndivisibleOverLimitWordIsSourceLocatedAndNeverTruncated() {
        let w = window("word")
        XCTAssertThrowsError(try PhonemeUtterancePacker.pack(window: w, tokens: tokens(w.text) { _ in String(repeating: "a", count: 511) }, vocabulary: ["a"], identity: "test")) {
            let error = $0 as? SpeechPreparationError
            XCTAssertEqual(error?.source.location, 40)
            XCTAssertEqual(error?.source.blockIndices, [2])
        }
    }
    func testHardLimit510AndCombiningScalars() throws {
        let phones = String(repeating: "a", count: 508) + "ɔ\u{0303}"
        let result = try PhonemeUtterancePacker.pack(window: window("bonjour"), tokens: tokens("bonjour") { _ in phones }, vocabulary: ["a", "ɔ", "\u{0303}"], identity: "test")
        XCTAssertEqual(result.first?.tokenCount, 510)
        XCTAssertEqual(result.first?.phonemes, phones)
    }
    func testBoundedSentenceWindowsRetainUnicodeCoverageAndOrigin() throws {
        let text = "“Café is open.” " + Array(repeating: "Readers continue beside the river.", count: 90).joined(separator: " ")
        let plan = NarrationPlan(version: "test", chunks: [.init(index: 0, text: text, blockIndices: [5], boundaryAfter: .heading, origin: .authored)], notices: [])
        let windows = try SpeechTextWindows.make(from: plan)
        XCTAssertEqual(windows.map(\.text).joined(separator: " "), text)
        XCTAssertTrue(windows.allSatisfy { $0.text.unicodeScalars.count <= 1_000 && $0.source.blockIndices == [5] })
        XCTAssertEqual(windows.last?.boundaryAfter, .heading)
        for window in windows {
            XCTAssertEqual((text as NSString).substring(with: NSRange(location: window.source.location, length: window.source.length)), window.text)
        }
    }
    func testProjectionUsesCapturedRulesAndPreservesOriginalBlock() throws {
        let text = Array(repeating: "A quiet morning by the river.", count: 30).joined(separator: " ")
        let document = SemanticDocument(blocks: [.init(kind: .paragraph, text: text)], extractorVersion: "fixture")
        let preview = try NarrationPlanner.prepare(document)
        let projection = try NarrationPlanner.prepare(document, purpose: .speechPreparation)
        XCTAssertGreaterThan(preview.chunks.count, 1)
        XCTAssertEqual(projection.chunks.count, 1)
        XCTAssertEqual(projection.chunks.first?.text, text)
        XCTAssertEqual(document.blocks.first?.text, text)
        XCTAssertNotEqual(preview.version, projection.version)
    }
    func testLegacyPlanDecodesWithoutNewMetadataAndAcceptedPolicyIsDefault() throws {
        let data = Data(#"{"version":"old","chunks":[{"index":0,"text":"hello","blockIndices":[0]}],"notices":[]}"#.utf8)
        let plan = try JSONDecoder().decode(NarrationPlan.self, from: data)
        XCTAssertNil(plan.chunks.first?.boundaryAfter)
        XCTAssertEqual(SpeechPreparationPolicy.current, .longformPausesCandidate)
        XCTAssertEqual(SpeechPreparationPolicy.current.rawValue, "phoneme-200-pauses-candidate-1")
        XCTAssertTrue(SpeechPreparationPolicy.current.usesPreparedPhonemes)
        XCTAssertTrue(SpeechPreparationPolicy.current.usesStructuralPauses)
    }
    func testTamperedUtteranceIsRejected() throws {
        let utterance = PreparedUtterance(text: "word", phonemes: "a", tokenCount: 1, source: .init(blockIndices: [0], location: 0, length: 4), boundaryAfter: .paragraph, acousticIdentity: "identity")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(utterance)) as? [String: Any])
        object["phonemes"] = "b"
        let changed = try JSONDecoder().decode(PreparedUtterance.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try changed.validate(identity: "identity", prepared: true))
    }
}

extension PreparedSpeechTests {
    func testUserRuleRangesAndFootnoteOpeningSurviveProjectionAndPacking() throws {
        let dictionary = try PronunciationDictionary(entries: [.init(word: "SQLite", spelling: "sequel lite")])
        let document = SemanticDocument(blocks: [
            .init(kind: .paragraph, text: "SQLite is useful.", footnoteReferences: ["one"]),
            .init(kind: .footnote, text: "SQLite is pronounced using this dictionary.", footnoteID: "one")
        ], extractorVersion: "fixture")
        let plan = try NarrationPlanner.prepareForSpeech(document, settings: .init(), pronunciations: dictionary, policy: .longformCandidate)
        XCTAssertEqual(plan.chunks.filter { $0.text == "Footnote:" }.count, 0)
        XCTAssertTrue(plan.chunks.contains { $0.text.hasPrefix("Footnote: sequel lite") && $0.blockIndices.contains(1) })
        let windows = try SpeechTextWindows.make(from: plan)
        let applications = windows.flatMap { $0.source.pronunciationApplications ?? [] }
        XCTAssertEqual(applications.count, 2)
        XCTAssertTrue(applications.allSatisfy { $0.word == "SQLite" && $0.spelling == "sequel lite" })
        XCTAssertEqual(document.blocks[0].text, "SQLite is useful.")
        XCTAssertTrue(plan.version.contains(dictionary.fingerprint))
    }
}

extension PreparedSpeechTests {
    func testAnUnvoicedWordCannotDisappearInsideOtherwiseValidSpeech() {
        let w = window("silent spoken")
        let aligned: [AlignedPhonemeToken] = [
            .init(range: NSRange(location: 0, length: 6), phonemes: "", whitespace: " "),
            .init(range: NSRange(location: 7, length: 6), phonemes: "a", whitespace: "")
        ]
        XCTAssertThrowsError(try PhonemeUtterancePacker.pack(window: w, tokens: aligned, vocabulary: ["a", " "], identity: "test"))
    }
}
