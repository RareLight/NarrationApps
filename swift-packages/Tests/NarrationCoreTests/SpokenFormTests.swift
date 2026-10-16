import Foundation
import XCTest
import Pronunciation
@testable import NarrationCore

final class SpokenFormTests: XCTestCase {
    func testConcreteSpokenFormsInBothRegionsWithoutUnitConversion() throws {
        let cases = [("Carry 2.4 kg.", "Carry 2.4 kilograms."), ("Carry 1kg.", "Carry 1 kilogram."),
                     ("It is 18°C.", "It is 18 degrees Celsius."), ("It is −4 °F.", "It is minus 4 degrees Fahrenheit."),
                     ("Meet at 9:30 am.", "Meet at 9 30 a.m."), ("Meet at 9:05 PM.", "Meet at 9 oh 5 p.m."),
                     ("Meet at 12:00 pm.", "Meet at 12 p.m.")]
        for voice in ["af_heart", "bf_emma"] {
            for (source, expected) in cases {
                let document = SemanticDocument(blocks: [.init(kind: .paragraph, text: source, origin: .authored)], extractorVersion: "fixture")
                let plan = try NarrationPlanner.prepareForSpeech(document, settings: .init(voice: voice))
                XCTAssertEqual(plan.chunks.map(\.text).joined(separator: " "), expected)
                XCTAssertEqual(document.blocks[0].text, source)
            }
        }
    }
}

extension SpokenFormTests {
    private func document(_ text: String, kind: ContentBlock.Kind = .paragraph) -> SemanticDocument {
        .init(blocks: [.init(kind: kind, text: text, origin: .authored, resourcePath: "EPUB/chapter.xhtml")], extractorVersion: "fixture")
    }
    func testAdversarialNonmatchesAndSopranoStayUnchanged() throws {
        for text in ["https://example.org/2kg", "version2.4kg", "2kg/day", "x = 2 kg", "2 kg = x", "x × 2kg", "1/2kg", "1,2kg", "18C", "18 °Celsius", "1e3kg", "1.2.3kg", "12:75 am", "00:30 pm", "13:30 am", "9:30", "`2 kg`", "reader@2kg.example", #"C:\books\2kg"#, "2 kg + 3 kg", "x * 2kg"] {
            let plan = try NarrationPlanner.prepareForSpeech(document(text), settings: .init())
            XCTAssertEqual(plan.chunks.map(\.text).joined(separator: " "), text, text)
            XCTAssertNil(plan.chunks.first?.sourceMappings)
        }
        let soprano = try NarrationPlanner.prepareForSpeech(document("Carry 2.4 kg at 18°C before 9:30 am."), settings: .init(model: .soprano))
        XCTAssertEqual(soprano.chunks.map(\.text).joined(separator: " "), "Carry 2.4 kg at 18°C before 9:30 am.")
        XCTAssertFalse(soprano.version.contains("spoken-forms"))
        XCTAssertNil(soprano.chunks.first?.sourceMappings)
        let code = try NarrationPlanner.prepareForSpeech(document("2 kg at 18°C", kind: .code), settings: .init())
        XCTAssertEqual(code.chunks.first?.text, "Code block omitted from narration.")
    }
    func testUserSpansWinAndOffsetsComposeAcrossAutomaticEdits() throws {
        let dictionary = try PronunciationDictionary(entries: [.init(word: "SQLite", spelling: "sequel lite"), .init(word: "foo", spelling: "kg")])
        let text = "Carry 2 kg beside SQLite and 2 foo."
        let plan = try NarrationPlanner.prepareForSpeech(document(text), settings: .init(), pronunciations: dictionary)
        let chunk = try XCTUnwrap(plan.chunks.first)
        XCTAssertEqual(chunk.text, "Carry 2 kilograms beside sequel lite and 2 kg.")
        let sqlite = try XCTUnwrap(chunk.pronunciationApplications?.first)
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: sqlite.sourceLocation, length: sqlite.sourceLength)), "SQLite")
        XCTAssertEqual((chunk.text as NSString).substring(with: NSRange(location: sqlite.spokenLocation, length: sqlite.spokenLength)), "sequel lite")
        let maps = try XCTUnwrap(chunk.sourceMappings)
        let quantity = try XCTUnwrap(maps.first { $0.rule == "quantity-kg-1" })
        let source = try XCTUnwrap(quantity.source)
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: source.location, length: source.length)), "2 kg")
        XCTAssertEqual((chunk.text as NSString).substring(with: NSRange(location: quantity.spokenLocation, length: quantity.spokenLength)), "2 kilograms")
        XCTAssertEqual(maps.filter { $0.rule == "quantity-kg-1" }.count, 1)
    }
    func testUnicodeWhitespaceNotesAndGeneratedPrefixKeepHonestOriginalCoordinates() throws {
        let raw = "  Cafe\u{0301} 😀 2.4\tkg [1] end."
        let block = ContentBlock(kind: .paragraph, text: raw, narrationText: "Cafe\u{0301} 😀 2.4 kg end.", footnoteReferences: ["one"], origin: .authored)
        let dictionary = try PronunciationDictionary(entries: [.init(word: "unmatched", spelling: "un matched")])
        let plan = try NarrationPlanner.prepareForSpeech(.init(blocks: [block], extractorVersion: "fixture"), settings: .init(), pronunciations: dictionary)
        let chunk = try XCTUnwrap(plan.chunks.first)
        XCTAssertEqual(chunk.text, "Café 😀 2.4 kilograms end.")
        let quantity = try XCTUnwrap(chunk.sourceMappings?.first { $0.rule == "quantity-kg-1" })
        let source = try XCTUnwrap(quantity.source)
        XCTAssertEqual((raw as NSString).substring(with: NSRange(location: source.location, length: source.length)), "2.4\tkg")
        XCTAssertTrue(chunk.sourceMappings?.contains { $0.rule == "canonical-unicode-1" } == true)
        let caption = SemanticDocument(blocks: [.init(kind: .caption, text: "2 kg", narrationText: "Image description: 2 kg", origin: .authored)], extractorVersion: "fixture")
        let rendered = try NarrationPlanner.prepareForSpeech(caption, settings: .init()).chunks[0]
        XCTAssertEqual(rendered.text, "Image description: 2 kilograms")
        XCTAssertTrue(rendered.sourceMappings?.contains { $0.source == nil && $0.rule == "generated-cue-1" } == true)
        let unknown = SemanticDocument(blocks: [.init(kind: .paragraph, text: "Different source.", narrationText: "Carry 2 kg.")], extractorVersion: "fixture")
        let untouched = try NarrationPlanner.prepareForSpeech(unknown, settings: .init())
        XCTAssertEqual(untouched.chunks[0].text, "Carry 2 kg.")
        XCTAssertTrue(untouched.notices.contains { $0.contains("could not be verified") })
    }
    func testPreviewSpeechWindowsAndPackingShareChangesAndCoverUnicode() throws {
        let text = String(repeating: "😀 Carry 2.4 kg at 18°C before 9:05 pm. ", count: 50)
        let original = document(text)
        let preview = try NarrationPlanner.prepare(original)
        let speech = try NarrationPlanner.prepareForSpeech(original, settings: .init())
        XCTAssertEqual(preview.chunks.map(\.text).joined(separator: " "), speech.chunks[0].text)
        XCTAssertEqual(preview.notices, speech.notices)
        XCTAssertTrue(speech.version.contains("spoken-forms-2-en_US"))
        for window in try SpeechTextWindows.make(from: speech) {
            XCTAssertLessThanOrEqual(window.text.unicodeScalars.count, 1000)
            let mappings = try XCTUnwrap(window.source.sourceMappings)
            var end = window.source.location
            for value in mappings where value.spokenLength > 0 {
                XCTAssertEqual(value.spokenLocation, end)
                end += value.spokenLength
                if let source = value.source {
                    XCTAssertEqual(source.blockIndex, 0)
                    XCTAssertLessThanOrEqual(source.location + source.length, text.utf16.count)
                    XCTAssertNotNil(Range(NSRange(location: source.location, length: source.length), in: text))
                }
            }
            XCTAssertEqual(end, window.source.location + window.source.length)
        }
        let retained = try JSONDecoder().decode(NarrationPlan.self, from: JSONEncoder().encode(speech))
        XCTAssertEqual(retained, speech)
        XCTAssertEqual(original.blocks[0].text, text)
    }
    func testNegativeFractionsZerosAndExactUnitValues() throws {
        for (source, expected) in [("-4 °F", "minus 4 degrees Fahrenheit"), ("−0.5°C", "minus 0.5 degrees Celsius"), ("1.00 kg", "1.00 kilograms"), ("2.400001kg", "2.400001 kilograms"), ("0kg", "0 kilograms")] {
            XCTAssertEqual(try NarrationPlanner.prepareForSpeech(document(source), settings: .init()).chunks[0].text, expected)
        }
    }
    func testCancellationIsObservedAndNoChangePathHasNoMappingPayload() async throws {
        let input = document(String(repeating: "Carry 2 kg. ", count: 10000))
        let task = Task { try NarrationPlanner.prepareForSpeech(input, settings: .init()) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled projection completed") } catch is CancellationError { }
        let untouched = try NarrationPlanner.prepareForSpeech(document("A quiet ordinary paragraph."), settings: .init())
        XCTAssertNil(untouched.chunks.first?.sourceMappings)
    }
}

extension SpokenFormTests {
    func testCandidateBudgetRejectsPathologicalDensityWithoutPartialOutput() {
        let input = document(String(repeating: "2kg ", count: 100_001))
        XCTAssertThrowsError(try NarrationPlanner.prepareForSpeech(input, settings: .init())) {
            XCTAssertTrue($0.localizedDescription.contains("candidate budget"))
        }
    }
}

extension SpokenFormTests {
    func testFormatterPrecisionDoesNotLeakBetweenQuantitiesWithinAJob() throws {
        let source = "Carry 2.4 kg, 1kg, 18°C, −4°F, 1.00kg and 2kg."
        let expected = "Carry 2.4 kilograms, 1 kilogram, 18 degrees Celsius, minus 4 degrees Fahrenheit, 1.00 kilograms and 2 kilograms."
        for voice in ["af_heart", "bf_emma"] {
            XCTAssertEqual(try NarrationPlanner.prepareForSpeech(document(source), settings: .init(voice: voice)).chunks[0].text, expected)
        }
    }
}

extension SpokenFormTests {
    func testGeneratedNoteCuesCannotBypassTheWholePlanMappingBudget() {
        let blocks = (0..<33_334).map { ContentBlock(kind: .footnote, text: "2kg", footnoteID: "note-\($0)", origin: .authored) }
        XCTAssertThrowsError(try NarrationPlanner.prepareForSpeech(.init(blocks: blocks, extractorVersion: "fixture"), settings: .init())) {
            XCTAssertTrue($0.localizedDescription.contains("after cue composition"))
        }
    }
}


extension SpokenFormTests {
    func testExplicitCapitalLetterALabelsPreserveSourceAndArticlePronunciation() throws {
        let source = "Package A weighs 2.4 kg; package B weighs 1kg. Plan A failed. A car carries a book."
        let expected = "Package ay weighs 2.4 kilograms; package B weighs 1 kilogram. Plan ay failed. A car carries a book."
        for voice in ["af_heart", "am_michael", "bf_emma"] {
            let original = document(source)
            let speech = try NarrationPlanner.prepareForSpeech(original, settings: .init(voice: voice))
            let chunk = try XCTUnwrap(speech.chunks.first)
            XCTAssertEqual(chunk.text, expected)
            XCTAssertEqual(original.blocks[0].text, source)
            let labels = try XCTUnwrap(chunk.sourceMappings).filter { $0.rule == "letter-label-a-1" }
            XCTAssertEqual(labels.count, 2)
            for label in labels {
                let origin = try XCTUnwrap(label.source)
                XCTAssertEqual((source as NSString).substring(with: NSRange(location: origin.location, length: origin.length)), "A")
                XCTAssertEqual((chunk.text as NSString).substring(with: NSRange(location: label.spokenLocation, length: label.spokenLength)), "ay")
            }
            XCTAssertEqual(try NarrationPlanner.prepare(original, settings: .init(voice: voice)).chunks.map(\.text).joined(separator: " "), expected)
        }
        for context in ["option", "appendix", "section", "figure", "table", "part", "group", "class", "type", "grade", "vitamin", "letter"] {
            XCTAssertEqual(try NarrationPlanner.prepareForSpeech(document("\(context) A."), settings: .init()).chunks[0].text, "\(context) ay.")
        }
    }
    func testLetterLabelsAbstainInArticlesIdentifiersCodeAndUserOverrides() throws {
        for source in ["A car and a book.", "A quiet ordinary paragraph.", "I package a book.", "Package Apple.", "Package AB.", "Package A1.", "Package A-file.", "Package A.B.", "Package A.1.", "Package A's contents.", "Repackage A.", "`Package A`", "https://example.org/Package A", "x = Package A"] {
            let speech = try NarrationPlanner.prepareForSpeech(document(source), settings: .init())
            XCTAssertEqual(speech.chunks[0].text, source)
            XCTAssertNil(speech.chunks[0].sourceMappings)
        }
        let dictionary = try PronunciationDictionary(entries: [.init(word: "A", spelling: "alpha")])
        let speech = try NarrationPlanner.prepareForSpeech(document("Package A weighs 2 kg."), settings: .init(), pronunciations: dictionary)
        XCTAssertEqual(speech.chunks[0].text, "Package alpha weighs 2 kilograms.")
        XCTAssertFalse(speech.chunks[0].sourceMappings?.contains { $0.rule == "letter-label-a-1" } == true)
        let soprano = try NarrationPlanner.prepareForSpeech(document("Package A weighs 2 kg."), settings: .init(model: .soprano))
        XCTAssertEqual(soprano.chunks[0].text, "Package A weighs 2 kg.")
        let code = SemanticDocument(blocks: [.init(kind: .paragraph, text: "Package A", origin: .authored, containsInlineCode: true)], extractorVersion: "fixture")
        XCTAssertEqual(try NarrationPlanner.prepareForSpeech(code, settings: .init()).chunks[0].text, "Package A")
    }
    func testSpokenFormUpgradeRetainsUnchangedChunkIdentity() {
        for locale in ["en_US", "en_GB"] {
            XCTAssertEqual(NarrationPlanner.chunkFingerprintVersion(NarrationPlanner.version + "/spoken-forms-1-" + locale), NarrationPlanner.chunkFingerprintVersion(NarrationPlanner.version + "/spoken-forms-2-" + locale))
        }
    }
}
