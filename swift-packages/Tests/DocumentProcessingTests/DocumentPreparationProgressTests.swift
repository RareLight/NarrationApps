import XCTest
import Foundation
import CoreGraphics
import CoreText
import NarrationCore
@testable import DocumentProcessing

private final class PreparationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DocumentPreparationProgress] = []
    func append(_ value: DocumentPreparationProgress) { lock.withLock { values.append(value) } }
    var snapshot: [DocumentPreparationProgress] { lock.withLock { values } }
}

private actor PDFPreviewLog {
    var values: [PDFExtractionPreview] = []
    func append(_ value: PDFExtractionPreview) { values.append(value) }
}

final class DocumentPreparationProgressTests: XCTestCase {
    private func pdf(_ texts: [String?], image: Bool = false) throws -> Data {
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 400)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: bytes)), mediaBox: &box, nil))
        for (index, text) in texts.enumerated() {
            context.beginPDFPage(nil)
            if let text {
                context.textPosition = CGPoint(x: 40, y: 300)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil)]))
                CTLineDraw(line, context)
            }
            if image && index == 0 {
                let bitmap = try XCTUnwrap(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                bitmap.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
                context.draw(try XCTUnwrap(bitmap.makeImage()), in: CGRect(x: 40, y: 40, width: 100, height: 100))
            }
            context.endPDFPage()
        }
        context.closePDF()
        return bytes as Data
    }
    func testMixedPDFReportsCompletedPagesOnlyAfterOCRAndKeepsProvenance() async throws {
        let log = PreparationLog()
        let data = try pdf(["First source page.", nil, "Third source page."])
        let result = try await PDFDocumentExtractor.extract(data: data, recognize: { _ in
            let current = try XCTUnwrap(log.snapshot.last)
            XCTAssertEqual(current.stage, .recognizingText)
            XCTAssertEqual(current.completed, 1); XCTAssertEqual(current.total, 3); XCTAssertEqual(current.currentPage, 2)
            XCTAssertTrue(current.status.contains("page 2 of 3"))
            return [.init(kind: .paragraph, text: "Recognized second page.")]
        }, progress: { log.append($0) })
        let events = log.snapshot
        XCTAssertEqual(events.first?.stage, .readingPDFStructure)
        XCTAssertTrue(events.contains { $0.stage == .renderingOCR && $0.currentPage == 2 })
        XCTAssertEqual(events.filter { $0.stage == .extractingText && $0.currentPage == nil }.map(\.completed), [1, 2, 3])
        XCTAssertEqual(events.last?.fractionCompleted, 1)
        XCTAssertEqual(result.blocks.map(\.pdfPageIndex), [0, 1, 2])
        XCTAssertEqual(result.blocks.map(\.origin), [.authored, .ocr, .authored])
        XCTAssertFalse(events.map(\.status).joined().contains("First source page"))
    }
    func testCancelledOCRNeverClaimsACompletedPage() async throws {
        let log = PreparationLog()
        let data = try pdf([nil, "Second source page."])
        do {
            _ = try await PDFDocumentExtractor.extract(data: data, recognize: { _ in throw CancellationError() }, progress: { log.append($0) })
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertFalse(log.snapshot.contains { $0.completed > 0 })
    }
    func testImageReviewReportsItsOwnPagePassAndDescriptionStageWithoutNativeModels() async throws {
        let log = PreparationLog()
        let data = try pdf(["First page with imagery.", "Second page."], image: true)
        let original = SemanticDocument(blocks: [.init(kind: .paragraph, text: "Source retained.", pdfPageIndex: 0)], extractorVersion: "fixture")
        let result = try await DocumentImages.enrich(original, pdfData: data, enabled: true, progress: { log.append($0) }, caption: { _ in
            let current = try XCTUnwrap(log.snapshot.last)
            XCTAssertEqual(current.stage, .describingImage)
            XCTAssertNotNil(current.currentPage)
            return "A red square."
        })
        XCTAssertTrue(result.blocks.contains { $0.imageDescriptionGenerated == true })
        XCTAssertEqual(result.blocks.first?.text, "Source retained.")
        XCTAssertEqual(log.snapshot.last?.completed, 2)
        XCTAssertEqual(log.snapshot.last?.total, 2)
        XCTAssertEqual(log.snapshot.last?.countLabel, "Image review: 2 of 2 pages checked")
    }
    func testCoordinatedReaderForwardsPDFStages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture.pdf")
        try pdf(["Source page.", nil]).write(to: url)
        let log = PreparationLog()
        _ = try await DocumentReader.readSemantic(.init(source: url, kind: .pdf, relativePath: "fixture.pdf"),
            recognize: { _ in [.init(kind: .paragraph, text: "Recognized page.")] }, progress: { log.append($0) })
        XCTAssertEqual(log.snapshot.first?.stage, .readingFile)
        XCTAssertTrue(log.snapshot.contains { $0.stage == .readingPDFStructure })
        XCTAssertTrue(log.snapshot.contains { $0.stage == .recognizingText })
        XCTAssertEqual(log.snapshot.last?.completed, 2)
    }

    func testUnknownWorkHasNoInventedPercentageAndCountersStayBounded() {
        XCTAssertNil(DocumentPreparationProgress(stage: .readingFile).fractionCompleted)
        XCTAssertNil(DocumentPreparationProgress(stage: .planningNarration).countLabel)
        XCTAssertNil(DocumentPreparationProgress(stage: .extractingText, total: 0).fractionCompleted)
        XCTAssertEqual(DocumentPreparationProgress(stage: .extractingText, completed: -1, total: 3).fractionCompleted, 0)
        XCTAssertEqual(DocumentPreparationProgress(stage: .extractingText, completed: 4, total: 3).fractionCompleted, 1)
    }

    func testFirstPreviewRoundsUpAndArrivesBeforeLaterOCR() async throws {
        let data = try pdf((0..<21).map { $0 < 2 ? "Readable source page \($0)." : nil })
        let previews = PDFPreviewLog()
        do {
            _ = try await PDFDocumentExtractor.extract(data: data, recognize: { _ in
                XCTFail("Later pages must not be analyzed before the first prefix is delivered")
                return []
            }, preview: { prefix in
                await previews.append(prefix)
                throw CancellationError()
            })
            XCTFail("Expected preview cancellation")
        } catch is CancellationError {}
        let values = await previews.values
        XCTAssertEqual(values.map(\.completedPages), [2])
        XCTAssertEqual(values.first?.totalPages, 21)
        XCTAssertEqual(values.first?.document.blocks.map(\.pdfPageIndex), [0, 1])
    }

    func testPreviewPrefixesGrowWithoutReextractingAndFinalDocumentMatchesNormalExtraction() async throws {
        let data = try pdf((0..<21).map { "Readable source page \($0)." })
        let previews = PDFPreviewLog()
        let streamed = try await PDFDocumentExtractor.extract(data: data, preview: { await previews.append($0) })
        let normal = try await PDFDocumentExtractor.extract(data: data)
        let values = await previews.values
        XCTAssertEqual(values.map(\.completedPages), [2, 4, 8, 16, 21])
        XCTAssertEqual(values.map { $0.document.blocks.count }, [2, 4, 8, 16, 21])
        XCTAssertEqual(values.first?.document.blocks.last?.pdfPageIndex, 1)
        XCTAssertEqual(streamed, normal)
    }

    func testLargePDFFirstPreviewIsCappedAtFivePages() async throws {
        let previews = PDFPreviewLog()
        do {
            _ = try await PDFDocumentExtractor.extract(data: pdf((0..<121).map { "Source page \($0)." }),
                preview: { prefix in await previews.append(prefix); throw CancellationError() })
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let values = await previews.values
        XCTAssertEqual(values.map(\.completedPages), [5])
        XCTAssertEqual(values.first?.totalPages, 121)
    }

    func testPreviewCheckpointsDoNotResetTheMandatoryTextBudget() async throws {
        let previews = PDFPreviewLog()
        do {
            _ = try await PDFDocumentExtractor.extract(data: pdf(Array(repeating: "Readable source.", count: 5)),
                limits: .init(maximumTextBytes: 35), preview: { await previews.append($0) })
            XCTFail("A partial preview cannot turn an over-budget document into a success")
        } catch PDFExtractionError.textLimit {}
        let values = await previews.values
        XCTAssertEqual(values.map(\.completedPages), [1, 2])
    }

    func testCancellationAtPreviewDeliveryStopsBeforeTheNextPage() async throws {
        let log = PreparationLog()
        let data = try pdf(["First source page.", "Second source page."])
        let task = Task {
            try await PDFDocumentExtractor.extract(data: data,
                preview: { _ in withUnsafeCurrentTask { $0?.cancel() } }, progress: { log.append($0) })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertFalse(log.snapshot.contains { $0.currentPage == 2 })
    }

    func testEmptyLeadingOCRDoesNotPublishAnUnusablePreview() async throws {
        let previews = PDFPreviewLog()
        _ = try await PDFDocumentExtractor.extract(data: pdf([nil, "Readable second page."]),
            recognize: { _ in [] }, preview: { await previews.append($0) })
        let values = await previews.values
        XCTAssertEqual(values.map(\.completedPages), [2])
        XCTAssertEqual(values.first?.document.blocks.first?.pdfPageIndex, 1)
    }
}
