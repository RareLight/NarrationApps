import Foundation

public enum RelayError: Error, LocalizedError, Sendable, Equatable {
    case setup(String), extraction(String), artifact(String), storage(String), tool(String), interrupted
    public var errorDescription: String? {
        switch self {
        case .setup(let s), .extraction(let s), .artifact(let s), .storage(let s), .tool(let s): return s
        case .interrupted: return "Fixture interrupted at the requested recovery boundary. Run it again to resume."
        }
    }
}

public enum Stage: String, Codable, Sendable {
    case discovered = "DISCOVERED", fetching = "FETCHING", extracted = "EXTRACTED"
    case synthesizing = "SYNTHESIZING", encoding = "ENCODING", encoded = "ENCODED", published = "PUBLISHED"
}

public struct ContentBlock: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case heading, paragraph, listItem, quote, code, table, caption, footnote, unsupported
    }
    public let kind: Kind
    public let text: String
    public let headingLevel: Int?
    public let narrationText: String?
    public let footnoteReferences: [String]?
    public let footnoteID: String?
    public init(kind: Kind, text: String, headingLevel: Int? = nil, narrationText: String? = nil,
                footnoteReferences: [String]? = nil, footnoteID: String? = nil) {
        self.kind = kind; self.text = text; self.headingLevel = headingLevel
        self.narrationText = narrationText; self.footnoteReferences = footnoteReferences; self.footnoteID = footnoteID
    }
}

public struct SemanticArticle: Codable, Sendable, Equatable {
    public let title: String
    public let originalURL: URL
    public let finalURL: URL
    public let canonicalURL: URL?
    public let author: String?
    public let blocks: [ContentBlock]
    public let warnings: [String]
    public let extractorVersion: String
}

public struct NarrationChunk: Codable, Sendable, Equatable {
    public let index: Int
    public let text: String
    public let blockIndices: [Int]
}

public struct NarrationPlan: Codable, Sendable, Equatable {
    public let version: String
    public let chunks: [NarrationChunk]
    public let notices: [String]
}

public struct AudioInfo: Codable, Sendable, Equatable {
    public let duration: Double
    public let byteLength: Int64
    public let sampleRate: Int
    public let channels: Int
    public let codec: String
}

public struct Episode: Codable, Sendable {
    public let id: String
    public var title: String
    public var stage: Stage
    public var publicationDate: Date?
    public var encodedHash: String?
    public var audioHash: String?
    public var info: AudioInfo?
    public var synthesisFingerprint: String?
    public var settings: PrototypeProfile
    public var guid: String { id }
}

public struct FixtureResult: Codable, Sendable {
    public let episode: Episode
    public let audioURL: URL
    public let feedURL: URL
    public let article: SemanticArticle
    public let narration: NarrationPlan
    public let synthesizedChunks: Int
    public let localFeedCurrent: Bool
    public let remoteDelivery: String
}
