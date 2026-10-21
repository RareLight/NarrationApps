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
        var wordCuts: [Int: [NSRange]] = [:]
        var directJoins = Set<Int>()
        var readingOrder: [Int: [PDFTextLine]] = [:]
        var letterCuts: [Int: [NSRange]] = [:]
        var lineJoins: [Int: [Int: Int]] = [:]
        var budgetSkipped = false
    }
    private struct Candidate { let line: Line; let key: String; let reason: String; let sequenceKey: String; let folio: Int? }
    private static func folio(_ token: String) -> Int? {
        if let value = Int(token), (1...999_999).contains(value) { return value }
        let roman = token.uppercased()
        guard !roman.isEmpty, roman.range(of: #"^M{0,3}(?:CM|CD|D?C{0,3})(?:XC|XL|L?X{0,3})(?:IX|IV|V?I{0,3})$"#, options: .regularExpression) != nil else { return nil }
        let weights: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1_000]
        var value = 0, previous = 0
        for letter in roman.reversed() {
            guard let weight = weights[letter] else { return nil }
            value += weight < previous ? -weight : weight
            previous = max(previous, weight)
        }
        return value > 0 ? value : nil
    }
    private static func comparisonKey(_ text: String) -> String {
        var key = "", digit = false
        for value in NarrationText.normalizeWhitespace(text).precomposedStringWithCanonicalMapping.lowercased().unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(value) {
            if CharacterSet.decimalDigits.contains(value) {
                if !digit { key += "#" }; digit = true
            } else { key.unicodeScalars.append(value); digit = false }
        }
        return key
    }
    static func analyze(_ document: SemanticDocument, experimentalWordJoining: Bool = false,
                        excludedBlocks: Set<Int> = []) throws -> Result {
        var pages: [Int: [Line]] = [:], count = 0
        for (index, block) in document.blocks.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard !excludedBlocks.contains(index), block.kind == .paragraph, block.narrationText == nil, block.footnoteID == nil,
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
        let folioPattern = try NSRegularExpression(pattern: #"^(?:page[ ]+)?([0-9]{1,6})(?:[ ]*(?:/|of)[ ]*[0-9]{1,6})?$"#, options: .caseInsensitive)
        var candidates: [Candidate] = [], groups: [String: Set<Int>] = [:]
        var folioOffsets: [String: Set<Int>] = [:]
        var sequenceOffsets: [String: [Int: Set<Int>]] = [:]
        var sequenceAnchors: [String: [Int: [Int: Set<Int>]]] = [:]
        for (page, lines) in pages {
            try Task.checkCancellation()
            let body = lines.filter { line in
                let b = line.value.bounds
                return b.y >= 0.15 && b.y + b.height <= 0.88 && b.width > 0.15 && b.width > b.height * 2
            }
            guard body.reduce(0, { $0 + $1.value.length }) >= 120,
                  let bodyTop = body.map({ $0.value.bounds.y + $0.value.bounds.height }).max(),
                  let bodyBottom = body.map({ $0.value.bounds.y }).min(),
                  !body.isEmpty else { continue }
            let heights = body.map { $0.value.bounds.height }.sorted()
            let bodyHeight = heights[heights.count / 2]
            for line in lines {
                let b = line.value.bounds
                guard line.value.length <= 160, b.height <= min(0.04, bodyHeight * 1.6), b.width > 0,
                      (b.y >= 0.92 && b.y - bodyTop >= 0.03) || (b.y + b.height <= 0.08 && bodyBottom - b.y - b.height >= 0.03) else { continue }
                let source = document.blocks[line.block].text as NSString
                let text = source.substring(with: NSRange(location: line.value.location, length: line.value.length))
                let key = comparisonKey(text)
                guard !key.isEmpty, key.range(of: #"©|copyright|licen[cs]e|allrights|allerechte|droitsréservés|https?://|www\.|@"#, options: .regularExpression) == nil else { continue }
                let normalized = NarrationText.normalizeWhitespace(text) as NSString
                let match = folioPattern.firstMatch(in: normalized as String, range: NSRange(location: 0, length: normalized.length))
                let pureFolio = match.flatMap { folio(normalized.substring(with: $0.range(at: 1))) } ?? folio(normalized as String)
                let words = (normalized as String).split(whereSeparator: \.isWhitespace).map(String.init)
                let sequenceNumber = pureFolio ?? (words.count <= 12 ? words.last.flatMap(folio) ?? words.first.flatMap(folio) : nil)
                guard b.height <= min(0.035, bodyHeight * 1.1) || sequenceNumber != nil else { continue }
                let reason = b.y >= 0.92 ? "recurring PDF header" : "recurring PDF footer"
                let group = "\(line.basis.rawValue)/\(line.rotation)/\(reason)/\(Int((b.y * 40).rounded()))/\(Int((b.x * 20).rounded()))/\(key)"
                let anchor = b.x < 0.4 ? b.x : b.x + b.width
                let sequence = "\(line.basis.rawValue)/\(line.rotation)/\(reason)/\(Int((b.y * 40).rounded()))/\(Int((b.height * 100).rounded()))"
                candidates.append(.init(line: line, key: group, reason: reason, sequenceKey: sequence, folio: sequenceNumber)); groups[group, default: []].insert(page)
                if let pureFolio { folioOffsets[group, default: []].insert(pureFolio - page) }
                if let sequenceNumber {
                    sequenceOffsets[sequence, default: [:]][sequenceNumber - page, default: []].insert(page)
                    sequenceAnchors[sequence, default: [:]][sequenceNumber - page, default: [:]][page % 2, default: []].insert(Int((anchor * 20).rounded()))
                }
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
            let sorted = occurrences.sorted()
            let localRun = sorted.indices.dropFirst().contains { position in
                position >= 2 && sorted[position] - sorted[position - 2] <= 4
            }
            if pages.count >= 4 && sequentialFolio && (common || alternating || localRun) { accepted.insert(key) }
        }
        var result = Result()
        let lexicon = DocumentWordLexicon()
        for candidate in candidates {
            let sequential = candidate.folio.map { value in
                let offset = value - candidate.line.page
                let anchors = sequenceAnchors[candidate.sequenceKey]?[offset] ?? [:]
                return (sequenceOffsets[candidate.sequenceKey]?[offset]?.count ?? 0) >= 3 && anchors.values.allSatisfy { $0.count == 1 }
            } ?? false
            guard accepted.contains(candidate.key) || (pages.count >= 4 && sequential) else { continue }
            let line = candidate.line, range = NSRange(location: line.value.location, length: line.value.length)
            result.byBlock[line.block, default: []].append(range)
            result.omissions.append(.init(source: .init(blockIndex: line.block, location: range.location, length: range.length), pageIndex: line.page,
                                          rule: "pdf-recurring-margin-1", reason: candidate.reason))
        }
        result.omissions.sort { ($0.source.blockIndex, $0.source.location) < ($1.source.blockIndex, $1.source.location) }
        for key in result.byBlock.keys { result.byBlock[key]?.sort { $0.location < $1.location } }
        for (index, block) in document.blocks.enumerated() {
            guard block.origin == .authored, block.kind == .paragraph, block.narrationText == nil,
                  block.pdfLayout?.basis == .cropBox, block.pdfLayout?.rotation == 0,
                  !excludedBlocks.contains(index), let page = block.pdfPageIndex else { continue }
            let lines = (pages[page] ?? []).filter { $0.block == index }.map(\.value)
            if let ordered = PDFColumnReadingOrder.order(lines, text: block.text) { result.readingOrder[index] = ordered }
            let cuts = try PDFLetterSpacing.cuts(block.text, lines: lines, lexicon: lexicon)
            if !cuts.isEmpty { result.letterCuts[index] = cuts }
        }
        result.joins = try continuations(document, pages: pages, omissions: result.byBlock)
        if experimentalWordJoining {
            let words = try PDFWordJoining.analyze(document, pages: pages, omissions: result.byBlock, readingOrder: result.readingOrder, lexicon: lexicon)
            result.joins = PDFWordJoining.boundedJoins(result.joins.union(words.pageCuts.keys), document: document)
            result.wordCuts = words.cuts
            result.lineJoins = words.lineJoins
            for (index, range) in words.pageCuts where result.joins.contains(index) {
                result.wordCuts[index, default: []].append(range)
                result.directJoins.insert(index)
            }
            for key in result.wordCuts.keys { result.wordCuts[key]?.sort { $0.location < $1.location } }
        }
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
