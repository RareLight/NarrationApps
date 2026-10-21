import Foundation

/// Extracted block-local UTF-16 coordinates, never spoken-projection coordinates.
public struct ExtractedTextRange: Codable, Equatable, Sendable {
    public let blockIndex: Int
    public let location: Int
    public let length: Int
    public init(blockIndex: Int, location: Int, length: Int) {
        self.blockIndex = blockIndex; self.location = location; self.length = length
    }
}

/// Compact runs covering a spoken projection. A nil source explicitly means
/// generated or unaligned text; changed runs retain their whole original span.
public struct ProjectionMapping: Codable, Equatable, Sendable {
    public let source: ExtractedTextRange?
    public let spokenLocation: Int
    public let spokenLength: Int
    public let rule: String?
    public init(source: ExtractedTextRange?, spokenLocation: Int, spokenLength: Int, rule: String? = nil) {
        self.source = source; self.spokenLocation = spokenLocation; self.spokenLength = spokenLength; self.rule = rule
    }
    public func shiftedSpoken(by offset: Int) -> Self {
        .init(source: source, spokenLocation: spokenLocation + offset, spokenLength: spokenLength, rule: rule)
    }
    public static func intersecting(_ mappings: [Self]?, location: Int, length: Int) -> [Self]? {
        guard let mappings else { return nil }
        // Sorted runs permit bounded window/utterance lookup without rescanning
        // the entire book for each prepared utterance.
        var low = 0, high = mappings.count
        while low < high {
            let middle = low + (high - low) / 2
            if mappings[middle].spokenLocation + mappings[middle].spokenLength < location { low = middle + 1 }
            else { high = middle }
        }
        var result: [Self] = []
        for value in mappings[low...] {
            if value.spokenLocation >= location + length { break }
            if let clipped = value.clipped(to: NSRange(location: location, length: length)) { result.append(clipped) }
        }
        return result
    }
    func clipped(to range: NSRange) -> Self? {
        if spokenLength == 0 {
            return spokenLocation >= range.location && spokenLocation < NSMaxRange(range) ? self : nil
        }
        let intersection = NSIntersectionRange(NSRange(location: spokenLocation, length: spokenLength), range)
        guard intersection.length > 0 else { return nil }
        let original: ExtractedTextRange?
        if let source, rule == nil, source.length == spokenLength {
            original = .init(blockIndex: source.blockIndex, location: source.location + intersection.location - spokenLocation, length: intersection.length)
        } else { original = source }
        return .init(source: original, spokenLocation: intersection.location, spokenLength: intersection.length, rule: rule)
    }
}

struct ProjectionEdit {
    let range: NSRange
    let replacement: String
    let rule: String
}

/// Internal, job-local composition used by concrete spoken-form rules. It is not
/// a second document model or an extensible transformation framework.
struct MappedProjection {
    var text = ""
    private var length = 0
    var mappings: [ProjectionMapping] = []
    private mutating func append(_ string: String, source: ExtractedTextRange?, rule: String? = nil) {
        let offset = length
        text += string
        length += string.utf16.count
        appendMapping(.init(source: source, spokenLocation: offset, spokenLength: string.utf16.count, rule: rule))
    }
    private mutating func appendMapping(_ mapping: ProjectionMapping) {
        if let previous = mappings.last, previous.rule == nil, mapping.rule == nil,
           let a = previous.source, let b = mapping.source, a.blockIndex == b.blockIndex,
           a.length == previous.spokenLength, b.length == mapping.spokenLength,
           a.location + a.length == b.location,
           previous.spokenLocation + previous.spokenLength == mapping.spokenLocation {
            mappings[mappings.count - 1] = .init(source: .init(blockIndex: a.blockIndex, location: a.location, length: a.length + b.length),
                spokenLocation: previous.spokenLocation, spokenLength: previous.spokenLength + mapping.spokenLength)
        } else { mappings.append(mapping) }
    }
    static func source(_ raw: String, block: Int, canonical: Bool, sourceOffset: Int = 0) throws -> Self {
        var result = Self(), offset = 0, whitespaceStart: Int?, whitespaceLength = 0
        let rawSource = raw as NSString
        func range(_ start: Int, _ length: Int) -> ExtractedTextRange { .init(blockIndex: block, location: sourceOffset + start, length: length) }
        for character in raw {
            if offset % 1024 == 0 { try Task.checkCancellation() }
            let value = String(character), width = value.utf16.count
            if character.isWhitespace {
                if whitespaceStart == nil { whitespaceStart = offset }
                whitespaceLength += width
            } else {
                if let start = whitespaceStart {
                    let space = result.text.isEmpty ? "" : " "
                    result.append(space, source: range(start, whitespaceLength), rule: space == rawSource.substring(with: NSRange(location: start, length: whitespaceLength)) ? nil : "whitespace-1")
                    whitespaceStart = nil; whitespaceLength = 0
                }
                let normalized = canonical ? value.precomposedStringWithCanonicalMapping : value
                result.append(normalized, source: range(offset, width), rule: normalized.utf16.elementsEqual(value.utf16) ? nil : "canonical-unicode-1")
            }
            offset += width
            guard result.mappings.count <= 100_000 else { throw NarrationError.invalidInput("Spoken-form mapping budget exceeded. No text was truncated.") }
        }
        if let start = whitespaceStart { result.append("", source: range(start, whitespaceLength), rule: "whitespace-1") }
        return result
    }
    func applying(_ edits: [ProjectionEdit]) throws -> Self {
        let ns = text as NSString
        var result = Self(), cursor = 0, mappingCursor = 0
        func copied(_ range: NSRange, into result: inout Self) {
            let shift = result.length - range.location
            result.text += ns.substring(with: range)
            result.length += range.length
            while mappingCursor < mappings.count && mappings[mappingCursor].spokenLocation + mappings[mappingCursor].spokenLength < range.location { mappingCursor += 1 }
            var index = mappingCursor
            while index < mappings.count && mappings[index].spokenLocation < NSMaxRange(range) {
                if let value = mappings[index].clipped(to: range) { result.appendMapping(value.shiftedSpoken(by: shift)) }
                index += 1
            }
            mappingCursor = index > 0 ? index - 1 : 0
        }
        for edit in edits {
            try Task.checkCancellation()
            guard edit.range.location >= cursor, NSMaxRange(edit.range) <= ns.length else { throw NarrationError.invalidInput("Invalid spoken-form mapping. No text was truncated.") }
            copied(NSRange(location: cursor, length: edit.range.location - cursor), into: &result)
            let covered = ProjectionMapping.intersecting(mappings, location: edit.range.location, length: edit.range.length) ?? []
            let originals = covered.compactMap(\.source)
            let source: ExtractedTextRange?
            if let first = originals.first, originals.count == covered.count, originals.allSatisfy({ $0.blockIndex == first.blockIndex }) {
                let start = originals.map(\.location).min()!, end = originals.map { $0.location + $0.length }.max()!
                source = .init(blockIndex: first.blockIndex, location: start, length: end - start)
            } else { source = nil }
            result.append(edit.replacement, source: source, rule: edit.rule)
            cursor = NSMaxRange(edit.range)
            guard result.mappings.count <= 100_000, result.length <= ns.length * 8 + 256 else { throw NarrationError.invalidInput("Spoken-form preparation exceeds its mapping or expansion budget. No text was truncated.") }
        }
        copied(NSRange(location: cursor, length: ns.length - cursor), into: &result)
        guard result.mappings.count <= 100_000, result.length <= ns.length * 8 + 256 else { throw NarrationError.invalidInput("Spoken-form mapping or expansion budget exceeded. No text was truncated.") }
        return result
    }
    /// Equation edits use verified source-line ranges. A reordered line may have
    /// a different spoken offset, so resolve each edit through the retained map.
    func replacingSourceRanges(_ edits: [ProjectionEdit]) throws -> Self {
        guard !edits.isEmpty else { return self }
        let sourced = mappings.filter { $0.source != nil && $0.spokenLength > 0 }.sorted { $0.source!.location < $1.source!.location }
        var resolved: [ProjectionEdit] = [], cursor = 0
        for edit in edits.sorted(by: { $0.range.location < $1.range.location }) {
            try Task.checkCancellation()
            var low: Int?, high: Int?
            while cursor < sourced.count, let source = sourced[cursor].source, source.location + source.length <= edit.range.location { cursor += 1 }
            var index = cursor
            while index < sourced.count, let source = sourced[index].source, source.location < NSMaxRange(edit.range) {
                let mapping = sourced[index]
                index += 1
                let overlap = NSIntersectionRange(edit.range, NSRange(location: source.location, length: source.length))
                guard overlap.length > 0 else { continue }
                let linear = mapping.rule == nil && source.length == mapping.spokenLength
                let start = mapping.spokenLocation + (linear ? overlap.location - source.location : 0)
                let end = linear ? start + overlap.length : mapping.spokenLocation + mapping.spokenLength
                low = min(low ?? start, start); high = max(high ?? end, end)
            }
            if let low, let high, high > low {
                let range = NSRange(location: low, length: high - low)
                // Never span interleaved content from another source line.
                let covered = ProjectionMapping.intersecting(mappings, location: low, length: high - low) ?? []
                let unrelated = covered.filter { value in
                    if value.spokenLength == 0 { return false }
                    guard let source = value.source else { return value.rule != "pdf-continuation-space-1" }
                    return NSIntersectionRange(edit.range, NSRange(location: source.location, length: source.length)).length == 0
                }
                guard unrelated.isEmpty else { throw NarrationError.invalidInput("Scientific source alignment failed. No text was truncated.") }
                resolved.append(.init(range: range, replacement: edit.replacement, rule: edit.rule))
            }
        }
        return try applying(resolved.sorted { $0.range.location < $1.range.location })
    }
    func joining(_ next: Self, directly: Bool = false) throws -> Self {
        var result = self
        // A discretionary word split needs no invented separator; its explicit
        // soft hyphen is subsequently removed by the mapped spoken-text rule.
        if !directly && !result.text.hasSuffix("\u{ad}") { result.append(" ", source: nil, rule: "pdf-continuation-space-1") }
        let offset = result.length
        result.text += next.text; result.length += next.length
        for mapping in next.mappings { result.appendMapping(mapping.shiftedSpoken(by: offset)) }
        guard result.mappings.count <= 100_000 else { throw NarrationError.invalidInput("PDF continuation mapping budget exceeded.") }
        return result
    }

    func cleaningCitationWhitespace() throws -> Self {
        let expression = try NSRegularExpression(pattern: #" +(?=[.,;:!?])| {2,}"#)
        let ns = text as NSString
        let edits = expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            ProjectionEdit(range: match.range, replacement: NSMaxRange(match.range) < ns.length && ".,;:!?".contains(ns.substring(with: NSRange(location: NSMaxRange(match.range), length: 1))) ? "" : " ", rule: "citation-whitespace-1")
        }
        return try applying(edits)
    }

    static func orderedPDF(_ raw: String, block: Int, lines: [PDFTextLine], margins: [NSRange], wordCuts: [NSRange], lineJoins: [Int: Int], letterCuts: [NSRange], citations: [NSRange], canonical: Bool) throws -> Self {
        let ns = raw as NSString
        var result: Self?, previous: PDFTextLine?
        for line in lines {
            try Task.checkCancellation()
            let range = NSRange(location: line.location, length: line.length)
            var part = try source(ns.substring(with: range), block: block, canonical: canonical, sourceOffset: range.location)
            let localMargins = margins.filter { NSIntersectionRange($0, range).length > 0 }
            let localCuts = wordCuts.filter { NSIntersectionRange($0, range).length > 0 }
            part = try part.removingSourceRanges(localMargins).removingSourceRanges(localCuts, rule: PDFWordJoining.rule)
            part = try part.removingSourceRanges(letterCuts.filter { NSIntersectionRange($0, range).length > 0 }, rule: "pdf-letter-spacing-1")
            part = try part.removingSourceRanges(citations.filter { NSIntersectionRange($0, range).length > 0 }, rule: "academic-citation-1")
            // A cut may only bridge the same adjacent source lines it was verified against.
            let directly = previous.map { before in
                lineJoins[before.location] == line.location || wordCuts.contains { cut in
                    cut.location >= before.location && cut.location < before.location + before.length && NSMaxRange(cut) >= line.location
                }
            } ?? false
            if !part.text.isEmpty {
                result = try result.map { try $0.joining(part, directly: directly) } ?? part
                previous = line
            }
        }
        return result ?? Self()
    }

    /// Source spans from verified PDF lines become mapped spoken omissions.
    /// Scan compact runs once; a whitespace run may overlap a line separator.
    func removingSourceRanges(_ ranges: [NSRange], rule: String = "pdf-recurring-margin-1") throws -> Self {
        var edits: [ProjectionEdit] = [], cursor = 0
        for range in ranges {
            try Task.checkCancellation()
            while cursor < mappings.count, let source = mappings[cursor].source, source.location + source.length <= range.location { cursor += 1 }
            var index = cursor, start: Int?, end: Int?
            while index < mappings.count, let source = mappings[index].source, source.location < NSMaxRange(range) {
                let value = mappings[index], intersection = NSIntersectionRange(NSRange(location: source.location, length: source.length), range)
                if intersection.length > 0 && value.spokenLength > 0 {
                    let linear = value.rule == nil && source.length == value.spokenLength
                    let low = value.spokenLocation + (linear ? intersection.location - source.location : 0)
                    let high = linear ? low + intersection.length : value.spokenLocation + value.spokenLength
                    start = min(start ?? low, low); end = max(end ?? high, high)
                }
                index += 1
            }
            if let start, let end, end > start {
                let range = NSRange(location: start, length: end - start)
                if let last = edits.last, NSMaxRange(last.range) >= start {
                    edits[edits.count - 1] = .init(range: NSUnionRange(last.range, range), replacement: "", rule: rule)
                } else { edits.append(.init(range: range, replacement: "", rule: rule)) }
            }
        }
        var result = try applying(edits)
        var trim: [ProjectionEdit] = []
        if result.text.hasPrefix(" ") { trim.append(.init(range: .init(location: 0, length: 1), replacement: "", rule: "whitespace-1")) }
        if result.text.hasSuffix(" ") && result.length > 1 { trim.append(.init(range: .init(location: result.length - 1, length: 1), replacement: "", rule: "whitespace-1")) }
        if !trim.isEmpty { result = try result.applying(trim) }
        return result
    }

    static func aligned(_ text: String, block: ContentBlock, index: Int, canonical: Bool) throws -> Self? {
        guard block.origin != .generated else { return nil }
        var result = try source(block.text, block: index, canonical: canonical)
        if result.text == text { return result }
        if text.hasPrefix("Image description: "), String(text.dropFirst("Image description: ".count)) == result.text {
            let prefix = "Image description: "
            result.mappings = [.init(source: nil, spokenLocation: 0, spokenLength: prefix.utf16.count, rule: "generated-cue-1")] + result.mappings.map { $0.shiftedSpoken(by: prefix.utf16.count) }
            result.text = prefix + result.text
            result.length += prefix.utf16.count
            return result
        }
        if !(block.footnoteReferences ?? []).isEmpty {
            func boundedEdits(_ pattern: String, replacement: String, rule: String) throws -> [ProjectionEdit] {
                let expression = try NSRegularExpression(pattern: pattern)
                var edits: [ProjectionEdit] = [], exceeded = false
                expression.enumerateMatches(in: result.text, options: [.reportProgress], range: NSRange(location: 0, length: result.text.utf16.count)) { match, _, stop in
                    if Task.isCancelled { stop.pointee = true; return }
                    if let match {
                        if edits.count >= 100_000 { exceeded = true; stop.pointee = true; return }
                        edits.append(.init(range: match.range, replacement: replacement, rule: rule))
                    }
                }
                try Task.checkCancellation()
                if exceeded { throw NarrationError.invalidInput("Spoken-form note mapping budget exceeded. No text was truncated.") }
                return edits
            }
            let edits = try boundedEdits(#"\[[\p{L}\p{N}*†‡]{1,16}\]|[¹²³⁴⁵⁶⁷⁸⁹⁰†‡]"#, replacement: "", rule: "note-marker-1")
            if !edits.isEmpty {
                result = try result.applying(edits)
                // Compose the whitespace collapse after marker removal.
                result = try result.applying(boundedEdits(#"\s{2,}"#, replacement: " ", rule: "whitespace-1"))
                if result.text == text { return result }
            }
        }
        // Known credit removal can retain an exact source prefix. Arbitrary
        // authored/generated alternatives never acquire fabricated source ranges.
        if result.text.hasPrefix(text), !text.isEmpty {
            result.mappings = ProjectionMapping.intersecting(result.mappings, location: 0, length: text.utf16.count) ?? []
            result.text = text
            result.length = text.utf16.count
            return result
        }
        return nil
    }
}
