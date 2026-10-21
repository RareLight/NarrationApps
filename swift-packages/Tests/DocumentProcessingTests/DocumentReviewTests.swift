import XCTest
import Foundation
import AppKit
import PDFKit
import NarrationCore
@testable import DocumentProcessing

/// Explicit local review only. Source prose/reports never enter the fixture corpus.
final class DocumentReviewTests: XCTestCase {
    func testExplicitlyAuthorizedDocumentReview() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["NARRATION_DOCUMENT_REVIEW_INPUT"],
              let output = environment["NARRATION_DOCUMENT_REVIEW_OUTPUT"] else {
            throw XCTSkip("Requires an explicitly authorized local input and private output directory")
        }
        let url = URL(fileURLWithPath: input), directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document: SemanticDocument
        if url.pathExtension.lowercased() == "html" {
            guard let address = environment["NARRATION_DOCUMENT_REVIEW_URL"], let articleURL = URL(string: address) else {
                throw XCTSkip("HTML review also requires its explicitly selected source URL")
            }
            try WebDocumentURL.validate(articleURL)
            document = try HTMLDocumentExtractor.extract(html: String(contentsOf: url, encoding: .utf8),
                originalURL: articleURL, finalURL: articleURL).article.document
        } else {
            document = try await DocumentReader.readSemantic(.init(source: url, kind: url.pathExtension.lowercased() == "epub" ? .epub : .pdf, relativePath: url.lastPathComponent))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: directory.appendingPathComponent("source.json"), options: .atomic)
        try document.blocks.enumerated().map { "\n[Block \($0.offset), page \(($0.element.pdfPageIndex ?? -1) + 1)]\n\($0.element.text)" }
            .joined().write(to: directory.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        for model in SpeechModel.allCases {
            for (label, options) in [("default", NarrationOptions()), ("joined", .init(experimentalPDFWordJoining: true)),
                ("citations", .init(experimentalPDFWordJoining: true, stripInlineCitations: true, stripEndnoteCitations: true))] {
            let plan = try NarrationPlanner.prepare(document, settings: .init(model: model), options: options)
            let prepared = try NarrationPlanner.prepareForSpeech(document, settings: .init(model: model), options: options)
            let previewText = plan.chunks.map(\.text).joined(separator: "\n")
            let preparedText = prepared.chunks.map(\.text).joined(separator: "\n")
            try preparedText.write(to: directory.appendingPathComponent("prepared-\(model.rawValue)-\(label).txt"), atomically: true, encoding: .utf8)
            // Preview has display chunk breaks; preparation keeps whole paragraphs.
            // Compare text content without logging an entire private book on failure.
            XCTAssertTrue(previewText.filter { !$0.isWhitespace } == preparedText.filter { !$0.isWhitespace },
                "Preview and generation must preserve identical processed text content")
            try encoder.encode(plan).write(to: directory.appendingPathComponent("preview-\(model.rawValue)-\(label).json"), options: .atomic)
            try plan.chunks.map(\.text).joined(separator: "\n").write(to: directory.appendingPathComponent("preview-\(model.rawValue)-\(label).txt"), atomically: true, encoding: .utf8)
            XCTAssertFalse(plan.chunks.isEmpty)
            for omission in plan.omissions ?? [] {
                let text = document.blocks[omission.source.blockIndex].text
                XCTAssertNotNil(Range(NSRange(location: omission.source.location, length: omission.source.length), in: text))
            }
            for mapping in plan.chunks.flatMap({ $0.sourceMappings ?? [] }) {
                if let source = mapping.source {
                    XCTAssertNotNil(Range(NSRange(location: source.location, length: source.length), in: document.blocks[source.blockIndex].text))
                }
            }
            }
        }
        if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
            for index in [0, 1, 2, 3, 4, 8, 12] where index < pdf.pageCount {
                let image = try PDFDocumentExtractor.render(try XCTUnwrap(pdf.page(at: index)), maximumDimension: 1400)
                try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("page-\(index + 1).png"), options: .atomic)
            }
        }
    }
}
