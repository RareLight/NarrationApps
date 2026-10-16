import Foundation
import XCTest
@testable import NarrationCore

final class PDFMarginTests: XCTestCase {
    private func document(headers: [String], bodyY: Double = 0.65) -> SemanticDocument {
        .init(title: headers.first, author: headers.dropFirst().first, blocks: headers.enumerated().map { page, header in
            let texts = [header, "Repeated body refrain must always survive in the main text of the book.",
                         "Another full sentence gives geometric evidence of substantial body content.",
                         "A third ordinary sentence ends the author's body paragraph.", "\(page + 1)"]
            let positions = [0.95, bodyY + 0.1, bodyY, bodyY - 0.1, 0.03]
            var offset = 0
            let lines = texts.enumerated().map { index, text -> PDFTextLine in
                let length = text.utf16.count + (index == texts.count - 1 ? 0 : 1)
                defer { offset += length }
                return .init(location: offset, length: length, bounds: .init(x: 0.1, y: positions[index], width: index == 4 ? 0.012 : 0.7, height: 0.015))
            }
            return .init(kind: .paragraph, text: texts.joined(separator: "\n"), pdfPageIndex: page, origin: .authored,
                         pdfLayout: .init(basis: .cropBox, lines: lines))
        }, extractorVersion: "independent-margin-fixture")
    }
    func testAlternatingHeadersChangingFoliosAndBodyRefrains() throws {
        let doc = document(headers: (0..<6).map { $0 % 2 == 0 ? "Even volume title" : "Odd volume title" })
        let plan = try NarrationPlanner.prepareForSpeech(doc, settings: .init())
        XCTAssertEqual(plan.omissions?.count, 12)
        XCTAssertEqual(plan.chunks.filter { $0.text.contains("Repeated body refrain") }.count, 6)
        XCTAssertFalse(plan.chunks.contains { $0.text.contains("volume title") })
        XCTAssertEqual(doc.blocks[0].text.components(separatedBy: "\n").first, "Even volume title")
    }
    func testLegalNoticesAndURLsRemainEvenWhenRepeatedInMargins() throws {
        for header in ["Copyright 2026 Example", "© All rights reserved", "License terms apply", "https://example.org/book", "Contact reader@example.org"] {
            let plan = try NarrationPlanner.prepare(document(headers: Array(repeating: header, count: 6)))
            XCTAssertFalse(plan.omissions?.contains { $0.reason == "recurring PDF header" } == true)
            XCTAssertTrue(plan.chunks.contains { $0.text.contains(header) })
        }
    }
    func testUniqueHeadersShortDocumentsAndLegacyProseAbstain() throws {
        let doc = document(headers: ["Oak", "Pine", "Elm", "Birch"])
        let plan = try NarrationPlanner.prepare(doc)
        XCTAssertEqual(plan.omissions?.filter { $0.reason == "recurring PDF header" }.count, 0)
        for title in ["Oak", "Pine", "Elm", "Birch"] { XCTAssertTrue(plan.chunks.contains { $0.text.contains(title) }) }
        XCTAssertNil(try NarrationPlanner.prepare(document(headers: ["Same", "Same", "Same"])).omissions)
        let legacy = SemanticDocument(blocks: doc.blocks.map { .init(kind: $0.kind, text: $0.text, pdfPageIndex: $0.pdfPageIndex, origin: $0.origin) }, extractorVersion: "legacy")
        XCTAssertNil(try NarrationPlanner.prepare(legacy).omissions)
        for kind in [ContentBlock.Kind.heading, .caption, .footnote, .table] {
            let retained = SemanticDocument(blocks: doc.blocks.map { .init(kind: kind, text: $0.text, pdfPageIndex: $0.pdfPageIndex, origin: $0.origin, pdfLayout: $0.pdfLayout) }, extractorVersion: "typed")
            XCTAssertNil(try NarrationPlanner.prepare(retained).omissions)
        }
    }
    func testRepeatedBodyNearTopOfTextAreaIsNeverFurniture() throws {
        let doc = document(headers: Array(repeating: "A recurring body heading", count: 6))
        let changed = SemanticDocument(title: doc.title, author: doc.author, blocks: doc.blocks.map { block in
            let lines = block.pdfLayout!.lines.enumerated().map { i, line in
                PDFTextLine(location: line.location, length: line.length, bounds: i == 0 ? .init(x: 0.1, y: 0.85, width: 0.7, height: 0.015) : line.bounds)
            }
            return .init(kind: .paragraph, text: block.text, pdfPageIndex: block.pdfPageIndex, origin: .authored, pdfLayout: .init(basis: .cropBox, lines: lines))
        }, extractorVersion: "body-heading")
        let plan = try NarrationPlanner.prepare(changed)
        XCTAssertEqual(plan.omissions?.filter { $0.reason == "recurring PDF header" }.count, 0)
        XCTAssertEqual(plan.chunks.filter { $0.text.contains("A recurring body heading") }.count, 6)
    }
}

extension PDFMarginTests {
    func testOptionalMappingBudgetAbstainsWithoutLosingSource() throws {
        let original = document(headers: Array(repeating: "Running title", count: 60))
        let blocks = original.blocks.map { block -> ContentBlock in
            var texts = block.text.components(separatedBy: "\n")
            texts[1] = String(repeating: "word\tword ", count: 1_000)
            var offset = 0
            let lines = texts.enumerated().map { index, text -> PDFTextLine in
                let length = text.utf16.count + (index == texts.count - 1 ? 0 : 1)
                defer { offset += length }
                return .init(location: offset, length: length, bounds: block.pdfLayout!.lines[index].bounds)
            }
            return .init(kind: .paragraph, text: texts.joined(separator: "\n"), pdfPageIndex: block.pdfPageIndex, origin: .authored, pdfLayout: .init(basis: .cropBox, lines: lines))
        }
        let plan = try NarrationPlanner.prepareForSpeech(.init(blocks: blocks, extractorVersion: "budget"), settings: .init())
        XCTAssertNil(plan.omissions)
        XCTAssertEqual(plan.chunks.count, 60)
        XCTAssertTrue(plan.chunks.allSatisfy { $0.text.hasPrefix("Running title") && $0.sourceMappings == nil })
        XCTAssertTrue(plan.notices.contains { $0.contains("mapping budget") && $0.contains("skipped") })
    }
}

extension PDFMarginTests {
    func testIncompleteGeometryAndEvidenceBudgetAlwaysRetainText() throws {
        let original = document(headers: Array(repeating: "Header must remain when evidence is incomplete", count: 6))
        let incomplete = SemanticDocument(title: original.title, author: original.author, blocks: original.blocks.map { b in
            .init(kind: b.kind, text: b.text, pdfPageIndex: b.pdfPageIndex, origin: b.origin,
                  pdfLayout: .init(basis: .cropBox, lines: b.pdfLayout!.lines.enumerated().filter { $0.offset != 2 }.map(\.element)))
        }, extractorVersion: "incomplete")
        XCTAssertNil(try NarrationPlanner.prepare(incomplete).omissions)
        let line = PDFTextLine(location: 0, length: 1, bounds: .init(x: 0.1, y: 0.95, width: 0.2, height: 0.01))
        let layout = PDFTextLayout(basis: .cropBox, lines: Array(repeating: line, count: 1_024))
        let excessive = SemanticDocument(blocks: (0..<101).map { .init(kind: .paragraph, text: "Retained prose.", pdfPageIndex: $0, origin: .authored, pdfLayout: layout) }, extractorVersion: "excessive")
        let plan = try NarrationPlanner.prepare(excessive)
        XCTAssertNil(plan.omissions)
        XCTAssertEqual(plan.chunks.count, 101)
        XCTAssertTrue(plan.notices.contains { $0.contains("evidence budget") })
    }
}

extension PDFMarginTests {
    func testGenericMarginProseAndConstantYearsAreNotAutomaticOmissions() throws {
        let original = document(headers: Array(repeating: "Alle Rechte vorbehalten", count: 6))
        let anonymous = SemanticDocument(blocks: original.blocks, extractorVersion: "no-metadata")
        let plan = try NarrationPlanner.prepare(anonymous)
        XCTAssertFalse(plan.omissions?.contains { $0.reason == "recurring PDF header" } == true)
        XCTAssertTrue(plan.chunks.contains { $0.text.contains("Alle Rechte vorbehalten") })
        let years = document(headers: Array(repeating: "2026", count: 6))
        XCTAssertFalse(try NarrationPlanner.prepare(years).omissions?.contains { $0.reason == "recurring PDF header" } == true)
    }
}
