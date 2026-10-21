// Adapted from Readium's bounded fragment joining in PR #877, commit 3a50f066f0b050f2951c211b41cf69d8eab9be6a.
// Copyright 2026 Readium Foundation. BSD-3-Clause; see ThirdPartyNotices/Readium/LICENSE.
import Foundation
import NaturalLanguage

enum PDFWordJoining {
    static let rule = "pdf-word-wrap-readium-1"
    static let maximumFragments = 200
    static let maximumPages = 4

    struct Result {
        var cuts: [Int: [NSRange]] = [:]
        var pageCuts: [Int: NSRange] = [:]
        var lineJoins: [Int: [Int: Int]] = [:]
    }

    private struct Fragment {
        let line: PDFLayoutAnalysis.Line
        let text: String
        let start: Int
        var end: Int { start + text.utf16.count }
    }

    private static func eligible(_ block: ContentBlock) -> Bool {
        block.kind == .paragraph && block.origin == .authored && block.resourcePath == nil &&
            block.narrationText == nil && block.footnoteID == nil &&
            (block.footnoteReferences ?? []).isEmpty && block.containsInlineCode != true
    }

    private static func hardBreak(_ text: String) -> Bool {
        if text.count <= 60, !text.contains(where: \.isLowercase),
           text.filter(\.isUppercase).count >= 3, text.last.map({ !".!?…".contains($0) }) == true { return true }
        return text.count <= 60 && text.range(
            of: #"^(chapter|chapitre|part|partie|book|section|prologue|epilogue|act|scene)\b[\s.:]*([0-9]{1,4}|[ivxlcdm]{1,8})?$"#,
            options: .caseInsensitive) != nil
    }

    private static func wordCut(_ left: String, _ right: String) -> Bool {
        guard !hardBreak(left), !hardBreak(right), let hyphen = left.last,
              ["-", "\u{2010}"].contains(hyphen), right.first?.isLowercase == true,
              let before = left.dropLast().last, before.isLetter else { return false }
        let forbidden = CharacterSet(charactersIn: "/\\@_:0123456789=+")
        let tail = left.split(whereSeparator: \.isWhitespace).last ?? ""
        let head = right.split(whereSeparator: \.isWhitespace).first ?? ""
        return tail.count <= 120 && head.count <= 120 &&
            !tail.unicodeScalars.contains(where: forbidden.contains) &&
            !head.unicodeScalars.contains(where: forbidden.contains)
    }

    private static func column(_ fragments: [Fragment], pageSeam: Bool = false) -> (left: Double, right: Double, height: Double)? {
        guard fragments.count >= (pageSeam ? 3 : 2),
              !pageSeam || fragments.reduce(0, { $0 + $1.text.utf16.count }) >= 120 else { return nil }
        let bounds = fragments.map { $0.line.value.bounds }
        guard bounds.allSatisfy({ $0.width > $0.height * 3 && (0.005...0.04).contains($0.height) }),
              let left = bounds.map(\.x).min(), let right = bounds.map({ $0.x + $0.width }).max(),
              let height = bounds.map(\.height).min(),
              bounds.map(\.x).max()! - left <= 0.025,
              bounds.map(\.height).max()! <= height * 1.3 else { return nil }
        return (left, right, height)
    }

    /// Preserve a recognized compound; remove the printing hyphen only when the
    /// combined word is recognized. Unknown spellings never authorize mutation.
    private static func hyphenLength(_ left: String, _ right: String, lexicon: DocumentWordLexicon) -> Int? {
        let tail = String(left.dropLast().reversed().prefix(while: { $0.isLetter }).reversed())
        let head = String(right.prefix(while: { $0.isLetter }))
        guard !tail.isEmpty, !head.isEmpty else { return nil }
        if lexicon.contains(tail + "-" + head) { return 0 }
        return lexicon.contains(tail + head) ? 1 : nil
    }

    static func analyze(_ document: SemanticDocument, pages: [Int: [PDFLayoutAnalysis.Line]],
                        omissions: [Int: [NSRange]], readingOrder: [Int: [PDFTextLine]], lexicon: DocumentWordLexicon) throws -> Result {
        let omitted = omissions.mapValues(Set.init)
        var blocks: [Int: [Fragment]] = [:], pageFragments: [Int: [Fragment]] = [:]
        for (page, lines) in pages {
            try Task.checkCancellation()
            for line in lines {
                let block = document.blocks[line.block]
                guard eligible(block), line.basis == .cropBox, line.rotation == 0,
                      !(omitted[line.block]?.contains(NSRange(location: line.value.location, length: line.value.length)) ?? false) else { continue }
                let raw = (block.text as NSString).substring(with: NSRange(location: line.value.location, length: line.value.length))
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let leading = raw.prefix(while: \.isWhitespace).utf16.count
                let fragment = Fragment(line: line, text: trimmed, start: line.value.location + leading)
                blocks[line.block, default: []].append(fragment)
                pageFragments[page, default: []].append(fragment)
            }
        }
        for (index, order) in readingOrder {
            let fragments = Dictionary(uniqueKeysWithValues: (blocks[index] ?? []).map { ($0.line.value.location, $0) })
            blocks[index] = order.compactMap { fragments[$0.location] }
        }
        var result = Result()
        for (index, fragments) in blocks {
            try Task.checkCancellation()
            let source = document.blocks[index].text as NSString
            for position in fragments.indices.dropFirst() {
                if position.isMultiple(of: maximumFragments) { continue }
                let previous = fragments[position - 1], next = fragments[position]
                let a = previous.line.value.bounds, b = next.line.value.bounds
                let drop = a.y - b.y
                let sameColumn = column([previous, next]) != nil && abs(a.x - b.x) <= 0.025 &&
                    drop >= min(a.height, b.height) * 0.3 && drop <= max(a.height, b.height) * 2.1
                let columnSeam = readingOrder[index] != nil && a.x + a.width < b.x && a.y < 0.35 && b.y > 0.65 &&
                    abs(a.width - b.width) < 0.05 && max(a.height, b.height) <= min(a.height, b.height) * 1.3 && bridges(previous.text, next.text)
                guard sameColumn || columnSeam,
                      wordCut(previous.text, next.text),
                      let hyphen = hyphenLength(previous.text, next.text, lexicon: lexicon) else { continue }
                if readingOrder[index] != nil {
                    result.cuts[index, default: []].append(NSRange(location: previous.end - hyphen, length: hyphen))
                    result.lineJoins[index, default: [:]][previous.line.value.location] = next.line.value.location
                    continue
                }
                guard next.start >= previous.end else { continue }
                let whitespace = source.substring(with: NSRange(location: previous.end, length: next.start - previous.end))
                guard whitespace.allSatisfy(\.isWhitespace), whitespace.filter(\.isNewline).count == 1 else { continue }
                result.cuts[index, default: []].append(NSRange(location: previous.end - hyphen, length: next.start - previous.end + hyphen))
            }
        }
        for index in document.blocks.indices.dropLast() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let a = document.blocks[index], b = document.blocks[index + 1]
            guard eligible(a), eligible(b), let page = a.pdfPageIndex, b.pdfPageIndex == page + 1,
                  let last = blocks[index]?.last, let first = blocks[index + 1]?.first,
                  let from = column(pageFragments[page] ?? [], pageSeam: true),
                  let to = column(pageFragments[page + 1] ?? [], pageSeam: true) else { continue }
            let end = last.line.value.bounds, start = first.line.value.bounds
            guard (0.1...0.2).contains(end.y), start.y >= 0.75, start.y + start.height <= 0.9,
                  abs(from.left - to.left) <= 0.02, abs(from.right - to.right) <= 0.03,
                  abs(end.x + end.width - from.right) <= 0.025, abs(start.x + start.width - to.right) <= 0.025,
                  abs(end.x - start.x) <= 0.02, max(end.height, start.height) <= min(end.height, start.height) * 1.3,
                  wordCut(last.text, first.text), bridges(last.text, first.text),
                  let hyphen = hyphenLength(last.text, first.text, lexicon: lexicon) else { continue }
            result.pageCuts[index] = NSRange(location: last.end - hyphen, length: hyphen)
        }
        return result
    }

    private static func bridges(_ left: String, _ right: String) -> Bool {
        let head = String(left.dropLast().suffix(600)), tail = String(right.prefix(600))
        let text = head + tail
        let seam = text.index(text.startIndex, offsetBy: head.count)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.setLanguage(.english)
        var bridged = false
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if range.lowerBound < seam && range.upperBound > seam { bridged = true; return false }
            return true
        }
        return bridged
    }

    static func boundedJoins(_ candidates: Set<Int>, document: SemanticDocument) -> Set<Int> {
        var result = candidates, pages = 1
        var fragments = document.blocks.first?.pdfLayout?.lines.count ?? 0
        for index in document.blocks.indices.dropLast() {
            let next = document.blocks[index + 1].pdfLayout?.lines.count ?? maximumFragments
            if !result.contains(index) || pages >= maximumPages || fragments + next > maximumFragments {
                result.remove(index); pages = 1; fragments = next
            } else { pages += 1; fragments += next }
        }
        return result
    }
}
