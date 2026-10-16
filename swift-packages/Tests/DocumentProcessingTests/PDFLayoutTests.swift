import Foundation
import CoreGraphics
import CoreText
import PDFKit
import XCTest
import NarrationCore
@testable import DocumentProcessing

final class PDFLayoutTests: XCTestCase {
    static func fixture(pages: Int = 6) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: "Synthetic running header"] as CFDictionary))
        for page in 0..<pages {
            context.beginPDFPage(nil)
            for (y, text) in [(750.0, "Synthetic running header"),
                              (680.0, "Page \(page + 1) begins a carefully authored body paragraph."),
                              (660.0, "Repeated body prose must survive on every page."),
                              (640.0, "The final line ends this paragraph with café and [12]."), (30.0, "\(page + 1)")] {
                context.textPosition = CGPoint(x: 60, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil)])), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
    func testNativeDigitalGeometryRetainsSourceOrderAndAvoidsOCR() async throws {
        let data = try Self.fixture()
        let native = try XCTUnwrap(PDFDocument(data: data))
        let result = try await PDFDocumentExtractor.extract(data: data, recognize: { _ in XCTFail("Usable embedded text must not invoke OCR"); return [] })
        XCTAssertEqual(result.blocks.count, 6)
        for (index, block) in result.blocks.enumerated() {
            XCTAssertEqual(block.text, native.page(at: index)?.string)
            XCTAssertEqual(block.pdfPageIndex, index)
            let layout = try XCTUnwrap(block.pdfLayout)
            XCTAssertEqual(layout.lines.count, 5)
            XCTAssertEqual(layout.basis, .cropBox)
            for line in layout.lines {
                XCTAssertTrue(line.bounds.isValid)
                XCTAssertNotNil(Range(NSRange(location: line.location, length: line.length), in: block.text))
            }
            XCTAssertGreaterThan(layout.lines[0].bounds.y, 0.9)
            XCTAssertLessThan(layout.lines.last!.bounds.y + layout.lines.last!.bounds.height, 0.08)
        }
        XCTAssertEqual(try JSONDecoder().decode(SemanticDocument.self, from: JSONEncoder().encode(result)), result)
    }
    func testCropAndRotationCoordinatesAndUnreconciledGeometryAbstain() throws {
        let crop = CGRect(x: 20, y: 10, width: 100, height: 200)
        let rect = CGRect(x: 30, y: 150, width: 30, height: 20)
        let expected = [(0, 0.1, 0.7, 0.3, 0.1), (90, 0.7, 0.6, 0.1, 0.3), (180, 0.6, 0.2, 0.3, 0.1), (270, 0.2, 0.1, 0.1, 0.3)]
        for (rotation, x, y, width, height) in expected {
            let bounds = try XCTUnwrap(PDFTextGeometry.normalized(rect, crop: crop, rotation: rotation))
            XCTAssertEqual(bounds.x, x, accuracy: 0.000001); XCTAssertEqual(bounds.y, y, accuracy: 0.000001)
            XCTAssertEqual(bounds.width, width, accuracy: 0.000001); XCTAssertEqual(bounds.height, height, accuracy: 0.000001)
        }
        XCTAssertNil(PDFTextGeometry.normalized(rect, crop: .zero, rotation: 0))
        let page = try XCTUnwrap(PDFDocument(data: Self.fixture(pages: 1))?.page(at: 0))
        XCTAssertNil(try PDFTextGeometry.capture(page: page, text: "Different text", blocks: [], remaining: 100))
        XCTAssertNil(try PDFTextGeometry.capture(page: page, text: page.string!, blocks: [], remaining: 0))
    }
    func testOCRGeometryAndLegacyArtifactsStayCompatible() throws {
        let blocks = StructuredDocumentOCR.project(paragraphs: [.init(text: "OCR paragraph.", bounds: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.1))], structures: [], fallback: "")
        XCTAssertEqual(blocks[0].pdfLayout?.basis, .image)
        XCTAssertEqual(blocks[0].pdfLayout?.lines[0].length, "OCR paragraph.".utf16.count)
        let legacy = try JSONDecoder().decode(ContentBlock.self, from: Data(#"{"kind":"paragraph","text":"Legacy."}"#.utf8))
        XCTAssertNil(legacy.pdfLayout)
    }
}

extension PDFLayoutTests {
    func testRecurringMarginsHaveSourceOmissionsWhileAllBodyProseSurvives() async throws {
        let document = try await PDFDocumentExtractor.extract(data: Self.fixture())
        let plan = try NarrationPlanner.prepareForSpeech(document, settings: .init())
        XCTAssertEqual(plan.omissions?.count, 12)
        XCTAssertFalse(plan.chunks.map(\.text).joined().contains("Synthetic running header"))
        for page in 1...6 {
            XCTAssertTrue(plan.chunks[page - 1].text.hasPrefix("Page \(page) begins"))
            XCTAssertTrue(plan.chunks[page - 1].text.contains("Repeated body prose must survive"))
            XCTAssertTrue(plan.chunks[page - 1].text.hasSuffix("café and [12]."))
        }
        for omission in plan.omissions ?? [] {
            let source = document.blocks[omission.source.blockIndex].text as NSString
            let original = source.substring(with: .init(location: omission.source.location, length: omission.source.length))
            XCTAssertTrue(original.contains("Synthetic running header") || Int(original.trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
        }
        XCTAssertTrue(plan.chunks.allSatisfy { $0.sourceMappings?.contains { $0.rule == "pdf-recurring-margin-1" && $0.spokenLength == 0 } == true })
        XCTAssertEqual(try JSONDecoder().decode(NarrationPlan.self, from: JSONEncoder().encode(plan)), plan)
        XCTAssertEqual(try NarrationPlanner.prepare(document).omissions, plan.omissions)
        let short = try await PDFDocumentExtractor.extract(data: Self.fixture(pages: 3))
        XCTAssertNil(try NarrationPlanner.prepare(short).omissions)
        XCTAssertTrue(document.blocks[0].text.contains("Synthetic running header"))
    }
}

extension PDFLayoutTests {
    func testActualPDFKitPageEdgesProveASingleColumnContinuation() async throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        let pages = [["A full line of body prose establishes this column and style.", "A second full line preserves the same text column and style.", "The narrator carefully described the river beyond the valley"],
                     ["where the quiet reader listened to another page of the story", "A second full line preserves the same text column and style.", "This final full sentence closes the preserved body paragraph."]]
        for lines in pages {
            context.beginPDFPage(nil)
            for (i, line) in lines.enumerated() {
                context.textPosition = CGPoint(x: 60, y: [650.0, 400.0, 95.0][i])
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Courier" as CFString, 12, nil)])), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        let doc = try await PDFDocumentExtractor.extract(data: data as Data)
        let plan = try NarrationPlanner.prepareForSpeech(doc, settings: .init())
        XCTAssertEqual(doc.blocks.count, 2)
        XCTAssertEqual(plan.chunks.count, 1)
        XCTAssertTrue(plan.chunks[0].text.contains("valley where the quiet reader"))
        XCTAssertEqual(plan.chunks[0].blockIndices, [0, 1])
        XCTAssertTrue(plan.notices.contains { $0.contains("page continuations") })
    }
    func testNativeRotatedCropBoxGeometryNeverReordersOrDropsText() async throws {
        let pdf = try XCTUnwrap(PDFDocument(data: Self.fixture(pages: 1)))
        let page = try XCTUnwrap(pdf.page(at: 0))
        let original = page.string
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            page.setBounds(CGRect(x: 20, y: 10, width: 572, height: 772), for: .cropBox)
            let doc = try await PDFDocumentExtractor.extract(data: XCTUnwrap(pdf.dataRepresentation()))
            XCTAssertEqual(doc.blocks[0].text, original)
            XCTAssertEqual(doc.blocks[0].pdfLayout?.rotation, rotation)
            XCTAssertTrue(doc.blocks[0].pdfLayout?.lines.allSatisfy { $0.bounds.isValid } == true)
        }
    }
}

extension PDFLayoutTests {
    func testOCRPageGeometryBudgetAppliesAcrossAllParagraphs() async throws {
        let regions: [ContentBlock] = (0..<1_025).map { index in
            let text = "Recognized region \(index)."
            return .init(kind: .paragraph, text: text, origin: .ocr,
                         pdfLayout: .init(basis: .image, lines: [.init(location: 0, length: text.utf16.count,
                             bounds: .init(x: 0.1, y: 0.5, width: 0.8, height: 0.01))]))
        }
        let doc = try await PDFDocumentExtractor.extract(data: Self.fixture(pages: 1), forceOCR: true, recognize: { _ in regions })
        XCTAssertEqual(doc.blocks.count, regions.count)
        XCTAssertTrue(doc.blocks.allSatisfy { $0.pdfLayout == nil && $0.origin == .ocr })
        XCTAssertEqual(doc.blocks.map(\.text), regions.map(\.text))
        XCTAssertTrue(doc.warnings.contains { $0.contains("Layout evidence unavailable") })
    }
}
