import Foundation
import CryptoKit
import NaturalLanguage
import Pronunciation

/// Versioned preparation contracts, not user quality modes. Historical identifiers
/// remain decodable; Kokoro's mandatory semantic policy was accepted October 30, 2026.
public enum SpeechPreparationPolicy: String, Codable, Sendable {
    case nativeText = "native-text-1"
    case legacy = "legacy-character-1"
    case correctnessCandidate = "misaki-correctness-candidate-1"
    case longformCandidate = "phoneme-200-candidate-1"
    case longformPausesCandidate = "phoneme-200-pauses-candidate-1"
    case semanticCandidate = "phoneme-semantic-200-1"
    case semantic = "phoneme-semantic-compounds-2"
    public static let current: Self = .semantic
    public var usesPreparedPhonemes: Bool { self != .legacy && self != .nativeText }
    public var usesStructuralPauses: Bool { self == .longformPausesCandidate || self == .nativeText || self == .semanticCandidate || self == .semantic }
    public static func selected(settings: SpeechSettings, requested: Self) -> Self {
        settings.model == .kokoro ? .current : .nativeText
    }
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
    public let sourceMappings: [ProjectionMapping]?
    public init(blockIndices: [Int], location: Int, length: Int, origin: ContentOrigin? = nil, pronunciationApplications: [PronunciationApplication]? = nil, sourceMappings: [ProjectionMapping]? = nil) {
        self.blockIndices = blockIndices; self.location = location; self.length = length; self.origin = origin; self.pronunciationApplications = pronunciationApplications; self.sourceMappings = sourceMappings
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
    public let documentTitle: String?
    public init(policy: SpeechPreparationPolicy, settings: SpeechSettings, semanticVersion: String,
                acousticIdentity: String, utterances: [PreparedUtterance], notices: [String], provenance: [String: String]? = nil, documentTitle: String? = nil) {
        version = 1; self.policy = policy; self.settings = settings; self.semanticVersion = semanticVersion
        self.acousticIdentity = acousticIdentity; self.utterances = utterances; self.notices = notices; self.provenance = provenance
        self.documentTitle = documentTitle
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
                            identity: String, target: Int = 200, semantic: Bool = false) throws -> [PreparedUtterance] {
        guard !tokens.isEmpty, (100...400).contains(target), window.text.unicodeScalars.count <= 1_000,
              window.source.location >= 0, window.source.length == window.text.utf16.count,
              window.source.location <= Int.max - window.source.length else {
            throw SpeechPreparationError(source: window.source)
        }
        let ns = window.text as NSString
        // A letter-to-letter compound is one packing unit. Misaki tags its
        // hyphens as dashes; use a word separator instead of a pause phoneme.
        // Keep source ranges/text intact, and leave punctuation/numeric dashes alone.
        let compounds = semantic ? compoundPattern.matches(in: window.text, range: NSRange(location: 0, length: ns.length)).map(\.range) : []
        let interior = Set(compounds.flatMap { ($0.location + 1)..<NSMaxRange($0) })
        let tokens = tokens.map { token in
            if semantic, token.range.length == 1, token.range.location >= 0, token.range.location < ns.length,
               interior.contains(token.range.location), interior.contains(NSMaxRange(token.range)),
               ["-", "\u{2010}", "\u{2011}"].contains(ns.substring(with: token.range)),
               ["", "-", "—"].contains(token.phonemes) {
                return AlignedPhonemeToken(range: token.range, phonemes: " ", whitespace: token.whitespace)
            }
            return token
        }
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType]); tagger.string = window.text
        let sentences = NLTokenizer(unit: .sentence); sentences.string = window.text
        var sentenceEnds = Set<Int>()
        sentences.enumerateTokens(in: window.text.startIndex..<window.text.endIndex) { range, _ in
            var end = range.upperBound
            while end > range.lowerBound && window.text[window.text.index(before: end)].isWhitespace { end = window.text.index(before: end) }
            sentenceEnds.insert(NSRange(window.text.startIndex..<end, in: window.text).length); return true
        }
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
                if count + added > (semantic ? target + target / 2 : target) && count >= 100,
                   !semantic || end > start && !tokens[end - 1].whitespace.isEmpty { break }
                count += added; end += 1
                let text = ns.substring(with: token.range)
                let priority = text.contains(where: { ".!?…".contains($0) }) ? 3 : text.contains(where: { ";:".contains($0) }) ? 2 : text.contains(where: { ",—–".contains($0) }) ? 1 : 0
                if count >= 100, priority > 0 { preferred.append((end, priority)) }
            }
            guard end > start else { throw SpeechPreparationError(source: .init(blockIndices: window.source.blockIndices,
                location: window.source.location + tokens[start].range.location, length: tokens[start].range.length, origin: window.source.origin)) }
            if semantic {
                var used = 0, bestScore = Int.min, selected = end
                for candidate in start..<end {
                    used += tokens[candidate].phonemes.unicodeScalars.count + (candidate == start ? 0 : tokens[candidate - 1].whitespace.unicodeScalars.count)
                    if interior.contains(NSMaxRange(tokens[candidate].range)) { continue }
                    let tail = ns.substring(with: tokens[candidate].range).trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’»)]}"))
                    let strength = sentenceEnds.contains(NSMaxRange(tokens[candidate].range)) ? 8 : tail.last.map { ";:—".contains($0) ? 5 : ",".contains($0) ? 2 : 0 } ?? 0
                    var penalty = 0
                    if let range = Range(tokens[candidate].range, in: window.text) {
                        let tag = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lexicalClass).0
                        if tag == .determiner || tag == .preposition || tag == .conjunction || tag == .number { penalty += 500 }
                        if candidate + 1 < tokens.count, let next = Range(tokens[candidate + 1].range, in: window.text) {
                            let name = tagger.tag(at: range.lowerBound, unit: .word, scheme: .nameType).0
                            if name == .personalName && tagger.tag(at: next.lowerBound, unit: .word, scheme: .nameType).0 == name { penalty += 500 }
                            let nextText = ns.substring(with: tokens[candidate + 1].range)
                            if tokens[candidate].whitespace.isEmpty, tail.last?.isLetter == true,
                               nextText.first.map({ $0.isLetter || "'’".contains($0) }) == true { continue }
                        }
                    }
                    let score = strength * 100 - abs(target - used) - (used < target / 2 ? 600 : 0) - penalty
                    if score >= bestScore { bestScore = score; selected = candidate + 1 }
                }
                if end < tokens.count {
                    guard bestScore > Int.min else { throw SpeechPreparationError(source: window.source) }
                    end = selected
                }
            } else if end < tokens.count, let best = preferred.max(by: { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }) { end = best.0 }
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
                    }, sourceMappings: ProjectionMapping.intersecting(window.source.sourceMappings, location: window.source.location + range.location, length: range.length)), boundaryAfter: end == tokens.count ? window.boundaryAfter : semantic ? (sentenceEnds.contains(NSMaxRange(tokens[end - 1].range)) ? .sentence : .continuation) : boundary(text),
                acousticIdentity: identity))
            start = end
        }
        return output
    }

    private static let compoundPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{M}]+(?:[-\x{2010}\x{2011}][\p{L}\p{M}]+)+"#)

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
                                 policy: SpeechPreparationPolicy = .current, options: NarrationOptions = .init()) throws -> NarrationPlan {
        return try prepare(document, settings: settings, profile: profile, pronunciations: pronunciations,
                           purpose: .speechPreparation, options: options)
    }
}
