import XCTest
import NarrationCore
import CoreGraphics
import CoreText
import PDFKit
@testable import DocumentProcessing

final class ScientificIntakeTests: XCTestCase {
    private func imageTablePDF() throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        for (text, y) in [("This synthetic document has enough native body text to remain an authored PDF.", 680.0),
                          ("An image-only table follows; the prose must not be replaced by OCR.", 660.0),
                          ("Table 3 Experimental Results", 170.0)] {
            context.textPosition = CGPoint(x: 60, y: y)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil)]))
            CTLineDraw(line, context)
        }
        let pixels = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        pixels.setFillColor(CGColor(gray: 0.7, alpha: 1)); pixels.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        context.draw(try XCTUnwrap(pixels.makeImage()), in: CGRect(x: 80, y: 60, width: 400, height: 90))
        context.endPDFPage(); context.closePDF()
        return data as Data
    }
    func testTargetedImageTableRecognitionKeepsNativeProseAndRespectsBudgetsAndCancellation() async throws {
        let data = try imageTablePDF()
        let original = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0)?.string)
        let result = try await PDFDocumentExtractor.extract(data: data, recognize: { image in
            XCTAssertLessThan(image.height, image.width)
            return [.init(kind: .table, text: "Condition | Description\nControl | The sample remained unchanged during the entire experiment", origin: .ocr)]
        })
        XCTAssertEqual(result.blocks.first?.text, original)
        XCTAssertNotNil(result.blocks.first?.pdfLayout)
        XCTAssertEqual(result.blocks.last?.kind, .table)
        XCTAssertEqual(result.blocks.last?.origin, .ocr)
        let spoken = try NarrationPlanner.prepare(result).chunks.map(\.text).joined(separator: " ")
        XCTAssertTrue(spoken.contains("remained unchanged during the entire experiment"))
        let limited = try await PDFDocumentExtractor.extract(data: data, limits: .init(maximumOCRPages: 0), recognize: { _ in
            XCTFail("A disabled optional OCR budget must not invoke recognition"); return []
        })
        XCTAssertEqual(limited.blocks.first?.text, original)
        XCTAssertTrue(limited.blocks.last?.narrationText?.contains("could not be read reliably") == true)
        do {
            _ = try await PDFDocumentExtractor.extract(data: data, recognize: { _ in throw CancellationError() })
            XCTFail("Cancellation must propagate")
        } catch is CancellationError { }
        do {
            _ = try await PDFDocumentExtractor.extract(data: data, limits: .init(maximumTextBytes: 1), recognize: { _ in
                XCTFail("Native text limits must be checked before optional OCR"); return []
            })
            XCTFail("Native text budget must remain enforced")
        } catch { XCTAssertEqual(error as? PDFExtractionError, .textLimit) }
    }
    func testHTMLVerboseEntriesReadAsProseEvenWithSpannedCells() throws {
        let html = "<table><caption>Experimental observations</caption><tr><th>Condition</th><th>Observation</th></tr><tr><td>Cold</td><td>The sample was unchanged after two hours.</td></tr></table>"
        let blocks = try HTMLDocumentExtractor.semanticBlocks(html: html, baseURL: URL(string: "https://example.invalid/")!)
        let table = try XCTUnwrap(blocks.first)
        XCTAssertEqual(table.text, "Experimental observations Condition Observation Cold The sample was unchanged after two hours.")
        XCTAssertTrue(table.narrationText?.hasPrefix("Experimental observations. Condition.") == true)
        XCTAssertTrue(table.narrationText?.contains("Cold. The sample was unchanged") == true)
        let complex = html.replacingOccurrences(of: "<th>Condition", with: "<th colspan='2'>Condition")
        let other = try HTMLDocumentExtractor.semanticBlocks(html: complex, baseURL: URL(string: "https://example.invalid/")!)
        XCTAssertEqual(other.first?.narrationText, table.narrationText)
        let rowHeaders = "<table><tr><th>Cold</th><td>The first observation must remain a data row.</td></tr><tr><th>Hot</th><td>The second observation must also remain.</td></tr></table>"
        let rowBlocks = try HTMLDocumentExtractor.semanticBlocks(html: rowHeaders, baseURL: URL(string: "https://example.invalid/")!)
        XCTAssertTrue(rowBlocks.first?.narrationText?.contains("Cold. The first observation") == true)
        XCTAssertTrue(rowBlocks.first?.narrationText?.contains("Hot. The second observation") == true)
        let single = try HTMLDocumentExtractor.semanticBlocks(html: "<table><tr><td>A verbose entry that must remain audible.</td></tr></table>", baseURL: URL(string: "https://example.invalid/")!)
        XCTAssertTrue((single.first?.narrationText ?? single.first?.text)?.contains("A verbose entry that must remain audible.") == true)
    }
    func testImageOnlyTableEvidenceRejectsOrdinaryMentionsAndNativeTextBelowCaption() {
        func block(_ text: String, y: Double) -> ContentBlock {
            .init(kind: .paragraph, text: text, pdfPageIndex: 0, origin: .authored,
                pdfLayout: .init(basis: .cropBox, lines: [.init(location: 0, length: text.utf16.count,
                    bounds: .init(x: 0.1, y: y, width: 0.7, height: 0.015))]))
        }
        let caption = block("Table 3 Experimental Results", y: 0.25)
        XCTAssertNotNil(PDFImageTable.candidate([caption]))
        XCTAssertNil(PDFImageTable.candidate([block("Table 3 shows the results of our experiment.", y: 0.25)]))
        XCTAssertNil(PDFImageTable.candidate([caption, block("Native table data", y: 0.2)]))
        let recovered = PDFImageTable.recovered([.init(kind: .paragraph, text: "Unstructured uncertain OCR")], caption: caption.text)
        XCTAssertEqual(recovered.first?.kind, .table)
        XCTAssertTrue(recovered.first?.narrationText?.contains("could not be read reliably") == true)
        XCTAssertEqual(recovered.first?.origin, .generated)
    }
    func testTableNoteMarkersStayInSourceAndResolveOnlyOnce() throws {
        let html = "<table><tr><th>Condition</th><th>Observation</th></tr><tr><td>Cold</td><td>Stable<a role='doc-noteref' href='#fn1'>[1]</a></td></tr></table><aside id='fn1' role='doc-footnote'>An explanatory note about the observation.</aside>"
        let blocks = try HTMLDocumentExtractor.semanticBlocks(html: html, baseURL: URL(string: "https://example.invalid/")!)
        let table = try XCTUnwrap(blocks.first)
        XCTAssertTrue(table.text.contains("[1]")); XCTAssertFalse(table.narrationText?.contains("[1]") ?? true)
        let spoken = try NarrationPlanner.prepare(.init(blocks: blocks, extractorVersion: "synthetic-table-note")).chunks.map(\.text).joined(separator: " ")
        XCTAssertEqual(spoken.components(separatedBy: "An explanatory note about the observation.").count - 1, 1)
    }
    func testBottomInsetAndCaptionFollowIntactPageBodyOnce() {
        let table = OCRStructure(blocks: [.init(kind: .table, text: "A verbose inset with a useful explanation for the reader.", origin: .ocr)],
            bounds: CGRect(x: 0.1, y: 0.08, width: 0.7, height: 0.12))
        let result = StructuredDocumentOCR.project(paragraphs: [
            .init(text: "The first body paragraph.", bounds: CGRect(x: 0.1, y: 0.7, width: 0.7, height: 0.1)),
            .init(text: "Table 2: Additional explanation", bounds: CGRect(x: 0.1, y: 0.21, width: 0.7, height: 0.02)),
            .init(text: table.blocks[0].text, bounds: CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.08)),
            .init(text: "The second body paragraph stays complete.", bounds: CGRect(x: 0.1, y: 0.4, width: 0.7, height: 0.1))
        ], structures: [table], fallback: "")
        XCTAssertEqual(result.map(\.text), ["The first body paragraph.", "The second body paragraph stays complete.", "Table 2: Additional explanation", table.blocks[0].text])
    }
    func testUnownedInsetStaysInItsColumnAndBeforeFollowingParagraph() {
        let table = OCRStructure(blocks: [.init(kind: .table, text: "Inset content")], bounds: CGRect(x: 0.55, y: 0.6, width: 0.35, height: 0.1))
        let result = StructuredDocumentOCR.project(paragraphs: [
            .init(text: "Left column.", bounds: CGRect(x: 0.1, y: 0.4, width: 0.35, height: 0.1)),
            .init(text: "Right above.", bounds: CGRect(x: 0.55, y: 0.8, width: 0.35, height: 0.1)),
            .init(text: "Right below.", bounds: CGRect(x: 0.55, y: 0.4, width: 0.35, height: 0.1))
        ], structures: [table], fallback: "")
        XCTAssertEqual(result.map(\.text), ["Left column.", "Right above.", "Inset content", "Right below."])
    }
    func testTopInsetWithoutChildParagraphsPrecedesPageBody() {
        let table = OCRStructure(blocks: [.init(kind: .table, text: "Inset content")], bounds: CGRect(x: 0.1, y: 0.82, width: 0.7, height: 0.1))
        let result = StructuredDocumentOCR.project(paragraphs: [
            .init(text: "Body paragraph.", bounds: CGRect(x: 0.1, y: 0.6, width: 0.7, height: 0.1))
        ], structures: [table], fallback: "")
        XCTAssertEqual(result.map(\.text), ["Inset content", "Body paragraph."])
    }
}
