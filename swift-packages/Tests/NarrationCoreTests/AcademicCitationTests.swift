import XCTest
@testable import NarrationCore

final class AcademicCitationTests: XCTestCase {
    private func document(_ blocks: [ContentBlock]) -> SemanticDocument { .init(blocks: blocks, extractorVersion: "independent-citation-fixture") }
    private func spoken(_ doc: SemanticDocument, _ options: NarrationOptions) throws -> String {
        try NarrationPlanner.prepare(doc, settings: .init(model: .soprano), options: options).chunks.map(\.text).joined(separator: " ")
    }
    func testInlineCitationsAreOptInAndRetainOrdinaryParenthesesAndNumbers() throws {
        let source = document([.init(kind: .paragraph, text: "Café 😀 grows (Rivera and Chen, 2020; Patel et al., 2021). Keep (that is, nearby), (2020), (n = 20), [12] and temperatures (20–30 °C).")])
        XCTAssertTrue(try spoken(source, .init()).contains("Rivera"))
        let text = try spoken(source, .init(stripInlineCitations: true))
        XCTAssertTrue(text.hasPrefix("Café 😀 grows.")); XCTAssertFalse(text.contains("Rivera"))
        for value in ["(that is, nearby)", "(2020)", "(n = 20)", "[12]", "(20–30 °C)"] { XCTAssertTrue(text.contains(value), value) }
        let plan = try NarrationPlanner.prepare(source, options: .init(stripInlineCitations: true))
        XCTAssertEqual(plan.omissions?.count, 1)
        XCTAssertTrue(plan.chunks.flatMap { $0.sourceMappings ?? [] }.contains { $0.rule == "academic-citation-1" && $0.spokenLength == 0 })
    }
    func testNumberedReferencesNeedAReferenceListAndPreserveSource() throws {
        let source = document([
            .init(kind: .paragraph, text: "The study [1–2] confirms this. The array [9] stays."),
            .init(kind: .heading, text: "References", headingLevel: 1),
            .init(kind: .paragraph, text: "[1] Rivera, A., 2020. Forest studies. Example Press."),
            .init(kind: .paragraph, text: "[2] Chen, B., 2021. Rock studies. Example Press."),
            .init(kind: .heading, text: "Appendix", headingLevel: 1),
            .init(kind: .paragraph, text: "Important appendix prose.")
        ])
        let original = source
        XCTAssertTrue(try spoken(source, .init(stripInlineCitations: true)).contains("Example Press"))
        let inline = try spoken(source, .init(stripInlineCitations: true))
        XCTAssertFalse(inline.contains("study [1–2]")); XCTAssertTrue(inline.contains("array [9]"))
        let endnotes = try spoken(source, .init(stripEndnoteCitations: true))
        XCTAssertTrue(endnotes.contains("study [1–2]")); XCTAssertFalse(endnotes.contains("Example Press"))
        XCTAssertTrue(endnotes.contains("Important appendix prose")); XCTAssertEqual(source, original)
    }
    func testEndnoteCitationsRetainExplanationsAndDoNotEmitEmptyFootnoteCues() throws {
        let source = document([
            .init(kind: .paragraph, text: "Body prose.", footnoteReferences: ["c", "e"]),
            .init(kind: .footnote, text: "Rivera, Ana. Forest Life (Example City: Example Press, 2020), 42.", footnoteID: "c"),
            .init(kind: .footnote, text: "A moraine is a ridge of material left by moving ice.", footnoteID: "e"),
            .init(kind: .footnote, text: "Rivera, Ana. This is an explanation with a source (Example City: Example Press, 2020)."),
            .init(kind: .paragraph, text: "A marked bibliography entry.", role: .bibliography)
        ])
        let value = try spoken(source, .init(stripEndnoteCitations: true))
        XCTAssertFalse(value.contains("Forest Life")); XCTAssertFalse(value.contains("bibliography"))
        XCTAssertTrue(value.contains("moraine")); XCTAssertTrue(value.contains("This is an explanation"))
        XCTAssertEqual(value.components(separatedBy: "Footnote:").count - 1, 2)
    }
    func testCodeAndUnverifiedReferenceHeadingsDoNotLoseText() throws {
        let source = document([
            .init(kind: .code, text: "array[1] (Rivera, 2020)"),
            .init(kind: .paragraph, text: "Code (Rivera, 2020) stays.", containsInlineCode: true),
            .init(kind: .heading, text: "References"),
            .init(kind: .paragraph, text: "References are important to understanding this explanation.")
        ])
        let value = try spoken(source, .init(stripInlineCitations: true, stripEndnoteCitations: true))
        XCTAssertTrue(value.contains("Code (Rivera, 2020) stays")); XCTAssertTrue(value.contains("understanding this explanation"))
    }
    func testUnmarkedReferenceListCannotConsumeFollowingAcknowledgmentOrNextChapter() throws {
        let first = "Body text.\nReferences cited\nRivera, A., 2020, Forest studies.\nChen, B., 2021, Rock studies.\n1 • JOURNAL\nPatel, C., 2022, Another reference.\nLin, D., 2023, A final reference.\nThank you to the volunteers who contributed observations.\n"
        var offset = 0
        let lines = first.split(separator: "\n").enumerated().map { index, line -> PDFTextLine in
            let length = line.utf16.count + 1
            defer { offset += length }
            return .init(location: offset, length: length, bounds: .init(x: index >= 5 ? 0.55 : 0.1,
                y: [0.8, 0.7, 0.66, 0.62, 0.03, 0.85, 0.81, 0.65][index], width: 0.34, height: 0.02))
        }
        let source = document([
            .init(kind: .paragraph, text: first, pdfPageIndex: 0, origin: .authored, pdfLayout: .init(basis: .cropBox, lines: lines)),
            .init(kind: .paragraph, text: "NEW CHAPTER\nA new chapter explains the study of forests in 2020.\n", pdfPageIndex: 1, origin: .authored)
        ])
        let value = try spoken(source, .init(stripEndnoteCitations: true))
        XCTAssertFalse(value.contains("Forest studies")); XCTAssertFalse(value.contains("Rock studies"))
        XCTAssertFalse(value.contains("Another reference")); XCTAssertFalse(value.contains("A final reference"))
        XCTAssertTrue(value.contains("Thank you to the volunteers")); XCTAssertTrue(value.contains("new chapter explains"))
    }
    func testLegacyDefaultsAndRoundTripDoNotChangeAcousticIdentity() throws {
        let legacy = try JSONDecoder().decode(NarrationOptions.self, from: Data(#"{"notes":"current","includeAuxiliary":true}"#.utf8))
        XCTAssertFalse(legacy.stripInlineCitations); XCTAssertFalse(legacy.stripEndnoteCitations)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        XCTAssertNil(encoded["stripInlineCitations"]); XCTAssertNil(encoded["stripEndnoteCitations"])
        let selected = NarrationOptions(stripInlineCitations: true, stripEndnoteCitations: true)
        XCTAssertEqual(try JSONDecoder().decode(NarrationOptions.self, from: JSONEncoder().encode(selected)), selected)
        XCTAssertEqual(NarrationPlanner.chunkFingerprintVersion(NarrationPlanner.version(settings: .init(), options: legacy)),
            NarrationPlanner.chunkFingerprintVersion(NarrationPlanner.version(settings: .init(), options: selected)))
    }
}
