import Foundation

/// A bounded whitespace-gutter/vertical-band analysis, using retained PDFKit lines.
/// Full-width titles divide bands; overlapping/irregular layouts retain native order.
enum PDFColumnReadingOrder {
    static func order(_ lines: [PDFTextLine], text: String) -> [PDFTextLine]? {
        guard lines.count >= 12 else { return nil }
        let ns = text as NSString
        let body = lines.filter {
            let b = $0.bounds
            return $0.length >= 25 && b.y > 0.09 && b.y < 0.91 &&
                b.width > 0.18 && (0.008...0.035).contains(b.height)
        }
        guard body.count >= 12, body.count * 2 >= lines.count else { return nil }
        var best: (gutter: Double, score: Int)?
        for step in 25...75 {
            let gutter = Double(step) / 100
            let left = body.filter { $0.bounds.x + $0.bounds.width <= gutter - 0.008 }
            let right = body.filter { $0.bounds.x >= gutter + 0.008 }
            guard left.count >= 6, right.count >= 6, left.count + right.count >= body.count * 4 / 5,
                  left.map({ $0.bounds.x }).max()! - left.map({ $0.bounds.x }).min()! <= 0.08,
                  right.map({ $0.bounds.x }).max()! - right.map({ $0.bounds.x }).min()! <= 0.08,
                  let leftTop = left.map({ $0.bounds.y }).max(), let leftBottom = left.map({ $0.bounds.y }).min(),
                  let rightTop = right.map({ $0.bounds.y }).max(), let rightBottom = right.map({ $0.bounds.y }).min(),
                  min(leftTop, rightTop) - max(leftBottom, rightBottom) >= 0.12 else { continue }
            let score = min(left.count, right.count)
            if score > (best?.score ?? 0) { best = (gutter, score) }
        }
        guard let gutter = best?.gutter else { return nil }
        let spanners = lines.filter { $0.bounds.x < gutter && $0.bounds.x + $0.bounds.width > gutter }
            .sorted { $0.bounds.y > $1.bounds.y }
        let narrow = lines.filter { line in !spanners.contains(where: { $0.location == line.location }) }
        // A full-width paragraph beside column text is an irregular layout, not a heading.
        for span in spanners {
            if narrow.contains(where: { abs($0.bounds.y - span.bounds.y) < min($0.bounds.height, span.bounds.height) * 0.7 }) { return nil }
        }
        var remaining = narrow, ordered: [PDFTextLine] = []
        func band(_ values: [PDFTextLine]) -> [PDFTextLine] {
            let left = values.filter { $0.bounds.x + $0.bounds.width <= gutter }
            let right = values.filter { $0.bounds.x >= gutter }
            guard left.count + right.count == values.count else { return values.sorted { $0.location < $1.location } }
            func topDown(_ a: PDFTextLine, _ b: PDFTextLine) -> Bool {
                if a.bounds.y == b.bounds.y { return a.bounds.x < b.bounds.x }
                return a.bounds.y > b.bounds.y
            }
            return left.sorted(by: topDown) + right.sorted(by: topDown)
        }
        for span in spanners {
            let above = remaining.filter { $0.bounds.y > span.bounds.y }
            ordered += band(above); ordered.append(span)
            remaining.removeAll { $0.bounds.y > span.bounds.y }
        }
        ordered += band(remaining)
        guard ordered.count == lines.count, Set(ordered.map(\.location)).count == lines.count,
              ordered.map(\.location) != lines.map(\.location),
              ordered.allSatisfy({ NSMaxRange(NSRange(location: $0.location, length: $0.length)) <= ns.length }) else { return nil }
        return ordered
    }
}
