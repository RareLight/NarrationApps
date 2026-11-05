import XCTest
import Pronunciation
@testable import NarrationCore

final class LiveSpeechFirstUnitTests: XCTestCase {
    private func window(_ text: String) -> SpeechTextWindow {
        .init(text: text, source: .init(blockIndices: [3], location: 20,
            length: text.utf16.count, origin: .authored,
            sourceMappings: [.init(source: .init(blockIndex: 3, location: 100, length: text.utf16.count),
                spokenLocation: 20, spokenLength: text.utf16.count)]), boundaryAfter: .paragraph)
    }
    func testCompleteFirstSentencePreservesUnicodeRangesAndMappings() throws {
        let original = window("🚀 Ready to go. Café opens next. A third sentence follows.")
        let parts = try LiveSpeechFirstUnit.split(original, language: "en")
        XCTAssertEqual(parts.map(\.text), ["🚀 Ready to go.", "Café opens next. A third sentence follows."])
        XCTAssertEqual(parts.map(\.boundaryAfter), [.sentence, .paragraph])
        for part in parts {
            let range = (original.text as NSString).range(of: part.text)
            XCTAssertEqual(part.source.location, 20 + range.location)
            XCTAssertEqual(part.source.length, range.length)
            XCTAssertEqual(part.source.blockIndices, [3])
            XCTAssertEqual(part.source.sourceMappings?.first?.source?.location, 100 + range.location)
        }
    }
    func testAbbreviationDoesNotManufactureAnInitialFragment() throws {
        let parts = try LiveSpeechFirstUnit.split(window("Dr. Rivera arrived at noon. The next observation follows."), language: "en")
        XCTAssertEqual(parts.first?.text, "Dr. Rivera arrived at noon.")
    }
    func testJapaneseSentenceBoundaryNeedsNoWhitespace() throws {
        let parts = try LiveSpeechFirstUnit.split(window("最初の文です。次の文です。"), language: "ja")
        XCTAssertEqual(parts.map(\.text), ["最初の文です。", "次の文です。"])
    }
    func testSingleIndivisibleSentenceRemainsUnchanged() throws {
        for text in ["One complete sentence.", "An indivisible phrase without terminal punctuation", ""] {
            let value = window(text)
            XCTAssertEqual(try LiveSpeechFirstUnit.split(value, language: "en"), [value])
        }
    }
    func testCrossingPronunciationOverrideKeepsOrdinaryWindow() throws {
        let text = "First sentence. Second sentence."
        let application = PronunciationApplication(word: text, spelling: text,
            sourceLocation: 0, sourceLength: text.utf16.count, spokenLocation: 20,
            spokenLength: text.utf16.count, phonemes: "a")
        let value = SpeechTextWindow(text: text, source: .init(blockIndices: [0], location: 20,
            length: text.utf16.count, pronunciationApplications: [application]), boundaryAfter: .paragraph)
        XCTAssertEqual(try LiveSpeechFirstUnit.split(value, language: "en"), [value])
    }
    func testNormalPlannerRemainsUnchangedAndSplitCoversAllSpokenText() throws {
        let text = "A quiet morning begins. The river passes under a bridge."
        let plan = try NarrationPlanner.prepareForSpeech(.init(blocks: [.init(kind: .paragraph, text: text, origin: .authored)], extractorVersion: "synthetic-first-unit-1"), settings: .init())
        let ordinary = try SpeechTextWindows.make(from: plan)
        let split = try LiveSpeechFirstUnit.split(ordinary[0], language: "en")
        XCTAssertEqual(try SpeechTextWindows.make(from: plan), ordinary)
        XCTAssertEqual(split.map(\.text).joined(separator: " "), text)
        XCTAssertEqual(LiveSpeechFirstUnit.version, "live-first-sentence-1")
    }
}
