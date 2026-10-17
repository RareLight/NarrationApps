import Foundation
import XCTest
import Pronunciation
@testable import NarrationCore

final class PDFWordJoiningTests: XCTestCase {
    private let enabled = NarrationOptions(experimentalPDFWordJoining: true)

    private func document(_ lines: [String], blankBefore: Int? = nil) -> SemanticDocument {
        var offset = 0
        let layout = lines.enumerated().map { index, text -> PDFTextLine in
            let separator = index == lines.count - 1 ? "" : (blankBefore == index + 1 ? "\n\n" : "\n")
            let length = (text + separator).utf16.count
            defer { offset += length }
            return .init(location: offset, length: length,
                bounds: .init(x: 0.1, y: 0.8 - Double(index) * 0.025, width: 0.75, height: 0.02))
        }
        let text = lines.enumerated().map { index, line in
            line + (index == lines.count - 1 ? "" : (blankBefore == index + 1 ? "\n\n" : "\n"))
        }.joined()
        return .init(blocks: [.init(kind: .paragraph, text: text, pdfPageIndex: 0, origin: .authored,
            pdfLayout: .init(basis: .cropBox, lines: layout))], extractorVersion: "independent-pdf-word-wrap-fixture")
    }

    private func pages(_ count: Int) -> SemanticDocument {
        .init(blocks: (0..<count).map { page in
            let lines = [
                page == 0 ? "A full introductory line establishes the beginning of this column."
                    : "larly comfortable hotel in this town continues the printed sentence.",
                "Another full line provides ordinary text and consistent body evidence.",
                page == count - 1 ? "A final sentence closes the last page of this synthetic document."
                    : "The narrator says there is a particu-"
            ]
            var offset = 0
            let layout = lines.enumerated().map { index, line -> PDFTextLine in
                let length = line.utf16.count + (index == 2 ? 0 : 1)
                defer { offset += length }
                return .init(location: offset, length: length,
                    bounds: .init(x: 0.1, y: [0.82, 0.5, 0.12][index], width: 0.75, height: 0.015))
            }
            return .init(kind: .paragraph, text: lines.joined(separator: "\n"), pdfPageIndex: page,
                origin: .authored, pdfLayout: .init(basis: .cropBox, lines: layout))
        }, extractorVersion: "independent-pdf-page-word-wrap-fixture")
    }

    func testReadiumExampleIsRejoinedOnlyWhenExplicitlyEnabled() throws {
        let doc = document(["There is a particu-", "larly comfortable hotel in this town."])
        let original = doc
        for model in [SpeechModel.kokoro, .soprano] {
            let before = try NarrationPlanner.prepareForSpeech(doc, settings: .init(model: model))
            XCTAssertTrue(before.chunks[0].text.contains("particu- larly"))
            let plan = try NarrationPlanner.prepareForSpeech(doc, settings: .init(model: model), options: enabled)
            XCTAssertEqual(plan.chunks[0].text, "There is a particularly comfortable hotel in this town.")
            XCTAssertTrue(plan.notices.contains { $0.contains("experimental") })
            let maps = try XCTUnwrap(plan.chunks[0].sourceMappings)
            let removed = try XCTUnwrap(maps.first { $0.rule == "pdf-word-wrap-readium-1" })
            XCTAssertEqual(removed.spokenLength, 0)
            let source = try XCTUnwrap(removed.source)
            XCTAssertEqual((doc.blocks[0].text as NSString).substring(with: .init(location: source.location, length: source.length)), "-\n")
            let preview = try NarrationPlanner.prepare(doc, settings: .init(model: model), options: enabled)
            XCTAssertEqual(preview.chunks.map(\.text).joined(separator: " "), plan.chunks[0].text)
        }
        XCTAssertEqual(doc, original)
    }

    func testDraftCompoundLimitationIsOptInNotAnImplicitDefault() throws {
        let doc = document(["A well-", "known example."])
        XCTAssertTrue(try NarrationPlanner.prepareForSpeech(doc, settings: .init()).chunks[0].text.contains("well- known"))
        XCTAssertTrue(try NarrationPlanner.prepareForSpeech(doc, settings: .init(), options: enabled).chunks[0].text.contains("wellknown"))
    }

    func testParagraphGapUppercaseAndIdentifiersAreNotWordCuts() throws {
        for doc in [
            document(["A particu-", "lar continuation."], blankBefore: 1),
            document(["Salt Lake-", "City is a name."]),
            document(["Visit https://example.invalid/particu-", "larly for details."]),
            document(["Value 123-", "abc must stay unchanged."]),
            document(["A sentence -", "another sentence."])
        ] {
            let before = try NarrationPlanner.prepareForSpeech(doc, settings: .init())
            let after = try NarrationPlanner.prepareForSpeech(doc, settings: .init(), options: enabled)
            XCTAssertEqual(after.chunks.map(\.text), before.chunks.map(\.text))
        }
    }

    func testOptionDecodesLegacySettingsAndKeepsUnchangedAcousticFingerprints() throws {
        let legacy = try JSONDecoder().decode(NarrationOptions.self, from: Data(#"{"notes":"current","includeAuxiliary":true}"#.utf8))
        XCTAssertFalse(legacy.experimentalPDFWordJoining)
        let encodedLegacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        XCTAssertNil(encodedLegacy["experimentalPDFWordJoining"])
        XCTAssertEqual(try JSONDecoder().decode(NarrationOptions.self, from: JSONEncoder().encode(enabled)), enabled)
        let before = NarrationPlanner.version(settings: .init(), options: legacy)
        let after = NarrationPlanner.version(settings: .init(), options: enabled)
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(NarrationPlanner.chunkFingerprintVersion(before), NarrationPlanner.chunkFingerprintVersion(after))
    }

    func testPageSeamRetainsBothSourceBlocksAndDoesNotInventAJoiningSpace() throws {
        let doc = pages(2), original = doc
        for model in [SpeechModel.kokoro, .soprano] {
            let plan = try NarrationPlanner.prepareForSpeech(doc, settings: .init(model: model), options: enabled)
            if model == .kokoro { XCTAssertEqual(plan.chunks.count, 1) }
            let spoken = plan.chunks.map(\.text).joined(separator: " ")
            XCTAssertTrue(spoken.contains("particularly comfortable hotel"))
            XCTAssertEqual(Set(plan.chunks.flatMap(\.blockIndices)), [0, 1])
            let maps = plan.chunks.flatMap { $0.sourceMappings ?? [] }
            XCTAssertEqual(Set(maps.compactMap { $0.source?.blockIndex }), [0, 1])
            let cut = try XCTUnwrap(maps.first { $0.rule == "pdf-word-wrap-readium-1" })
            XCTAssertEqual(cut.source?.blockIndex, 0)
            XCTAssertEqual(cut.source?.location, doc.blocks[0].text.utf16.count - 1)
            XCTAssertEqual(cut.source?.length, 1)
            XCTAssertFalse(maps.contains { $0.rule == "pdf-continuation-space-1" })
            XCTAssertEqual(try NarrationPlanner.prepare(doc, settings: .init(model: model), options: enabled).chunks.map(\.text).joined(separator: " "),
                spoken)
        }
        XCTAssertEqual(doc, original)
    }

    func testFourPageWindowDoesNotRemoveAHyphenAcrossACappedBoundary() throws {
        let doc = pages(5)
        let plan = try NarrationPlanner.prepareForSpeech(doc, settings: .init(), options: enabled)
        XCTAssertEqual(plan.chunks.count, 2)
        XCTAssertEqual(plan.chunks[0].blockIndices, [0, 1, 2, 3])
        XCTAssertTrue(plan.chunks[0].text.hasSuffix("particu-"))
        XCTAssertTrue(plan.chunks[1].text.hasPrefix("larly"))
        XCTAssertEqual(plan.chunks[0].sourceMappings?.filter { $0.rule == "pdf-word-wrap-readium-1" }.count, 3)
    }

    func testOmittedContinuationCannotRemoveThePrecedingHyphen() throws {
        let original = pages(2)
        let next = original.blocks[1]
        let doc = SemanticDocument(blocks: [original.blocks[0],
            .init(kind: .paragraph, text: next.text, pdfPageIndex: next.pdfPageIndex,
                origin: next.origin, pdfLayout: next.pdfLayout, role: .auxiliary)
        ], extractorVersion: "omitted-page-continuation-fixture")
        let plan = try NarrationPlanner.prepareForSpeech(doc, settings: .init(),
            options: .init(includeAuxiliary: false, experimentalPDFWordJoining: true))
        XCTAssertEqual(plan.chunks.count, 1)
        XCTAssertTrue(plan.chunks[0].text.hasSuffix("particu-"))
        XCTAssertFalse(plan.chunks[0].sourceMappings?.contains { $0.rule == PDFWordJoining.rule } == true)
        XCTAssertFalse(plan.notices.contains { $0.contains("Rejoined") || $0.contains("page continuations") })
    }

    func testLegacyOCRRotatedColumnsAndCodeAbstain() throws {
        let original = document(["There is a particu-", "larly comfortable hotel."]).blocks[0]
        var examples = [
            ContentBlock(kind: .paragraph, text: original.text, pdfPageIndex: 0, origin: .authored),
            ContentBlock(kind: .paragraph, text: original.text, pdfPageIndex: 0, origin: .ocr,
                pdfLayout: .init(basis: .image, lines: original.pdfLayout!.lines)),
            ContentBlock(kind: .paragraph, text: original.text, pdfPageIndex: 0, origin: .authored,
                pdfLayout: .init(basis: .cropBox, rotation: 90, lines: original.pdfLayout!.lines)),
            ContentBlock(kind: .paragraph, text: original.text, pdfPageIndex: 0, origin: .authored,
                containsInlineCode: true, pdfLayout: original.pdfLayout),
            ContentBlock(kind: .paragraph, text: original.text, pdfPageIndex: 0, origin: .authored,
                resourcePath: "chapter.xhtml", pdfLayout: original.pdfLayout)
        ]
        let lines = original.pdfLayout!.lines.enumerated().map { index, line in
            PDFTextLine(location: line.location, length: line.length,
                bounds: .init(x: index == 0 ? 0.1 : 0.55, y: line.bounds.y, width: 0.3, height: line.bounds.height))
        }
        examples.append(.init(kind: .paragraph, text: original.text, pdfPageIndex: 0, origin: .authored,
            pdfLayout: .init(basis: .cropBox, lines: lines)))
        for block in examples {
            let doc = SemanticDocument(blocks: [block], extractorVersion: "independent-abstention-fixture")
            XCTAssertEqual(try NarrationPlanner.prepareForSpeech(doc, settings: .init(), options: enabled).chunks.map(\.text),
                try NarrationPlanner.prepareForSpeech(doc, settings: .init()).chunks.map(\.text))
        }
    }

    func testHeadingsAndMultiplePrintedCutsDoNotLoseUnicodeOrApplyOverridesTwice() throws {
        let doc = document(["Café 😀 is a particu-", "larly extraordinary and comfor-", "table place for readers."])
        let rules = try PronunciationDictionary(entries: [
            .init(word: "particularly", spelling: "especially"),
            .init(word: "especially", spelling: "not repeated")
        ])
        let plan = try NarrationPlanner.prepareForSpeech(doc, settings: .init(), pronunciations: rules, options: enabled)
        XCTAssertEqual(plan.chunks[0].text, "Café 😀 is a especially extraordinary and comfortable place for readers.")
        XCTAssertEqual(plan.chunks[0].pronunciationApplications?.count, 1)
        XCTAssertTrue(plan.chunks[0].sourceMappings?.allSatisfy {
            guard let source = $0.source else { return true }
            return Range(NSRange(location: source.location, length: source.length), in: doc.blocks[source.blockIndex].text) != nil
        } == true)
        let heading = document(["PART-", "one introduces a section."])
        XCTAssertTrue(try NarrationPlanner.prepareForSpeech(heading, settings: .init(), options: enabled).chunks[0].text.contains("PART- one"))
    }

    func testFragmentCapAndCancellationRemainBounded() async throws {
        let doc = pages(2)
        let dense = SemanticDocument(blocks: doc.blocks.map {
            ContentBlock(kind: .paragraph, text: $0.text, pdfPageIndex: $0.pdfPageIndex, origin: $0.origin,
                pdfLayout: .init(basis: .cropBox, lines: Array(repeating: $0.pdfLayout!.lines[0], count: 150)))
        }, extractorVersion: "fragment-budget-count-fixture")
        XCTAssertTrue(PDFWordJoining.boundedJoins([0], document: dense).isEmpty)
        let options = enabled
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try NarrationPlanner.prepareForSpeech(doc, settings: .init(), options: options)
        }
        do { _ = try await task.value; XCTFail("Cancelled preparation succeeded") }
        catch is CancellationError { }
    }
}
