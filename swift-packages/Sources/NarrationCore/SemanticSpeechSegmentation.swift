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
        try plan(text, language: language, target: target, maximum: maximum, batchSize: 1) { values in
            values.map { value in Result { try measure(value) } }
        }
    }

    /// CPU-only token counting. The supplied counter must be deterministic and
    /// thread-safe; model generation and mutable linguistic taggers stay serial.
    public static func parallelSlices(_ text: String, language: String = "en", target: Int,
                                      maximum: Int, workers: Int,
                                      measure: @escaping @Sendable (String) throws -> Int) throws -> [Slice] {
        guard CPUTextPreparation.validates(workers) else { throw SpeechFailure(.invalidInput) }
        return try plan(text, language: language, target: target, maximum: maximum, batchSize: workers) { values in
            if workers == 1 || values.count == 1 { return values.map { value in Result { try measure(value) } } }
            let counts = ParallelCounts(count: values.count), joined = DispatchGroup()
            for (index, value) in values.enumerated() {
                joined.enter()
                preparationQueue.async {
                    defer { joined.leave() }
                    counts.store(Result { try measure(value) }, at: index)
                }
            }
            joined.wait() // One bounded batch; cancellation is checked before and after it.
            return counts.values
        }
    }
    private static let preparationQueue = DispatchQueue(label: "org.narration.text-token-counting", qos: .utility, attributes: .concurrent)
    private final class ParallelCounts: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<Int, Error>?]
        init(count: Int) { results = Array(repeating: nil, count: count) }
        func store(_ result: Result<Int, Error>, at index: Int) { lock.withLock { results[index] = result } }
        var values: [Result<Int, Error>] { lock.withLock { results.map { $0! } } }
    }
    private static func plan(_ text: String, language: String, target: Int, maximum: Int, batchSize: Int,
                             measureBatch: ([String]) -> [Result<Int, Error>]) throws -> [Slice] {
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
        // A short passage needs no lexical scoring if the exact original
        // prefix scan would keep it whole. Token counts can be non-monotonic:
        // retain every original stop condition rather than guessing from the
        // whole passage's token count alone.
        var tagger: NLTagger?
        var output: [Slice] = [], start = text.startIndex
        func boundary(_ end: String.Index) -> SpeechBoundary {
            var contentEnd = end
            while contentEnd > start && text[text.index(before: contentEnd)].isWhitespace { contentEnd = text.index(before: contentEnd) }
            return sentences.contains(contentEnd) ? .sentence : .continuation
        }
        while start < text.endIndex {
            try NarrationWorkCheckpoint.check()
            var measured: [(end: String.Index, count: Int, text: String)] = []
            let candidates = ends.filter { $0 > start }
            var cursor = 0, stopped = false
            while cursor < candidates.count && !stopped {
                try NarrationWorkCheckpoint.check()
                var batch: [(end: String.Index, text: String)] = []
                while cursor < candidates.count && batch.count < batchSize {
                    let end = candidates[cursor]; cursor += 1
                    let trimmed = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { batch.append((end, trimmed)) }
                }
                let counts = measureBatch(batch.map(\.text))
                try NarrationWorkCheckpoint.check()
                for (item, result) in zip(batch, counts) {
                    let count = try result.get()
                    if count > maximum { stopped = true; break }
                    measured.append((item.end, count, item.text))
                    if count >= target + target / 2 { stopped = true; break }
                }
                // Results past the original stop boundary are speculative. Their
                // errors must not change a passage that never needed them.
            }
            if let whole = measured.last, whole.end == text.endIndex, whole.count <= target + target / 2 {
                output.append(.init(range: start..<text.endIndex, boundary: boundary(whole.end))); break
            }
            if tagger == nil {
                let owned = NLTagger(tagSchemes: [.lexicalClass]); owned.string = text; tagger = owned
            }
            var choices: [(String.Index, Int, Int, SpeechBoundary)] = []
            for item in measured {
                try NarrationWorkCheckpoint.check()
                let end = item.end, count = item.count
                let tail = item.text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’»)]}"))
                let last = tail.last, sentence = boundary(end) == .sentence
                let strength = sentence ? 8 : last.map { ";:；：—".contains($0) ? 5 : ",，、".contains($0) ? 2 : 0 } ?? 0
                let sliceBoundary: SpeechBoundary = sentence ? .sentence : .continuation
                var score = strength * 100 - abs(target - count)
                if let lastWord = text.rangeOfCharacter(from: .alphanumerics, options: .backwards, range: start..<end) {
                    let tag = tagger!.tag(at: lastWord.lowerBound, unit: .word, scheme: .lexicalClass).0
                    if tag == .determiner || tag == .preposition || tag == .conjunction || tag == .number { score -= 500 }
                }
                if count < target / 2 { score -= 600 }
                choices.append((end, count, score, sliceBoundary))
            }
            guard let selected = choices.max(by: { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 < $1.2 }) else {
                throw SpeechFailure(.textPreparation)
            }
            output.append(.init(range: start..<selected.0, boundary: selected.3)); start = selected.0
        }
        return output
    }
}

/// Operational CPU concurrency, independent of voice/acoustic identity. A worker
/// is a token-counting task inside the existing helper, never another TTS model.
public enum CPUTextPreparation {
    public static let maximumWorkers = 32
    public static var automaticWorkers: Int { max(1, min(maximumWorkers, ProcessInfo.processInfo.activeProcessorCount)) }
    public static func validates(_ workers: Int) -> Bool { (1...maximumWorkers).contains(workers) }
    public static func resolvedWorkers(preference: Int) -> Int {
        preference <= 0 ? automaticWorkers : min(preference, automaticWorkers)
    }
}
