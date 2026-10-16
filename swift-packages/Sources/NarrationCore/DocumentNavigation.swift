import Foundation

public struct DocumentOutlineEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Precision: String, Codable, Sendable { case block, page, unresolved }
    public let id: String
    public let label: String
    public let depth: Int
    public let blockIndex: Int?
    public let pageIndex: Int?
    public let resourcePath: String?
    public let fragment: String?
    public let precision: Precision
    public init(id: String, label: String, depth: Int = 0, blockIndex: Int? = nil,
                pageIndex: Int? = nil, resourcePath: String? = nil, fragment: String? = nil,
                precision: Precision = .block) {
        self.id = id; self.label = String(label.prefix(4096)); self.depth = min(max(depth, 0), 31)
        self.blockIndex = blockIndex; self.pageIndex = pageIndex
        self.resourcePath = resourcePath; self.fragment = fragment; self.precision = precision
    }
    public func shiftedForInsertion(at index: Int) -> Self {
        .init(id: id, label: label, depth: depth, blockIndex: blockIndex.map { $0 >= index ? $0 + 1 : $0 },
              pageIndex: pageIndex, resourcePath: resourcePath, fragment: fragment, precision: precision)
    }
}

public enum DocumentNavigation {
    public static let maximumEntries = 4096
    public static func headings(in blocks: [ContentBlock]) -> [DocumentOutlineEntry] {
        blocks.enumerated().lazy.filter { $0.element.kind == .heading }.prefix(maximumEntries).map { index, block in
            .init(id: "heading-\(index)", label: NarrationText.normalizeWhitespace(block.text),
                  depth: max(0, (block.headingLevel ?? 1) - 1), blockIndex: index,
                  pageIndex: block.pdfPageIndex, resourcePath: block.resourcePath, fragment: block.sourceID)
        }
    }
}

public extension SemanticDocument {
    var navigationEntries: [DocumentOutlineEntry] { outline ?? DocumentNavigation.headings(in: blocks) }
}

public enum ContentRole: String, Codable, Sendable { case auxiliary, bibliography }
