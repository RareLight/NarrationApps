import Foundation
import Pronunciation
import NaturalLanguage

public enum SpeechTextWindows {
    /// Sentence context within bounded, word-aligned windows. No phoneme cuts.
    /// This is an IPC/context bound, not a source-character quality target.
    public static func make(from plan: NarrationPlan, maximumScalars: Int = 1_000) throws -> [SpeechTextWindow] {
        guard maximumScalars > 0, maximumScalars <= 1_000 else { throw SpeechFailure(.invalidInput) }
        var result: [SpeechTextWindow] = []
        for chunk in plan.chunks {
            let chunkStart = result.count
            let text = chunk.text
            func applications(location: Int, length: Int) -> [PronunciationApplication]? {
                guard let values = chunk.pronunciationApplications else { return nil }
                var low = 0, high = values.count
                while low < high {
                    let middle = low + (high - low) / 2
                    if values[middle].spokenLocation + values[middle].spokenLength <= location { low = middle + 1 }
                    else { high = middle }
                }
                let start = low
                while low < values.count && values[low].spokenLocation < location + length { low += 1 }
                return Array(values[start..<low])
            }
            let tokenizer = NLTokenizer(unit: .sentence); tokenizer.string = text
            var ranges: [Range<String.Index>] = []
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in ranges.append(range); return true }
            if ranges.isEmpty, !text.isEmpty { ranges = [text.startIndex..<text.endIndex] }
            var previousEnd = text.startIndex
            for (position, sentence) in ranges.enumerated() {
                // Include tokenizer gaps so coverage never depends on its choice
                // to attach whitespace/punctuation to a neighboring sentence.
                let end = position == ranges.count - 1 ? text.endIndex : sentence.upperBound
                var start = previousEnd; previousEnd = end
                while start < end {
                    try Task.checkCancellation()
                    var cut = start
                    var count = 0
                    var lastSpace: String.Index?
                    while cut < end && count < maximumScalars {
                        let next = text.index(after: cut)
                        let added = text[cut..<next].unicodeScalars.count
                        if count + added > maximumScalars { break }
                        count += added
                        if text[cut].isWhitespace { lastSpace = cut }
                        cut = next
                    }
                    if cut < end {
                        guard let space = lastSpace, space > start else {
                            throw SpeechPreparationError(source: .init(blockIndices: chunk.blockIndices,
                                location: text.utf16.distance(from: text.utf16.startIndex, to: start),
                                length: text[start..<end].utf16.count, origin: chunk.origin))
                        }
                        cut = space
                    }
                    let raw = text[start..<cut]
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, let range = raw.range(of: trimmed) {
                        let offset = NSRange(range, in: text).location
                        let boundary: SpeechBoundary = cut == text.endIndex ? (chunk.boundaryAfter ?? .paragraph) : cut == end ? .sentence : .continuation
                        let value = SpeechTextWindow(text: trimmed,
                            source: .init(blockIndices: chunk.blockIndices, location: offset,
                                length: trimmed.utf16.count, origin: chunk.origin, pronunciationApplications: applications(location: offset, length: trimmed.utf16.count),
                                    sourceMappings: ProjectionMapping.intersecting(chunk.sourceMappings, location: offset, length: trimmed.utf16.count)), boundaryAfter: boundary)
                        if result.count > chunkStart, let last = result.last {
                            let range = NSRange(location: last.source.location, length: offset + trimmed.utf16.count - last.source.location)
                            let combined = (text as NSString).substring(with: range)
                            if combined.unicodeScalars.count <= maximumScalars {
                                result[result.count - 1] = .init(text: combined,
                                    source: .init(blockIndices: chunk.blockIndices, location: range.location,
                                        length: range.length, origin: chunk.origin, pronunciationApplications: applications(location: range.location, length: range.length),
                                        sourceMappings: ProjectionMapping.intersecting(chunk.sourceMappings, location: range.location, length: range.length)), boundaryAfter: boundary)
                            } else { result.append(value) }
                        } else { result.append(value) }
                    }
                    start = cut
                    while start < end && text[start].isWhitespace { start = text.index(after: start) }
                }
            }
        }
        return result
    }
}
