import Foundation
import CryptoKit

public struct PronunciationEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var word: String
    public var spelling: String
    public init(id: UUID = UUID(), word: String = "", spelling: String = "") {
        self.id = id; self.word = word; self.spelling = spelling
    }
}

public enum PronunciationError: Error, LocalizedError, Equatable {
    case invalidEntry, duplicateWord, tooManyEntries, tooManyApplications, conflict, invalidFile
    public var errorDescription: String? {
        switch self {
        case .invalidEntry: "Enter a word (up to 120 characters) and an English phonetic spelling (up to 160 characters). Use letters, spaces, hyphens and apostrophes for the spelling, not IPA."
        case .duplicateWord: "Each word can have only one pronunciation. Capitalization does not distinguish words."
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

    public init(entries: [PronunciationEntry]) throws {
        guard entries.count <= 500 else { throw PronunciationError.tooManyEntries }
        var values: [String: String] = [:]
        var normalized: [PronunciationEntry] = []
        var identifiers: Set<UUID> = []
        for entry in entries {
            let word = entry.word.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            let spelling = entry.spelling.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, word.count <= 120, word.range(of: #"[\p{L}\p{N}]"#, options: .regularExpression) != nil, !word.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  spelling.count <= 160, spelling.range(of: "[A-Za-z]", options: .regularExpression) != nil,
                  spelling.unicodeScalars.allSatisfy({ (65...90).contains($0.value) || (97...122).contains($0.value) || " '-".unicodeScalars.contains($0) }),
                  identifiers.insert(entry.id).inserted else { throw PronunciationError.invalidEntry }
            let key = Self.key(word)
            guard values[key] == nil else { throw PronunciationError.duplicateWord }
            values[key] = spelling
            normalized.append(.init(id: entry.id, word: word, spelling: spelling))
        }
        self.entries = normalized
        replacements = values
        if values.isEmpty { expression = nil; fingerprint = ""; return }
        let keys = values.keys.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
        let alternatives = keys.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        expression = try NSRegularExpression(pattern: "(?<![\\p{L}\\p{M}\\p{N}_])(?:\(alternatives))(?![\\p{L}\\p{M}\\p{N}_])", options: [.caseInsensitive])
        let encoded = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        fingerprint = Self.digest(Data("whole-word-english-spelling-1\n".utf8) + encoded)
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
                    sourceLength: match.range.length, spokenLocation: spokenOffset, spokenLength: spelling.utf16.count))
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
    public func shiftedSpoken(by offset: Int) -> Self {
        .init(word: word, spelling: spelling, sourceLocation: sourceLocation, sourceLength: sourceLength, spokenLocation: spokenLocation + offset, spokenLength: spokenLength)
    }
}

public struct PronunciationApplicationResult: Sendable {
    public let text: String
    public let applications: [PronunciationApplication]
    public init(text: String, applications: [PronunciationApplication]) { self.text = text; self.applications = applications }
}
