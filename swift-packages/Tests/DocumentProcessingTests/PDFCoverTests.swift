import Foundation
import CoreGraphics
import PDFKit
import ImageIO
import XCTest
@testable import DocumentProcessing

final class PDFCoverTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func pdf(blankFirstPage: Bool = false) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 600)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        context.beginPDFPage(nil)
        if !blankFirstPage {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(box)
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
        }
        context.endPDFPage()
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func cover(_ url: URL) throws -> CGImage {
        let input = InputDocument(source: url, kind: .pdf, relativePath: url.lastPathComponent)
        let bytes = try XCTUnwrap(DocumentReader.bookCover(input))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testWholeFirstPageIsBoundedRectangularAndSourceBytesStayUnchanged() throws {
        let url = try root().appendingPathComponent("book.pdf"), original = try pdf()
        try original.write(to: url)
        let image = try cover(url)
        XCTAssertEqual(image.width, 800)
        XCTAssertEqual(image.height, 1200)
        var pixels = [UInt8](repeating: 0, count: 12 * 18 * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 12, height: 18,
                bitsPerComponent: 8, bytesPerRow: 12 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 12, height: 18))
        }
        let colors = stride(from: 0, to: pixels.count, by: 4).map { (pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) }
        XCTAssertTrue(colors.contains { $0.0 > 200 && $0.1 < 40 && $0.2 < 40 })
        XCTAssertTrue(colors.contains { $0.1 > 200 && $0.0 < 40 && $0.2 < 40 })
        XCTAssertFalse(colors.contains { $0.2 > 200 && $0.0 < 40 && $0.1 < 40 })
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testRotationAndAuthoredCropBoxDetermineTheDisplayedCoverShape() throws {
        let document = try XCTUnwrap(PDFDocument(data: pdf()))
        let page = try XCTUnwrap(document.page(at: 0))
        page.setBounds(CGRect(x: 50, y: 50, width: 300, height: 500), for: .cropBox)
        page.rotation = 90
        let url = try root().appendingPathComponent("rotated.pdf")
        try XCTUnwrap(document.dataRepresentation()).write(to: url)
        let image = try cover(url)
        XCTAssertEqual(image.width, 1200)
        XCTAssertEqual(image.height, 720)
    }

    func testBlankFirstPageMalformedPDFAndUnsupportedKindsDoNotInventCovers() throws {
        let folder = try root(), url = folder.appendingPathComponent("blank.pdf")
        try pdf(blankFirstPage: true).write(to: url)
        XCTAssertNil(try DocumentReader.bookCover(.init(source: url, kind: .pdf, relativePath: "blank.pdf")))
        try Data("not a PDF".utf8).write(to: url)
        XCTAssertNil(try DocumentReader.bookCover(.init(source: url, kind: .pdf, relativePath: "blank.pdf")))
        XCTAssertNil(try DocumentReader.bookCover(.init(source: folder.appendingPathComponent("missing.txt"), kind: .text, relativePath: "missing.txt")))
    }

    func testCancelledCoverReadStopsBeforeFileAccess() async throws {
        let input = InputDocument(source: try root().appendingPathComponent("missing.pdf"), kind: .pdf, relativePath: "missing.pdf")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DocumentReader.bookCover(input)
        }
        do { _ = try await task.value; XCTFail("Cancelled cover read succeeded") }
        catch is CancellationError { }
    }
}
