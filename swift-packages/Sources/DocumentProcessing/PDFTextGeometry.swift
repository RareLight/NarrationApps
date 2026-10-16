import Foundation
import PDFKit
import NarrationCore

/// PDFKit owns text order and line finding. Unsupported geometry abstains as a
/// whole page; it must never change text, trigger OCR or bypass intake limits.
enum PDFTextGeometry {
    static let maximumLinesPerPage = 1_024
    static let maximumLines = 100_000

    static func normalized(_ rect: CGRect, crop: CGRect, rotation: Int) -> PDFTextBounds? {
        guard !rect.isNull, !rect.isEmpty, crop.width > 0, crop.height > 0,
              [rect.minX, rect.minY, rect.width, rect.height, crop.minX, crop.minY, crop.width, crop.height].allSatisfy(\.isFinite),
              [0, 90, 180, 270].contains(rotation) else { return nil }
        let points = [(rect.minX, rect.minY), (rect.minX, rect.maxY), (rect.maxX, rect.minY), (rect.maxX, rect.maxY)].map { x, y -> (Double, Double) in
            let a = (x - crop.minX) / crop.width, b = (y - crop.minY) / crop.height
            switch rotation {
            case 90: return (b, 1 - a)
            case 180: return (1 - a, 1 - b)
            case 270: return (1 - b, a)
            default: return (a, b)
            }
        }
        let x = points.map(\.0), y = points.map(\.1)
        let result = PDFTextBounds(x: x.min()!, y: y.min()!, width: x.max()! - x.min()!, height: y.max()! - y.min()!)
        return result.isValid ? result : nil
    }

    static func capture(page: PDFPage, text: String, blocks: [ContentBlock], remaining: Int) throws -> [PDFTextLayout]? {
        guard text == page.string, page.numberOfCharacters == text.utf16.count,
              page.numberOfCharacters <= 128_000, remaining > 0,
              text.utf16.lazy.filter({ $0 == 10 || $0 == 13 }).prefix(maximumLinesPerPage + 1).count <= maximumLinesPerPage else { return nil }
        let crop = page.bounds(for: .cropBox), rotation = (page.rotation % 360 + 360) % 360
        guard let selection = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)) else { return nil }
        let selections = selection.selectionsByLine()
        guard selections.count <= min(maximumLinesPerPage, remaining) else { return nil }
        let ns = text as NSString
        var lines: [PDFTextLine] = [], previousEnd = 0
        for selection in selections {
            try Task.checkCancellation()
            guard selection.numberOfTextRanges(on: page) == 1 else { return nil }
            let range = selection.range(at: 0, on: page)
            guard range.location != NSNotFound, range.location >= previousEnd, range.length > 0,
                  range.location <= ns.length, range.length <= ns.length - range.location,
                  Range(range, in: text) != nil,
                  NarrationText.normalizeWhitespace(ns.substring(with: range)) == NarrationText.normalizeWhitespace(selection.string ?? ""),
                  let bounds = normalized(selection.bounds(for: page), crop: crop, rotation: rotation) else { return nil }
            guard ns.substring(with: NSRange(location: previousEnd, length: range.location - previousEnd)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            lines.append(.init(location: range.location, length: range.length, bounds: bounds))
            previousEnd = NSMaxRange(range)
        }
        guard ns.substring(from: previousEnd).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var output: [PDFTextLayout] = [], start = 0, lineIndex = 0
        for block in blocks {
            let length = block.text.utf16.count, end = start + length
            var retained: [PDFTextLine] = []
            while lineIndex < lines.count && lines[lineIndex].location < end {
                let line = lines[lineIndex]
                guard line.location >= start, line.length <= end - line.location else { return nil }
                retained.append(.init(location: line.location - start, length: line.length, bounds: line.bounds))
                lineIndex += 1
            }
            output.append(.init(basis: .cropBox, rotation: rotation, lines: retained))
            start = end
        }
        guard start == ns.length, lineIndex == lines.count else { return nil }
        return output
    }
}
