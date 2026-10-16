import XCTest
import Foundation
import AppKit
@testable import DocumentProcessing

final class TextEncodingTests: XCTestCase {
    private let western = "The café’s old résumé — written in 1995 — costs £12.50. Enjoy “curly quotes” and naïve prose."
    func testUnicodeBOMsAndUnmarkedUTF16KeepExactText() throws {
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .utf32] {
            let data = try XCTUnwrap(western.data(using: encoding))
            XCTAssertEqual(try DocumentReader.decodeText(data), western)
        }
        XCTAssertEqual(try DocumentReader.decodeText(Data([0xef, 0xbb, 0xbf]) + Data(western.utf8)), western)
    }
    func testWindowsTextConvertsSmartPunctuationWithoutLoss() throws {
        let data = try XCTUnwrap(western.data(using: .windowsCP1252))
        let result = try DocumentTextDecoder.decode(data)
        XCTAssertEqual(result.text, western)
        XCTAssertEqual(result.encoding, .windowsCP1252)
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertEqual(try DocumentReader.decodeText(data, encoding: .windows1252), western)
    }
    func testExplicitHistoricalEncodingChoicesResolveAmbiguity() throws {
        let samples: [(TextFileEncoding, String)] = [
            (.macRoman, western), (.isoLatin1, "A café and a résumé cost £12."),
            (.dos437, "The café costs £12."), (.shiftJIS, "日本語の古いテキスト。"), (.windows1251, "Старинный текст.")
        ]
        for (choice, text) in samples {
            let data = try XCTUnwrap(text.data(using: try XCTUnwrap(choice.encoding)))
            XCTAssertEqual(try DocumentReader.decodeText(data, encoding: choice), text, choice.label)
        }
        let data = try XCTUnwrap(western.data(using: .macOSRoman))
        XCTAssertFalse(try DocumentTextDecoder.decode(data).warnings.isEmpty) // The native detector may improve; the explicit choice must remain exact.
        XCTAssertEqual(try DocumentReader.decodeText(data, encoding: .macRoman), western)
    }
    func testBinaryAndMalformedMarkedUnicodeAreRejectedWithoutLatinFallback() {
        for bytes in [Data([0, 1, 2, 3, 4, 5]), Data([0xef, 0xbb, 0xbf, 0xff]), Data([0xff, 0xfe, 0x41])] {
            XCTAssertThrowsError(try DocumentReader.decodeText(bytes))
        }
        XCTAssertThrowsError(try DocumentReader.decodeText(Data([0xff]), encoding: .utf8))
        XCTAssertEqual(try DocumentReader.decodeText(Data("DOS text.\u{001a}".utf8)), "DOS text.")
    }
    func testTextAndMarkdownIngressShareEncodingAndNeverRewriteSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for kind in [DocumentKind.text, .markdown] {
            let text = kind == .text ? western + " [12]" : "# Résumé\n\n" + western
            let bytes = try XCTUnwrap(text.data(using: .macOSRoman))
            let url = root.appendingPathComponent(kind == .text ? "old.txt" : "old.md")
            try bytes.write(to: url)
            let input = InputDocument(source: url, kind: kind, relativePath: url.lastPathComponent, textEncoding: .macRoman)
            let document = try await DocumentReader.readSemantic(input)
            XCTAssertTrue(document.blocks.map(\.text).joined(separator: " ").contains(western))
            XCTAssertTrue(try DocumentReader.read(input).contains("café"))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }
    func testSemanticRTFSignatureIsRecognized() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".rtf")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = NSAttributedString(string: "A rich café paragraph.")
        try original.data(from: NSRange(location: 0, length: original.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: url)
        let result = try await DocumentReader.readSemantic(.init(source: url, kind: .rtf, relativePath: "text.rtf"))
        XCTAssertEqual(result.blocks.first?.text, original.string)
    }
}
