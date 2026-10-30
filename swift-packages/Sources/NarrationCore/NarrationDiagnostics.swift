import Foundation
import NaturalLanguage

public struct NarrationDiagnostics: Codable, Equatable, Sendable {
    public enum Flag: String, Codable, Sendable { case unusualDuration, longSilence, repeatedAudio, transcriptMismatch }
    public let duration: Double
    public let longestSilence: Double
    public var flags: [Flag]
    public var wordErrorRate: Double?

    /// Read-only screening. A flag asks for review; it never edits or rejects PCM.
    public static func inspect(samples: [Float], sampleRate: Int, text: String) throws -> Self {
        guard (8_000...192_000).contains(sampleRate), !samples.isEmpty, samples.count <= sampleRate * 120,
              samples.allSatisfy(\.isFinite), text.utf8.count <= 64_000 else { throw SpeechFailure(.invalidInput) }
        let duration = Double(samples.count) / Double(sampleRate)
        let words = tokens(text).count
        var flags: [Flag] = []
        if words >= 4, duration < Double(words) / 15 || duration > max(20, Double(words) * 2) { flags.append(.unusualDuration) }
        var silence = 0, longest = 0
        var hashes: [UInt64: Int] = [:], repeated = false
        let window = sampleRate / 2
        for start in stride(from: 0, to: samples.count, by: window) {
            try Task.checkCancellation()
            let part = samples[start..<min(samples.count, start + window)]
            var hash: UInt64 = 14695981039346656037, audible = false
            for sample in part {
                if abs(sample) < 0.0001 { silence += 1; longest = max(longest, silence) }
                else { silence = 0; audible = true }
                hash = (hash ^ UInt64(sample.bitPattern)) &* 1099511628211
            }
            if audible, part.count == window { hashes[hash, default: 0] += 1; if hashes[hash]! >= 4 { repeated = true } }
        }
        if Double(longest) / Double(sampleRate) > 3 { flags.append(.longSilence) }
        if repeated { flags.append(.repeatedAudio) }
        return .init(duration: duration, longestSilence: Double(longest) / Double(sampleRate), flags: flags, wordErrorRate: nil)
    }

    public mutating func compare(expected: String, recognized: String) throws {
        let a = Self.tokens(expected), b = Self.tokens(recognized)
        guard !a.isEmpty, a.count <= 2_000, b.count <= 2_000 else { throw SpeechFailure(.invalidInput) }
        var previous = Array(0...b.count)
        for (i, word) in a.enumerated() {
            try Task.checkCancellation()
            var row = [i + 1] + Array(repeating: 0, count: b.count)
            for j in b.indices { row[j + 1] = min(previous[j + 1] + 1, row[j] + 1, previous[j] + (word == b[j] ? 0 : 1)) }
            previous = row
        }
        wordErrorRate = Double(previous[b.count]) / Double(a.count)
        flags.removeAll { $0 == .transcriptMismatch }
        if wordErrorRate! > 0.15 { flags.append(.transcriptMismatch) }
    }
    private static func tokens(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text
        var values: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            values.append(String(text[range]).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))); return values.count <= 2_000
        }
        return values
    }
}
