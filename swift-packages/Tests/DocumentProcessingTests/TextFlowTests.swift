import Foundation
import XCTest
import NarrationCore
@testable import DocumentProcessing

final class TextFlowTests: XCTestCase {
    func testExplicitBlankLinesPreserveExactSourceAndSingleLineWraps() async throws {
        for newline in ["\n", "\r\n", "\r"] {
            let first = "First [12] paragraph." + newline + "Still the first."
            let second = "“Dialogue.”" + newline + "- A list line." + newline + "> A quote."
            let text = "  " + first + newline + " \t" + newline + second + newline + newline + "Verse line one" + newline + "Verse line two"
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("flow.txt")
            try Data(text.utf8).write(to: url)
            let document = try await DocumentReader.readSemantic(.init(source: url, kind: .text, relativePath: "flow.txt"))
            XCTAssertEqual(document.blocks.count, 3)
            XCTAssertEqual(document.blocks.map(\.text).joined(), text)
            XCTAssertTrue(document.blocks[0].text.contains(first))
            let plan = try NarrationPlanner.prepareForSpeech(document, settings: .init())
            XCTAssertEqual(plan.chunks.map(\.text), ["First [12] paragraph. Still the first.", "“Dialogue.” - A list line. > A quote.", "Verse line one Verse line two"])
            XCTAssertEqual(plan.chunks.map(\.boundaryAfter), [.paragraph, .paragraph, .paragraph])
        }
    }
    func testDiscretionaryHyphensAreMappedAndHardHyphensAndReferencesSurvive() throws {
        let source = "Cafe\u{301} 😀 discre\u{ad}\ntionary co\u{ad}operate well-known X-ray [12]."
        let original = SemanticDocument(blocks: [.init(kind: .paragraph, text: source, origin: .authored)], extractorVersion: "fixture")
        for model in [SpeechModel.kokoro, .soprano] {
            let plan = try NarrationPlanner.prepareForSpeech(original, settings: .init(model: model))
            XCTAssertEqual(plan.chunks[0].text, "Cafe\u{301} 😀 discretionary cooperate well-known X-ray [12].")
            let omissions = try XCTUnwrap(plan.chunks[0].sourceMappings).filter { $0.rule == "discretionary-hyphen-1" }
            XCTAssertEqual(omissions.count, 2)
            XCTAssertTrue(omissions.allSatisfy { $0.spokenLength == 0 && $0.source?.blockIndex == 0 })
            for omission in omissions {
                let range = try XCTUnwrap(omission.source)
                XCTAssertTrue((source as NSString).substring(with: .init(location: range.location, length: range.length)).contains("\u{ad}"))
            }
            XCTAssertEqual(try NarrationPlanner.prepare(original, settings: .init(model: model)).chunks[0].text, plan.chunks[0].text)
        }
        XCTAssertEqual(original.blocks[0].text, source)
    }
}

extension TextFlowTests {
    func testWhitespaceOnlySegmentsAreScannedOnceAndRetainedWithTheNextParagraph() throws {
        let source = String(repeating: "\n\n\u{a0}", count: 20_000) + "The only paragraph." + String(repeating: "\n\n\u{a0}", count: 20_000)
        let blocks = try DocumentReader.plainTextBlocks(source)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].text, source)
    }
}
