import Foundation
import NarrationCore
import DocumentProcessing

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

public typealias ContentBlock = NarrationCore.ContentBlock

public struct SemanticArticle: Codable, Sendable, Equatable {
    public var title: String
    public var titleOrigin: DocumentTitle.Origin? = nil
    public let originalURL: URL
    public let finalURL: URL
    public let canonicalURL: URL?
    public let author: String?
    public let blocks: [ContentBlock]
    public let warnings: [String]
    public let extractorVersion: String
    public var sourceName: String? = nil
    public var previewImageURL: URL? = nil
    public var archivedCopy: ArchivedArticleCopy? = nil
    public var outline: [NarrationCore.DocumentOutlineEntry]? = nil
}

public typealias NarrationChunk = NarrationCore.NarrationChunk
public typealias NarrationPlan = NarrationCore.NarrationPlan

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
    public var verificationFailed: Bool? = nil
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
    public var readingListEntryID: String? = nil
    /// Only fresh Reading List generations may automatically replace older matching audio.
    public var replacesDuplicateAudio: Bool? = nil
    public var podcastDate: Date? { readingListSavedAt ?? publicationDate }
    public var encodedHash: String?
    public var audioHash: String?
    public var info: AudioInfo?
    public var synthesisFingerprint: String?
    public var audioVolumeID: String? = nil
    /// Durable cleanup intent, committed before unlink; remote episode membership is retained.
    public var localAudioReleased: Bool? = nil
    /// Explicit local-only removal; automatic recovery must not recreate this copy.
    public var localAudioDiscarded: Bool? = nil
    /// Source removal purges article caches without retiring server episode history.
    public var readingListRemoved: Bool? = nil
    public var articleCachePurged: Bool? = nil
    /// Local cleanup verification failed; the confirmed remote copy remains intact.
    public var localCleanupNotice: String? = nil
    /// Cleanup cannot race final publication validation, even if a periodic delivery starts.
    public var audioFinalizationComplete: Bool? = nil
    public var manualAudioDeletionRequested: Bool? = nil
    public var author: String? = nil
    public var sourceHost: String? = nil
    /// Original article website for library presentation, independent of redirects/canonical RSS links.
    public var originalSourceHost: String? = nil
    /// Hashed original source identity, exported for future server recovery without private paths.
    public var originalSourceIdentity: String? = nil
    public var sourceURL: URL? = nil
    public var artworkURL: URL? = nil
    public var transcript: EpisodeTranscript? = nil
    /// Published references, including those retained from a reconciled server feed.
    public var transcriptReferences: [PodcastTranscriptReference]? = nil
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
