import XCTest
@testable import NarrationCore

final class NarrationOptionsTests: XCTestCase {
    private var document: SemanticDocument {
        .init(blocks: [
            .init(kind: .paragraph, text: "First body paragraph.", footnoteReferences: ["n"]),
            .init(kind: .footnote, text: "An explanatory note.", footnoteID: "n"),
            .init(kind: .paragraph, text: "Last body paragraph."),
            .init(kind: .paragraph, text: "An explicit appendix.", role: .auxiliary),
            .init(kind: .paragraph, text: "A bibliography entry.", role: .bibliography)
        ], extractorVersion: "synthetic")
    }
    func testNotePlacementAndOmissionPreserveSourceAndBibliography() throws {
        let original = document
        let current = try NarrationPlanner.prepare(document).chunks.map(\.text).joined(separator: " ")
        XCTAssertLessThan(current.range(of: "explanatory")!.lowerBound, current.range(of: "Last body")!.lowerBound)
        let end = try NarrationPlanner.prepare(document, options: .init(notes: .endOfDocument)).chunks.map(\.text).joined(separator: " ")
        XCTAssertLessThan(end.range(of: "Last body")!.lowerBound, end.range(of: "explanatory")!.lowerBound)
        XCTAssertEqual(end.components(separatedBy: "An explanatory note.").count - 1, 1)
        let omitted = try NarrationPlanner.prepare(document, options: .init(notes: .omit, includeAuxiliary: false))
        let text = omitted.chunks.map(\.text).joined(separator: " ")
        XCTAssertFalse(text.contains("explanatory")); XCTAssertFalse(text.contains("appendix"))
        XCTAssertTrue(text.contains("bibliography")); XCTAssertEqual(document, original)
        XCTAssertEqual(omitted.omissions?.map { $0.source.blockIndex }, [1, 3])
        XCTAssertEqual(omitted.omissions?.first?.source.length, document.blocks[1].text.utf16.count)
        XCTAssertNil(omitted.omissions?.first?.pageIndex)
        XCTAssertEqual(NarrationPlanner.chunkFingerprintVersion(omitted.version), NarrationPlanner.chunkFingerprintVersion(try NarrationPlanner.prepare(document).version))
    }
    func testLocalHeadingDedupDoesNotSuppressOtherChaptersOrDistinctAnchors() throws {
        let source = SemanticDocument(blocks: [
            .init(kind: .heading, text: "Introduction", headingLevel: 1, resourcePath: "one"),
            .init(kind: .heading, text: "Introduction", headingLevel: 1, resourcePath: "one"),
            .init(kind: .paragraph, text: "Body prose."),
            .init(kind: .heading, text: "Introduction", headingLevel: 1, resourcePath: "two"),
            .init(kind: .heading, text: "Introduction", headingLevel: 1, resourcePath: "two", sourceID: "different"),
            .init(kind: .quote, text: "Introduction")
        ], extractorVersion: "synthetic")
        let plan = try NarrationPlanner.prepare(source)
        XCTAssertEqual(plan.omissions?.map { $0.source.blockIndex }, [1])
        XCTAssertEqual(source.blocks.count, 6)
        XCTAssertEqual(plan.chunks.map(\.text).filter { $0 == "Introduction" }.count, 4)
    }
    func testStandaloneNotesAndUnmarkedProseRemainWellDefined() throws {
        let source = SemanticDocument(blocks: [.init(kind: .footnote, text: "Standalone note."), .init(kind: .paragraph, text: "References are discussed in this paragraph.")], extractorVersion: "synthetic")
        let plan = try NarrationPlanner.prepare(source, options: .init(notes: .omit, includeAuxiliary: false))
        XCTAssertEqual(plan.chunks.map(\.text), ["References are discussed in this paragraph."])
        let old = Data("{\"title\":\"Old\",\"blocks\":[],\"warnings\":[],\"extractorVersion\":\"old\"}".utf8)
        XCTAssertNil(try JSONDecoder().decode(SemanticDocument.self, from: old).outline)
    }
}
