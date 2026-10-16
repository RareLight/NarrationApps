import Foundation
import PDFKit
import NarrationCore

enum PDFNavigation {
    static func entries(_ pdf: PDFDocument, blocks: [ContentBlock]) throws -> [DocumentOutlineEntry]? {
        guard let root = pdf.outlineRoot else { return nil }
        var result: [DocumentOutlineEntry] = [], visited = Set<ObjectIdentifier>()
        var firstOnPage: [Int: Int] = [:]
        for (index, block) in blocks.enumerated() { if let page = block.pdfPageIndex, firstOnPage[page] == nil { firstOnPage[page] = index } }
        func visit(_ node: PDFOutline, depth: Int) throws {
            try Task.checkCancellation()
            guard depth < 32, result.count < DocumentNavigation.maximumEntries, visited.count < DocumentNavigation.maximumEntries else { throw DocumentProcessingError.extraction("The PDF outline exceeds its navigation budget.") }
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            for i in 0..<min(node.numberOfChildren, DocumentNavigation.maximumEntries - result.count) {
                guard result.count < DocumentNavigation.maximumEntries else { throw DocumentProcessingError.extraction("The PDF outline exceeds its navigation budget.") }
                guard let child = node.child(at: i) else { continue }
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                let page = destination?.page.map { pdf.index(for: $0) }.flatMap { (0..<pdf.pageCount).contains($0) ? $0 : nil }
                let label = NarrationText.normalizeWhitespace(child.label ?? "")
                if !label.isEmpty {
                    result.append(.init(id: "pdf-outline-\(result.count)", label: label, depth: depth,
                        blockIndex: page.flatMap { firstOnPage[$0] }, pageIndex: page,
                        precision: page == nil ? .unresolved : .page))
                }
                try visit(child, depth: depth + 1)
            }
        }
        try visit(root, depth: 0)
        return result
    }
}
