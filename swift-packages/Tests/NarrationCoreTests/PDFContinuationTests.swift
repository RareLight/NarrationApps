import Foundation
import XCTest
import Pronunciation
@testable import NarrationCore

final class PDFContinuationTests: XCTestCase {
    private func document(ending: String = "The account continues across the page into a quieter place", beginning: String = "where SQLite carries the story forward in the next paragraph.") -> SemanticDocument {
        let texts = [["This first full line establishes the width of the text column.", "A second ordinary sentence establishes the style of this page.", ending],
                     [beginning, "A second full line continues the same column and its style.", "A final full sentence closes this carefully preserved paragraph."]]
        return .init(blocks: texts.enumerated().map { page, lines in
            var offset = 0
            let layout = lines.enumerated().map { index, text -> PDFTextLine in
                let length = text.utf16.count + (index == 2 ? 0 : 1)
                defer { offset += length }
                return .init(location: offset, length: length, bounds: .init(x: 0.1, y: [0.82, 0.5, 0.12][index], width: 0.75, height: 0.015))
            }
            return .init(kind: .paragraph, text: lines.joined(separator: "\n"), pdfPageIndex: page, origin: .authored, pdfLayout: .init(basis: .cropBox, lines: layout))
        }, extractorVersion: "independent-continuation-fixture")
    }
    func testPageContinuationKeepsBothSourcesAndCapturedPronunciationMappings() throws {
        let doc = document()
        let dictionary = try PronunciationDictionary(entries: [.init(word: "SQLite", spelling: "sequel lite")])
        let plan = try NarrationPlanner.prepareForSpeech(doc, settings: .init(), pronunciations: dictionary)
        XCTAssertEqual(plan.chunks.count, 1)
        XCTAssertEqual(plan.chunks[0].blockIndices, [0, 1])
        XCTAssertTrue(plan.chunks[0].text.contains("place where sequel lite"))
        XCTAssertEqual(plan.chunks[0].boundaryAfter, .paragraph)
        let maps = try XCTUnwrap(plan.chunks[0].sourceMappings)
        XCTAssertEqual(Set(maps.compactMap { $0.source?.blockIndex }), [0, 1])
        XCTAssertTrue(maps.contains { $0.source == nil && $0.rule == "pdf-continuation-space-1" })
        XCTAssertEqual(maps.first { $0.rule == "pronunciation-1" }?.source?.blockIndex, 1)
        XCTAssertTrue(doc.blocks[1].text.contains("SQLite"))
        for window in try SpeechTextWindows.make(from: plan) { XCTAssertNotNil(window.source.sourceMappings) }
        let preview = try NarrationPlanner.prepare(doc, pronunciations: dictionary)
        XCTAssertEqual(preview.chunks.map(\.text).joined(separator: " "), plan.chunks[0].text)
    }
    func testOnlyExplicitDiscretionaryWordSplitIsRepairedAcrossPages() throws {
        let plan = try NarrationPlanner.prepareForSpeech(document(ending: "The narrator tells a tale about an extraor\u{ad}", beginning: "dinary arrival in an otherwise quiet town."), settings: .init())
        XCTAssertEqual(plan.chunks.count, 1)
        XCTAssertTrue(plan.chunks[0].text.contains("extraordinary arrival"))
        XCTAssertEqual(plan.chunks[0].sourceMappings?.first { $0.rule == "discretionary-hyphen-1" }?.source?.blockIndex, 0)
        let hard = try NarrationPlanner.prepareForSpeech(document(ending: "The narrator describes a well-", beginning: "known compound with an authored hyphen."), settings: .init())
        XCTAssertEqual(hard.chunks.count, 2)
        XCTAssertTrue(hard.chunks[0].text.hasSuffix("well-"))
    }
    func testPlausibleNonjoinsAndNonPDFStructuresAbstain() throws {
        for doc in [document(ending: "A complete paragraph ends here."), document(beginning: "Chapter Two begins a new section."), document(beginning: "“Quoted dialogue begins here.”"), document(beginning: "- a new list item begins here.")] {
            XCTAssertEqual(try NarrationPlanner.prepareForSpeech(doc, settings: .init()).chunks.count, 2)
        }
        let original = document()
        for kind in [ContentBlock.Kind.heading, .quote, .listItem, .caption, .footnote] {
            var blocks = original.blocks
            let b = blocks[1]
            blocks[1] = .init(kind: kind, text: b.text, pdfPageIndex: b.pdfPageIndex, origin: b.origin, pdfLayout: b.pdfLayout)
            XCTAssertFalse(try NarrationPlanner.prepareForSpeech(.init(blocks: blocks, extractorVersion: "typed"), settings: .init()).notices.contains { $0.contains("page continuations") })
        }
        let epub = SemanticDocument(blocks: original.blocks.map { .init(kind: $0.kind, text: $0.text, pdfPageIndex: $0.pdfPageIndex, origin: $0.origin, resourcePath: "chapter.xhtml", pdfLayout: $0.pdfLayout) }, extractorVersion: "EPUB")
        XCTAssertEqual(try NarrationPlanner.prepareForSpeech(epub, settings: .init()).chunks.count, 2)
        let caption = ContentBlock(kind: .caption, text: "A figure caption.", pdfPageIndex: 0, origin: .authored)
        let interrupted = SemanticDocument(blocks: [original.blocks[0], caption, original.blocks[1]], extractorVersion: "caption")
        XCTAssertFalse(try NarrationPlanner.prepare(interrupted).notices.contains { $0.contains("page continuations") })
    }
    func testIncompatibleColumnAndOCRParagraphGeometryCannotProveAJoin() throws {
        let original = document()
        for (x, basis) in [(0.5, PDFTextLayout.Basis.cropBox), (0.1, .image)] {
            let blocks = original.blocks.enumerated().map { page, b -> ContentBlock in
                let lines = b.pdfLayout!.lines.enumerated().map { i, line in
                    PDFTextLine(location: line.location, length: line.length, bounds: .init(x: page == 1 && i == 1 ? x : 0.1, y: line.bounds.y, width: page == 1 && i == 1 ? 0.4 : 0.75, height: 0.015))
                }
                return .init(kind: .paragraph, text: b.text, pdfPageIndex: b.pdfPageIndex, origin: .authored, pdfLayout: .init(basis: basis, lines: lines))
            }
            XCTAssertEqual(try NarrationPlanner.prepareForSpeech(.init(blocks: blocks, extractorVersion: "uncertain"), settings: .init()).chunks.count, 2)
        }
    }
}
