import XCTest
@testable import NarrationCore

final class PDFReconstructionTests: XCTestCase {
    private func columns(spanning: Bool = false, wrap: Bool = false) -> SemanticDocument {
        var text = "", lines: [PDFTextLine] = []
        func append(_ value: String, x: Double, y: Double, width: Double = 0.34) {
            let length = value.utf16.count + 1
            lines.append(.init(location: text.utf16.count, length: length, bounds: .init(x: x, y: y, width: width, height: 0.02)))
            text += value + "\n"
        }
        if spanning { append("A full-width chapter title", x: 0.1, y: 0.9, width: 0.8) }
        for row in 0..<8 {
            append(wrap && row == 7 ? "This is a particu-" : "Left column sentence number \(row) retains its information.", x: 0.1, y: 0.8 - Double(row) * (wrap ? 0.07 : 0.03))
            append(wrap && row == 0 ? "larly important right-column fact." : "Right column sentence number \(row) has other information.", x: 0.55, y: 0.8 - Double(row) * (wrap ? 0.07 : 0.03))
        }
        return .init(blocks: [.init(kind: .paragraph, text: text, pdfPageIndex: 0, origin: .authored, pdfLayout: .init(basis: .cropBox, lines: lines))], extractorVersion: "independent-column-fixture")
    }
    func testInterleavedColumnsReconstructWithoutLosingSourceAndPreserveWideTitle() throws {
        for spanning in [false, true] {
            let source = columns(spanning: spanning), original = source
            for model in SpeechModel.allCases {
                let plan = try NarrationPlanner.prepareForSpeech(source, settings: .init(model: model))
                let text = plan.chunks.map(\.text).joined(separator: " ")
                XCTAssertLessThan(text.range(of: "Left column sentence number 7")!.lowerBound, text.range(of: "Right column sentence number 0")!.lowerBound)
                for side in ["Left", "Right"] { for row in 0..<8 { XCTAssertEqual(text.components(separatedBy: "\(side) column sentence number \(row)").count - 1, 1) } }
                if spanning { XCTAssertTrue(text.hasPrefix("A full-width chapter title")) }
                for mapping in plan.chunks.flatMap({ $0.sourceMappings ?? [] }) {
                    if let range = mapping.source { XCTAssertNotNil(Range(NSRange(location: range.location, length: range.length), in: source.blocks[range.blockIndex].text)) }
                }
                XCTAssertEqual(source, original)
            }
        }
    }
    func testSparseAndRotatedLayoutAbstain() throws {
        let original = columns().blocks[0]
        XCTAssertNil(PDFColumnReadingOrder.order(Array(original.pdfLayout!.lines.prefix(6)), text: original.text))
        let rotated = SemanticDocument(blocks: [.init(kind: .paragraph, text: original.text, pdfPageIndex: 0, origin: .authored,
            pdfLayout: .init(basis: .cropBox, rotation: 90, lines: original.pdfLayout!.lines))], extractorVersion: "rotated-column-fixture")
        XCTAssertFalse(try NarrationPlanner.prepare(rotated).notices.contains { $0.contains("Reconstructed column") })
    }
    func testThreeColumnsAreNotMisclassifiedAsTwoColumns() throws {
        var text = "", lines: [PDFTextLine] = []
        for row in 0..<8 {
            for column in 0..<3 {
                let value = "Column \(column) has independent information on line \(row).\n"
                lines.append(.init(location: text.utf16.count, length: value.utf16.count,
                    bounds: .init(x: 0.06 + Double(column) * 0.31, y: 0.8 - Double(row) * 0.04, width: 0.25, height: 0.02)))
                text += value
            }
        }
        XCTAssertNil(PDFColumnReadingOrder.order(lines, text: text))
    }
    func testWordJoinAcrossReconstructedColumnsDoesNotDeleteInterleavedText() throws {
        let source = columns(wrap: true)
        let plan = try NarrationPlanner.prepare(source, settings: .init(model: .soprano), options: .init(experimentalPDFWordJoining: true))
        let text = plan.chunks.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("particularly important right-column fact."))
        for row in 0..<7 { XCTAssertTrue(text.contains("Left column sentence number \(row)")) }
        for row in 1..<8 { XCTAssertTrue(text.contains("Right column sentence number \(row)")) }
    }
    func testTrackedAndFragmentedTitlesNeedDictionaryEvidence() throws {
        let text = "T I T L E\nHEA DER\nNO MORE\nA B C D\n"
        var offset = 0
        let lines = text.split(separator: "\n").enumerated().map { i, value -> PDFTextLine in
            let length = value.utf16.count + 1
            defer { offset += length }
            return .init(location: offset, length: length, bounds: .init(x: 0.1, y: 0.8 - Double(i) * 0.04, width: 0.5, height: 0.02))
        }
        let doc = SemanticDocument(blocks: [.init(kind: .paragraph, text: text, pdfPageIndex: 0, origin: .authored, pdfLayout: .init(basis: .cropBox, lines: lines))], extractorVersion: "tracked-heading-fixture")
        let value = try NarrationPlanner.prepare(doc, settings: .init(model: .soprano)).chunks.map(\.text).joined(separator: " ")
        XCTAssertTrue(value.contains("TITLE")); XCTAssertTrue(value.contains("HEADER"))
        XCTAssertTrue(value.contains("NO MORE"), value); XCTAssertTrue(value.contains("A B C D"), value)
    }
}
