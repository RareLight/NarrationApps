import Foundation

/// Explicit trusted dictionary values only. Source markup is never interpreted.
public enum PronunciationPhoneOverrides {
    public static func apply(window: SpeechTextWindow, tokens: [AlignedPhonemeToken]) throws -> [AlignedPhonemeToken] {
        var result = tokens
        for application in (window.source.pronunciationApplications ?? []).reversed() {
            guard let phones = application.phonemes else { continue }
            let offset = application.spokenLocation - window.source.location
            let range = NSRange(location: offset, length: application.spokenLength)
            guard offset >= 0, range.length > 0, NSMaxRange(range) <= window.text.utf16.count,
                  Range(range, in: window.text) != nil,
                  let first = result.firstIndex(where: { $0.range.location == range.location }),
                  let last = result.lastIndex(where: { NSMaxRange($0.range) == NSMaxRange(range) }), first <= last else {
                throw SpeechPreparationError(source: window.source)
            }
            // The packer validates every resulting phone against the checkpoint's
            // actual vocabulary and rejects indivisible over-limit overrides.
            let replacement = AlignedPhonemeToken(range: range, phonemes: phones, whitespace: result[last].whitespace)
            result.replaceSubrange(first...last, with: [replacement])
        }
        return result
    }
}
