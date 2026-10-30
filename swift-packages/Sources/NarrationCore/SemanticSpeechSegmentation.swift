import Foundation
import NaturalLanguage

/// Bounded planning, not a document rewriter. Returned slices concatenate exactly
/// to the input. Token/phone budgets are supplied by the owning native frontend.
public enum SemanticSpeechSegmentation {
    public struct Slice: Sendable {
        public let range: Range<String.Index>
        public let boundary: SpeechBoundary
    }

    public static func slices(_ text: String, language: String = "en", target: Int,
                              maximum: Int, measure: (String) throws -> Int) throws -> [Slice] {
        guard target > 0, maximum >= target, text.unicodeScalars.count <= 1_000 else { throw SpeechFailure(.invalidInput) }
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text; tokenizer.setLanguage(NLLanguage(rawValue: language))
        var sentences = Set<String.Index>()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            var end = range.upperBound
            while end > range.lowerBound && text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
            sentences.insert(end); return true
        }
        let words = NLTokenizer(unit: .word)
        words.string = text; words.setLanguage(NLLanguage(rawValue: language))
        var wordEnds = Set<String.Index>()
        words.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in wordEnds.insert(range.upperBound); return true }
        // Prefer whitespace boundaries, keeping a word's closing punctuation.
        // For scripts without spaces, use the platform's linguistic boundaries.
        var ends: [String.Index] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let next = text.index(after: cursor)
            let linguistic = wordEnds.contains(next) && (next == text.endIndex || !".,!?;:…'’\"”»)]}、。，！？；：".contains(text[next]))
            if text[cursor].isWhitespace || (next < text.endIndex && text[next].isWhitespace) || linguistic { ends.append(next) }
            cursor = next
        }
        ends.append(text.endIndex)
        let tagger = NLTagger(tagSchemes: [.lexicalClass]); tagger.string = text
        var output: [Slice] = [], start = text.startIndex
        while start < text.endIndex {
            try Task.checkCancellation()
            var choices: [(String.Index, Int, Int, SpeechBoundary)] = []
            for end in ends where end > start {
                let raw = String(text[start..<end]), trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let count = try measure(trimmed)
                if count > maximum { break }
                let tail = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’»)]}"))
                let last = tail.last
                var contentEnd = end
                while contentEnd > start && text[text.index(before: contentEnd)].isWhitespace { contentEnd = text.index(before: contentEnd) }
                let sentence = sentences.contains(contentEnd)
                let strength = sentence ? 8 : last.map { ";:；：—".contains($0) ? 5 : ",，、".contains($0) ? 2 : 0 } ?? 0
                let boundary: SpeechBoundary = sentence ? .sentence : .continuation
                var score = strength * 100 - abs(target - count)
                if let lastWord = text.rangeOfCharacter(from: .alphanumerics, options: .backwards, range: start..<end) {
                    let tag = tagger.tag(at: lastWord.lowerBound, unit: .word, scheme: .lexicalClass).0
                    if tag == .determiner || tag == .preposition || tag == .conjunction || tag == .number { score -= 500 }
                }
                // A tiny fragment is worse than a modest, complete extension.
                if count < target / 2 { score -= 600 }
                choices.append((end, count, score, boundary))
                if count >= target + target / 2 { break }
            }
            guard let selected = choices.max(by: { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 < $1.2 }) else {
                throw SpeechFailure(.textPreparation)
            }
            // Preserve a short remainder if all input fits; don't manufacture an
            // additional reset merely to hit a numerical target.
            if let whole = choices.last, whole.0 == text.endIndex, whole.1 <= target + target / 2 {
                output.append(.init(range: start..<text.endIndex, boundary: whole.3)); break
            }
            output.append(.init(range: start..<selected.0, boundary: selected.3)); start = selected.0
        }
        return output
    }
}
