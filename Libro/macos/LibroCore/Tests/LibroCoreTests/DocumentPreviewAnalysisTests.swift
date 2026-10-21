import XCTest
import CoreGraphics
import CoreText
import DocumentProcessing
import NarrationCore
import Pronunciation
@testable import LibroCore

private actor PreviewUpdates {
    var values: [DocumentPreviewContent] = []
    func append(_ value: DocumentPreviewContent) { values.append(value) }
}

final class DocumentPreviewAnalysisTests: XCTestCase {
    private func pdf(_ count: Int, readablePages: Int? = nil, at root: URL) throws -> InputDocument {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("preview.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(url: url as CFURL)), mediaBox: &box, nil))
        for page in 0..<count {
            context.beginPDFPage(nil)
            if page < (readablePages ?? count) {
                for (index, line) in ["There is a particu-", "larly comfortable hotel on page \(page + 1)."].enumerated() {
                    context.textPosition = CGPoint(x: 50, y: 700 - index * 18)
                    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil)
                    ])), context)
                }
            }
            context.endPDFPage()
        }
        context.closePDF()
        return .init(source: url, kind: .pdf, relativePath: "preview.pdf")
    }

    func testPrefixesContainNarrationAndFinalResultMatchesCanonicalPlanningForBothEngines() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try pdf(21, at: root)
        let options = NarrationOptions(experimentalPDFWordJoining: true)
        let dictionary = try PronunciationDictionary(entries: [
            .init(word: "particularly", spelling: "especially"),
            .init(word: "especially", spelling: "never apply twice")
        ])
        for model in SpeechModel.allCases {
            let updates = PreviewUpdates(), settings = SpeechSettings(model: model)
            try await DocumentPreviewAnalysis.run(input, describeImages: false, settings: settings,
                pronunciations: dictionary, options: options, update: { await updates.append($0) })
            let values = await updates.values
            XCTAssertEqual(values.compactMap(\.completedPages), [2, 4, 8, 16, 21])
            XCTAssertEqual(values.filter(\.isComplete).count, 1)
            XCTAssertTrue(values.last?.isComplete == true)
            XCTAssertEqual(values.first?.document.blocks.count, 2)
            XCTAssertTrue(values.allSatisfy { $0.chunks.first?.text.contains("especially comfortable hotel") == true })
            XCTAssertFalse(values.flatMap(\.chunks).contains { $0.text.contains("never apply twice") })
            let normal = try await DocumentReader.readSemantic(input)
            let expected = try NarrationPlanner.prepare(normal, settings: settings, pronunciations: dictionary, options: options)
            XCTAssertEqual(values.last?.document, normal)
            XCTAssertEqual(values.last?.chunks, expected.chunks)
        }
    }

    func testClosingDuringFirstPrefixStopsBeforeLaterPagesAndNoCompleteUpdateEscapes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try pdf(21, readablePages: 2, at: root), updates = PreviewUpdates()
        do {
            try await DocumentPreviewAnalysis.run(input, describeImages: false, settings: .init(),
                pronunciations: .empty, options: .init(), recognize: { _ in
                    XCTFail("Later OCR must not start after the preview is closed"); return []
                }, update: { content in
                    await updates.append(content)
                    throw CancellationError()
                })
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let values = await updates.values
        XCTAssertEqual(values.count, 1)
        XCTAssertFalse(values[0].isComplete)
    }

    func testLaterFailureCannotPublishACompletePreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try pdf(3, readablePages: 1, at: root), updates = PreviewUpdates()
        do {
            try await DocumentPreviewAnalysis.run(input, describeImages: false, settings: .init(),
                pronunciations: .empty, options: .init(), recognize: { _ in throw DocumentReadError.malformed },
                update: { await updates.append($0) })
            XCTFail("Expected later extraction failure")
        } catch DocumentReadError.malformed {}
        let values = await updates.values
        XCTAssertEqual(values.count, 1)
        XCTAssertFalse(values[0].isComplete)
    }
}
