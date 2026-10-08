import Foundation

public enum RelayError: Error, LocalizedError, Sendable, Equatable {
    case setup(String), extraction(String), artifact(String), storage(String), tool(String), interrupted, writerBusy
    public var errorDescription: String? {
        switch self {
        case .setup(let s), .extraction(let s), .artifact(let s), .storage(let s), .tool(let s): return s
        case .interrupted: return "Fixture interrupted at the requested recovery boundary. Run it again to resume."
        case .writerBusy: return "Another native coordinator owns this fixture database."
        }
    }
}

public enum Stage: String, Codable, Sendable {
    case discovered = "DISCOVERED", fetching = "FETCHING", extracted = "EXTRACTED"
    case synthesizing = "SYNTHESIZING", encoding = "ENCODING", encoded = "ENCODED", published = "PUBLISHED"
    case expired = "EXPIRED"
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
    public var sourceName: String? = nil
    public var previewImageURL: URL? = nil
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

/// Recorded remote-delivery state for one episode; nil until delivery is configured or a drain claims it.
public struct DeliveryState: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case pending, uploaded, failed }
    public var status: Status
    public var remotePath: String
    public var destinationURL: URL?
    public var attempts = 0
    public var lastError: String?
    public var uploadedByteLength: Int64?
    public var lastAttemptAt: Date?
    public var nextAttemptAt: Date?
    public init(status: Status, remotePath: String, attempts: Int = 0, lastError: String? = nil,
                uploadedByteLength: Int64? = nil, lastAttemptAt: Date? = nil, nextAttemptAt: Date? = nil) {
        self.status = status; self.remotePath = remotePath; self.attempts = attempts
        self.lastError = lastError; self.uploadedByteLength = uploadedByteLength
        self.lastAttemptAt = lastAttemptAt; self.nextAttemptAt = nextAttemptAt
    }
}

public struct Episode: Codable, Sendable {
    public let id: String
    public var title: String
    public var stage: Stage
    public var publicationDate: Date?
    /// Reading List save time, independent of the audio's generation/commit time.
    public var readingListSavedAt: Date? = nil
    public var podcastDate: Date? { readingListSavedAt ?? publicationDate }
    public var encodedHash: String?
    public var audioHash: String?
    public var info: AudioInfo?
    public var synthesisFingerprint: String?
    public var audioVolumeID: String? = nil
    public var manualAudioDeletionRequested: Bool? = nil
    public var author: String? = nil
    public var sourceHost: String? = nil
    public var sourceURL: URL? = nil
    public var artworkURL: URL? = nil
    public var delivery: DeliveryState? = nil
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
