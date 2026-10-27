import Foundation
import Testing
import NarrationCore
@testable import DocumentProcessing

private let titleURLs = [URL(string: "https://articles.example/Report_2042.pdf")!, URL(string: "https://cdn.example/files/report-2042.PDF")!]
private let openingProse = "This synthetic article describes how coastal wetlands protect nearby communities. Researchers compared several restoration methods and measured changes over multiple years."

@Test(arguments: ["Report_2042.pdf", "REPORT 2042", "report-2042", "report%5F2042.pdf", "", "Untitled article", "9", "https://articles.example/file"])
func documentTitleRecognizesWeakCandidates(_ title: String) {
    #expect(DocumentTitles.isWeak(title, urls: titleURLs))
}

@Test func documentTitlePreservesUsefulMetadataAndReadingListBeforeInference() async throws {
    let never: DocumentTitles.Generate = { _ in Issue.record("A useful title must not invoke a model"); return nil }
    let blocks = [ContentBlock(kind: .heading, text: "A different opening headline"), .init(kind: .paragraph, text: openingProse)]
    let metadata = try await DocumentTitles.resolve(title: "How Wetlands Protect Coastal Communities", sourceTitle: "Another useful title", blocks: blocks, urls: titleURLs, generate: never)
    #expect(metadata.origin == .metadata && metadata.text == "How Wetlands Protect Coastal Communities")
    let source = try await DocumentTitles.resolve(title: "Report_2042.pdf", sourceTitle: "How Wetlands Protect Coastal Communities", blocks: blocks, urls: titleURLs, generate: never)
    #expect(source.origin == .readingList)
}

@Test func documentTitleRecoversHeadingWhenMetadataRepeatsFilename() async throws {
    let blocks = [ContentBlock(kind: .heading, text: "How Wetlands Protect Coastal Communities", headingLevel: 1), .init(kind: .paragraph, text: openingProse)]
    let result = try await DocumentTitles.resolve(title: "Report 2042", blocks: blocks, urls: titleURLs,
        generate: { _ in Issue.record("Extracted headings take precedence"); return nil })
    #expect(result == DocumentTitle(text: blocks[0].text, origin: .headline))
    #expect(blocks[1].text == openingProse)
}

private func titleLine(_ text: String, y: Double, height: Double, page: Int = 0, basis: PDFTextLayout.Basis = .cropBox) -> ContentBlock {
    .init(kind: .paragraph, text: text, pdfPageIndex: page, origin: basis == .image ? .ocr : .authored,
        pdfLayout: .init(basis: basis, lines: [.init(location: 0, length: text.utf16.count,
            bounds: .init(x: 0.15, y: y, width: 0.7, height: height))]))
}

@Test func documentTitleUsesMultilineProminenceAndRejectsRepeatedMastheads() {
    let blocks = [titleLine("THE SYNTHETIC JOURNAL", y: 0.92, height: 0.03),
        titleLine("How Wetlands Protect", y: 0.82, height: 0.04),
        titleLine("Coastal Communities", y: 0.77, height: 0.04)] + (0..<7).map {
            titleLine("Ordinary body prose remains unchanged.", y: 0.65 - Double($0) * 0.04, height: 0.018)
        } + [titleLine("THE SYNTHETIC JOURNAL", y: 0.92, height: 0.03, page: 1)]
    #expect(DocumentTitles.headline(in: blocks, urls: titleURLs) == "How Wetlands Protect Coastal Communities")
    #expect(DocumentTitles.headline(in: [.init(kind: .paragraph, text: openingProse)], urls: titleURLs) == nil)
}

@Test func documentTitleAbstainsOnAmbiguousBandsAndInvalidGeometry() {
    let blocks = [titleLine("A Magazine Masthead", y: 0.9, height: 0.04), titleLine("A Separate Article Headline", y: 0.65, height: 0.04)]
        + (0..<5).map { titleLine("Ordinary body prose.", y: 0.4 - Double($0) * 0.04, height: 0.018) }
    #expect(DocumentTitles.headline(in: blocks, urls: titleURLs) == nil)
    let invalid = ContentBlock(kind: .paragraph, text: "Example headline", pdfLayout: .init(basis: .cropBox, lines: [.init(location: 99, length: 10, bounds: .init(x: 0, y: 0.7, width: 0.5, height: 0.04))]))
    #expect(DocumentTitles.headline(in: [invalid] + blocks.dropFirst(2), urls: titleURLs) == nil)
}

@Test func documentTitleGenerationGetsOnlyBoundedOpeningSourceText() async throws {
    let blocks = [ContentBlock(kind: .paragraph, text: String(repeating: openingProse + " ", count: 80), pdfPageIndex: 0),
        .init(kind: .paragraph, text: "GENERATED IMAGE DESCRIPTION", origin: .generated),
        .init(kind: .paragraph, text: "LATER PAGE", pdfPageIndex: 2)]
    let result = try await DocumentTitles.resolve(title: "Report_2042.pdf", blocks: blocks, urls: titleURLs, generate: { excerpt in
        #expect(excerpt.count <= DocumentTitles.maximumExcerptCharacters && excerpt.split(separator: " ").count <= 600)
        #expect(!excerpt.contains("LATER PAGE") && !excerpt.contains("GENERATED IMAGE"))
        return "Wetland Restoration Protects Coastal Communities"
    })
    #expect(result.origin == .generated)
}

@Test func documentTitleInferenceFailureAbstentionTimeoutAndCancellation() async throws {
    struct Unavailable: Error {}
    let blocks = [ContentBlock(kind: .paragraph, text: openingProse)]
    let generators: [DocumentTitles.Generate] = [{ @Sendable _ in nil }, { @Sendable _ in "NONE" }, { @Sendable _ in throw Unavailable() }]
    for generator in generators {
        let result = try await DocumentTitles.resolve(title: "Report_2042.pdf", blocks: blocks, urls: titleURLs, generate: generator)
        #expect(result.text == "Report_2042.pdf" && result.origin == .filename)
    }
    let timed = try await DocumentTitles.resolve(title: "Report_2042.pdf", blocks: blocks, urls: titleURLs,
        generate: { _ in try await Task.sleep(for: .seconds(30)); return "A title that arrives too late" }, generationSeconds: 0.01)
    #expect(timed.origin == .filename)
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let work = Task {
        try await DocumentTitles.resolve(title: nil, blocks: blocks, urls: titleURLs,
            generate: { _ in continuation.yield(); try await Task.sleep(for: .seconds(30)); return nil })
    }
    for await _ in started { break }
    work.cancel()
    await #expect(throws: CancellationError.self) { try await work.value }
    continuation.finish()
}

@Test func documentTitleDoesNotDiscardDescriptiveFilenameWithoutBetterEvidence() async throws {
    let url = URL(string: "https://articles.example/Restoring-Coastal-Wetlands.pdf")!
    let result = try await DocumentTitles.resolve(title: "Restoring Coastal Wetlands", blocks: [.init(kind: .paragraph, text: openingProse)], urls: [url])
    #expect(result.text == "Restoring Coastal Wetlands" && result.origin == .filename)
}

@Test func documentTitleChecksDistinctOriginalAndRedirectedFilenames() async throws {
    let urls = [URL(string: "https://articles.example/Original_Report.pdf")!, URL(string: "https://cdn.example/cache/c7d42.pdf")!]
    #expect(DocumentTitles.isWeak("Original report", urls: urls))
    #expect(DocumentTitles.isWeak("C7D42.PDF", urls: urls))
    let blocks = [ContentBlock(kind: .heading, text: "Restoring Wetlands Along the Coast", headingLevel: 1)]
    #expect(try await DocumentTitles.resolve(title: "Original Report", blocks: blocks, urls: urls).origin == .headline)
}

@Test func documentTitleDoesNotMistakeTallOCRParagraphsForLargeHeadlineType() {
    let prose = "This ordinary paragraph wraps over several lines in the scanned document and must remain body text."
    let blocks = [titleLine(prose, y: 0.72, height: 0.08, basis: .image)]
        + (0..<5).map { titleLine("A shorter body paragraph.", y: 0.6 - Double($0) * 0.05, height: 0.02, basis: .image) }
    #expect(DocumentTitles.headline(in: blocks, urls: titleURLs) == nil)
    #expect(DocumentTitles.excerpt(blocks).contains(prose))
}
