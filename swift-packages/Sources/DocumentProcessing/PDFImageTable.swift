import Foundation
import CoreGraphics
import NarrationCore

/// A caption followed by an image-only area is evidence for a missing table,
/// not permission to OCR/replace the surrounding authored page.
enum PDFImageTable {
    struct Candidate {
        let label: String
        let bounds: CGRect
    }
    static func candidate(_ blocks: [ContentBlock]) -> Candidate? {
        let lines = blocks.flatMap { block -> [(String, PDFTextBounds)] in
            guard let layout = block.pdfLayout, layout.basis == .cropBox, layout.rotation == 0 else { return [] }
            let ns = block.text as NSString
            return layout.lines.compactMap { line in
                guard line.location >= 0, line.length > 0, line.location <= ns.length,
                      line.length <= ns.length - line.location, line.bounds.isValid else { return nil }
                return (NarrationText.normalizeWhitespace(ns.substring(with: NSRange(location: line.location, length: line.length))), line.bounds)
            }
        }
        for (text, bounds) in lines {
            guard text.range(of: #"^Table\s+(?:[0-9]+|[IVX]+)\s+[A-Z]"#, options: .regularExpression) != nil,
                  (0.12...0.65).contains(bounds.y),
                  !lines.contains(where: { $0.1.y < bounds.y - 0.01 && $0.1.y > 0.08 }) else { continue }
            return .init(label: text, bounds: CGRect(x: 0, y: 0.04, width: 1, height: bounds.y - 0.045))
        }
        return nil
    }
    static func crop(_ image: CGImage, to bounds: CGRect) -> CGImage? {
        image.cropping(to: CGRect(x: bounds.minX * Double(image.width),
            y: (1 - bounds.maxY) * Double(image.height), width: bounds.width * Double(image.width),
            height: bounds.height * Double(image.height)).integral)
    }
    static func recovered(_ blocks: [ContentBlock], caption: String) -> [ContentBlock] {
        let tables = blocks.filter { $0.kind == .table }
        return tables.isEmpty ? [.init(kind: .table, text: caption,
            narrationText: "Table image. Its contents could not be read reliably. See the original document.", origin: .generated)] : tables
    }
}
