import Foundation

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
}
public struct LosslessArtifact: Codable, Sendable {
    public let url: URL
    public let sampleRate: Int
    public let channels: Int
    public let format: String
}
public struct SynthesisResult: Codable, Sendable {
    public let artifacts: [LosslessArtifact]
}
public protocol TTSBackend: Sendable {
    var identity: BackendIdentity { get }
    func prepare() throws
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult
    func cancel()
}

struct ChunkCheckpoint: Codable {
    let request: SynthesisRequest
    let result: SynthesisResult
    let hashes: [String]
}
