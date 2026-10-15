import Foundation
import CryptoKit
import NaturalLanguage
import Pronunciation

/// Versioned preparation contracts, not user quality modes. The operator accepted
/// the pause profile on October 15, 2026; retain its identifier for evidence and recovery.
public enum SpeechPreparationPolicy: String, Codable, Sendable {
    case legacy = "legacy-character-1"
    case correctnessCandidate = "misaki-correctness-candidate-1"
    case longformCandidate = "phoneme-200-candidate-1"
    case longformPausesCandidate = "phoneme-200-pauses-candidate-1"
    public static let current: Self = .longformPausesCandidate
    public var usesPreparedPhonemes: Bool { self != .legacy }
    public var usesStructuralPauses: Bool { self == .longformPausesCandidate }
}

public enum SpeechBoundary: String, Codable, Sendable {
    case continuation, sentence, paragraph, heading, footnote
}

public struct SpokenSourceRange: Codable, Equatable, Sendable {
    public let blockIndices: [Int]
    public let location: Int
    public let length: Int
    public let origin: ContentOrigin?
    public let pronunciationApplications: [PronunciationApplication]?
    public init(blockIndices: [Int], location: Int, length: Int, origin: ContentOrigin? = nil, pronunciationApplications: [PronunciationApplication]? = nil) {
        self.blockIndices = blockIndices; self.location = location; self.length = length; self.origin = origin; self.pronunciationApplications = pronunciationApplications
    }
}

/// One bounded prose window. Ranges refer to the spoken projection, after the
/// captured dictionary rules; original blocks stay in the semantic document.
public struct SpeechTextWindow: Codable, Equatable, Sendable {
    public let text: String
    public let source: SpokenSourceRange
    public let boundaryAfter: SpeechBoundary
    public init(text: String, source: SpokenSourceRange, boundaryAfter: SpeechBoundary) {
        self.text = text; self.source = source; self.boundaryAfter = boundaryAfter
    }
}

public struct AlignedPhonemeToken: Sendable {
    public let range: NSRange
    public let phonemes: String
    public let whitespace: String
    public init(range: NSRange, phonemes: String, whitespace: String) {
        self.range = range; self.phonemes = phonemes; self.whitespace = whitespace
    }
}

public struct PreparedUtterance: Codable, Equatable, Sendable {
    public let text: String
    public let phonemes: String?
    public let tokenCount: Int
    public let source: SpokenSourceRange
    public let boundaryAfter: SpeechBoundary
    public let acousticIdentity: String
    public let fingerprint: String

    public init(text: String, phonemes: String?, tokenCount: Int, source: SpokenSourceRange,
                boundaryAfter: SpeechBoundary, acousticIdentity: String) {
        self.text = text; self.phonemes = phonemes; self.tokenCount = tokenCount
        self.source = source; self.boundaryAfter = boundaryAfter; self.acousticIdentity = acousticIdentity
        fingerprint = Self.digest(text: text, phonemes: phonemes, tokenCount: tokenCount,
                                  source: source, boundary: boundaryAfter, identity: acousticIdentity)
    }

    public func validate(identity: String, prepared: Bool) throws {
        guard acousticIdentity == identity, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.location >= 0, source.length == text.utf16.count, source.location <= Int.max - source.length,
              source.blockIndices.allSatisfy({ $0 >= 0 }), text.unicodeScalars.count <= 1_000,
              prepared ? (phonemes != nil && (1...510).contains(tokenCount) && phonemes!.unicodeScalars.count == tokenCount) : (phonemes == nil && tokenCount == 0),
              fingerprint == Self.digest(text: text, phonemes: phonemes, tokenCount: tokenCount,
                                        source: source, boundary: boundaryAfter, identity: identity) else {
            throw SpeechFailure(.invalidInput)
        }
    }

    private static func digest(text: String, phonemes: String?, tokenCount: Int,
                               source: SpokenSourceRange, boundary: SpeechBoundary, identity: String) -> String {
        struct Value: Encodable { let text: String; let phonemes: String?; let tokens: Int
            let source: SpokenSourceRange; let boundary: SpeechBoundary; let identity: String }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try! encoder.encode(Value(text: text, phonemes: phonemes, tokens: tokenCount,
                                             source: source, boundary: boundary, identity: identity))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public struct PreparedSpeechPlan: Codable, Equatable, Sendable {
    public let version: Int
    public let policy: SpeechPreparationPolicy
    public let settings: SpeechSettings
    public let semanticVersion: String
    public let acousticIdentity: String
    public let utterances: [PreparedUtterance]
    public let notices: [String]
    public let provenance: [String: String]?
    public init(policy: SpeechPreparationPolicy, settings: SpeechSettings, semanticVersion: String,
                acousticIdentity: String, utterances: [PreparedUtterance], notices: [String], provenance: [String: String]? = nil) {
        version = 1; self.policy = policy; self.settings = settings; self.semanticVersion = semanticVersion
        self.acousticIdentity = acousticIdentity; self.utterances = utterances; self.notices = notices; self.provenance = provenance
    }
}

public struct SpeechPreparationError: Error, LocalizedError, Sendable {
    public let source: SpokenSourceRange
    public init(source: SpokenSourceRange) { self.source = source }
    public var errorDescription: String? {
        let block = source.blockIndices.first.map { " in source block \($0 + 1)" } ?? ""
        return "Text\(block), at spoken character \(source.location + 1), cannot be prepared within the model's supported vocabulary and token limit. Review this passage; no text was truncated."
    }
}

/// Pure packing policy. G2P remains helper-owned; this consumes actual aligned
/// frontend tokens. It never guesses alignment, cuts a word's phonemes or drops
/// unsupported symbols. Soft target 200, hard model ceiling 510.
public enum PhonemeUtterancePacker {
    public static func pack(window: SpeechTextWindow, tokens: [AlignedPhonemeToken], vocabulary: Set<String>,
                            identity: String, target: Int = 200) throws -> [PreparedUtterance] {
        guard !tokens.isEmpty, (100...400).contains(target), window.text.unicodeScalars.count <= 1_000,
              window.source.location >= 0, window.source.length == window.text.utf16.count,
              window.source.location <= Int.max - window.source.length else {
            throw SpeechPreparationError(source: window.source)
        }
        let ns = window.text as NSString
        var previous = 0
        for token in tokens {
            guard token.range.location >= previous, token.range.length > 0,
                  token.range.location <= ns.length, token.range.length <= ns.length - token.range.location,
                  Range(token.range, in: window.text) != nil,
                  ns.substring(with: NSRange(location: previous, length: token.range.location - previous))
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SpeechPreparationError(source: window.source)
            }
            guard (!token.phonemes.isEmpty || ns.substring(with: token.range).rangeOfCharacter(from: .alphanumerics) == nil),
                  token.phonemes.unicodeScalars.allSatisfy({ vocabulary.contains(String($0)) }),
                  token.whitespace.unicodeScalars.allSatisfy({ vocabulary.contains(String($0)) }) else {
                throw SpeechPreparationError(source: .init(blockIndices: window.source.blockIndices,
                    location: window.source.location + token.range.location, length: token.range.length, origin: window.source.origin))
            }
            previous = NSMaxRange(token.range)
        }
        guard ns.substring(from: previous).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechPreparationError(source: window.source)
        }
        var output: [PreparedUtterance] = []
        var start = 0
        while start < tokens.count {
            try Task.checkCancellation()
            var end = start; var count = 0; var preferred: [(Int, Int)] = []
            while end < tokens.count {
                let token = tokens[end]
                let added = token.phonemes.unicodeScalars.count + (end == start ? 0 : tokens[end - 1].whitespace.unicodeScalars.count)
                if count + added > 510 { break }
                if count + added > target && count >= 100 { break }
                count += added; end += 1
                let text = ns.substring(with: token.range)
                let priority = text.contains(where: { ".!?…".contains($0) }) ? 3 : text.contains(where: { ";:".contains($0) }) ? 2 : text.contains(where: { ",—–".contains($0) }) ? 1 : 0
                if count >= 100, priority > 0 { preferred.append((end, priority)) }
            }
            guard end > start else { throw SpeechPreparationError(source: .init(blockIndices: window.source.blockIndices,
                location: window.source.location + tokens[start].range.location, length: tokens[start].range.length, origin: window.source.origin)) }
            if end < tokens.count, let best = preferred.max(by: { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }) { end = best.0 }
            // Keep trailing punctuation/quotes with the preceding phrase. If the
            // hard ceiling would be exceeded, choose an earlier natural boundary.
            while end < tokens.count {
                let tail = ns.substring(with: tokens[end].range)
                guard tail.allSatisfy({ ".,!?;:…—–)\u{201D}\u{2019}\"'»]".contains($0) }) else { break }
                let trial = tokens[start...end].enumerated().map { $0.element.phonemes + ($0.offset == end - start ? "" : $0.element.whitespace) }.joined()
                guard trial.unicodeScalars.count <= 510 else { throw SpeechPreparationError(source: window.source) }
                end += 1
            }
            let range = NSRange(location: tokens[start].range.location,
                length: NSMaxRange(tokens[end - 1].range) - tokens[start].range.location)
            let text = ns.substring(with: range)
            let phones = tokens[start..<end].enumerated().map { $0.element.phonemes + ($0.offset == end - start - 1 ? "" : $0.element.whitespace) }.joined()
            guard !phones.isEmpty, phones.unicodeScalars.count <= 510 else { throw SpeechPreparationError(source: window.source) }
            output.append(.init(text: text, phonemes: phones, tokenCount: phones.unicodeScalars.count,
                source: .init(blockIndices: window.source.blockIndices, location: window.source.location + range.location,
                    length: range.length, origin: window.source.origin, pronunciationApplications: window.source.pronunciationApplications?.filter {
                        $0.spokenLocation < window.source.location + range.location + range.length && $0.spokenLocation + $0.spokenLength > window.source.location + range.location
                    }), boundaryAfter: end == tokens.count ? window.boundaryAfter : boundary(text),
                acousticIdentity: identity))
            start = end
        }
        return output
    }

    private static func boundary(_ text: String) -> SpeechBoundary {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’»)] "))
        return trimmed.last.map { ".!?…".contains($0) } == true ? .sentence : .continuation
    }
}

public enum PreparedSpeechCoverage {
    public static func validate(_ values: [PreparedUtterance], window: SpeechTextWindow) throws {
        let ns = window.text as NSString
        var end = 0
        guard !values.isEmpty else { throw SpeechFailure(.protocolViolation) }
        for value in values {
            let offset = value.source.location - window.source.location
            guard value.source.blockIndices == window.source.blockIndices, value.source.origin == window.source.origin,
                  offset >= end, offset <= ns.length, value.source.length <= ns.length - offset,
                  ns.substring(with: NSRange(location: end, length: offset - end)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ns.substring(with: NSRange(location: offset, length: value.source.length)) == value.text else {
                throw SpeechFailure(.protocolViolation)
            }
            end = offset + value.source.length
        }
        guard ns.substring(from: end).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              values.last?.boundaryAfter == window.boundaryAfter else { throw SpeechFailure(.protocolViolation) }
    }
}

public extension NarrationPlanner {
    static func prepareForSpeech(_ document: SemanticDocument, settings: SpeechSettings,
                                 profile: NarrationProfile = .document,
                                 pronunciations: PronunciationDictionary = .empty,
                                 policy: SpeechPreparationPolicy = .current) throws -> NarrationPlan {
        let projection = settings.model == .kokoro && policy != .legacy && policy != .correctnessCandidate
        return try prepare(document, settings: settings, profile: profile, pronunciations: pronunciations,
                           purpose: projection ? .speechPreparation : .preview)
    }
}
