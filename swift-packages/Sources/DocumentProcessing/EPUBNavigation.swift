import Foundation
import CryptoKit
import SwiftSoup
import NarrationCore

/// Navigation resources are metadata only; never schedule them as new spine prose.
enum EPUBNavigation {
    static func anchor(_ path: String, _ id: String) -> String {
        "epub-" + SHA256.hash(data: Data((path + "#" + id).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func read(container: EPUBContainer, package: EPUBPackage, blocks: [ContentBlock]) throws -> [DocumentOutlineEntry]? {
        guard let path = package.navigationPath ?? package.ncxPath else { return nil }
        let bytes = try container.read(path, maximum: 4_000_000)
        var entries: [DocumentOutlineEntry] = []
        // Indexed source anchors make TOC resolution linear in source size + entries.
        var resources: [String: Int] = [:], anchors: [String: Int] = [:], duplicateIDs = Set<String>()
        for (index, block) in blocks.enumerated() {
            guard let resource = block.resourcePath else { continue }
            if resources[resource] == nil { resources[resource] = index }
            for id in block.sourceAnchors ?? [] where anchors[id] == nil { anchors[id] = index }
            if let id = block.sourceID {
                if blocks[index].sourceAnchors?.first == id, let prior = anchors[id], prior != index,
                   blocks[prior].sourceID == id { duplicateIDs.insert(id) }
            }
        }
        func append(label: String, href: String?, depth: Int) throws {
            try Task.checkCancellation()
            guard depth < 32, entries.count < DocumentNavigation.maximumEntries else { throw EPUBReadError.limit }
            let label = NarrationText.normalizeWhitespace(label)
            guard !label.isEmpty, label.utf16.count <= 4096 else { return }
            let target = href.flatMap { try? EPUBContainer.reference($0, relativeTo: path) }
            let index: Int?
            if let target, let id = target.fragment {
                let key = anchor(target.path, id)
                index = duplicateIDs.contains(key) ? nil : anchors[key]
            } else { index = target.flatMap { resources[$0.path] } }
            entries.append(.init(id: "epub-outline-\(entries.count)", label: label, depth: depth,
                blockIndex: index, resourcePath: target?.path, fragment: target?.fragment,
                precision: index == nil ? .unresolved : .block))
        }
        if package.navigationPath != nil {
            let document = try SwiftSoup.parse(DocumentTextDecoder.decode(bytes).text)
            let toc = try document.select("nav").first { try $0.attr("epub:type").split(whereSeparator: \.isWhitespace).contains("toc") }
            guard let toc else { throw EPUBReadError.malformed }
            func list(_ node: Element, depth: Int) throws {
                guard depth < 32 else { throw EPUBReadError.limit }
                for item in node.children().array() where item.tagName() == "li" {
                    if let label = item.children().array().first(where: { ["a", "span"].contains($0.tagName()) }) {
                        try append(label: label.text(), href: label.tagName() == "a" ? label.attr("href") : nil, depth: depth)
                    }
                    for child in item.children().array() where child.tagName() == "ol" { try list(child, depth: depth + 1) }
                }
            }
            for child in toc.children().array() where child.tagName() == "ol" { try list(child, depth: 0) }
        } else {
            let tree = try parseEPUBXML(bytes)
            func visit(_ node: EPUBXMLNode, depth: Int) throws {
                guard depth < 32 else { throw EPUBReadError.limit }
                for point in node.children where point.name == "navPoint" {
                    let label = point.children.first(where: { $0.name == "navLabel" })?.descendants("text").first?.text ?? ""
                    try append(label: label, href: point.children.first(where: { $0.name == "content" })?.attributes["src"], depth: depth)
                    try visit(point, depth: depth + 1)
                }
            }
            if let map = tree.descendants("navMap").first { try visit(map, depth: 0) }
        }
        return entries
    }
}

public extension EPUBDocumentExtractor {
    /// Explicit optional cover selection; does not run image narration or fetch URLs.
    static func coverImage(data: Data) throws -> Data? {
        let container = try EPUBContainer(data: data, limits: .init())
        let package = try EPUBPackage(container: container)
        return try package.coverPath.map { try container.read($0, maximum: 20 * 1024 * 1024) }
    }
}
