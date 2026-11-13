import CoreText
import Foundation
import PDFKit
import XCTest
import ZIPFoundation
@testable import DocumentProcessing
@testable import NarrationCore

final class SourceLinkExtractionTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func links(_ document: SemanticDocument) -> [(label: String, url: String)] {
        (document.links ?? []).map { ($0.label, $0.url.absoluteString) }
    }

    func testPlainTextCapturesVisibleURLsWithBounds() async throws {
        let root = try temporary()
        let file = root.appendingPathComponent("notes.txt")
        try "Read https://a.example/x then https://b.example/y again https://a.example/x. Also file:///etc/passwd and ftp://z.example/nope.".write(to: file, atomically: true, encoding: .utf8)
        let document = try await DocumentReader.readSemantic(InputDocument(source: file, kind: .text, relativePath: "notes.txt"))
        let found = links(document)
        XCTAssertEqual(Set(found.map(\.url)), ["https://a.example/x", "https://b.example/y"])
        XCTAssertEqual(found.count, 2, "duplicates must collapse in source order")
    }

    func testMarkdownLinkRunsAndBoundaries() async throws {
        let root = try temporary()
        let file = root.appendingPathComponent("doc.md")
        try """
        # Heading

        Intro prose with [Apple](https://apple.example/one) and [relative](../other.md) plus [file](file:///tmp/x).
        """.write(to: file, atomically: true, encoding: .utf8)
        let document = try await DocumentReader.readSemantic(InputDocument(source: file, kind: .markdown, relativePath: "doc.md"))
        let found = links(document)
        XCTAssertTrue(found.contains { $0.label == "Apple" && $0.url == "https://apple.example/one" })
        XCTAssertFalse(found.contains { $0.url.hasPrefix("file:") }, "file links excluded")
    }

    func testRTFLinkAttributesSurvive() async throws {
        let root = try temporary()
        let attributed = NSMutableAttributedString(string: "See the report here for details.")
        attributed.addAttributes([.link: URL(string: "https://rep.example/r")!], range: NSRange(location: 8, length: 13))
        let data = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let file = root.appendingPathComponent("doc.rtf")
        try data.write(to: file)
        let document = try await DocumentReader.readSemantic(InputDocument(source: file, kind: .rtf, relativePath: "doc.rtf"))
        XCTAssertTrue(links(document).contains { $0.url == "https://rep.example/r" })
    }

    func testHTMLReadableAnchorsOnlyResolveAndFilter() throws {
        let html = """
        <html><body>
        <nav><a href="https://nav.example/menu">menu link</a></nav>
        <article><p>Body text that exceeds the readable article minimum length requirement for the fixture contract substantially and continues.</p>
        <p><a href="https://src.example/abs">abs</a> <a href="/relative/path">rel</a> <a href="#frag">frag</a> <a href="javascript:alert(1)">js</a> <a href="https://user:pw@bad.example/creds">creds</a></p>
        <script>var x = "https://script.example/hidden";</script></article>
        </body></html>
        """
        let result = try HTMLDocumentExtractor.extract(html: html, originalURL: URL(string: "https://site.example/old")!, finalURL: URL(string: "https://site.example/final/dir/")!)
        let found = links(result.article.document)
        XCTAssertTrue(found.contains { $0.url == "https://src.example/abs" })
        XCTAssertTrue(found.contains { $0.url == "https://site.example/relative/path" }, "relative resolves against finalURL")
        XCTAssertFalse(found.contains { $0.url.contains("nav.example") }, "nav outside readable extraction")
        XCTAssertFalse(found.contains { $0.url.contains("script.example") }, "script text never captured")
        XCTAssertFalse(found.contains { $0.url.contains("javascript") || $0.url.contains("user:pw") })
    }

    func testEPUBRetainsExternalLinksOnly() async throws {
        // Minimal EPUB: one chapter with external + internal + file anchors.
        let archive = try Archive(accessMode: .create)
        let container = "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='EPUB/book.opf' media-type='application/oebps-package+xml'/></rootfiles></container>"
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title><dc:language>en</dc:language><dc:identifier id="id">f</dc:identifier></metadata>
        <manifest><item id="one" href="Text/one.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="one"/></spine></package>
        """
        let chapter = """
        <html><body><h1>C1</h1><p>Prose.</p>
        <p><a href="https://ext.example/ref">External</a> <a href="two.xhtml#n">internal</a> <a href="file:///tmp/x">file</a> <a href="#local">localfrag</a></p>
        </body></html>
        """
        for (path, bytes) in [
            ("mimetype", "application/epub+zip"), ("META-INF/container.xml", container),
            ("EPUB/book.opf", opf), ("EPUB/Text/one.xhtml", chapter),
        ] {
            let data = Data(bytes.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: path == "mimetype" ? .none : .deflate) { offset, count in
                data.subdata(in: Int(offset)..<min(data.count, Int(offset) + count))
            }
        }
        let root = try temporary()
        let file = root.appendingPathComponent("book.epub")
        try XCTUnwrap(archive.data).write(to: file)
        let document = try await DocumentReader.readSemantic(InputDocument(source: file, kind: .epub, relativePath: "book.epub"))
        let found = links(document)
        XCTAssertTrue(found.contains { $0.url == "https://ext.example/ref" })
        XCTAssertEqual(found.count, 1, "internal epub resources and file/local refs excluded")
    }

    func testPDFAnnotationAndVisibleURLs() async throws {
        let root = try temporary()
        let pdfPath = root.appendingPathComponent("annotated.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 400)
        let context = try XCTUnwrap(CGContext(consumer: CGDataConsumer(url: pdfPath as CFURL)!, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 40, y: 300)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Body mentions https://visible.example/tok inline.", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil)]))
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        let pdf = try XCTUnwrap(PDFDocument(url: pdfPath))
        let page = try XCTUnwrap(pdf.page(at: 0))
        let annotation = PDFAnnotation(bounds: CGRect(x: 40, y: 290, width: 100, height: 14), forType: .link, withProperties: nil)
        annotation.action = PDFActionURL(url: URL(string: "https://annot.example/link")!)
        page.addAnnotation(annotation)
        try XCTUnwrap(pdf.write(to: pdfPath))
        let document = try await DocumentReader.readSemantic(InputDocument(source: pdfPath, kind: .pdf, relativePath: "annotated.pdf"))
        let found = links(document)
        XCTAssertTrue(found.contains { $0.url == "https://annot.example/link" }, "annotation URL captured")
        XCTAssertTrue(found.contains { $0.url == "https://visible.example/tok" }, "visible text URL captured")
    }

    func testEnrichUnavailablePreservesLinks() async throws {
        let original = SemanticDocument(title: "T", blocks: [.init(kind: .paragraph, text: "Body")], extractorVersion: "t",
            links: [DocumentSourceLink(label: "L", url: URL(string: "https://kept.example/a")!)])
        let enriched = try await DocumentImages.enrich(original, enabled: true)
        XCTAssertEqual(enriched.links, original.links)
        // Disabled enrichment is a fully inert pass-through.
        let untouched = try await DocumentImages.enrich(original, enabled: false)
        XCTAssertEqual(untouched, original)
    }
}
