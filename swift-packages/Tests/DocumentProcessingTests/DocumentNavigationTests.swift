import XCTest
import PDFKit
import NarrationCore
@testable import DocumentProcessing

final class DocumentNavigationTests: XCTestCase {
    func testPDFBookmarksRetainPagePrecisionAndSourceOrder() async throws {
        // Authored PDF fixture: this SDK's dataRepresentation() drops a newly
        // assigned outline tree, so it cannot serve as our bookmark serializer.
        let prose = "BT /F1 12 Tf 50 700 Td (An authored page of body prose for navigation.) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 7 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(prose.utf8.count) >>\nstream\n" + prose + "\nendstream",
            "<< /Type /Outlines /First 8 0 R /Last 8 0 R /Count 1 >>",
            "<< /Title (Authored second page) /Parent 7 0 R /Dest [4 0 R /Fit] >>"
        ]
        var text = "%PDF-1.4\n", offsets: [Int] = []
        for (index, object) in objects.enumerated() { offsets.append(text.utf8.count); text += "\(index + 1) 0 obj\n" + object + "\nendobj\n" }
        let xref = text.utf8.count
        text += "xref\n0 9\n0000000000 65535 f \n"
        for offset in offsets { text += String(format: "%010d 00000 n \n", offset) }
        text += "trailer\n<< /Size 9 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        let document = try await PDFDocumentExtractor.extract(data: Data(text.utf8))
        let entry = try XCTUnwrap(document.outline?.first)
        XCTAssertEqual(entry.label, "Authored second page")
        XCTAssertEqual(entry.pageIndex, 1); XCTAssertEqual(entry.precision, .page)
        XCTAssertEqual(document.blocks[try XCTUnwrap(entry.blockIndex)].pdfPageIndex, 1)
        XCTAssertEqual(entry.shiftedForInsertion(at: 0).blockIndex, entry.blockIndex.map { $0 + 1 })
    }
    func testMarkedBibliographyIsNotConvertedToFootnoteAndHeadingsHaveDestinations() throws {
        let blocks = try HTMLDocumentExtractor.semanticBlocks(html: "<h1 id='start'>Start</h1><section role='doc-bibliography'><p role='doc-biblioentry' id='fn1'>Author. Reference work.</p></section><aside role='doc-appendix'><h2>Appendix</h2><p>Auxiliary explanation.</p></aside>", baseURL: URL(string: "https://example.test/")!)
        let bibliography = try XCTUnwrap(blocks.first { $0.text.contains("Reference work") })
        XCTAssertNotEqual(bibliography.kind, .footnote); XCTAssertNil(bibliography.footnoteID)
        XCTAssertEqual(bibliography.role, .bibliography)
        XCTAssertEqual(blocks.last?.role, .auxiliary)
        let entries = DocumentNavigation.headings(in: blocks)
        XCTAssertEqual(entries.first?.fragment, "start")
        XCTAssertEqual(entries.map(\.depth), [0, 1])
    }
}
