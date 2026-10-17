import Foundation
import ZIPFoundation
import NarrationCore

public enum EPUBReadError: Error, LocalizedError, Sendable {
    case malformed, protected, unsafeReference, limit, unsupportedContent, empty
    public var errorDescription: String? {
        switch self {
        case .malformed: "The EPUB is damaged or references a missing book resource."
        case .protected: "This EPUB contains protected content. Import a DRM-free EPUB copy."
        case .unsafeReference: "The EPUB contains an invalid or external book resource reference."
        case .limit: "The EPUB exceeds the document resource or text budget."
        case .unsupportedContent: "An EPUB reading-order item has no readable XHTML or SVG fallback."
        case .empty: "No readable text or authored image descriptions were found in this EPUB."
        }
    }
}

public struct EPUBExtractionLimits: Sendable {
    public var maximumEntries: Int
    public var maximumExpandedBytes: Int
    public var maximumResourceBytes: Int
    public var maximumTextBytes: Int
    public var maximumChapters: Int
    public init(maximumEntries: Int = 20_000, maximumExpandedBytes: Int = 512_000_000,
                maximumResourceBytes: Int = 32_000_000, maximumTextBytes: Int = 32_000_000, maximumChapters: Int = 5_000) {
        self.maximumEntries = maximumEntries; self.maximumExpandedBytes = maximumExpandedBytes
        self.maximumResourceBytes = maximumResourceBytes; self.maximumTextBytes = maximumTextBytes
        self.maximumChapters = maximumChapters
    }
}

/// Entries are read to bounded buffers with CRC verification. No ZIP path is
/// ever unpacked onto the filesystem; no book resource initiates a network request.
final class EPUBContainer {
    private let archive: Archive
    private var entries: [String: Entry] = [:]
    let limits: EPUBExtractionLimits
    init(data: Data, limits: EPUBExtractionLimits) throws {
        guard limits.maximumEntries > 0, limits.maximumExpandedBytes > 0,
              limits.maximumResourceBytes > 0, limits.maximumTextBytes > 0, limits.maximumChapters > 0,
              data.count <= 512_000_000 else { throw EPUBReadError.limit }
        self.limits = limits
        do { archive = try Archive(data: data, accessMode: .read) }
        catch { throw EPUBReadError.malformed }
        var expanded: UInt64 = 0, count = 0
        for entry in archive {
            try Task.checkCancellation()
            count += 1
            guard count <= limits.maximumEntries,
                  entry.uncompressedSize <= UInt64(limits.maximumResourceBytes),
                  entry.uncompressedSize <= UInt64(limits.maximumExpandedBytes) - expanded else { throw EPUBReadError.limit }
            expanded += entry.uncompressedSize
            let name = entry.path
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"),
                  !components.contains(where: { $0 == "." || $0 == ".." }), entry.type != .symlink else { throw EPUBReadError.unsafeReference }
            if entry.type == .directory { continue }
            guard !components.contains(where: \.isEmpty), entries.updateValue(entry, forKey: name) == nil else { throw EPUBReadError.malformed }
        }
        guard try read("mimetype", maximum: 64) == Data("application/epub+zip".utf8) else { throw EPUBReadError.malformed }
        if contains("META-INF/license.lcpl") { throw EPUBReadError.protected }
    }
    func contains(_ path: String) -> Bool { entries[path] != nil }
    func read(_ path: String, maximum: Int? = nil) throws -> Data {
        try Task.checkCancellation()
        guard let entry = entries[path] else { throw EPUBReadError.malformed }
        let limit = min(maximum ?? limits.maximumResourceBytes, limits.maximumResourceBytes)
        guard entry.uncompressedSize <= UInt64(max(0, limit)) else { throw EPUBReadError.limit }
        var data = Data()
        let checksum: CRC32
        do {
            checksum = try archive.extract(entry, bufferSize: 65_536) { buffer in
                try Task.checkCancellation()
                guard buffer.count <= limit - data.count else { throw EPUBReadError.limit }
                data.append(buffer)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as EPUBReadError { throw error }
        catch { throw EPUBReadError.malformed }
        guard checksum == entry.checksum, UInt64(data.count) == entry.uncompressedSize else { throw EPUBReadError.malformed }
        return data
    }

    static func reference(_ raw: String, relativeTo resource: String = "") throws -> (path: String, fragment: String?) {
        guard !raw.isEmpty, !raw.contains("\\"), !raw.contains("\0"),
              let uri = URLComponents(string: raw), uri.scheme == nil, uri.host == nil, uri.query == nil,
              let decoded = uri.percentEncodedPath.removingPercentEncoding,
              !decoded.hasPrefix("/"), !decoded.contains("\\"), !decoded.contains("\0") else { throw EPUBReadError.unsafeReference }
        var parts = resource.split(separator: "/").dropLast().map(String.init)
        if decoded.isEmpty { return (resource, uri.fragment) }
        for part in decoded.split(separator: "/", omittingEmptySubsequences: false) {
            switch part {
            case ".": continue
            case "..": guard !parts.isEmpty else { throw EPUBReadError.unsafeReference }; parts.removeLast()
            case "": throw EPUBReadError.unsafeReference
            default: parts.append(String(part))
            }
        }
        guard !parts.isEmpty else { throw EPUBReadError.unsafeReference }
        return (parts.joined(separator: "/"), uri.fragment)
    }
}

final class EPUBXMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [EPUBXMLNode] = []
    init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
    func descendants(_ name: String) -> [EPUBXMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
}

/// Small OCF/OPF adapter over Foundation XMLParser, not an XML/ZIP implementation.
/// External entity resolution is disabled and entity declarations abort parsing.
private final class EPUBXMLParser: NSObject, XMLParserDelegate {
    var root: EPUBXMLNode?
    var stack: [EPUBXMLNode] = []
    var count = 0
    var rejected = false
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        count += 1
        if stack.count >= 64 || count > 50_000 || Task.isCancelled { rejected = true; parser.abortParsing(); return }
        let node = EPUBXMLNode(name, attributes)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA bytes: Data) {
        guard let text = String(data: bytes, encoding: .utf8) else { rejected = true; parser.abortParsing(); return }
        stack.last?.text += text
    }
    func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName: String, value: String?) { rejected = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName: String, publicID: String?, systemID: String?) { rejected = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, resolveExternalEntityName: String, systemID: String?) -> Data? { rejected = true; parser.abortParsing(); return nil }
}

func parseEPUBXML(_ bytes: Data) throws -> EPUBXMLNode {
    try Task.checkCancellation()
    guard bytes.count <= 4_000_000 else { throw EPUBReadError.limit }
    let parser = XMLParser(data: bytes), delegate = EPUBXMLParser()
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    parser.delegate = delegate
    guard parser.parse(), !delegate.rejected, let root = delegate.root else {
        try Task.checkCancellation(); throw EPUBReadError.malformed
    }
    return root
}

struct EPUBManifestItem {
    let id: String
    let path: String
    let mediaType: String
    let fallback: String?
}

struct EPUBPackage {
    let title: String?
    let author: String?
    let manifest: [String: EPUBManifestItem]
    let navigationPath: String?
    let ncxPath: String?
    let coverPath: String?
    let coverPagePath: String?
    let spine: [(id: String, auxiliary: Bool)]
    init(container: EPUBContainer) throws {
        let ocf = try parseEPUBXML(container.read("META-INF/container.xml", maximum: 4_000_000))
        guard ocf.name == "container", let rootfile = ocf.descendants("rootfile").first(where: { $0.attributes["media-type"] == "application/oebps-package+xml" }),
              let fullPath = rootfile.attributes["full-path"] else { throw EPUBReadError.malformed }
        let path = try EPUBContainer.reference(fullPath).path
        let opf = try parseEPUBXML(container.read(path, maximum: 4_000_000))
        guard opf.name == "package", let version = opf.attributes["version"], version.hasPrefix("2.") || version.hasPrefix("3."),
              let metadata = opf.children.first(where: { $0.name == "metadata" }),
              let resources = opf.children.first(where: { $0.name == "manifest" }),
              let reading = opf.children.first(where: { $0.name == "spine" }) else { throw EPUBReadError.malformed }
        title = metadata.children.first(where: { $0.name == "title" })?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let authors = metadata.children.filter { $0.name == "creator" }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        author = authors.isEmpty ? nil : authors.joined(separator: ", ")
        var items: [String: EPUBManifestItem] = [:]
        for node in resources.children where node.name == "item" {
            guard let id = node.attributes["id"], !id.isEmpty, items[id] == nil,
                  let href = node.attributes["href"], let type = node.attributes["media-type"] else { throw EPUBReadError.malformed }
            // Non-reading resources can be external in EPUB 3. They remain inert
            // and are never fetched; a remote spine dependency fails explicitly.
            guard let target = try? EPUBContainer.reference(href, relativeTo: path), target.fragment == nil else { continue }
            items[id] = .init(id: id, path: target.path, mediaType: type, fallback: node.attributes["fallback"])
        }
        var order: [(String, Bool)] = []
        for node in reading.children where node.name == "itemref" {
            guard let id = node.attributes["idref"], items[id] != nil else { throw EPUBReadError.malformed }
            order.append((id, node.attributes["linear"] == "no"))
        }
        guard !order.isEmpty, order.count <= container.limits.maximumChapters else { throw EPUBReadError.limit }
        let navID = resources.children.first { ($0.attributes["properties"] ?? "").split(whereSeparator: \.isWhitespace).contains("nav") }?.attributes["id"]
        navigationPath = navID.flatMap { items[$0]?.path }
        ncxPath = reading.attributes["toc"].flatMap { items[$0]?.path }
        let coverID = resources.children.first { ($0.attributes["properties"] ?? "").split(whereSeparator: \.isWhitespace).contains("cover-image") }?.attributes["id"]
            ?? metadata.children.first { $0.name == "meta" && $0.attributes["name"] == "cover" }?.attributes["content"]
        coverPath = coverID.flatMap { items[$0] }.flatMap { ["image/jpeg", "image/png"].contains($0.mediaType) ? $0.path : nil }
        let markedPage = coverID.flatMap { items[$0] }.flatMap {
            ["application/xhtml+xml", "text/html", "image/svg+xml"].contains($0.mediaType) ? $0.path : nil
        }
        let guideCover = opf.children.first { $0.name == "guide" }?.children.first {
            $0.name == "reference" && ($0.attributes["type"] ?? "").split(whereSeparator: \.isWhitespace).contains("cover")
        }?.attributes["href"]
        coverPagePath = markedPage ?? guideCover.flatMap { try? EPUBContainer.reference($0, relativeTo: path).path }
        manifest = items; spine = order
        if container.contains("META-INF/encryption.xml") {
            let encryption = try parseEPUBXML(container.read("META-INF/encryption.xml", maximum: 4_000_000))
            guard encryption.name == "encryption" else { throw EPUBReadError.malformed }
            for node in encryption.descendants("EncryptedData") {
                let algorithm = node.descendants("EncryptionMethod").first?.attributes["Algorithm"]
                let uri = node.descendants("CipherReference").first?.attributes["URI"]
                guard let algorithm, ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"].contains(algorithm),
                      let uri, let font = try? EPUBContainer.reference(uri).path,
                      items.values.contains(where: { $0.path == font && ($0.mediaType.contains("font") || ["otf", "ttf", "woff", "woff2"].contains((font as NSString).pathExtension.lowercased())) }) else { throw EPUBReadError.protected }
            }
            if !encryption.descendants("EncryptedKey").isEmpty { throw EPUBReadError.protected }
        }
    }
    func readable(_ id: String) throws -> EPUBManifestItem {
        var cursor: String? = id, seen: Set<String> = []
        while let value = cursor {
            guard seen.insert(value).inserted, let item = manifest[value] else { throw EPUBReadError.unsupportedContent }
            if ["application/xhtml+xml", "text/html", "image/svg+xml"].contains(item.mediaType) { return item }
            cursor = item.fallback
        }
        throw EPUBReadError.unsupportedContent
    }
}
