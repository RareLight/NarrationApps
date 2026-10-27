import Foundation
import CoreGraphics
import CoreText
import PDFKit
import Testing
@testable import VoiceRelayCore

private let pdfLines = [
    "Synthetic document for local article intake.",
    "Local text recognition keeps this document private.",
    "The second paragraph remains in reading order.",
    "A listener should hear the title and the source.",
    "This fixture contains no personal information."
]
private func drawPDFText(_ context: CGContext) {
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    for (index, text) in pdfLines.enumerated() {
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 22, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 40, y: 700 - index * 50)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
}
private func pdfFixture(scanned: Bool = false, blank: Bool = false, pages: Int = 1, alt: String? = nil) throws -> Data {
    let data = NSMutableData(), consumer = try #require(CGDataConsumer(data: data as CFMutableData))
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, [kCGPDFContextTitle: "Synthetic PDF & title", kCGPDFContextAuthor: "Synthetic Author"] as CFDictionary))
    for _ in 0..<pages {
        context.beginPDFPage(nil)
        if !blank {
            if scanned {
                let bitmap = try #require(CGContext(data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(bounds)
                drawPDFText(bitmap)
                if let alt { CGPDFContextBeginTag(context, .figure, [CGPDFTagProperty.alternativeText.rawValue as String: alt] as CFDictionary) }
                context.draw(try #require(bitmap.makeImage()), in: bounds)
                if alt != nil { CGPDFContextEndTag(context) }
            } else { drawPDFText(context) }
        }
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}
private func pdfPage(_ data: Data) -> FetchedPage {
    FetchedPage(originalURL: URL(string: "https://articles.example/original.pdf")!, finalURL: URL(string: "https://cdn.example/document.pdf")!, bytes: data, html: "", contentType: "application/pdf", encoding: "binary", fetchedAt: .distantPast)
}

@Test func pdfEmbeddedTextPreservesSourceAndNarrationAndOfflineSnapshots() async throws {
    let page = pdfPage(try pdfFixture()), review = try await ReviewedSource.prepareAsync(page, chunkLimit: 180)
    let article = try #require(review.document?.article)
    #expect(article.title == "Synthetic PDF & title" && article.author == "Synthetic Author")
    #expect(article.originalURL == page.originalURL && article.finalURL == page.finalURL && article.sourceName == "articles.example")
    #expect(article.blocks.map(\.text).joined().contains(pdfLines[1]))
    #expect(review.document!.cleanedHTML.contains("&amp;") && !review.document!.cleanedHTML.contains("<script"))
    let spoken = try #require(review.narration).chunks.map(\.text).joined(separator: "\n")
    #expect(spoken.hasPrefix("Synthetic PDF & title") && spoken.contains("articles.example") && spoken.hasSuffix("End of article."))
    let ocrCalls = PDFRecognitionCounter()
    _ = try await PDFArticleExtractor.extract(page) { _ in ocrCalls.increment(); return "" }
    #expect(ocrCalls.value == 0)
    let saved = try StoredExtraction(review: review, chunkLimit: 180).review()
    #expect(saved.page.bytes == page.bytes && saved.page.contentType == "application/pdf" && saved.document?.article == article)
}

@Test func scannedPDFUsesNativeVisionOCR() async throws {
    let bytes = try pdfFixture(scanned: true)
    #expect(PDFDocument(data: bytes)?.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
    let review = try await ReviewedSource.prepareAsync(pdfPage(bytes), chunkLimit: 180)
    let text = try #require(review.document).article.blocks.map(\.text).joined(separator: " ")
    #expect(text.localizedCaseInsensitiveContains("Local text recognition keeps this document private"))
    #expect(review.document!.article.warnings.contains { $0.contains("OCR") })
}

@Test func pdfFailuresAreBoundedAndSanitizedWithoutPartialNarration() async throws {
    await #expect(throws: SourceFetchError.invalidPDF) { try await ReviewedSource.prepareAsync(pdfPage(Data("%PDF-broken".utf8)), chunkLimit: 180) }
    await #expect(throws: SourceFetchError.pdfNoText) { try await PDFArticleExtractor.extract(pdfPage(pdfFixture(blank: true)), ocr: { _ in "" }) }
    await #expect(throws: SourceFetchError.pdfPageLimit) { try await ReviewedSource.prepareAsync(pdfPage(pdfFixture(blank: true, pages: 501)), chunkLimit: 180) }
    let calls = PDFRecognitionCounter()
    await #expect(throws: SourceFetchError.pdfOCRLimit) {
        try await PDFArticleExtractor.extract(pdfPage(pdfFixture(blank: true, pages: 51))) { _ in calls.increment(); return pdfLines.joined(separator: " ") }
    }
    #expect(calls.value == 50)
    let pdf = try #require(PDFDocument(data: pdfFixture()))
    let locked = try #require(pdf.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "fixture-owner", PDFDocumentWriteOption.userPasswordOption: "fixture-user"]))
    await #expect(throws: SourceFetchError.lockedPDF) { try await ReviewedSource.prepareAsync(pdfPage(locked), chunkLimit: 180) }
    #expect(!SourceFetchError.pdfOCRFailed.localizedDescription.contains("articles.example"))
}

@Test func taggedPDFAltIsPreferredOverGeneratedDescriptions() async throws {
    let page = pdfPage(try pdfFixture(scanned: true, alt: "An authored description of this scanned illustration."))
    // Avoid system OCR/model use in this metadata test; retain synthetic page prose.
    let document = try await PDFArticleExtractor.extract(page, ocr: { _ in pdfLines.joined(separator: " ") })
    let review = ReviewedSource(page: page, document: document, narration: try Narration.prepare(document.article, limit: 180), issue: nil)
    let enriched = try await ImageNarration.enrich(review, chunkLimit: 180, nativeEnabled: false)
    let text = try #require(enriched.narration).chunks.map(\.text).joined(separator: " ")
    #expect(text.contains("Image description: An authored description"))
    #expect(!enriched.document!.article.blocks.contains { $0.imageDescriptionGenerated == true })
}

private final class PDFIntakeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pdf-intake.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let bytes = try pdfFixture(), url = request.url!
            let type = url.path == "/binary" ? "application/octet-stream" : "application/pdf"
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type, "Content-Length": String(bytes.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Test(arguments: ["/document.pdf", "/binary"]) func pdfURLIntakeStreamsOriginalBytesAndExportsWithCorrectExtension(_ path: String) async throws {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PDFIntakeProtocol.self]
    let url = URL(string: "https://pdf-intake.invalid" + path)!
    let page = try await PageFetcher(limits: FetchLimits()).fetch(url, configuration: configuration)
    #expect(page.originalURL == url && page.contentType == "application/pdf" && page.html.isEmpty && page.bytes.starts(with: Data("%PDF-".utf8)))
    let review = try await ReviewedSource.prepareAsync(page, chunkLimit: 180)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-export-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let export = try SourceReviewArchive.save(review, root: root)
    #expect(try Data(contentsOf: export.appendingPathComponent("source.pdf")) == page.bytes)
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: export.appendingPathComponent("response.json"))) as! [String: Any]
    #expect(manifest["sourceFilename"] as? String == "source.pdf")
    #expect(!FileManager.default.fileExists(atPath: export.appendingPathComponent("source.html").path))
}

private final class PDFRecognitionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@Test func pdfFilenameMetadataYieldsToPrintedMultilineHeadline() async throws {
    let data = NSMutableData(), consumer = try #require(CGDataConsumer(data: data as CFMutableData))
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, [kCGPDFContextTitle: "DOCUMENT.pdf"] as CFDictionary))
    context.beginPDFPage(nil)
    for (index, text) in (["How Wetlands Protect", "Coastal Communities"] + pdfLines).enumerated() {
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, index < 2 ? 26 : 12, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 50, y: 710 - index * 36)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
    context.endPDFPage(); context.closePDF()
    let page = pdfPage(data as Data)
    let review = try await ReviewedSource.prepareAsync(page, chunkLimit: 180)
    let article = try #require(review.document?.article)
    #expect(article.title == "How Wetlands Protect Coastal Communities" && article.titleOrigin == .headline)
    #expect(review.narration?.chunks.first?.text.hasPrefix(article.title) == true)
    #expect(review.document?.cleanedHTML.contains("<title>How Wetlands Protect Coastal Communities</title>") == true)
    let restored = try StoredExtraction(review: review, chunkLimit: 180).review()
    #expect(restored.page.bytes == page.bytes && restored.document?.article == article)
    #expect(PDFDocument(data: restored.page.bytes)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "DOCUMENT.pdf")
}
