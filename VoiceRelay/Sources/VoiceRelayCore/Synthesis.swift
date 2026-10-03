import Foundation

public struct BackendIdentity: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
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

public struct MockToneBackend: TTSBackend {
    public let identity = BackendIdentity(id: "mock-tone-pcm-v1", displayName: "Deterministic mock tones — no speech", isMock: true)
    public init() {}
    public func prepare() throws { try Task.checkCancellation() }
    public func cancel() {}
    public func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        try Task.checkCancellation()
        let rate = 24000; let count = rate / 4
        var pcm = Data()
        func u16(_ v: UInt16) { var v = v.littleEndian; withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var v = v.littleEndian; withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) } }
        pcm.append(Data("RIFF".utf8)); u32(UInt32(36 + count * 2)); pcm.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        pcm.append(Data("data".utf8)); u32(UInt32(count * 2))
        let frequency = 330.0 + Double(request.chunkIndex % 7) * 30
        for sample in 0..<count {
            let ramp = min(1.0, Double(min(sample, count - 1 - sample)) / 240.0)
            let value = Int16(sin(Double(sample) * 2 * .pi * frequency / Double(rate)) * 3000 * ramp)
            u16(UInt16(bitPattern: value))
        }
        let file = directory.appendingPathComponent("segment.wav")
        try Files.write(pcm, to: file)
        return SynthesisResult(artifacts: [LosslessArtifact(url: file, sampleRate: rate, channels: 1, format: "wav")])
    }
}

struct ChunkCheckpoint: Codable {
    let request: SynthesisRequest
    let result: SynthesisResult
    let hashes: [String]
}
