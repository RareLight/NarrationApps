import Foundation
import SwiftReadability
import SwiftSoup
import NaturalLanguage

public struct ExtractedDocument: Sendable {
    public let article: SemanticArticle
    public let cleanedHTML: String
}

public enum ArticleExtractor {
    public static let version = "SwiftReadability-0.3.3/semantic-2"
    public static func extract(html: String, originalURL: URL, finalURL: URL) throws -> ExtractedDocument {
        // Readers and DOMs stay in this invocation; neither is shared across tasks.
        let original = try SwiftSoup.parse(html, finalURL.absoluteString)
        let prepared = try SwiftSoup.parse(html, finalURL.absoluteString)
        try markCaptions(prepared)
        let reader = Readability(html: try prepared.outerHtml(), url: finalURL)
        guard let result = try reader.parse() else {
            throw RelayError.extraction("No readable article selected. Inspect the private source snapshot.")
        }
        let canonical = try original.select("link[rel=canonical]").first()?.attr("href")
        let canonicalURL = canonical.flatMap { URL(string: $0, relativeTo: finalURL)?.absoluteURL }
        let cleaned = try SwiftSoup.parseBodyFragment(result.contentHTML, finalURL.absoluteString)
        try cleaned.select("header time, header a[title=Permalink], header a[rel=bookmark]").remove()
        let conversion = try convert(cleaned, baseURL: finalURL, footnoteSource: original)
        try cleaned.select("img, picture, source, svg, canvas, video, audio, iframe, object, embed, script, style, noscript").remove()
        let blocks = conversion.blocks
        guard blocks.contains(where: { !$0.text.isEmpty }), result.textContent.count >= 80 else {
            throw RelayError.extraction("Extracted content is too short for the fixture article contract.")
        }
        let special = blocks.filter { [.code, .table, .footnote, .unsupported].contains($0.kind) }
        let warnings = conversion.warnings + (special.isEmpty ? [] : ["Special structures are retained; inspect narration treatment before speech acceptance."])
        try cleaned.head()?.appendElement("meta").attr("charset", "utf-8")
        try cleaned.title(result.title ?? "Untitled article")
        return ExtractedDocument(article: SemanticArticle(
            title: normalize(result.title ?? "Untitled article"), originalURL: originalURL, finalURL: finalURL,
            canonicalURL: canonicalURL.flatMap { ["https", "http"].contains($0.scheme ?? "") && $0.user == nil && $0.password == nil ? $0 : nil },
            author: result.byline, blocks: blocks, warnings: warnings, extractorVersion: version),
                                 cleanedHTML: "<!doctype html>\n" + (try cleaned.outerHtml()))
    }

    public static func semanticBlocks(html: String, baseURL: URL) throws -> [ContentBlock] {
        let document = try SwiftSoup.parseBodyFragment(html, baseURL.absoluteString)
        try markCaptions(document)
        return try convert(document, baseURL: baseURL, footnoteSource: document).blocks
    }

    // Preserve a site's explicit caption semantics before Readability removes CSS classes.
    private static func markCaptions(_ document: Document) throws {
        let candidates = try document.select("figcaption, .caption, .caption-content, .image-caption, .wp-caption-text, [role=doc-caption]")
        let identities = Set(candidates.map { ObjectIdentifier($0) })
        for element in candidates where !element.parents().contains(where: { identities.contains(ObjectIdentifier($0)) }) {
            try element.tagName("figcaption")
        }
    }

    private static func definition(_ element: Element) throws -> Bool {
        let id = try element.attr("id").lowercased(), role = try element.attr("role")
        guard !id.isEmpty, !id.hasPrefix("fnref"), !id.hasPrefix("cite_ref") else { return false }
        if ["doc-footnote", "doc-endnote", "doc-biblioentry"].contains(role) { return true }
        guard ["li", "p", "div", "aside"].contains(element.tagName()) else { return false }
        if id.range(of: #"^(fn[:_-]|fn[0-9]|footnote[:_-]|footnote[0-9]|cite_note)"#, options: .regularExpression) != nil { return true }
        return element.tagName() == "li" && element.parents().contains {
            $0.hasClass("footnotes") || (try? $0.attr("role")) == "doc-endnotes"
        }
    }

    private static func convert(_ document: Document, baseURL: URL, footnoteSource: Document) throws -> (blocks: [ContentBlock], warnings: [String]) {
        var definitions: [String: Element] = [:]
        var retainedDefinitions: Set<String> = []
        // Use original definitions when Readability discarded an appendix.
        for dom in [document, footnoteSource] {
            for element in try dom.select("[id]") where try definition(element) {
                let id = try element.attr("id")
                if dom === document { retainedDefinitions.insert(id) }
                if definitions[id] == nil { definitions[id] = element }
            }
        }
        var blocks: [ContentBlock] = []
        var referenced: [String] = []; var warnings: [String] = []
        let leafKinds: [String: ContentBlock.Kind] = ["p": .paragraph, "pre": .code, "table": .table, "figcaption": .caption, "caption": .caption]
        let containerTags: Set<String> = ["div", "section", "article", "main", "body", "header", "ul", "ol", "figure", "blockquote", "li", "aside", "dl", "dt", "dd"]
        let ignored: Set<String> = ["script", "style", "noscript", "nav", "footer", "img", "picture", "source", "svg", "canvas", "video", "audio", "iframe", "object", "embed"]

        func reference(_ element: Element) throws -> String? {
            let href = try element.attr("href")
            guard element.hasAttr("href") else { return nil }
            let role = try element.attr("role"), rel = try element.attr("rel").lowercased().split(separator: " ")
            var target: String?
            if href.hasPrefix("#") { target = String(href.dropFirst()).removingPercentEncoding }
            else if var destination = URLComponents(string: href), var base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
                let fragment = destination.fragment; destination.fragment = nil; base.fragment = nil
                if destination.url == base.url { target = fragment }
            }
            let epubType = try element.attr("epub:type")
            let explicitlyMarked = role == "doc-noteref" || rel.contains("footnote") || element.hasClass("footnote-ref")
                || element.hasClass("reference") || epubType == "noteref" || element.parents().contains {
                    $0.hasClass("reference") || $0.hasClass("footnote-ref") || (try? $0.attr("role")) == "doc-noteref"
                }
            let marker = normalize(try element.text())
            let markerLike = marker.count <= 16 && marker.range(of: #"^[\[\]()0-9*†‡§¶⁎⁕a-zA-Z]+$"#, options: .regularExpression) != nil
            if let target, !target.isEmpty,
               explicitlyMarked || (markerLike && (definitions[target] != nil || target.lowercased().range(of: #"^(fn[:_-]|fn[0-9]|footnote|cite_note)"#, options: .regularExpression) != nil)) {
                return target
            }
            return explicitlyMarked ? "unresolved:" + Files.hash(Data(href.utf8)) : nil
        }
        func backlink(_ element: Element) throws -> Bool {
            let role = try element.attr("role"), rev = try element.attr("rev")
            let href = try element.attr("href")
            return role == "doc-backlink" || rev == "footnote" || element.hasClass("footnote-backref")
                || href.hasPrefix("#fnref") || href.hasPrefix("#cite_ref")
        }
        func text(_ node: Node, references: inout [String]) throws -> (original: String, spoken: String) {
            if let node = node as? TextNode { return (node.getWholeText(), node.getWholeText()) }
            guard let element = node as? Element else { return ("", "") }
            if ignored.contains(element.tagName()) { return ("", "") }
            if element.tagName() == "br" { return ("\n", "\n") }
            if try backlink(element) { return (try element.text(), "") }
            if let id = try reference(element) {
                if !references.contains(id) { references.append(id) }
                if !referenced.contains(id) { referenced.append(id) }
                return (try element.text(), "")
            }
            var original = "", spoken = ""
            for child in element.getChildNodes() {
                let value = try text(child, references: &references)
                original += value.original; spoken += value.spoken
                if let child = child as? Element,
                   leafKinds[child.tagName()] != nil || containerTags.contains(child.tagName()) || ["td", "th", "tr"].contains(child.tagName()) {
                    original += " "; spoken += " "
                }
            }
            return (original, spoken)
        }
        func append(_ kind: ContentBlock.Kind, _ original: String, spoken: String, references: [String], level: Int? = nil, note: String? = nil, element: Element? = nil) throws {
            let original = kind == .code ? original.trimmingCharacters(in: .whitespacesAndNewlines) : normalize(original)
            var spoken = kind == .code ? spoken.trimmingCharacters(in: .whitespacesAndNewlines) : normalize(spoken)
            guard !original.isEmpty else { return }
            if kind == .caption, blocks.last?.kind == .caption, blocks.last?.text == original {
                try element?.remove()
                if !warnings.contains("Adjacent duplicate caption omitted.") { warnings.append("Adjacent duplicate caption omitted.") }
                return
            }
            let divider = spoken.filter { !$0.isWhitespace }
            if divider.count >= 3, divider.allSatisfy({ "*⁂⁎•·—–_-".contains($0) }) { spoken = "" }
            blocks.append(ContentBlock(kind: note != nil && ![.code, .table].contains(kind) ? .footnote : kind,
                text: original, headingLevel: level, narrationText: spoken == original ? nil : spoken,
                footnoteReferences: references.isEmpty ? nil : references, footnoteID: note))
        }
        func visit(_ element: Element, inherited: ContentBlock.Kind? = nil, note: String? = nil) throws {
            let tag = element.tagName().lowercased()
            if ignored.contains(tag) { return }
            if note == nil, try definition(element) { return }
            if tag.count == 2, tag.hasPrefix("h"), let n = Int(tag.dropFirst()), (1...6).contains(n) {
                var references: [String] = []; let value = try text(element, references: &references)
                try append(.heading, value.original, spoken: value.spoken, references: references, level: n, note: note); return
            }
            if let kind = leafKinds[tag] {
                var references: [String] = []; let value = try text(element, references: &references)
                try append(kind == .paragraph ? (inherited ?? kind) : kind, value.original, spoken: value.spoken,
                           references: references, note: note, element: element); return
            }
            let role = try element.attr("role")
            let kind: ContentBlock.Kind? = tag == "li" ? .listItem : tag == "blockquote" ? .quote : role == "doc-footnote" ? .footnote : inherited
            if !containerTags.contains(tag), kind == nil {
                var references: [String] = []; let value = try text(element, references: &references)
                try append(.unsupported, value.original, spoken: value.spoken, references: references, note: note); return
            }
            var inline = "", spoken = ""; var references: [String] = []
            func flush() throws {
                try append(kind ?? .paragraph, inline, spoken: spoken, references: references, note: note)
                inline = ""; spoken = ""; references = []
            }
            for node in element.getChildNodes() {
                if let text = node as? TextNode { inline += text.getWholeText(); spoken += text.getWholeText() }
                else if let child = node as? Element {
                    let t = child.tagName().lowercased()
                    if leafKinds[t] != nil || containerTags.contains(t) || (t.count == 2 && t.hasPrefix("h")) {
                        try flush(); try visit(child, inherited: kind, note: note)
                    } else {
                        let value = try text(child, references: &references)
                        inline += value.original; spoken += value.spoken
                    }
                }
            }
            try flush()
        }
        if let body = document.body() { try visit(body) }
        // Keep definitions in the semantic appendix; narration resolves their references inline.
        var ordered = referenced
        ordered += retainedDefinitions.filter { !ordered.contains($0) }.sorted()
        var inspected: Set<String> = []; var cursor = 0
        var recoveredList: Element?
        while cursor < ordered.count {
            let id = ordered[cursor]; cursor += 1
            guard inspected.insert(id).inserted else { continue }
            if let element = definitions[id] {
                var note = element
                if !retainedDefinitions.contains(id), let copied = element.copy() as? Element, let body = document.body() {
                    if recoveredList == nil {
                        let section = try body.appendElement("section"); try section.attr("role", "doc-endnotes")
                        recoveredList = try section.appendElement("ol")
                    }
                    if copied.tagName() != "li" { try copied.tagName("li") }
                    try recoveredList?.appendChild(copied); note = copied
                }
                try visit(note, note: id)
            }
            else { warnings.append("A marked footnote/citation could not be resolved; its marker is omitted from speech.") }
            for target in referenced where !ordered.contains(target) { ordered.append(target) }
        }
        return (blocks, warnings)
    }

    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\u{200b}", with: "")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

public enum Narration {
    public static let version = "conservative-2/footnotes-1/sentence-chunks-1"
    public static func prepare(_ article: SemanticArticle, limit: Int) throws -> NarrationPlan {
        guard limit > 0 else { throw RelayError.setup("Narration chunk limit must be positive.") }
        var chunks: [NarrationChunk] = []; var notices: [String] = []
        var noteIndices: [String: [Int]] = [:]
        for (index, block) in article.blocks.enumerated() {
            if let id = block.footnoteID { noteIndices[id, default: []].append(index) }
        }
        var emitted: Set<String> = []
        func emit(_ text: String, indices: [Int]) {
            let tokenizer = NLTokenizer(unit: .sentence); tokenizer.string = text
            var sentences: [String] = []
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                sentences.append(String(text[range])); return true
            }
            if sentences.isEmpty && !text.isEmpty { sentences = [text] }
            var current = ""
            func flush() {
                if !current.isEmpty { chunks.append(NarrationChunk(index: chunks.count, text: current, blockIndices: indices)) }
                current = ""
            }
            for sentence in sentences {
                var remainder = ArticleExtractor.normalize(sentence)
                while !remainder.isEmpty {
                    var part = remainder
                    if remainder.count > limit {
                        let boundary = remainder.index(remainder.startIndex, offsetBy: limit)
                        let prefix = remainder[..<boundary]
                        if let space = prefix.lastIndex(where: { $0.isWhitespace }), space != remainder.startIndex {
                            part = String(remainder[..<space]); remainder = String(remainder[space...]).trimmingCharacters(in: .whitespaces)
                        } else {
                            part = String(prefix); remainder = String(remainder[boundary...])
                        }
                    } else { remainder = "" }
                    let candidate = current.isEmpty ? part : current + " " + part
                    if candidate.count > limit { flush(); current = part } else { current = candidate }
                }
            }
            flush()
        }
        func content(_ index: Int) {
            let block = article.blocks[index]
            var text = ArticleExtractor.normalize(block.narrationText ?? block.text)
            if block.kind == .code || block.kind == .table {
                notices.append("Block \(index): \(block.kind.rawValue) retained in semantic artifact and omitted from narration.")
                text = block.kind == .code ? "Code block omitted from narration." : "Table omitted from narration."
            }
            if block.kind == .unsupported {
                notices.append("Block \(index): unsupported structure read as plain text; inspect before listening acceptance.")
            }
            emit(text, indices: [index])
            for id in block.footnoteReferences ?? [] { footnote(id, referredBy: index) }
        }
        func footnote(_ id: String, referredBy index: Int?) {
            guard emitted.insert(id).inserted else { return }
            guard let notes = noteIndices[id], notes.contains(where: { !ArticleExtractor.normalize(article.blocks[$0].narrationText ?? article.blocks[$0].text).isEmpty }) else {
                notices.append("A marked footnote/citation could not be resolved; its marker is omitted from speech.")
                return
            }
            let provenance = (index.map { [$0] } ?? []) + notes
            if index == nil { notices.append("Unreferenced footnote retained at the end of narration.") }
            emit("Footnote:", indices: provenance)
            for note in notes { content(note) }
            emit("End Footnote", indices: provenance)
        }
        for (index, block) in article.blocks.enumerated() where block.footnoteID == nil {
            if block.kind == .footnote {
                notices.append("Block \(index): standalone footnote read with spoken boundary cues.")
                emit("Footnote:", indices: [index]); content(index); emit("End Footnote", indices: [index])
            } else { content(index) }
        }
        for block in article.blocks {
            if let id = block.footnoteID, !emitted.contains(id) { footnote(id, referredBy: nil) }
        }
        guard !chunks.isEmpty else { throw RelayError.extraction("No narration chunks were produced.") }
        return NarrationPlan(version: version, chunks: chunks, notices: notices)
    }
}
