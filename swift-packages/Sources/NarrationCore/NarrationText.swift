import Foundation
import NaturalLanguage

public enum NarrationText {
    public static func clean(_ text: String) -> String {
        // The CLI's small cleanup policy only. Engines own normalization/G2P.
        text.replacingOccurrences(of: #"\[\s*\d+\s*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalizeWhitespace(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    public static func chunks(_ text: String, settings: SpeechSettings, maximumScalars: Int = 480) throws -> [String] {
        guard settings.speed.isFinite, settings.speed > 0, (1...480).contains(maximumScalars) else { throw DocumentReadError.malformed }
        let speed = settings.model == .kokoro ? Double(settings.speed) : 1
        // Scalar counts agree with Python's code-point count, while cuts stay
        // on grapheme boundaries. Keep chunks small; Kokoro also enforces its
        // actual 510-phoneme-token limit inside the engine before inference.
        let target = min(maximumScalars, Int(min(max(12 * speed * 12.5, 50), 400)))
        let maximum = min(maximumScalars, Int(min(max(12 * speed * 15, Double(target)), 480)))
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.setLanguage(.english)
        var ends: [String.Index] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in ends.append(range.upperBound); return true }
        if ends.last != text.endIndex { ends.append(text.endIndex) }
        var start = text.startIndex
        var units: [String] = []
        for end in ends {
            try Task.checkCancellation()
            if start < end { units += try split(String(text[start..<end]), maximum: maximum) }
            start = end
        }
        var chunks: [String] = []
        var current = ""
        for unit in units {
            if !current.isEmpty, (current + unit).unicodeScalars.count > target {
                chunks.append(current); current = ""
            }
            current += unit
        }
        if !current.isEmpty { chunks.append(current) }
        guard chunks.joined() == text else { throw DocumentReadError.malformed }
        // Preserve even whitespace-only slices in this projection. The
        // scheduler must omit those from speech jobs, not send empty text.
        return chunks
    }

    private static func split(_ text: String, maximum: Int) throws -> [String] {
        var rest = text[...]
        var result: [String] = []
        while rest.unicodeScalars.count > maximum {
            try Task.checkCancellation()
            var cut = rest.startIndex
            var count = 0
            for character in rest {
                let size = character.unicodeScalars.count
                if count + size > maximum { break }
                count += size
                cut = rest.index(after: cut)
            }
            guard cut > rest.startIndex else { throw DocumentReadError.malformed }
            let prefix = String(rest[..<cut])
            let words = NLTokenizer(unit: .word)
            words.string = prefix
            var boundary = prefix.startIndex
            words.enumerateTokens(in: prefix.startIndex..<prefix.endIndex) { range, _ in boundary = range.upperBound; return true }
            // Use a real word boundary when the capped prefix ended mid-word.
            if cut < rest.endIndex, !rest[cut].isWhitespace, let space = prefix.lastIndex(where: { $0.isWhitespace }), space > prefix.startIndex {
                boundary = prefix.index(after: space)
            }
            let length = boundary == prefix.startIndex ? prefix.count : prefix.distance(from: prefix.startIndex, to: boundary)
            let end = rest.index(rest.startIndex, offsetBy: length)
            result.append(String(rest[..<end]))
            rest = rest[end...]
        }
        if !rest.isEmpty { result.append(String(rest)) }
        return result
    }
}
