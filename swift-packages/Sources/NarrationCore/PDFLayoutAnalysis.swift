import Foundation

/// A visible omission from the spoken projection, never a deletion from source.
public struct NarrationOmission: Codable, Equatable, Sendable {
    public let source: ExtractedTextRange
    public let pageIndex: Int?
    public let rule: String
    public let reason: String
    public init(source: ExtractedTextRange, pageIndex: Int?, rule: String, reason: String) {
        self.source = source; self.pageIndex = pageIndex; self.rule = rule; self.reason = reason
    }
}

/// Narrow, indexed margin evidence. Repetition alone is never eligible. All
/// uncertain/legacy regions abstain; no source text or native order is rewritten.
enum PDFLayoutAnalysis {
    struct Line {
        let block: Int, page: Int
        let value: PDFTextLine
        let basis: PDFTextLayout.Basis
        let rotation: Int
    }
    struct Result {
        var omissions: [NarrationOmission] = []
        var byBlock: [Int: [NSRange]] = [:]
        var joins = Set<Int>()
        var budgetSkipped = false
    }
    private struct Candidate { let line: Line; let key: String; let reason: String; let folio: Int? }
    private static func comparisonKey(_ text: String) -> String {
        var key = "", digit = false
        for value in NarrationText.normalizeWhitespace(text).precomposedStringWithCanonicalMapping.lowercased().unicodeScalars {
            if CharacterSet.decimalDigits.contains(value) {
                if !digit { key += "#" }; digit = true
            } else { key.unicodeScalars.append(value); digit = false }
        }
        return key
    }
    static func analyze(_ document: SemanticDocument) throws -> Result {
        var pages: [Int: [Line]] = [:], count = 0
        for (index, block) in document.blocks.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard block.kind == .paragraph, block.narrationText == nil, block.footnoteID == nil,
                  (block.footnoteReferences ?? []).isEmpty, block.containsInlineCode != true,
                  block.origin == .authored || block.origin == .ocr,
                  let page = block.pdfPageIndex, (0..<10_000).contains(page), let layout = block.pdfLayout,
                  [0, 90, 180, 270].contains(layout.rotation), layout.lines.count <= 1_024 else { continue }
            count += layout.lines.count
            guard count <= 100_000 else { return .init(budgetSkipped: true) }
            let ns = block.text as NSString, length = block.text.utf16.count
            var previousEnd = 0, verified: [Line] = []
            for line in layout.lines {
                guard line.bounds.isValid, line.location >= previousEnd, line.length > 0,
                      line.location <= length, line.length <= length - line.location,
                      Range(NSRange(location: line.location, length: line.length), in: block.text) != nil,
                      ns.substring(with: NSRange(location: previousEnd, length: line.location - previousEnd)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { verified = []; break }
                verified.append(.init(block: index, page: page, value: line, basis: layout.basis, rotation: layout.rotation))
                previousEnd = line.location + line.length
            }
            if !ns.substring(from: previousEnd).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { verified = [] }
            if !verified.isEmpty { pages[page, default: []] += verified }
        }
        guard !pages.isEmpty else { return .init() }
        let titles = Set(([document.title, document.author].compactMap { $0 } + document.blocks.filter { $0.kind == .heading && $0.origin == .authored }.map(\.text)).map(comparisonKey).filter { !$0.isEmpty })
        let folioPattern = try NSRegularExpression(pattern: #"^(?:page[ ]+)?([0-9]{1,6})(?:[ ]*(?:/|of)[ ]*[0-9]{1,6})?$"#, options: .caseInsensitive)
        var candidates: [Candidate] = [], groups: [String: Set<Int>] = [:]
        var folioOffsets: [String: Set<Int>] = [:]
        for (page, lines) in pages {
            try Task.checkCancellation()
            let body = lines.filter { line in
                let b = line.value.bounds
                return b.y >= 0.15 && b.y + b.height <= 0.88 && b.width > 0.15 && b.width > b.height * 2
            }
            guard body.reduce(0, { $0 + $1.value.length }) >= 120,
                  let bodyTop = body.map({ $0.value.bounds.y + $0.value.bounds.height }).max(),
                  let bodyBottom = body.map({ $0.value.bounds.y }).min(),
                  let bodyHeight = body.map({ $0.value.bounds.height }).min() else { continue }
            for line in lines {
                let b = line.value.bounds
                guard line.value.length <= 160, b.height <= min(0.035, bodyHeight * 1.1), b.width > 0,
                      (b.y >= 0.92 && b.y - bodyTop >= 0.03) || (b.y + b.height <= 0.08 && bodyBottom - b.y - b.height >= 0.03) else { continue }
                let source = document.blocks[line.block].text as NSString
                let text = source.substring(with: NSRange(location: line.value.location, length: line.value.length))
                let key = comparisonKey(text)
                guard !key.isEmpty, key.range(of: #"©|copyright|licen[cs]e|all rights|https?://|www\.|@"#, options: .regularExpression) == nil else { continue }
                let normalized = NarrationText.normalizeWhitespace(text) as NSString
                let match = folioPattern.firstMatch(in: normalized as String, range: NSRange(location: 0, length: normalized.length))
                let folio = match.flatMap { Int(normalized.substring(with: $0.range(at: 1))) }
                guard titles.contains(key) || folio != nil else { continue }
                let reason = b.y >= 0.92 ? "recurring PDF header" : "recurring PDF footer"
                let group = "\(line.basis.rawValue)/\(line.rotation)/\(reason)/\(Int((b.y * 40).rounded()))/\(Int((b.x * 20).rounded()))/\(key)"
                candidates.append(.init(line: line, key: group, reason: reason, folio: folio)); groups[group, default: []].insert(page)
                if let folio { folioOffsets[group, default: []].insert(folio - page) }
            }
        }
        let parityPages = [0, 1].map { parity in pages.keys.filter { $0 % 2 == parity }.count }
        var accepted = Set<String>()
        for (key, occurrences) in groups {
            let common = occurrences.count >= max(3, Int(ceil(Double(pages.count) * 0.65)))
            let alternating = (0...1).contains { parity in
                let matches = occurrences.filter { $0 % 2 == parity }.count
                return matches >= 3 && matches >= Int(ceil(Double(parityPages[parity]) * 0.75))
            }
            // A constant year or repeated reference number is not a folio.
            let sequentialFolio = folioOffsets[key].map { $0.count == 1 } ?? true
            if pages.count >= 4 && sequentialFolio && (common || alternating) { accepted.insert(key) }
        }
        var result = Result()
        for candidate in candidates where accepted.contains(candidate.key) {
            let line = candidate.line, range = NSRange(location: line.value.location, length: line.value.length)
            result.byBlock[line.block, default: []].append(range)
            result.omissions.append(.init(source: .init(blockIndex: line.block, location: range.location, length: range.length), pageIndex: line.page,
                                          rule: "pdf-recurring-margin-1", reason: candidate.reason))
        }
        result.omissions.sort { ($0.source.blockIndex, $0.source.location) < ($1.source.blockIndex, $1.source.location) }
        for key in result.byBlock.keys { result.byBlock[key]?.sort { $0.location < $1.location } }
        result.joins = try continuations(document, pages: pages, omissions: result.byBlock)
        return result
    }
    private struct Column {
        let left: Double, right: Double, height: Double
    }
    private static func continuations(_ document: SemanticDocument, pages: [Int: [Line]], omissions: [Int: [NSRange]]) throws -> Set<Int> {
        let omitted = omissions.mapValues(Set.init)
        var byBlock: [Int: [Line]] = [:], columns: [Int: Column] = [:]
        for (page, all) in pages {
            try Task.checkCancellation()
            let remaining = all.filter { !(omitted[$0.block]?.contains(NSRange(location: $0.value.location, length: $0.value.length)) ?? false) }
            for line in remaining { byBlock[line.block, default: []].append(line) }
            let body = remaining.filter { line in
                let b = line.value.bounds
                return line.basis == .cropBox && line.rotation == 0 && b.y >= 0.1 && b.y + b.height <= 0.9 && b.width > b.height * 3 && (0.005...0.04).contains(b.height)
            }
            guard body.count >= 3, body.reduce(0, { $0 + $1.value.length }) >= 120 else { continue }
            let left = body.map { $0.value.bounds.x }, heights = body.map { $0.value.bounds.height }
            guard left.max()! - left.min()! <= 0.025, heights.max()! <= heights.min()! * 1.3 else { continue }
            columns[page] = .init(left: left.min()!, right: body.map { $0.value.bounds.x + $0.value.bounds.width }.max()!, height: heights.min()!)
        }
        var joins = Set<Int>()
        for index in document.blocks.indices.dropLast() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let a = document.blocks[index], b = document.blocks[index + 1]
            guard a.kind == .paragraph, b.kind == .paragraph, a.origin == .authored, b.origin == .authored,
                  a.resourcePath == nil, b.resourcePath == nil,
                  let page = a.pdfPageIndex, b.pdfPageIndex == page + 1,
                  let first = byBlock[index]?.last, let second = byBlock[index + 1]?.first,
                  first.basis == .cropBox, second.basis == .cropBox, first.rotation == 0, second.rotation == 0,
                  let from = columns[page], let to = columns[page + 1] else { continue }
            let end = first.value.bounds, start = second.value.bounds
            guard (0.1...0.2).contains(end.y), start.y >= 0.75, start.y + start.height <= 0.9,
                  abs(from.left - to.left) <= 0.02, abs(from.right - to.right) <= 0.03,
                  abs(end.x + end.width - from.right) <= 0.025, abs(start.x + start.width - to.right) <= 0.025,
                  abs(end.x - start.x) <= 0.02, max(end.height, start.height) <= min(end.height, start.height) * 1.3 else { continue }
            let endText = NarrationText.normalizeWhitespace((a.text as NSString).substring(with: NSRange(location: first.value.location, length: first.value.length)))
            let startText = NarrationText.normalizeWhitespace((b.text as NSString).substring(with: NSRange(location: second.value.location, length: second.value.length)))
            guard let last = endText.last, last.isLetter || last == "\u{ad}", let next = startText.first, next.isLowercase else { continue }
            joins.insert(index)
        }
        return joins
    }
}
