import Foundation
import CryptoKit
import SwiftSoup
import NarrationCore

public enum EPUBDocumentExtractor {
    public static let version = "OCF-EPUB2-3/ZIPFoundation-0.9.20/FoundationXML/semantic-1/inline-code-1"
    public static func extract(data: Data, title: String? = nil, limits: EPUBExtractionLimits = .init(),
                               describeImages: Bool = false, caption: ImageDescriptions.Caption? = nil,
                               progress: @escaping @Sendable (DocumentPreparationProgress) -> Void = { _ in }) async throws -> SemanticDocument {
        let prepared = try read(data: data, title: title, limits: limits, loadImages: describeImages, progress: progress)
        let images = prepared.images
        return try await DocumentImages.enrich(prepared.document, enabled: describeImages, progress: progress,
            fetch: { url in guard let bytes = images[url] else { throw EPUBReadError.malformed }; return bytes }, caption: caption)
    }

    struct Prepared {
        let document: SemanticDocument
        let images: [URL: Data]
    }
    static func read(data: Data, title: String?, limits: EPUBExtractionLimits = .init(), loadImages: Bool = false,
                     progress: @Sendable (DocumentPreparationProgress) -> Void = { _ in }) throws -> Prepared {
        progress(.init(stage: .readingEPUBStructure))
        let container = try EPUBContainer(data: data, limits: limits)
        let package = try EPUBPackage(container: container)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let base = URL(string: "epub-resource://\(digest)/")!
        var queue = try package.spine.map { (try package.readable($0.id), false) }
        var scheduled = Set(queue.map { $0.0.path }), read = Set<String>()
        var warnings: [String] = [], textBytes = 0, position = 0
        if package.spine.contains(where: \.auxiliary) {
            warnings.append("Includes auxiliary spine sections in their declared order; review narration placement.")
        }
        let combined = try SwiftSoup.parse("<html><body></body></html>", base.absoluteString)
        let body = combined.body()!
        func anchor(_ path: String, _ id: String) -> String {
            EPUBNavigation.anchor(path, id)
        }
        func isNoteReference(_ element: Element) throws -> Bool {
            try element.attr("role") == "doc-noteref" || element.attr("epub:type").split(whereSeparator: \.isWhitespace).contains("noteref") || element.hasClass("footnote-ref")
        }
        while position < queue.count {
            try Task.checkCancellation()
            guard queue.count <= limits.maximumChapters else { throw EPUBReadError.limit }
            let (item, auxiliary) = queue[position]
            progress(.init(stage: .extractingEPUBChapter, completed: position, total: queue.count, unit: .chapters, currentChapter: position + 1))
            position += 1
            guard read.insert(item.path).inserted else { throw EPUBReadError.malformed }
            let decoded = try DocumentTextDecoder.decode(container.read(item.path))
            warnings += decoded.warnings
            textBytes += decoded.text.utf8.count
            guard textBytes <= limits.maximumTextBytes else { throw EPUBReadError.limit }
            let resourceURL = base.appendingPathComponent(item.path)
            let html: String
            if item.mediaType == "image/svg+xml" {
                html = try svgText(decoded.text)
                warnings.append("SVG reading-order text uses document order; review fixed-layout reading order.")
            } else { html = decoded.text }
            let chapter = try SwiftSoup.parse(html, resourceURL.absoluteString)
            try chapter.select("base, script, style, iframe, object, embed").remove()
            for element in try chapter.select("[data-narration-resource]") { try element.removeAttr("data-narration-resource") }
            let section = try body.appendElement("section").attr("data-narration-resource", item.path)
            let chapterBody = chapter.body()!
            // Retain only semantic note definitions when a non-spine resource
            // was reached through an explicit note reference.
            if auxiliary {
                let definitions = try chapter.select("[id]").filter { try HTMLDocumentExtractor.definition($0) }
                for definition in definitions where !definition.parents().contains(where: { parent in definitions.contains { $0 === parent } }) {
                    try section.appendChild(definition.copy() as! Element)
                }
            } else { try section.html(chapterBody.html()) }
            for svg in try section.select("svg") where !svg.parents().contains(where: { $0.tagName() == "svg" }) {
                try svg.before(svgText(svg.outerHtml())); try svg.remove()
            }
            let nodes = try section.select("[id]")
            var identifiers = Set<String>()
            for element in nodes {
                guard identifiers.insert(try element.attr("id")).inserted else { throw EPUBReadError.malformed }
                if try HTMLDocumentExtractor.definition(element) { try element.attr("role", "doc-footnote") }
                try element.attr("id", anchor(item.path, element.attr("id")))
            }
            for link in try section.select("a[href]") {
                let href = try link.attr("href")
                if let reference = try? EPUBContainer.reference(href, relativeTo: item.path) {
                    if let fragment = reference.fragment {
                        if try isNoteReference(link), !scheduled.contains(reference.path) {
                            guard let target = package.manifest.values.first(where: { $0.path == reference.path }),
                                  ["application/xhtml+xml", "text/html"].contains(target.mediaType) else { throw EPUBReadError.malformed }
                            scheduled.insert(reference.path); queue.append((target, true))
                        }
                        try link.attr("href", "#" + anchor(reference.path, fragment))
                    }
                }
            }
            for image in try section.select("img") {
                for attribute in ["data-src", "data-original", "src"] where image.hasAttr(attribute) {
                    if let target = try? EPUBContainer.reference(image.attr(attribute), relativeTo: item.path) {
                        try image.attr(attribute, base.appendingPathComponent(target.path).absoluteString)
                    } else {
                        try image.removeAttr(attribute)
                        warnings.append("External or invalid image references were not loaded; authored descriptions remain available.")
                    }
                }
            }
            progress(.init(stage: .extractingEPUBChapter, completed: position, total: queue.count, unit: .chapters))
        }
        let conversion = try HTMLDocumentExtractor.semanticBlocks(html: body.html(), baseURL: base, epubResources: true)
        let blocks = conversion.blocks
        warnings += conversion.warnings
        guard blocks.contains(where: { !($0.narrationText ?? $0.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw EPUBReadError.empty }
        guard blocks.reduce(0, { $0 + $1.text.utf8.count }) <= limits.maximumTextBytes else { throw EPUBReadError.limit }
        var images: [URL: Data] = [:], imageBytes = 0
        if loadImages {
            let resources = Set(package.manifest.values.filter { $0.mediaType.hasPrefix("image/") }.map(\.path))
            for block in blocks where block.narrationText == "" {
                guard images.count < 20, let url = block.imageURL, url.scheme == base.scheme, url.host == base.host,
                      resources.contains(String(url.path.dropFirst())), images[url] == nil else { continue }
                if let bytes = try? container.read(String(url.path.dropFirst()), maximum: 2_000_000), imageBytes + bytes.count <= 16_000_000 {
                    images[url] = bytes; imageBytes += bytes.count
                }
            }
        }
        var outline: [DocumentOutlineEntry]?
        do {
            outline = try EPUBNavigation.read(container: container, package: package, blocks: blocks)
            if outline?.contains(where: { $0.precision == .unresolved }) == true { warnings.append("Some outline destinations are unavailable; narration retains spine order.") }
        } catch is CancellationError { throw CancellationError() }
        catch { warnings.append("The book outline could not be read; narration retains spine order.") }
        let uniqueWarnings = warnings.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return .init(document: .init(title: package.title?.isEmpty == false ? package.title : title, author: package.author,
                                    blocks: blocks, warnings: uniqueWarnings, extractorVersion: version, outline: outline), images: images)
    }

    private static func svgText(_ xml: String) throws -> String {
        let svg = try SwiftSoup.parse(xml, "", Parser.xmlParser())
        let output = try SwiftSoup.parse("<html><body></body></html>")
        let body = output.body()!
        if let title = try svg.select("svg > title").first(), !(try title.text()).isEmpty { try body.appendElement("h1").text(title.text()) }
        if let description = try svg.select("svg > desc").first(), !(try description.text()).isEmpty { try body.appendElement("figcaption").text(description.text()) }
        for text in try svg.select("text") where !text.parents().contains(where: { $0.tagName() == "defs" }) {
            try body.appendElement("p").text(text.text())
        }
        for content in try svg.select("foreignObject") { try body.appendElement("section").html(content.html()) }
        for image in try svg.select("image") {
            let source = try image.hasAttr("href") ? image.attr("href") : image.attr("xlink:href")
            try body.appendElement("img").attr("src", source)
        }
        return try output.outerHtml()
    }
}
