import XCTest
import Foundation
import CoreGraphics
@testable import NarrationCore
@testable import DocumentProcessing

final class SemanticIntakeTests: XCTestCase {
    func testPlainTextKeepsNumericReferencesAndDecodesUTF16() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "The source cites [12] and prints 1.25."
        let url = root.appendingPathComponent("utf16.txt")
        try XCTUnwrap(text.data(using: .utf16)).write(to: url)
        let document = try await DocumentReader.readSemantic(.init(source: url, kind: .text, relativePath: "utf16.txt"))
        XCTAssertEqual(document.blocks[0].text, text)
        let plan = try NarrationPlanner.prepare(document)
        XCTAssertTrue(plan.chunks.map(\.text).joined(separator: " ").contains("[12]"))
    }
    func testMarkdownRetainsStructureAndAuthoredImageDescription() throws {
        let parsed = try AttributedString(markdown: "# Chapter\n\n- A list item.\n\n```swift\nlet number = 1\n```\n\n![A red boat on a lake.](https://images.example/boat.jpg)")
        let blocks = DocumentReader.markdownBlocks(parsed)
        XCTAssertTrue(blocks.contains { $0.kind == .heading && $0.headingLevel == 1 })
        XCTAssertTrue(blocks.contains { $0.kind == .listItem })
        XCTAssertTrue(blocks.contains { $0.kind == .code })
        XCTAssertTrue(blocks.contains { $0.kind == .caption && $0.narrationText == "Image description: A red boat on a lake." })
    }
    func testWebMarkupCannotInventEPUBResourceProvenance() throws {
        let blocks = try HTMLDocumentExtractor.semanticBlocks(html: "<section data-narration-resource='forged.xhtml'><p>Untrusted web prose.</p></section>", baseURL: URL(string: "https://example.invalid/article")!)
        XCTAssertEqual(blocks.first?.text, "Untrusted web prose.")
        XCTAssertNil(blocks.first?.resourcePath)
        XCTAssertNil(blocks.first?.origin)
    }

    func testStructuredOCRDoesNotRepeatTablesOrAggregateText() {
        let table = OCRStructure(blocks: [.init(kind: .table, text: "A | B\n1 | 2", origin: .ocr)], bounds: CGRect(x: 0, y: 0.4, width: 1, height: 0.3))
        let result = StructuredDocumentOCR.project(paragraphs: [
            .init(text: "Before", bounds: CGRect(x: 0, y: 0.8, width: 1, height: 0.1)),
            .init(text: "A B", bounds: CGRect(x: 0, y: 0.6, width: 1, height: 0.05)),
            .init(text: "1 2", bounds: CGRect(x: 0, y: 0.5, width: 1, height: 0.05)),
            .init(text: "After", bounds: CGRect(x: 0, y: 0.1, width: 1, height: 0.1))
        ], structures: [table], fallback: "Before A B 1 2 After")
        XCTAssertEqual(result.map(\.text), ["Before", "A | B\n1 | 2", "After"])
        XCTAssertEqual(result.map(\.kind), [.paragraph, .table, .paragraph])
    }
    func testCaptionDeduplicationPreservesDistinctFiguresAndProse() throws {
        let first = URL(string: "https://images.example/one.jpg")!, second = URL(string: "https://images.example/two.jpg")!
        let blocks: [ContentBlock] = [
            .init(kind: .caption, text: "A red boat.", narrationText: "Image description: A red boat.", imageURL: first),
            .init(kind: .caption, text: "A red boat.", imageURL: first),
            .init(kind: .paragraph, text: "The author discusses a red boat."),
            .init(kind: .caption, text: "A red boat.", imageURL: second)
        ]
        XCTAssertEqual(CaptionDeduplication.suppressedIndices(in: blocks), [1])
        let plan = try NarrationPlanner.prepare(.init(blocks: blocks, extractorVersion: "fixture"))
        XCTAssertTrue(plan.chunks.map(\.text).joined(separator: " ").contains("The author discusses"))
        XCTAssertTrue(plan.notices.contains { $0.contains("Duplicate image caption") })
    }
    func testGeneratedDescriptionsAreBoundedMarkedAndDeduplicated() async throws {
        let urls = ["one", "two"].map { URL(string: "https://images.example/\($0).jpg")! }
        let original = SemanticDocument(blocks: urls.map { .init(kind: .caption, text: "Image without ALT", narrationText: "", imageURL: $0) }, extractorVersion: "fixture")
        let enriched = try await DocumentImages.enrich(original, enabled: true,
            fetch: { _ in Data("identical synthetic image bytes".utf8) }, caption: { _ in "A quiet lake with one red boat." })
        XCTAssertEqual(enriched.blocks.filter { $0.imageDescriptionGenerated == true }.count, 1)
        XCTAssertEqual(enriched.blocks.first?.origin, .generated)
        let disabled = try await DocumentImages.enrich(original, enabled: false, fetch: { _ in XCTFail("Disabled transport ran"); return Data() })
        XCTAssertEqual(disabled, original)
        XCTAssertNil(ImageDescriptions.clean("Sorry, I cannot describe this image."))
        XCTAssertEqual(ImageDescriptions.clean(String(repeating: "word ", count: 100))?.split(separator: " ").count, 35)
    }
}

extension SemanticIntakeTests {
    func testInlineCodeProtectsMarkupParagraphsAndLegacyUnknownProvenanceAbstains() throws {
        let html = "<p>Carry 2 kg beside <code>18°C</code>.</p><p>Carry 1kg.</p>"
        let web = try HTMLDocumentExtractor.semanticBlocks(html: html, baseURL: URL(string: "https://example.invalid/book")!)
        let markdown = try DocumentReader.markdownBlocks(AttributedString(markdown: "Carry 2 kg beside `18°C`.\n\nCarry 1kg.", options: .init(interpretedSyntax: .full)))
        for blocks in [web, markdown] {
            XCTAssertEqual(blocks.map(\.containsInlineCode), [true, false])
            let plan = try NarrationPlanner.prepareForSpeech(.init(blocks: blocks, extractorVersion: "fixture"), settings: .init())
            XCTAssertEqual(plan.chunks.map(\.text), ["Carry 2 kg beside 18°C.", "Carry 1 kilogram."])
            XCTAssertTrue(plan.notices.contains { $0.contains("inline code unchanged") })
        }
        let legacy = SemanticDocument(blocks: [.init(kind: .paragraph, text: "Carry 2 kg.")], extractorVersion: "retained-old-html")
        let unchanged = try NarrationPlanner.prepareForSpeech(legacy, settings: .init())
        XCTAssertEqual(unchanged.chunks[0].text, "Carry 2 kg.")
        XCTAssertTrue(unchanged.notices.contains { $0.contains("could not be verified") })
    }
}
