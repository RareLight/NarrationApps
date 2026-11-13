import Foundation
@testable import NarrationCore
import Testing

private func block(_ kind: ContentBlock.Kind, _ text: String, _ level: Int? = nil, role: ContentRole? = nil) -> ContentBlock {
    ContentBlock(kind: kind, text: text, headingLevel: level, role: role)
}
private func entry(_ id: String, _ label: String, _ depth: Int, _ block: Int?) -> DocumentOutlineEntry {
    .init(id: id, label: label, depth: depth, blockIndex: block)
}

@Test func bookSelectsShallowestAuthoredLevel() {
    let blocks = [block(.heading, "My Book", 1), block(.heading, "Part I", 1),
                  block(.heading, "Ch 1", 2), block(.paragraph, "Text"),
                  block(.heading, "Ch 2", 2), block(.paragraph, "More")]
    let entries = [entry("t", "My Book", 0, 0), entry("p", "Part I", 0, 1),
                   entry("c1", "Ch 1", 1, 2), entry("c2", "Ch 2", 1, 4)]
    let result = ChapterSelection.select(entries: entries, blocks: blocks,
        spoken: Set(0...5), documentTitle: "My Book", style: .book)
    // Title-equivalent wrapper excluded; lone Part wrapper descends to real chapters.
    // Narrated wrapper text at block 0 becomes the time-zero opening marker.
    #expect(result.chapters.map { $0.title } == ["My Book", "Ch 1", "Ch 2"])
    #expect(result.chapters.map { $0.blockIndex } == [0, 2, 4])
}

@Test func bookDescendsSingleWrapper() {
    let blocks = [block(.heading, "Part", 1), block(.heading, "A", 2), block(.heading, "B", 2)]
    let entries = [entry("p", "Part", 0, 0), entry("a", "A", 1, 1), entry("b", "B", 1, 2)]
    let result = ChapterSelection.select(entries: entries, blocks: blocks,
        spoken: Set(0...2), documentTitle: nil, style: .book)
    // Wrapper descends; narrated wrapper text before chapter A gets an opening marker.
    #expect(result.chapters.map { $0.title } == ["Opening", "A", "B"])
}

@Test func bookFallsBackToShallowestHeadings() {
    let blocks = [block(.heading, "Part", 1), block(.paragraph, "x"),
                  block(.heading, "A", 2), block(.heading, "B", 2)]
    let result = ChapterSelection.select(entries: [], blocks: blocks,
        spoken: Set(0...3), documentTitle: nil, style: .book)
    #expect(result.chapters.map { $0.title } == ["Part"])
}

@Test func omittedAndAuxiliaryTargetsSkipped() {
    let blocks = [block(.heading, "Keep", 1), block(.heading, "Biblio", 1, role: .bibliography),
                  block(.heading, "Skip", 1)]
    let entries = [entry("k", "Keep", 0, 0), entry("b", "Biblio", 0, 1), entry("s", "Skip", 0, 2)]
    let result = ChapterSelection.select(entries: entries, blocks: blocks,
        spoken: [0, 1], documentTitle: nil, style: .book) // block 2 not narrated
    #expect(result.chapters.map { $0.blockIndex } == [0])
}

@Test func openingChapterWhenFirstTargetLater() {
    let blocks = [block(.paragraph, "Intro text"), block(.heading, "Ch 1", 1)]
    let entries = [entry("c", "Ch 1", 0, 1)]
    let result = ChapterSelection.select(entries: entries, blocks: blocks,
        spoken: [0, 1], documentTitle: "Tale", style: .book)
    #expect(result.chapters.map { $0.title } == ["Tale", "Ch 1"])
    #expect(result.chapters.first?.blockIndex == 0)
}

@Test func articleKeepsEveryHeading() {
    let blocks = [block(.heading, "A", 1), block(.heading, "B", 2), block(.heading, "C", 3)]
    let result = ChapterSelection.select(entries: [], blocks: blocks,
        spoken: [0, 1, 2], documentTitle: nil, style: .article)
    #expect(result.chapters.map { $0.title } == ["A", "B", "C"])
}

@Test func makeUsesNarratedIndicesNotOmissions() {
    // A heading omitted from narration (not merely partially omitted) is skipped;
    // narrated indices from chunks are authoritative, not whole-block omission rules.
    let blocks = [block(.heading, "Seen", 1), block(.heading, "Missed", 1),
                  block(.paragraph, "Body"), block(.heading, "Seen2", 1)]
    let document = SemanticDocument(title: "Doc", blocks: blocks, extractorVersion: "t")
    let notes = DocumentShowNotes.make(document: document, narrated: [0, 2, 3], style: .book)!
    #expect(notes.chapters.map { $0.blockIndex } == [0, 3])
}

@Test func pdfPageLevelTargetsRefine() {
    // Page-level bookmark: first block on page omitted, matching heading later
    // on the same page narrated -> resolves to that heading with .block precision.
    let pageBlocks: [ContentBlock] = [
        .init(kind: .paragraph, text: "lead", pdfPageIndex: 0),
        .init(kind: .heading, text: "Intro", headingLevel: 1, pdfPageIndex: 0),
        .init(kind: .paragraph, text: "text", pdfPageIndex: 0),
    ]
    let entries = [DocumentOutlineEntry(id: "p", label: "Intro", depth: 0, pageIndex: 0, precision: .page)]
    // Book style: narrated excludes block 0, exact label match on page -> block 1.
    let book = ChapterSelection.select(entries: entries, blocks: pageBlocks,
        spoken: [1, 2], documentTitle: nil, style: .book)
    #expect(book.chapters.map { $0.blockIndex } == [1])
    #expect(book.chapters.first?.precision == .block)
    // Unmatched label -> first actually narrated block on the page, .page precision.
    let fallback = ChapterSelection.select(entries: [.init(id: "p", label: "Missing", depth: 0, pageIndex: 0, precision: .page)],
        blocks: pageBlocks, spoken: [1, 2], documentTitle: nil, style: .book)
    #expect(fallback.chapters.map { $0.blockIndex } == [1])
    #expect(fallback.chapters.first?.precision == .page)
    // Article style keeps the same refinement.
    let article = ChapterSelection.select(entries: entries, blocks: pageBlocks,
        spoken: [1, 2], documentTitle: nil, style: .article)
    #expect(article.chapters.map { $0.blockIndex } == [1])
}

@Test func sanitizeRejectsMissingHostKeepsExternalFragments() {
    let out = SourceLinks.sanitize([
        ("nohost", "https:foo"),
        ("frag", "https://host.example/a#deep"),
        ("ctrl", "https://ok.example/b\u{0007}"),
    ])
    #expect(out.map { $0.url.absoluteString } == ["https://host.example/a#deep"])
}

@Test func sanitizeFirstFiftyUniqueNotFiftyCandidates() {
    var candidates: [(label: String, url: String)] = (0..<55).map { _ in ("dup", "https://dup.example/x") }
    candidates += (0..<60).map { ("u\($0)", "https://u\($0).example/") }
    let out = SourceLinks.sanitize(candidates)
    #expect(out.count == 50)
    #expect(out.first?.url.absoluteString == "https://dup.example/x")
}

@Test func htmlBudgetStaysCompleteAndEscaped() {
    let huge = String(repeating: "word ", count: 9_000)
    let chapters = (0..<30).map { ("Ch \($0)", Double($0) * 60) }
    let links = (0..<60).map { DocumentSourceLink(label: "L\($0) <script>", url: URL(string: "https://l\($0).example/")!) }
    let out = ShowNotesText.html(summary: huge + " <script>alert(1)</script>", sourceTitle: nil,
        sourceURL: nil, chapters: chapters, links: links)
    #expect(out.utf8.count <= ShowNotesText.maximumBytes)
    #expect(!out.contains("\u{FFFD}"))
    #expect(!out.contains("<script>"))
    // No dangling partial tag at the truncation boundary.
    #expect((out.lastIndex(of: "<") ?? out.endIndex) <= (out.lastIndex(of: ">") ?? out.endIndex))
    if let list = out.range(of: "<ul>") {
        #expect(out[list.upperBound...].contains("</ul>"))
    }
}

@Test func chapterCapOmitsList() {
    var blocks = [block(.paragraph, "x")]
    var entries: [DocumentOutlineEntry] = []
    for i in 0..<300 { blocks.append(block(.heading, "H\(i)", 1)); entries.append(entry("e\(i)", "H\(i)", 0, i + 1)) }
    let result = ChapterSelection.select(entries: entries, blocks: blocks,
        spoken: Set(0...300), documentTitle: nil, style: .book)
    #expect(result.chapters.isEmpty && result.notice != nil)
}

@Test func sourceLinkSanitize() {
    let out = SourceLinks.sanitize([
        ("ok", "https://example.com/a"),
        ("bad-scheme", "javascript:alert(1)"),
        ("creds", "https://user:pass@example.com/x"),
        ("frag", "#section"),
        ("plain-http", "http://example.com/insecure"),
        ("port-zero", "https://example.com:0/x"),
        ("port-over", "https://example.com:65536/x"),
        ("dupe", "https://example.com/a"),
        ("too-long", "https://x.com/" + String(repeating: "a", count: 5000)),
    ])
    #expect(out.map { $0.label } == ["ok"])
}

@Test func visibleURLsDetected() {
    let urls = SourceLinks.visibleURLs(in: "See https://a.com/x and http://b.org for more.")
    #expect(urls.map(\.url) == ["https://a.com/x"], "only HTTPS links are retained")
}

@Test func visibleURLsFirstFiftyUniqueNotDuplicates() {
    let dupes = (0..<55).map { _ in "https://dup.example/x" }.joined(separator: " ")
    let uniques = (0..<60).map { "https://u\($0).example/" }.joined(separator: " ")
    let out = SourceLinks.visibleURLs(in: dupes + " " + uniques)
    #expect(out.count == 50)
    #expect(Set(out.map { $0.url }).count == 50, "50 UNIQUE urls, not first-50 raw matches")
    #expect(out.contains { $0.url == "https://dup.example/x" })
}

@Test func summaryValidation() {
    #expect(DocumentSummaries.validated("The document explains seed germination simply.") == "The document explains seed germination simply.")
    #expect(DocumentSummaries.validated((1...60).map { "w\($0)" }.joined(separator: " ")) == nil) // >50 words
    #expect(DocumentSummaries.validated("One. Two. Three. Four sentences now.") == nil) // >3 sentences
    #expect(DocumentSummaries.validated("Visit https://x.com for details.") == nil)
    #expect(DocumentSummaries.validated("<b>Bold</b> summary") == nil)
    #expect(DocumentSummaries.validated("I cannot summarize this.") == nil)
    #expect(DocumentSummaries.validated("") == nil)
}

@Test func summarySourceEligibility() {
    #expect(DocumentSummaries.eligibleSource("short text"))
    #expect(!DocumentSummaries.eligibleSource(""))
    #expect(!DocumentSummaries.eligibleSource(String(repeating: "x", count: 9_000)))
    #expect(!DocumentSummaries.eligibleSource((1...2_000).map { "w\($0)" }.joined(separator: " ")))
}

@Test func optionsSummaryDefaultsTrue() throws {
    #expect(NarrationOptions().generateSummary)
    let legacy = try JSONDecoder().decode(NarrationOptions.self, from: Data(#"{"notes":"endOfDocument"}"#.utf8))
    #expect(legacy.generateSummary)
    let off = try JSONDecoder().decode(NarrationOptions.self, from: Data(#"{"generateSummary":false}"#.utf8))
    #expect(!off.generateSummary)
}

@Test func planCodableRoundTripsShowNotes() throws {
    let notes = DocumentShowNotes(summary: "S", links: [DocumentSourceLink(label: "L", url: URL(string: "https://a.com")!)],
        chapters: [DocumentChapter(title: "C", blockIndex: 2)])
    let plan = NarrationPlan(version: "v", chunks: [], notices: [], showNotes: notes)
    let round = try JSONDecoder().decode(NarrationPlan.self, from: try JSONEncoder().encode(plan))
    #expect(round.showNotes == notes)
    let old = try JSONDecoder().decode(NarrationPlan.self, from: Data(#"{"version":"v","chunks":[],"notices":[]}"#.utf8))
    #expect(old.showNotes == nil)
}
