import Foundation
import Pronunciation
import NarrationCore

public struct BackendIdentity: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    // Retained in checkpoint encoding for compatibility; there is no product tone mode.
    public let isMock: Bool
    public init(id: String, displayName: String, isMock: Bool) { self.id = id; self.displayName = displayName; self.isMock = isMock }
}
public struct SynthesisRequest: Codable, Sendable {
    public let text: String
    public let language: String
    public let voice: String?
    public let articleID: String
    public let chunkIndex: Int
    public let blockIndices: [Int]
    public let settings: [String: SettingValue]
    public var preparedUtterance: PreparedUtterance? = nil
}
public struct LosslessArtifact: Codable, Sendable {
    public let url: URL
    public let sampleRate: Int
    public let channels: Int
    public let format: String
    public var gapAfterSeconds: Double? = nil
    public var assemblyPolicy: String? = nil
}
public struct SynthesisResult: Codable, Sendable {
    public let artifacts: [LosslessArtifact]
}
public protocol TTSBackend: Sendable {
    var pronunciations: PronunciationDictionary { get }
    var identity: BackendIdentity { get }
    func prepare() throws
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult
    func cancel()
}

public extension TTSBackend { var pronunciations: PronunciationDictionary { .empty } }

/// Optional CPU pronunciation lookahead; engines remain usable without it.
public protocol LookaheadTTSBackend: TTSBackend {
    func synthesize(_ request: SynthesisRequest, directory: URL, next: SynthesisRequest?) throws -> SynthesisResult
}

struct ChunkCheckpoint: Codable, Sendable {
    let request: SynthesisRequest
    let result: SynthesisResult
    let hashes: [String]
}

/// Optional native final-preparation boundary. Fixture and alternative backends
/// retain their existing contract; no native model is loaded by pure previews.
public protocol PreparedTTSBackend: TTSBackend {
    var speechSettings: SpeechSettings { get }
    var narrationVersion: String { get }
    var preparationPurpose: NarrationPlanPurpose { get }
    func prepareNarration(_ projection: NarrationPlan) throws -> NarrationPlan
}
