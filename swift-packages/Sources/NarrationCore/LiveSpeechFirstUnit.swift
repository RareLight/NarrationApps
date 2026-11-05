import Foundation
import NaturalLanguage

/// Opt-in live/probe policy. Normal document/podcast packing never calls this.
/// A complete first sentence is an acoustic unit, not an arbitrary character cut.
public enum LiveSpeechFirstUnit {
    public static let version = "live-first-sentence-1"

    public static func split(_ window: SpeechTextWindow, language: String) throws -> [SpeechTextWindow] {
        try NarrationWorkCheckpoint.check()
        guard window.text.unicodeScalars.count <= 1_000 else { throw SpeechFailure(.invalidInput) }
        let text = window.text
        guard !text.isEmpty else { return [window] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text; tokenizer.setLanguage(NLLanguage(rawValue: language))
        var end: String.Index?
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in end = range.upperBound; return false }
        guard let end, end < text.endIndex,
              !text[end...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [window] }
        let cut = window.source.location + NSRange(text.startIndex..<end, in: text).length
        // Trusted overrides are indivisible; retain the ordinary unit if a rule
        // crosses this sentence boundary rather than splitting its alignment.
        if (window.source.pronunciationApplications ?? []).contains(where: {
            $0.spokenLocation < cut && $0.spokenLocation + $0.spokenLength > cut
        }) { return [window] }
        return [text.startIndex..<end, end..<text.endIndex].compactMap { raw in
            let value = text[raw].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, let range = text[raw].range(of: value) else { return nil }
            let location = window.source.location + NSRange(range, in: text).location
            let length = value.utf16.count
            return SpeechTextWindow(text: value, source: .init(blockIndices: window.source.blockIndices,
                location: location, length: length, origin: window.source.origin,
                pronunciationApplications: window.source.pronunciationApplications?.filter {
                    $0.spokenLocation < location + length && $0.spokenLocation + $0.spokenLength > location
                }, sourceMappings: ProjectionMapping.intersecting(window.source.sourceMappings, location: location, length: length)),
                boundaryAfter: raw.upperBound == end ? .sentence : window.boundaryAfter)
        }
    }
}
