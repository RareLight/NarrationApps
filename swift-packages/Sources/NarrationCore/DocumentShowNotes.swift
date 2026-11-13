import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// A source link captured from an authored document. Metadata only: never part
/// of acoustic identity, utterance fingerprints or worker IPC payloads.
public struct DocumentSourceLink: Codable, Equatable, Sendable {
    public let label: String
    public let url: URL
    public init(label: String, url: URL) {
        self.label = String(NarrationText.normalizeWhitespace(label).prefix(200))
        self.url = url
    }
}

/// A structural chapter target resolved to a spoken source block.
public struct DocumentChapter: Codable, Equatable, Sendable {
    public let title: String
    public let blockIndex: Int
    public let precision: DocumentOutlineEntry.Precision
    public init(title: String, blockIndex: Int, precision: DocumentOutlineEntry.Precision = .block) {
        self.title = String(NarrationText.normalizeWhitespace(title).prefix(200)); self.blockIndex = blockIndex; self.precision = precision
    }
}

/// Optional host-side show-notes enrichment carried on narration plans.
/// Additive Codable; never included in acoustic identity or IPC.
public struct DocumentShowNotes: Codable, Equatable, Sendable {
    public var summary: String?
    public let links: [DocumentSourceLink]
    public let chapters: [DocumentChapter]
    public let chapterNotice: String?
    public init(summary: String? = nil, links: [DocumentSourceLink] = [], chapters: [DocumentChapter] = [], chapterNotice: String? = nil) {
        self.summary = summary; self.links = links; self.chapters = chapters; self.chapterNotice = chapterNotice
    }
}

/// Source-link extraction bounds and scheme safety.
public enum SourceLinks {
    public static let maximumLinks = 50
    public static let maximumURLLength = 4096

    /// Keep HTTPS links without credentials, deduplicated in source order.
    /// Fragment-only internal links are dropped. Never resolves or fetches.
    public static func sanitize(_ candidates: [(label: String, url: String)]) -> [DocumentSourceLink] {
        var seen = Set<String>()
        var result: [DocumentSourceLink] = []
        for candidate in candidates {
            let raw = candidate.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.utf8.count <= maximumURLLength,
                  !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let components = URLComponents(string: raw),
                  components.scheme?.lowercased() == "https",
                  components.host?.isEmpty == false, components.user == nil, components.password == nil,
                  components.port == nil || (1...65535).contains(components.port!), let url = components.url else { continue }
            let key = url.absoluteString
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(DocumentSourceLink(label: candidate.label.isEmpty ? (url.host ?? key) : candidate.label, url: url))
            if result.count >= maximumLinks { break }
        }
        return result
    }

    /// Visible HTTPS URLs detected in plain text, deduplicated in reading
    /// order and capped at maximumLinks UNIQUE safe URLs.
    public static func visibleURLs(in text: String) -> [(label: String, url: String)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var links: [(label: String, url: String)] = []
        var seen = Set<String>()
        detector.enumerateMatches(in: text, range: range) { match, _, stop in
            guard let match, let url = match.url,
                  let safe = sanitize([("", url.absoluteString)]).first,
                  seen.insert(safe.url.absoluteString).inserted,
                  let range = Range(match.range, in: text) else { return }
            links.append((String(text[range]), safe.url.absoluteString))
            if links.count >= maximumLinks { stop.pointee = true }
        }
        return links
    }
}

/// Pure structural chapter policy shared by Libro (book) and VoiceRelay (article).
public enum ChapterSelection {
    public static let maximumChapters = 255

    public enum Style: Sendable { case book, article }

    public struct Result: Equatable, Sendable {
        public let chapters: [DocumentChapter]
        /// Human-readable limitation recorded when the list had to be dropped.
        public let notice: String?
    }

    /// - parameters:
    ///   - entries: authored outline entries (may be empty).
    ///   - blocks: source blocks for role filtering and heading fallback.
    ///   - spoken: block indices actually narrated (omitted blocks excluded).
    ///   - documentTitle: used for the opening chapter when the first real
    ///     chapter does not start at the document start.
    ///   - style: `.book` selects the main authored level (or shallowest heading
    ///     fallback); `.article` keeps every narrated source heading.
    public static func select(entries: [DocumentOutlineEntry], blocks: [ContentBlock],
                              spoken: Set<Int>, documentTitle: String?, style: Style) -> Result {
        func narrated(_ block: Int) -> Bool { spoken.contains(block) && block >= 0 && block < blocks.count }
        func eligible(_ block: Int) -> Bool {
            guard narrated(block) else { return false }
            let role = blocks[block].role
            return role != .auxiliary && role != .bibliography
        }

        let refined = entries.compactMap { entry -> DocumentOutlineEntry? in
            guard entry.precision != .unresolved else { return nil }
            if entry.precision == .page {
                guard let page = entry.pageIndex ?? entry.blockIndex.flatMap({ blocks.indices.contains($0) ? blocks[$0].pdfPageIndex : nil }) else { return nil }
                let candidates = blocks.indices.filter { eligible($0) && blocks[$0].pdfPageIndex == page }
                let matches = candidates.filter { NarrationText.normalizeWhitespace(blocks[$0].text) == NarrationText.normalizeWhitespace(entry.label) }
                guard let index = matches.count == 1 ? matches.first : candidates.first else { return nil }
                return .init(id: entry.id, label: entry.label, depth: entry.depth, blockIndex: index,
                    pageIndex: page, resourcePath: entry.resourcePath, fragment: entry.fragment,
                    precision: matches.count == 1 ? .block : .page)
            }
            return entry.blockIndex.map(eligible) == true ? entry : nil
        }
        var chosen: [(title: String, block: Int, precision: DocumentOutlineEntry.Precision)] = []
        switch style {
        case .book:
            var resolved = refined
            if resolved.count > 1, let title = documentTitle {
                resolved.removeAll { NarrationText.normalizeWhitespace($0.label) == NarrationText.normalizeWhitespace(title) }
            }
            if !resolved.isEmpty {
                var level = resolved.map(\.depth).min() ?? 0
                // A single wrapper heading at the shallowest level descends one
                // level to reach the real chapter grouping.
                if resolved.filter({ $0.depth == level }).count == 1,
                   resolved.contains(where: { $0.depth > level }) {
                    level += 1
                }
                chosen = resolved.filter { $0.depth == level }
                    .map { ($0.label, $0.blockIndex!, $0.precision) }
            }
            if chosen.isEmpty {
                // Fallback: shallowest heading level actually narrated.
                var headings = blocks.enumerated().filter { index, b in
                    b.kind == .heading && b.headingLevel != nil && eligible(index)
                }
                if headings.count > 1, let title = documentTitle {
                    headings.removeAll { NarrationText.normalizeWhitespace($0.element.text) == NarrationText.normalizeWhitespace(title) }
                }
                let minLevel = headings.map(\.element.headingLevel!).min()
                chosen = headings.filter { $0.element.headingLevel == minLevel }
                    .map { (NarrationText.normalizeWhitespace($0.element.text), $0.offset, .block) }
            }
        case .article:
            // Every authored/narrated heading becomes a chapter target.
            let headingEntries = refined
            if !headingEntries.isEmpty {
                chosen = headingEntries.map { ($0.label, $0.blockIndex!, $0.precision) }
            } else {
                chosen = blocks.enumerated().filter { index, b in
                    b.kind == .heading && eligible(index)
                }.map { (NarrationText.normalizeWhitespace($0.element.text), $0.offset, .block) }
            }
        }

        // Source order, deduplicated by target block.
        var seen = Set<Int>()
        var ordered = chosen.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.block).inserted }
            .sorted { $0.block < $1.block }
        if ordered.isEmpty { return Result(chapters: [], notice: nil) }

        // Opening chapter at time zero when the first structural target is later.
        let firstSpoken = spoken.sorted().first ?? ordered.first!.block
        if ordered.first!.block > firstSpoken {
            let title = documentTitle.map(NarrationText.normalizeWhitespace).flatMap { $0.isEmpty ? nil : $0 } ?? "Opening"
            ordered.insert((title, firstSpoken, .block), at: 0)
        }
        guard ordered.count <= maximumChapters else {
            return Result(chapters: [], notice:
                "Chapter list omitted: \(ordered.count) structural targets exceed the \(maximumChapters) chapter limit.")
        }
        return Result(chapters: ordered.map { DocumentChapter(title: $0.title, blockIndex: $0.block, precision: $0.precision) },
                      notice: nil)
    }
}

/// Show-notes rendering for embedded descriptions (plain text) and RSS
/// (escaped HTML). All source/model strings are emitted as text — never raw
/// HTML from articles or model output.
public enum ShowNotesText {
    public static let maximumBytes = 32 * 1_024

    /// Plain-text body: summary, source attribution, chapter timecodes, links.
    public static func plainText(summary: String?, sourceTitle: String?, sourceURL: String?,
                                 chapters: [(title: String, startTime: Double)], links: [DocumentSourceLink]) -> String {
        var out = ""
        func append(_ part: String) { if out.utf8.count + part.utf8.count <= maximumBytes { out += part } }
        if let summary, !summary.isEmpty { append(clean(summary) + "\n\n") }
        let source = sourceURL.flatMap { SourceLinks.sanitize([(sourceTitle ?? "", $0)]).first }
        if let source { append("Source: \(clean(source.label)) - \(source.url.absoluteString)\n\n") }
        else if let sourceTitle, !sourceTitle.isEmpty { append("Source: \(clean(sourceTitle))\n\n") }
        if !chapters.isEmpty {
            append("Chapters:\n")
            for ch in chapters where validTime(ch.startTime) { append("\(timecode(ch.startTime)) \(clean(ch.title))\n") }
            append("\n")
        }
        let safeLinks = SourceLinks.sanitize(links.map { ($0.label, $0.url.absoluteString) })
        if !safeLinks.isEmpty {
            append("Links:\n")
            for link in safeLinks { append("- \(clean(link.label)): \(link.url.absoluteString)\n") }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// RSS-ready HTML: escaped summary paragraph, source attribution, chapter
    /// timestamp list, then a real bulleted link list.
    public static func html(summary: String?, sourceTitle: String?, sourceURL: String?,
                            chapters: [(title: String, startTime: Double)], links: [DocumentSourceLink]) -> String {
        var out = ""
        func append(_ part: String, reserve: Int = 0) {
            if out.utf8.count + part.utf8.count + reserve <= maximumBytes { out += part }
        }
        if let summary, !summary.isEmpty { append("<p>\(escape(summary))</p>\n") }
        let source = sourceURL.flatMap { SourceLinks.sanitize([(sourceTitle ?? "", $0)]).first }
        if let source { append("<p>Source: <a href=\"\(escape(source.url.absoluteString))\">\(escape(source.label))</a></p>\n") }
        else if let sourceTitle, !sourceTitle.isEmpty { append("<p>Source: \(escape(sourceTitle))</p>\n") }
        if !chapters.isEmpty {
            let opening = "<p>Chapters:</p>\n<ul>\n"
            if out.utf8.count + opening.utf8.count + 6 <= maximumBytes {
                append(opening, reserve: 6)
                for ch in chapters where validTime(ch.startTime) { append("<li>\(timecode(ch.startTime)) \(escape(ch.title))</li>\n", reserve: 6) }
                append("</ul>\n")
            }
        }
        let safeLinks = SourceLinks.sanitize(links.map { ($0.label, $0.url.absoluteString) })
        if !safeLinks.isEmpty {
            let opening = "<p>Links:</p>\n<ul>\n"
            if out.utf8.count + opening.utf8.count + 6 <= maximumBytes {
                append(opening, reserve: 6)
                for link in safeLinks { append("<li><a href=\"\(escape(link.url.absoluteString))\">\(escape(link.label))</a></li>\n", reserve: 6) }
                append("</ul>\n")
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func escape(_ s: String) -> String {
        clean(s).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func validTime(_ seconds: Double) -> Bool { seconds.isFinite && seconds >= 0 && seconds < Double(Int32.max) }
    private static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 32 && $0.value != 0xFFFE && $0.value != 0xFFFF }))
    }
}

public extension DocumentShowNotes {
    /// Assembles chapter targets and authored links for a document. Returns nil
    /// when there is nothing to carry (no chapters, no links, no summary).
    /// `omitted` lists structurally omitted blocks so chapter selection only
    /// targets actually narrated text.
    static func make(document: SemanticDocument, narrated: Set<Int>,
                     style: ChapterSelection.Style) -> DocumentShowNotes? {
        let selection = ChapterSelection.select(entries: document.navigationEntries,
                                                blocks: document.blocks, spoken: narrated,
                                                documentTitle: document.title, style: style)
        let links = document.links ?? []
        return DocumentShowNotes(summary: nil, links: links, chapters: selection.chapters, chapterNotice: selection.notice)
    }
}

/// On-device summary capture contract. The generator itself is injected so
/// fixtures and inert paths never invoke a live model.
public enum DocumentSummaries {
    public static let maximumSourceBytes = 8_000
    public static let maximumSourceWords = 1_500
    public static let maximumOutputWords = 50
    /// Generation budget, excluding inference admission wait.
    public static let generationBudgetSeconds: TimeInterval = 20

    /// Whole-source eligibility: count complete retained source text.
    public static func eligibleSource(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.utf8.count <= maximumSourceBytes else { return false }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).count <= maximumSourceWords
    }

    /// Validates a model-produced summary. Returns the normalized summary or
    /// nil; invalid output is omitted, never cut mid-sentence or re-prompted.
    public static func validated(_ candidate: String) -> String? {
        guard !candidate.unicodeScalars.contains(where: { CharacterSet.controlCharacters.subtracting(.whitespacesAndNewlines).contains($0) }) else { return nil }
        let text = NarrationText.normalizeWhitespace(candidate)
        guard !text.isEmpty else { return nil }
        // No markup, control characters or URLs.
        guard !text.contains("<") && !text.contains(">") && SourceLinks.visibleURLs(in: text).isEmpty,
              text.range(of: #"\b[a-z][a-z0-9+.-]*://"#, options: [.regularExpression, .caseInsensitive]) == nil,
              !["#", "-", "*", "\u{2022}"].contains(where: text.hasPrefix),
              text.range(of: #"^\d+[.)]\s"#, options: .regularExpression) == nil else { return nil }
        guard text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        // Whitespace word bound.
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count <= maximumOutputWords else { return nil }
        #if canImport(NaturalLanguage)
        // NLTokenizer word tokens containing letters/numbers, and 1-3 sentences.
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var wordTokens = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if text[range].contains(where: { $0.isLetter || $0.isNumber }) { wordTokens += 1 }
            return true
        }
        guard (1...maximumOutputWords).contains(wordTokens) else { return nil }
        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        sentenceTokenizer.string = text
        var sentences = 0
        sentenceTokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in sentences += 1; return true }
        guard sentences >= 1 && sentences <= 3 else { return nil }
        #endif
        // Refusal boilerplate is not a summary.
        let lowered = text.lowercased()
        for refusal in ["i cannot", "i can't", "i'm sorry", "i am sorry", "cannot summarize", "unable to", "summary:"] {
            if lowered.hasPrefix(refusal) { return nil }
        }
        return text
    }
}
