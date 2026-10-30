import Foundation
import CryptoKit

public struct PronunciationEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var word: String
    public var spelling: String
    public var language: String?
    public var documentTitle: String?
    public var model: String?
    public var phonemes: String?
    public init(id: UUID = UUID(), word: String = "", spelling: String = "", language: String? = nil,
                documentTitle: String? = nil, model: String? = nil, phonemes: String? = nil) {
        self.id = id; self.word = word; self.spelling = spelling
        self.language = language; self.documentTitle = documentTitle; self.model = model; self.phonemes = phonemes
    }
}

public enum PronunciationError: Error, LocalizedError, Equatable {
    case invalidEntry, duplicateWord, tooManyEntries, tooManyApplications, conflict, invalidFile
    public var errorDescription: String? {
        switch self {
        case .invalidEntry: "Enter a word (up to 120 characters) and a spelling (up to 160). English spellings use English letters, spaces, hyphens and apostrophes. Advanced phones require Kokoro; check the language and scope fields."
        case .duplicateWord: "Each word can have only one pronunciation for the same language, document and model. Capitalization does not distinguish words."
        case .tooManyEntries: "The pronunciation dictionary supports up to 500 entries."
        case .tooManyApplications: "The document has too many pronunciation replacements to prepare safely. Divide it into smaller sections. No content was truncated."
        case .conflict: "The dictionary changed in another app. Reload it before saving your changes."
        case .invalidFile: "The pronunciation dictionary could not be read. Its existing contents have been preserved."
        }
    }
}

/// One simultaneous, longest-first whole-word substitution before narration chunking.
/// Original source blocks remain untouched; replacement text still uses the native G2P.
public struct PronunciationDictionary: Sendable {
    public static let empty = try! PronunciationDictionary(entries: [])
    public let entries: [PronunciationEntry]
    public let fingerprint: String
    private let expression: NSRegularExpression?
    private let replacements: [String: String]
    private let phoneOverrides: [String: String]

    public init(entries: [PronunciationEntry], language: String = "en", documentTitle: String? = nil, model: String? = nil) throws {
        guard entries.count <= 500 else { throw PronunciationError.tooManyEntries }
        var values: [String: String] = [:]
        var normalized: [PronunciationEntry] = []
        var identifiers: Set<UUID> = []
        var scopes = Set<String>(), priorities: [String: Int] = [:], phones: [String: String] = [:]
        for entry in entries {
            let word = entry.word.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            let spelling = entry.spelling.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, word.count <= 120, word.range(of: #"[\p{L}\p{N}]"#, options: .regularExpression) != nil, !word.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  spelling.count <= 160,
                  (!spelling.isEmpty || entry.phonemes != nil),
                  spelling.isEmpty || (spelling.range(of: (entry.language ?? "en").hasPrefix("en") ? "[A-Za-z]" : #"\p{L}"#, options: .regularExpression) != nil &&
                    spelling.unicodeScalars.allSatisfy({ (entry.language ?? "en").hasPrefix("en") ? (65...90).contains($0.value) || (97...122).contains($0.value) || " '-".unicodeScalars.contains($0) : CharacterSet.letters.union(.nonBaseCharacters).contains($0) || " '-".unicodeScalars.contains($0) })),
                  entry.language == nil || (entry.language!.count <= 20 && entry.language!.range(of: #"^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil),
                  entry.documentTitle == nil || (!entry.documentTitle!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && entry.documentTitle!.count <= 300 && !entry.documentTitle!.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)),
                  entry.model == nil || ["kokoro", "soprano", "qwen3", "chatterbox", "orpheus"].contains(entry.model!),
                  entry.phonemes == nil || (entry.model == "kokoro" && !entry.phonemes!.isEmpty && entry.phonemes!.unicodeScalars.count <= 510 && !entry.phonemes!.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)),
                  identifiers.insert(entry.id).inserted else { throw PronunciationError.invalidEntry }
            let key = Self.key(word)
            let scope = [key, (entry.language ?? "en").lowercased(), entry.documentTitle.map(Self.key) ?? "", entry.model ?? ""].joined(separator: "\n")
            guard scopes.insert(scope).inserted else { throw PronunciationError.duplicateWord }
            var value = entry; value.word = word; value.spelling = spelling; normalized.append(value)
            let requestedLanguage = language.lowercased(), entryLanguage = (entry.language ?? "en").lowercased()
            guard (requestedLanguage == entryLanguage || requestedLanguage.hasPrefix(entryLanguage + "-")),
                  entry.documentTitle == nil || entry.documentTitle.map(Self.key) == documentTitle.map(Self.key),
                  entry.model == nil || entry.model == model else { continue }
            let priority = (entry.documentTitle == nil ? 0 : 8) + (entry.model == nil ? 0 : 4) + (entryLanguage == requestedLanguage ? 2 : 0)
            if priority > priorities[key, default: -1] {
                priorities[key] = priority; values[key] = spelling.isEmpty ? word : spelling
                phones[key] = entry.phonemes
            }
        }
        self.entries = normalized
        replacements = values
        phoneOverrides = phones
        if normalized.isEmpty { expression = nil; fingerprint = ""; return }
        // Preserve the established identity for legacy global respellings.
        let advanced = normalized.contains { $0.language != nil || $0.documentTitle != nil || $0.model != nil || $0.phonemes != nil }
        if values.isEmpty { expression = nil }
        else {
        let keys = values.keys.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
        let alternatives = keys.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        expression = try NSRegularExpression(pattern: "(?<![\\p{L}\\p{M}\\p{N}_])(?:\(alternatives))(?![\\p{L}\\p{M}\\p{N}_])", options: [.caseInsensitive])
        }
        let encoded = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        if advanced {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            // UUIDs/order are UI identity, not pronunciation identity.
            let sorted = normalized.map { ["word": Self.key($0.word), "spelling": $0.spelling, "language": $0.language ?? "en", "document": $0.documentTitle.map(Self.key) ?? "", "model": $0.model ?? "", "phonemes": $0.phonemes ?? ""] }.sorted { left, right in
                ["word", "language", "document", "model", "spelling", "phonemes"].map { left[$0]! }.lexicographicallyPrecedes(["word", "language", "document", "model", "spelling", "phonemes"].map { right[$0]! })
            }
            fingerprint = Self.digest(Data("scoped-pronunciation-1\n".utf8) + (try encoder.encode(sorted)))
        } else { fingerprint = Self.digest(Data("whole-word-english-spelling-1\n".utf8) + encoded) }
    }

    public func resolving(language: String, documentTitle: String?, model: String) throws -> Self {
        try Self(entries: entries, language: language, documentTitle: documentTitle, model: model)
    }

    public func applying(to text: String) throws -> String { try apply(to: text, recordingMappings: false).text }

    /// Ranges refer to NFC-normalized spoken projection, before/after rules,
    /// respectively. Original document blocks are retained by the planner.
    public func applyingWithMappings(to text: String) throws -> PronunciationApplicationResult { try apply(to: text, recordingMappings: true) }

    private func apply(to text: String, recordingMappings: Bool) throws -> PronunciationApplicationResult {
        try Task.checkCancellation()
        guard let expression else { return .init(text: text, applications: []) }
        let normalized = text.precomposedStringWithCanonicalMapping
        let source = normalized as NSString
        var result = "", offset = 0, spokenOffset = 0
        var applications: [PronunciationApplication] = []
        var exceeded = false
        expression.enumerateMatches(in: normalized, options: [.reportProgress], range: NSRange(location: 0, length: source.length)) { match, _, stop in
            if Task.isCancelled { stop.pointee = true; return }
            guard let match else { return }
            let prefix = source.substring(with: NSRange(location: offset, length: match.range.location - offset))
            let word = source.substring(with: match.range)
            let spelling = replacements[Self.key(word)] ?? word
            result += prefix; spokenOffset += prefix.utf16.count
            if recordingMappings {
                guard applications.count < 100_000 else { exceeded = true; stop.pointee = true; return }
                applications.append(.init(word: word, spelling: spelling, sourceLocation: match.range.location,
                    sourceLength: match.range.length, spokenLocation: spokenOffset, spokenLength: spelling.utf16.count,
                    phonemes: phoneOverrides[Self.key(word)]))
            }
            result += spelling; spokenOffset += spelling.utf16.count
            offset = NSMaxRange(match.range)
        }
        try Task.checkCancellation()
        if exceeded { throw PronunciationError.tooManyApplications }
        result += source.substring(from: offset)
        return .init(text: result, applications: applications)
    }

    private static func key(_ word: String) -> String { word.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public struct PronunciationApplication: Codable, Equatable, Sendable {
    public let word: String
    public let spelling: String
    public let sourceLocation: Int
    public let sourceLength: Int
    public let spokenLocation: Int
    public let spokenLength: Int
    public let phonemes: String?
    public init(word: String, spelling: String, sourceLocation: Int, sourceLength: Int, spokenLocation: Int, spokenLength: Int, phonemes: String? = nil) {
        self.word = word; self.spelling = spelling; self.sourceLocation = sourceLocation; self.sourceLength = sourceLength
        self.spokenLocation = spokenLocation; self.spokenLength = spokenLength; self.phonemes = phonemes
    }
    public func shiftedSpoken(by offset: Int) -> Self {
        .init(word: word, spelling: spelling, sourceLocation: sourceLocation, sourceLength: sourceLength, spokenLocation: spokenLocation + offset, spokenLength: spokenLength, phonemes: phonemes)
    }
}

public struct PronunciationApplicationResult: Sendable {
    public let text: String
    public let applications: [PronunciationApplication]
    public init(text: String, applications: [PronunciationApplication]) { self.text = text; self.applications = applications }
}
