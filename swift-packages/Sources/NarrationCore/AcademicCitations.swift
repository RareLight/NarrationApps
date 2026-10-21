import Foundation

/// Conservative, opt-in spoken omissions. Never edits retained source blocks.
enum AcademicCitations {
    struct Result {
        var omissions: [NarrationOmission] = []
        var ranges: [Int: [NSRange]] = [:]
        var wholeBlocks = Set<Int>()
    }
    private struct Line {
        let block: Int, range: NSRange, text: String
    }
    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
    private static let year = #"(?:1[5-9][0-9]{2}|20[0-9]{2})[a-z]?"#
    private static let referenceHeading = #"(?i)^(?:(?:selected|cited)\s+)?(?:references(?:\s+cited)?|bibliography|literature\s+cited|works\s+cited)$"#
    private static func referenceLead(_ text: String) -> Bool {
        matches(text, #"^\s*(?:\[[0-9]{1,4}\]|[0-9]{1,4}[.)])\s+\p{Lu}"#) ||
            matches(text, #"^\s*\p{Lu}[\p{L}’'.-]+,\s*\p{Lu}(?:[., ]|[\p{L}’'.-]{1,30}[, ])"#)
    }

    static func citationOnly(_ raw: String) -> Bool {
        let text = NarrationText.normalizeWhitespace(raw)
            .replacingOccurrences(of: #"^\s*(?:\[\d+\]|\d+[.)]?)\s*"#, with: "", options: .regularExpression)
        if matches(text, #"(?i)^(?:ibid\.?|ibidem|op\.\s*cit\.)(?:[, .;:]*(?:p{1,2}\.?\s*)?[0-9–—-]*)[.]?$"#) { return true }
        if matches(text, #"(?i)\b(?:is|are|was|were|means|refers to|defined as|because|however|note that)\b"#) { return false }
        // Publication details, not merely a year mentioned in explanatory prose.
        let publication = matches(text, #"\([^()]{2,100}:\s*[^()]{2,100},\s*"# + year + #"\)"#) ||
            matches(text, #"(?i)\b(?:doi\s*:|https?://doi\.org/|ISBN\b)"#) ||
            matches(text, #"(?i)\b(?:press|publishing|publisher|journal|university|vol\.|v\.)\b.*"# + year)
        let author = matches(text, #"^(?:From\s+)?[\p{Lu}][\p{L}’'.-]+(?:[, .]+[\p{Lu}][\p{L}’'.-]*){1,8}[, .]"#)
        return text.count <= 1_500 && publication && author
    }

    static func analyze(_ document: SemanticDocument, options: NarrationOptions) throws -> Result {
        guard options.stripInlineCitations || options.stripEndnoteCitations else { return .init() }
        var result = Result(), bibliography: [Line] = [], region: [Line] = []
        var numericReferences = Set<Int>(), notes = Set<Int>(), inNotes = false
        var resource: String?, referenceLevel: Int?
        func addRegion() {
            let entries = region.filter { referenceLead($0.text) }
            if entries.count >= 2 { bibliography += region }
            region = []; referenceLevel = nil
        }
        for (index, block) in document.blocks.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            if block.resourcePath != resource { addRegion(); inNotes = false; resource = block.resourcePath }
            if block.pdfPageIndex != nil, block.pdfLayout == nil { addRegion() }
            guard ![.code, .table, .caption].contains(block.kind), block.containsInlineCode != true else { continue }
            let text = NarrationText.normalizeWhitespace(block.text)
            if block.pdfPageIndex != nil, referenceLevel != nil, !region.isEmpty,
               !block.text.split(separator: "\n").contains(where: { referenceLead(String($0)) || matches(NarrationText.normalizeWhitespace(String($0)), referenceHeading) }) {
                addRegion()
            }
            if block.kind == .heading {
                if matches(text, referenceHeading) { addRegion(); referenceLevel = block.headingLevel ?? 1; inNotes = false }
                else if referenceLevel != nil, (block.headingLevel ?? 1) <= referenceLevel! { addRegion() }
                if matches(text, #"(?i)^(?:end\s*)?notes$"#) { inNotes = true }
            }
            if inNotes || block.kind == .footnote || block.footnoteID != nil { notes.insert(index) }
            let ns = block.text as NSString
            var offset = 0
            for part in block.text.split(separator: "\n", omittingEmptySubsequences: false) {
                let length = String(part).utf16.count, range = NSRange(location: offset, length: length)
                defer { offset += length + 1 }
                let value = NarrationText.normalizeWhitespace(String(part))
                let line = Line(block: index, range: range, text: value)
                let geometry = block.pdfLayout?.lines.first { NSIntersectionRange(NSRange(location: $0.location, length: $0.length), range).length > 0 }
                if matches(value, referenceHeading), block.pdfPageIndex == nil || geometry != nil || block.kind == .heading {
                    if !region.isEmpty { addRegion() }
                    referenceLevel = block.headingLevel ?? 1
                } else if referenceLevel != nil, matches(value, #"(?i)^(?:acknowledg(?:e)?ments?|appendix(?:\s+[A-Z0-9]+)?|index|about the authors?)$"#) {
                    addRegion()
                } else if referenceLevel != nil, block.pdfPageIndex != nil, value.count <= 120,
                          value.filter(\.isLetter).count >= 5, !value.contains(where: \.isLowercase),
                          !value.contains(where: \.isNumber),
                          geometry.map({ $0.bounds.y > 0.1 && $0.bounds.y < 0.91 }) == true {
                    addRegion()
                }
                if referenceLevel != nil, !referenceLead(value), let current = geometry,
                   current.bounds.y > 0.1, current.bounds.y < 0.91,
                   let previous = region.last, previous.block == index,
                   let prior = block.pdfLayout?.lines.first(where: { NSIntersectionRange(NSRange(location: $0.location, length: $0.length), previous.range).length > 0 }),
                   let entry = region.last(where: { $0.block == index && referenceLead($0.text) }),
                   let entryLine = block.pdfLayout?.lines.first(where: { NSIntersectionRange(NSRange(location: $0.location, length: $0.length), entry.range).length > 0 }),
                   current.bounds.x <= entryLine.bounds.x + 0.008,
                   abs(current.bounds.x - prior.bounds.x) < 0.1,
                   prior.bounds.y - current.bounds.y > max(prior.bounds.height, current.bounds.height) * 1.7 {
                    addRegion()
                }
                if block.role == .bibliography { bibliography.append(line) }
                else if referenceLevel != nil { region.append(line) }
            }
            if ns.length == 0 { continue }
        }
        addRegion()
        var protected: [Int: [NSRange]] = [:]
        for line in bibliography {
            protected[line.block, default: []].append(line.range)
            if let number = line.text.range(of: #"^\s*\[?[0-9]{1,4}"#, options: .regularExpression),
               let value = Int(line.text[number].filter(\.isNumber)) { numericReferences.insert(value) }
        }
        func omit(_ block: Int, _ range: NSRange, _ rule: String, _ reason: String) {
            guard range.length > 0 else { return }
            result.ranges[block, default: []].append(range)
            result.omissions.append(.init(source: .init(blockIndex: block, location: range.location, length: range.length),
                pageIndex: document.blocks[block].pdfPageIndex, rule: rule, reason: reason))
        }
        if options.stripEndnoteCitations {
            for line in bibliography { omit(line.block, line.range, "endnote-citation-1", "Bibliographic reference omitted by the citation setting.") }
            for index in notes where citationOnly(document.blocks[index].text) {
                omit(index, NSRange(location: 0, length: document.blocks[index].text.utf16.count), "endnote-citation-1", "Citation-only note omitted; explanatory notes are retained.")
                result.wholeBlocks.insert(index)
            }
            for (index, ranges) in protected {
                let ns = document.blocks[index].text as NSString
                var remaining = ns as String
                for range in ranges.sorted(by: { $0.location > $1.location }) {
                    let value = remaining as NSString
                    remaining = value.replacingCharacters(in: range, with: "")
                }
                if remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.wholeBlocks.insert(index) }
            }
        }
        if options.stripInlineCitations {
            let parentheses = try NSRegularExpression(pattern: #"\([^()]{1,600}\)"#)
            let brackets = try NSRegularExpression(pattern: #"\[[0-9]{1,4}(?:\s*[,;–—-]\s*[0-9]{1,4})*\]"#)
            let authorYear = #"^[\p{Lu}][\p{L}’'.-]+(?:\s+(?:[\p{Lu}][\p{L}’'.-]+|and|others|&|et\s+al\.?))*\s*,?\s*"# + year + #"(?:\s*[,–-]\s*(?:[0-9]{1,4}[a-z]?|pp?\.?)\s*)*[.]?$"#
            for (index, block) in document.blocks.enumerated() {
                if index.isMultiple(of: 128) { try Task.checkCancellation() }
                guard !notes.contains(index), block.narrationText == nil, ![.code, .table, .caption, .heading].contains(block.kind), block.containsInlineCode != true else { continue }
                let ns = block.text as NSString
                for match in parentheses.matches(in: block.text, range: NSRange(location: 0, length: ns.length)) {
                    let inner = ns.substring(with: match.range).dropFirst().dropLast()
                    let parts = String(inner).split(separator: ";").map {
                        NarrationText.normalizeWhitespace(String($0)).replacingOccurrences(of: #"(?i)^(?:(?:see(?: also)?|for example|e\.g\.|and)[, ]+)"#, with: "", options: .regularExpression)
                    }
                    if !parts.isEmpty, parts.allSatisfy({ matches($0, authorYear) }),
                       !(protected[index] ?? []).contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                        omit(index, match.range, "inline-citation-1", "Author–year citation omitted by the citation setting.")
                    }
                }
                for match in brackets.matches(in: block.text, range: NSRange(location: 0, length: ns.length)) {
                    let marker = ns.substring(with: match.range)
                    let parts = marker.dropFirst().dropLast().split(whereSeparator: { ",;".contains($0) })
                    var ids: [Int] = []
                    for part in parts {
                        let ends = part.split(whereSeparator: { "-–—".contains($0) }).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                        if ends.count == 2, ends[0] <= ends[1], ends[1] - ends[0] < 100 { ids += Array(ends[0]...ends[1]) }
                        else { ids += ends }
                    }
                    if !ids.isEmpty, ids.allSatisfy(numericReferences.contains),
                       !(protected[index] ?? []).contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                        omit(index, match.range, "inline-citation-1", "Numbered citation linked to the reference list omitted by the citation setting.")
                    }
                }
            }
        }
        for index in result.ranges.keys {
            var merged: [NSRange] = []
            for range in result.ranges[index]!.sorted(by: { $0.location < $1.location }) {
                if let last = merged.last, NSMaxRange(last) >= range.location { merged[merged.count - 1] = NSUnionRange(last, range) }
                else { merged.append(range) }
            }
            result.ranges[index] = merged
        }
        guard result.omissions.count <= 100_000 else { throw NarrationError.invalidInput("Citation review exceeds its source-mapping budget. No text was truncated.") }
        return result
    }
}
