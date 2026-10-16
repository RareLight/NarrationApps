import Foundation
import CryptoKit
import NarrationCore
import SwiftReadability
import SwiftSoup
import NaturalLanguage

public struct ParsedWebArticle: Sendable {
    public let title: String
    public let originalURL: URL
    public let finalURL: URL
    public let canonicalURL: URL?
    public let author: String?
    public let blocks: [ContentBlock]
    public let warnings: [String]
    public let extractorVersion: String
    public let sourceName: String?
    public let previewImageURL: URL?
    public var document: SemanticDocument { .init(title: title, author: author, blocks: blocks, warnings: warnings, extractorVersion: extractorVersion) }
}

public enum DocumentProcessingError: Error, LocalizedError, Sendable {
    case extraction(String)
    public var errorDescription: String? { switch self { case .extraction(let message): message } }
}

public enum WebDocumentURL {
    @discardableResult public static func validate(_ url: URL) throws -> URL {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""), let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.port == nil || (1...65535).contains(c.port!) else {
            throw DocumentProcessingError.extraction("Invalid document URL.")
        }
        return url
    }
}

public struct ExtractedHTMLDocument: Sendable {
    public let article: ParsedWebArticle
    public let cleanedHTML: String
}

public enum HTMLDocumentExtractor {
    public static let version = "SwiftReadability-0.3.3/semantic-5-images/inline-code-1/anchors-1"
    public static func extract(html: String, originalURL: URL, finalURL: URL) throws -> ExtractedHTMLDocument {
        // Readers and DOMs stay in this invocation; neither is shared across tasks.
        let original = try SwiftSoup.parse(html, finalURL.absoluteString)
        let prepared = try SwiftSoup.parse(html, finalURL.absoluteString)
        try markCaptions(prepared)
        let reader = Readability(html: try prepared.outerHtml(), url: finalURL)
        guard let result = try reader.parse() else {
            throw DocumentProcessingError.extraction("No readable article selected. Inspect the private source snapshot.")
        }
        let canonical = try original.select("link[rel=canonical]").first()?.attr("href")
        let canonicalURL = canonical.flatMap { URL(string: $0, relativeTo: finalURL)?.absoluteURL }
        let cleaned = try SwiftSoup.parseBodyFragment(result.contentHTML, finalURL.absoluteString)
        try cleaned.select("header time, header a[title=Permalink], header a[rel=bookmark]").remove()
        try markNarrationImages(cleaned, baseURL: finalURL)
        let conversion = try convert(cleaned, baseURL: finalURL, footnoteSource: original)
        try cleaned.select("img, picture, source, svg, canvas, video, audio, iframe, object, embed, script, style, noscript").remove()
        let blocks = conversion.blocks
        guard blocks.contains(where: { !$0.text.isEmpty }), result.textContent.count >= 80 else {
            throw DocumentProcessingError.extraction("Extracted content is too short for the fixture article contract.")
        }
        let special = blocks.filter { [.code, .table, .footnote, .unsupported].contains($0.kind) }
        let warnings = conversion.warnings + (special.isEmpty ? [] : ["Special structures are retained; inspect narration treatment before speech acceptance."])
        try cleaned.head()?.appendElement("meta").attr("charset", "utf-8")
        try cleaned.title(result.title ?? "Untitled article")
        return ExtractedHTMLDocument(article: ParsedWebArticle(
            title: normalize(result.title ?? "Untitled article"), originalURL: originalURL, finalURL: finalURL,
            canonicalURL: canonicalURL.flatMap { ["https", "http"].contains($0.scheme ?? "") && $0.user == nil && $0.password == nil ? $0 : nil },
            author: result.byline, blocks: blocks, warnings: warnings, extractorVersion: version,
            sourceName: try metadata(original, key: "og:site_name").first.map { String(normalize($0).prefix(200)) },
            previewImageURL: try previewImage(original, baseURL: finalURL)),
                                 cleanedHTML: "<!doctype html>\n" + (try cleaned.outerHtml()))
    }

    private static func metadata(_ document: Document, key: String) throws -> [String] {
        try document.select("meta[property], meta[name]").compactMap { element in
            let name = try (element.hasAttr("property") ? element.attr("property") : element.attr("name"))
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = try element.attr("content").trimmingCharacters(in: .whitespacesAndNewlines)
            return name == key && !value.isEmpty ? value : nil
        }
    }
    /// Reuse the fetched page's standardized social preview metadata. No secondary
    /// image request is required, so absent or unusable art never blocks admission.
    private static func previewImage(_ document: Document, baseURL: URL) throws -> URL? {
        for key in ["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"] {
            for value in try metadata(document, key: key) where value.utf8.count <= 4096 {
                guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
                      url.scheme?.lowercased() == "https", (try? WebDocumentURL.validate(url)) != nil,
                      var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
                components.fragment = nil
                return components.url
            }
        }
        return nil
    }

    public static func semanticBlocks(html: String, baseURL: URL) throws -> [ContentBlock] {
        try semanticBlocks(html: html, baseURL: baseURL, epubResources: false).blocks
    }

    static func semanticBlocks(html: String, baseURL: URL, epubResources: Bool) throws -> (blocks: [ContentBlock], warnings: [String]) {
        let document = try SwiftSoup.parseBodyFragment(html, baseURL.absoluteString)
        try markCaptions(document)
        try markNarrationImages(document, baseURL: baseURL, epubResources: epubResources)
        return try convert(document, baseURL: baseURL, footnoteSource: document, publicationResources: epubResources)
    }

    private static func markNarrationImages(_ document: Document, baseURL: URL, epubResources: Bool = false) throws {
        for paragraph in try document.select("p") where !(try paragraph.select("img")).isEmpty() {
            try paragraph.tagName("div") // Keep prose and image descriptions as separate blocks.
        }
        for image in try document.select("img") {
            let hidden = try ([image] + image.parents().array()).contains { element in
                let aria = try element.attr("aria-hidden"), role = try element.attr("role")
                return element.hasAttr("hidden") || aria == "true" || role == "presentation"
            }
            let tiny = try ["width", "height"].contains { attribute in
                if let dimension = Int(try image.attr(attribute)) { return dimension < 40 }
                return false
            }
            let alt = normalize(try image.attr("alt"))
            // An explicit empty alt marks decorative content; never infer a caption.
            if hidden || tiny || (image.hasAttr("alt") && alt.isEmpty) { continue }
            var source: URL?
            for attribute in ["data-src", "data-original", "src"] {
                let value = try image.attr(attribute)
                if !value.isEmpty, let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
                   ((url.scheme == "https" && (try? WebDocumentURL.validate(url)) != nil) ||
                    (epubResources && url.scheme == "epub-resource" && url.host == baseURL.host)) { source = url; break }
            }
            let caption = Element(try Tag.valueOf("figcaption"), baseURL.absoluteString)
            try caption.attr("data-voicerelay-image", alt.isEmpty ? "pending" : "authored")
            if let source { try caption.attr("data-voicerelay-image-url", source.absoluteString) }
            try caption.text(alt.isEmpty ? "Image without a description" : alt)
            if let picture = image.parent(), picture.tagName() == "picture" { try picture.before(caption) }
            else { try image.before(caption) }
            try image.remove()
        }
    }

    // Preserve a site's explicit caption semantics before Readability removes CSS classes.
    private static func markCaptions(_ document: Document) throws {
        let candidates = try document.select("figcaption, .caption, .caption-content, .image-caption, .wp-caption-text, [role=doc-caption]")
        let identities = Set(candidates.map { ObjectIdentifier($0) })
        for element in candidates where !element.parents().contains(where: { identities.contains(ObjectIdentifier($0)) }) {
            try element.tagName("figcaption")
        }
    }

    static func definition(_ element: Element) throws -> Bool {
        let id = try element.attr("id").lowercased(), role = try element.attr("role")
        guard !id.isEmpty, !id.hasPrefix("fnref"), !id.hasPrefix("cite_ref") else { return false }
        if role == "doc-biblioentry" || role == "doc-bibliography" || element.parents().contains(where: { (try? $0.attr("role")) == "doc-bibliography" || (try? $0.attr("epub:type")) == "bibliography" }) { return false }
        if ["doc-footnote", "doc-endnote"].contains(role) { return true }
        let epubType = try element.attr("epub:type").split(whereSeparator: \.isWhitespace)
        if epubType.contains("footnote") || epubType.contains("endnote") { return true }
        guard ["li", "p", "div", "aside"].contains(element.tagName()) else { return false }
        if id.range(of: #"^(fn[:_-]|fn[0-9]|footnote[:_-]|footnote[0-9]|cite_note)"#, options: .regularExpression) != nil { return true }
        return element.tagName() == "li" && element.parents().contains {
            $0.hasClass("footnotes") || (try? $0.attr("role")) == "doc-endnotes"
        }
    }

    private static func convert(_ document: Document, baseURL: URL, footnoteSource: Document, publicationResources: Bool = false) throws -> (blocks: [ContentBlock], warnings: [String]) {
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
        var precedingSpokenBlock: (kind: ContentBlock.Kind, text: String)?
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
            let epubType = try element.attr("epub:type").split(whereSeparator: \.isWhitespace)
            let explicitlyMarked = role == "doc-noteref" || rel.contains("footnote") || element.hasClass("footnote-ref")
                || element.hasClass("reference") || epubType.contains("noteref") || element.parents().contains {
                    $0.hasClass("reference") || $0.hasClass("footnote-ref") || (try? $0.attr("role")) == "doc-noteref"
                }
            let marker = normalize(try element.text())
            let markerLike = marker.count <= 16 && marker.range(of: #"^[\[\]()0-9*†‡§¶⁎⁕a-zA-Z]+$"#, options: .regularExpression) != nil
            if let target, !target.isEmpty,
               explicitlyMarked || (markerLike && (definitions[target] != nil || target.lowercased().range(of: #"^(fn[:_-]|fn[0-9]|footnote|cite_note)"#, options: .regularExpression) != nil)) {
                return target
            }
            return explicitlyMarked ? "unresolved:" + SHA256.hash(data: Data(href.utf8)).map { String(format: "%02x", $0) }.joined() : nil
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
            if kind == .caption, element?.hasAttr("data-voicerelay-image") != true,
               precedingSpokenBlock?.kind == .caption, precedingSpokenBlock?.text == original {
                try element?.remove()
                if !warnings.contains("Adjacent duplicate caption omitted.") { warnings.append("Adjacent duplicate caption omitted.") }
                return
            }
            let divider = spoken.filter { !$0.isWhitespace }
            if divider.count >= 3, divider.allSatisfy({ "*⁂⁎•·—–_-".contains($0) }) { spoken = "" }
            let image = element?.hasAttr("data-voicerelay-image") == true
            let imageType = try element?.attr("data-voicerelay-image")
            let pending = image && imageType == "pending"
            let imageURL = image ? (try element?.attr("data-voicerelay-image-url")).flatMap { URL(string: $0) } : nil
            if pending { spoken = "" }
            else if image { spoken = "Image description: " + spoken }
            var owner = publicationResources ? element : nil
            var resourcePath: String?
            while let current = owner {
                if current.hasAttr("data-narration-resource") { resourcePath = try current.attr("data-narration-resource"); break }
                owner = current.parent()
            }
            var anchors: [String] = [], semanticRole: ContentRole?
            var ancestrySteps = 0
            var ancestor = element
            while let current = ancestor, ancestrySteps < 32 {
                ancestrySteps += 1
                let id = try current.attr("id")
                if !id.isEmpty { anchors.append(id) }
                let role = try current.attr("role"), types = try current.attr("epub:type").split(whereSeparator: \.isWhitespace)
                if role == "doc-bibliography" || role == "doc-biblioentry" || types.contains("bibliography") { semanticRole = .bibliography }
                else if semanticRole == nil && (role == "doc-appendix" || types.contains("appendix")) { semanticRole = .auxiliary }
                ancestor = current.parent()
            }
            blocks.append(ContentBlock(kind: note != nil && ![.code, .table].contains(kind) ? .footnote : kind,
                text: original, headingLevel: level, narrationText: spoken == original ? nil : spoken,
                footnoteReferences: references.isEmpty ? nil : references, footnoteID: note, imageURL: imageURL,
                origin: resourcePath == nil ? nil : .authored, resourcePath: resourcePath,
                containsInlineCode: try element.map { !(try $0.select("code")).isEmpty() } ?? false,
                sourceID: try element.flatMap { let id = try $0.attr("id"); return id.isEmpty ? nil : id },
                sourceAnchors: anchors.isEmpty ? nil : anchors, role: semanticRole))
            if !spoken.isEmpty { precedingSpokenBlock = (blocks.last!.kind, original) }
        }
        func visit(_ element: Element, inherited: ContentBlock.Kind? = nil, note: String? = nil) throws {
            let tag = element.tagName().lowercased()
            if ignored.contains(tag) { return }
            if note == nil, try definition(element) { return }
            if tag.count == 2, tag.hasPrefix("h"), let n = Int(tag.dropFirst()), (1...6).contains(n) {
                var references: [String] = []; let value = try text(element, references: &references)
                try append(.heading, value.original, spoken: value.spoken, references: references, level: n, note: note, element: element); return
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
                try append(.unsupported, value.original, spoken: value.spoken, references: references, note: note, element: element); return
            }
            var inline = "", spoken = ""; var references: [String] = []
            func flush() throws {
                try append(kind ?? .paragraph, inline, spoken: spoken, references: references, note: note, element: element)
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

    public static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\u{200b}", with: "")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
