import Foundation
import NaturalLanguage

public enum PronunciationSuggestions {
    /// Review candidates, never automatic rules or guessed pronunciations.
    public static func repeatedNames(in text: String) throws -> [String] {
        guard text.utf8.count <= 64_000 else { throw PronunciationError.tooManyApplications }
        try Task.checkCancellation()
        let tagger = NLTagger(tagSchemes: [.nameType]); tagger.string = text
        var counts: [String: Int] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.joinNames, .omitWhitespace, .omitPunctuation]) { tag, range in
            if Task.isCancelled { return false }
            if tag == .personalName || tag == .placeName || tag == .organizationName {
                let name = String(text[range]); if name.count <= 120 { counts[name, default: 0] += 1 }
            }
            return true
        }
        try Task.checkCancellation()
        return counts.filter { $0.value > 1 }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(30).map(\.key)
    }
}
