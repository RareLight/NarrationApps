import Foundation

/// Typography repair needs both native line evidence and the platform dictionary.
/// Ordinary word pairs, initials, acronyms and unknown spellings are left alone.
enum PDFLetterSpacing {
    static func cuts(_ text: String, lines: [PDFTextLine], lexicon: DocumentWordLexicon) throws -> [NSRange] {
        let pattern = try NSRegularExpression(pattern: #"\b(?:[A-Z]\s+){3,}[A-Z]\b|\b[A-Z]{1,12} [A-Z]{2,12}\b"#)
        let spaces = try NSRegularExpression(pattern: #"\s+"#)
        let ns = text as NSString
        var result: [NSRange] = []
        for line in lines {
            try Task.checkCancellation()
            for match in pattern.matches(in: text, range: NSRange(location: line.location, length: line.length)) {
                let value = ns.substring(with: match.range), parts = value.split(whereSeparator: \.isWhitespace).map(String.init)
                let joined = parts.joined()
                if parts.count == 2, lexicon.contains(parts[0]), lexicon.contains(parts[1]) { continue }
                guard (4...32).contains(joined.count), lexicon.contains(joined) else { continue }
                let letters = joined.unicodeScalars.map(\.value)
                // Alphabetic label sequences are often figure/axis labels, not words.
                if zip(letters, letters.dropFirst()).allSatisfy({ $0.1 == $0.0 + 1 }) { continue }
                let tracked = parts.count >= 4 && parts.allSatisfy { $0.count == 1 }
                let fragmented = parts.count == 2 && !["A", "I"].contains(parts[0]) &&
                    (!lexicon.contains(parts[0]) || !lexicon.contains(parts[1]))
                guard tracked || fragmented else { continue }
                result += spaces.matches(in: text, range: match.range).map(\.range)
            }
        }
        return result.sorted { $0.location < $1.location }
    }
}
