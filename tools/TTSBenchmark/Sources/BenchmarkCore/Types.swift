import Foundation
import CryptoKit

public struct BenchError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum Files {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    public static func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    public static func write<T: Encodable>(_ value: T, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    public static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var h = SHA256()
        while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty { h.update(data: bytes) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func child(_ root: URL, _ path: String) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty || $0 == "." }) else { throw BenchError("Unsafe relative path") }
        let result = root.appendingPathComponent(path).standardizedFileURL
        // Foundation does not resolve an ancestor link when the leaf is absent.
        var ancestor = result, missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) == nil,
                  ancestor.path != "/" else { throw BenchError("Invalid ancestor") }
            missing.append(ancestor.lastPathComponent); ancestor.deleteLastPathComponent()
        }
        var actual = ancestor.resolvingSymlinksInPath()
        for part in missing.reversed() { actual.appendPathComponent(part) }
        guard actual.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw BenchError("Path escapes workspace") }
        return result
    }
    public static func id(_ text: String) throws {
        guard !text.isEmpty, text.count < 100, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw BenchError("Invalid identifier") }
    }
}

public struct Profile: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var family: String
    public var repository: String
    public var revision: String?
    public var voice: String?
    public var language: String?
    public var precision: String
    public var license: String
    public var maxTokens: Int
    public var maxCharacters: Int
    public var dependencies: [String]
    public var referenceAudio: String?
    public var referenceText: String?
    public var blockedReason: String?
    public var productReference: Bool
    public init(id: String, label: String, family: String, repository: String, revision: String? = nil,
                voice: String? = nil, language: String? = "en", precision: String = "bf16",
                license: String = "See checkpoint license", maxTokens: Int = 4096,
                maxCharacters: Int = 350, dependencies: [String] = [], referenceAudio: String? = nil,
                referenceText: String? = nil, blockedReason: String? = nil, productReference: Bool = false) {
        self.id = id; self.label = label; self.family = family; self.repository = repository
        self.revision = revision; self.voice = voice; self.language = language; self.precision = precision
        self.license = license; self.maxTokens = maxTokens; self.maxCharacters = maxCharacters
        self.dependencies = dependencies; self.referenceAudio = referenceAudio; self.referenceText = referenceText
        self.blockedReason = blockedReason; self.productReference = productReference
    }
    public var listeningIdentity: String { "\(repository)|\(revision ?? "locked-at-prepare")|\(voice ?? "default")|\(referenceAudio ?? "preset")" }
}

public struct Passage: Codable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let text: String
    public init(id: String, role: String, text: String) { self.id = id; self.role = role; self.text = text }
}
public struct Matrix: Codable, Equatable, Sendable {
    public var version = 1
    public var profiles: [Profile]
    public var passages: [Passage]
    public var repetitions = 3
    public var seed: UInt64 = 20261024
    public var timeoutSeconds: Double = 1800
    public var footprintLimitBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024
    public var maximumAudioSeconds: Double = 1800
    public init(profiles: [Profile], passages: [Passage]) { self.profiles = profiles; self.passages = passages }
    public func validate() throws {
        guard version == 1, !profiles.isEmpty, !passages.isEmpty, (1...20).contains(repetitions),
              timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 86400,
              maximumAudioSeconds.isFinite, maximumAudioSeconds > 0, maximumAudioSeconds <= 7200,
              footprintLimitBytes >= 64 * 1_024 * 1_024 else { throw BenchError("Invalid matrix bounds") }
        guard Set(profiles.map(\.id)).count == profiles.count, Set(passages.map(\.id)).count == passages.count else { throw BenchError("Duplicate identifiers") }
        for p in profiles {
            try Files.id(p.id)
            guard p.maxCharacters > 0, p.maxCharacters <= 10000, (1...32768).contains(p.maxTokens),
                  p.repository.split(separator: "/").count == 2 else { throw BenchError("Invalid model profile") }
            if (p.referenceAudio == nil) != (p.referenceText == nil) { throw BenchError("Reference requires audio and transcript") }
            if p.family == "kokoro", let voice = p.voice {
                guard voice.hasPrefix("b") == (p.language?.lowercased().contains("gb") == true) else {
                    throw BenchError("Kokoro voice region and pronunciation language must agree; British voices require en-gb")
                }
            }
        }
        for p in passages {
            try Files.id(p.id)
            guard ["calibration", "heldout", "longform"].contains(p.role), !p.text.isEmpty,
                  p.text.utf8.count <= 200_000 else { throw BenchError("Invalid passage") }
        }
    }
}

public struct WorkerJob: Codable, Sendable {
    public var matrix: Matrix
    public var profile: Profile
    public var workspace: String
    public var output: String
    public var assetDirectory: String
    public var g2pDirectory: String?
    public var productWorker: String?
    public init(matrix: Matrix, profile: Profile, workspace: String, output: String,
                assetDirectory: String, g2pDirectory: String? = nil, productWorker: String? = nil) {
        self.matrix = matrix; self.profile = profile; self.workspace = workspace; self.output = output
        self.assetDirectory = assetDirectory; self.g2pDirectory = g2pDirectory; self.productWorker = productWorker
    }
}

public struct Measurement: Codable, Sendable {
    public var profile: String
    public var passage: String
    public var repetition: Int
    public var state: String
    public var seconds: Double
    public var requestSeconds: Double
    public var firstPCMSeconds: Double?
    public var admissionSeconds: Double
    public var duration: Double
    public var frames: Int
    public var sampleRate: Int
    public var tokenCount: Int?
    public var mlxPeakBytes: Int?
    public var chunks: [String]
    public var wav: String
    public var sha256: String
    public var peakAmplitude: Float
    public var clippedSamples: Int
    public var generationParameters: String
    public init(profile: String, passage: String, repetition: Int, state: String, seconds: Double,
                requestSeconds: Double, firstPCMSeconds: Double?, admissionSeconds: Double, duration: Double,
                frames: Int, sampleRate: Int, tokenCount: Int? = nil, mlxPeakBytes: Int? = nil,
                chunks: [String], wav: String, sha256: String, peakAmplitude: Float, clippedSamples: Int,
                generationParameters: String) {
        self.profile = profile; self.passage = passage; self.repetition = repetition; self.state = state
        self.seconds = seconds; self.requestSeconds = requestSeconds; self.firstPCMSeconds = firstPCMSeconds
        self.admissionSeconds = admissionSeconds; self.duration = duration; self.frames = frames
        self.sampleRate = sampleRate; self.tokenCount = tokenCount; self.mlxPeakBytes = mlxPeakBytes
        self.chunks = chunks; self.wav = wav; self.sha256 = sha256; self.peakAmplitude = peakAmplitude
        self.clippedSamples = clippedSamples; self.generationParameters = generationParameters
    }
    public var rtf: Double { seconds / duration }
    public func validate() throws {
        guard seconds.isFinite, seconds >= 0, requestSeconds.isFinite, requestSeconds >= 0,
              duration.isFinite, duration > 0, frames > 0, (8000...192000).contains(sampleRate),
              abs(duration - Double(frames) / Double(sampleRate)) < 0.001,
              peakAmplitude.isFinite, peakAmplitude > 0, sha256.count == 64 else { throw BenchError("Invalid measurement") }
    }
}
public struct WorkerEvent: Codable, Sendable {
    public var kind: String
    public var seconds: Double?
    public var measurement: Measurement?
    public var message: String?
    public init(_ kind: String, seconds: Double? = nil, measurement: Measurement? = nil, message: String? = nil) {
        self.kind = kind; self.seconds = seconds; self.measurement = measurement; self.message = message
    }
}
public struct Attempt: Codable, Sendable {
    public var version = 1
    public var id: String
    public var identity: String
    public var profile: Profile
    public var outcome: String
    public var reason: String?
    public var processSeconds: Double = 0
    public var readySeconds: Double?
    public var loadSeconds: Double?
    public var workerPeakBytes: UInt64 = 0
    public var hostPeakBytes: UInt64 = 0
    public var measurements: [Measurement] = []
    public var started: String = ISO8601DateFormatter().string(from: Date())
    public init(id: String, identity: String, profile: Profile, outcome: String) {
        self.id = id; self.identity = identity; self.profile = profile; self.outcome = outcome
    }
}

public struct SplitMix: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state; z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

public enum TextChunks {
    // Preserve all source scalars in order. Prefer punctuation/space; never split a word.
    public static func make(_ text: String, limit: Int) throws -> [String] {
        guard limit > 0 else { throw BenchError("Invalid text limit") }
        var chunks: [String] = [], rest = text[...]
        while rest.count > limit {
            let end = rest.index(rest.startIndex, offsetBy: limit)
            let prefix = rest[..<end]
            let punctuation = prefix.indices.last {
                let next = rest.index(after: $0)
                return ".!?;:\n".contains(prefix[$0]) && (next == rest.endIndex || rest[next].isWhitespace)
            }
            let space = prefix.indices.last { prefix[$0].isWhitespace }
            guard let split = punctuation ?? space else { throw BenchError("Indivisible word exceeds profile limit") }
            let after = rest.index(after: split)
            chunks.append(String(rest[..<after])); rest = rest[after...]
        }
        if !rest.isEmpty { chunks.append(String(rest)) }
        guard chunks.joined() == text else { throw BenchError("Text coverage failed") }
        return chunks
    }
}
