import Foundation
import Pronunciation
import NaturalLanguage

public enum SpeechTextWindows {
    /// Keep trusted phone overrides inside bounded control records without
    /// splitting an override or sending presentation/source maps to the helper.
    public static func boundedForControl(_ windows: [SpeechTextWindow]) throws -> [SpeechTextWindow] {
        func divide(_ window: SpeechTextWindow) throws -> [SpeechTextWindow] {
            try Task.checkCancellation()
            let transfer = SpeechTextWindow(text: window.text, source: .init(blockIndices: window.source.blockIndices,
                location: window.source.location, length: window.source.length, origin: window.source.origin,
                pronunciationApplications: window.source.pronunciationApplications?.filter { $0.phonemes != nil }), boundaryAfter: window.boundaryAfter)
            if try JSONEncoder().encode(transfer).count <= SpeechIPC.maximumRecordBytes / 2 { return [window] }
            let middle = window.text.utf16.count / 2
            let cuts = window.text.indices.filter { index in
                guard window.text[index].isWhitespace, index > window.text.startIndex else { return false }
                let offset = window.source.location + NSRange(window.text.startIndex..<index, in: window.text).length
                return !(window.source.pronunciationApplications ?? []).contains { $0.spokenLocation < offset && $0.spokenLocation + $0.spokenLength > offset }
            }
            guard let cut = cuts.min(by: { abs(NSRange(window.text.startIndex..<$0, in: window.text).length - middle) < abs(NSRange(window.text.startIndex..<$1, in: window.text).length - middle) }) else {
                throw SpeechPreparationError(source: window.source)
            }
            var result: [SpeechTextWindow] = []
            for raw in [window.text.startIndex..<cut, cut..<window.text.endIndex] {
                let value = window.text[raw].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, let range = window.text[raw].range(of: value) else { throw SpeechPreparationError(source: window.source) }
                let offset = window.source.location + NSRange(range, in: window.text).location
                let applications = window.source.pronunciationApplications?.filter { $0.spokenLocation < offset + value.utf16.count && $0.spokenLocation + $0.spokenLength > offset }
                let part = SpeechTextWindow(text: value, source: .init(blockIndices: window.source.blockIndices, location: offset,
                    length: value.utf16.count, origin: window.source.origin, pronunciationApplications: applications,
                    sourceMappings: ProjectionMapping.intersecting(window.source.sourceMappings, location: offset, length: value.utf16.count)),
                    boundaryAfter: raw.upperBound == window.text.endIndex ? window.boundaryAfter : .continuation)
                result += try divide(part)
            }
            return result
        }
        return try windows.flatMap { try divide($0) }
    }
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
