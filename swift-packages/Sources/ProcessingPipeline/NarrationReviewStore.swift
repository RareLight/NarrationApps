import Foundation
import CryptoKit
import Darwin
import NarrationCore
import AudioOutput

/// Opt-in private lossless material, independent of model caches and published media.
/// All callers perform these bounded file operations away from MainActor.
public struct NarrationReviewStore: Sendable {
    public struct Summary: Identifiable, Sendable {
        public let id: UUID
        public let created: Date
        public let passages: Int
        public let complete: Bool
    }
    public struct Cue: Codable, Sendable {
        public let text: String
        public let startFrame: UInt64
        public let endFrame: UInt64
        public let sampleRate: Int
    }
    public struct Artifact: Codable, Sendable {
        public let frames: Int
        public let sha256: String
        public let diagnostics: NarrationDiagnostics
    }
    public struct Record: Codable, Identifiable, Sendable {
        public let version: Int
        public let id: UUID
        public let created: Date
        public var plan: PreparedSpeechPlan
        public var artifacts: [Artifact?]
        public var complete: Bool { artifacts.count == plan.utterances.count && artifacts.allSatisfy { $0 != nil } }
    }
    public let root: URL
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SwiftNarration/Narration Reviews")) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }
    public func begin(plan: PreparedSpeechPlan) throws -> UUID {
        guard !plan.utterances.isEmpty, plan.utterances.count <= 10_000 else { throw SpeechFailure(.storage) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard root.resolvingSymlinksInPath().path == root.path else { throw SpeechFailure(.storage) }
        let id = UUID(), directory = root.appendingPathComponent(id.uuidString)
        guard mkdir(directory.path, 0o700) == 0 else { throw SpeechFailure(.storage) }
        do {
            try save(.init(version: 1, id: id, created: Date(), plan: plan, artifacts: Array(repeating: nil, count: plan.utterances.count)))
            return id
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    public func load(_ id: UUID) throws -> Record {
        let data = try read(file(id, "review.json"), maximum: 16 * 1_024 * 1_024)
        let value = try JSONDecoder().decode(Record.self, from: data)
        guard value.version == 1, value.id == id, !value.plan.utterances.isEmpty, value.plan.utterances.count <= 10_000,
              value.artifacts.count == value.plan.utterances.count, value.plan.settings.isValid else { throw SpeechFailure(.storage) }
        for utterance in value.plan.utterances { try utterance.validate(identity: utterance.acousticIdentity, prepared: utterance.phonemes != nil) }
        var result = value
        for index in result.artifacts.indices where result.artifacts[index] == nil {
            let metadata = try file(id, "\(index).json")
            if FileManager.default.fileExists(atPath: metadata.path) {
                result.artifacts[index] = try JSONDecoder().decode(Artifact.self, from: read(metadata, maximum: 16_384))
            }
        }
        let rate = result.plan.settings.model.capabilities.sampleRate
        for artifact in result.artifacts.compactMap({ $0 }) {
            guard (1...rate * 120).contains(artifact.frames), artifact.sha256.count == 64,
                  artifact.sha256.allSatisfy({ $0.isASCII && ($0.isNumber || "abcdef".contains($0)) }),
                  artifact.diagnostics.duration.isFinite,
                  abs(artifact.diagnostics.duration - Double(artifact.frames) / Double(rate)) < 1 / Double(rate),
                  artifact.diagnostics.longestSilence.isFinite, artifact.diagnostics.longestSilence >= 0,
                  artifact.diagnostics.longestSilence <= artifact.diagnostics.duration else { throw SpeechFailure(.storage) }
        }
        return result
    }
    public func records() throws -> [Summary] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { UUID(uuidString: $0.lastPathComponent) }.prefix(100)
            .map { let record = try load($0); return Summary(id: record.id, created: record.created, passages: record.plan.utterances.count, complete: record.complete) }.sorted { $0.created > $1.created }
    }
    public func record(_ id: UUID, index: Int, samples: [Float]) throws {
        let value = try load(id)
        let existingBytes = value.artifacts.compactMap { $0 }.reduce(Int64(0)) { $0 + Int64($1.frames) * 4 }
        try record(id, index: index, samples: samples, plan: value.plan, existingBytes: existingBytes)
    }
    /// Caller owns this captured plan/counter. The immutable plan is written
    /// once; per-chunk journals avoid quadratic whole-book JSON rewrites.
    func record(_ id: UUID, index: Int, samples: [Float], plan: PreparedSpeechPlan, existingBytes: Int64) throws {
        guard plan.utterances.indices.contains(index), existingBytes >= 0 else { throw SpeechFailure(.invalidInput) }
        let rate = plan.settings.model.capabilities.sampleRate
        let diagnostics = try NarrationDiagnostics.inspect(samples: samples, sampleRate: rate, text: plan.utterances[index].text)
        let bytes = samples.withUnsafeBytes { Data($0) }
        guard existingBytes + Int64(bytes.count) <= 4 * 1_024 * 1_024 * 1_024 else { throw SpeechFailure(.storage) }
        let destination = try file(id, "\(index).f32")
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw SpeechFailure(.storage) }
        try bytes.write(to: destination, options: [.withoutOverwriting])
        let metadata = Artifact(frames: samples.count, sha256: digest(bytes), diagnostics: diagnostics)
        do { try JSONEncoder().encode(metadata).write(to: file(id, "\(index).json"), options: [.withoutOverwriting]) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    public func samples(_ id: UUID, index: Int) throws -> [Float] {
        let value = try load(id)
        return try samples(id, index: index, record: value)
    }
    func samples(_ id: UUID, index: Int, record value: Record) throws -> [Float] {
        guard value.artifacts.indices.contains(index), let artifact = value.artifacts[index],
              (1...value.plan.settings.model.capabilities.sampleRate * 120).contains(artifact.frames) else { throw SpeechFailure(.storage) }
        let bytes = try read(file(id, "\(index).f32"), maximum: artifact.frames * 4)
        guard bytes.count == artifact.frames * 4, digest(bytes) == artifact.sha256 else { throw SpeechFailure(.storage) }
        let values = bytes.withUnsafeBytes { buffer in (0..<artifact.frames).map { buffer.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
        guard values.allSatisfy(\.isFinite) else { throw SpeechFailure(.storage) }
        return values
    }
    @discardableResult public func export(_ id: UUID, to destination: URL) throws -> [Cue] {
        let value = try load(id)
        guard value.complete, !destination.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw SpeechFailure(.storage) }
        let writer = try AtomicAudioWriter(destination: destination, format: .wav)
        defer { writer.abort() }
        let assembler = try ZeroFrameAudioAssembler(writer: writer, sampleRate: value.plan.settings.model.capabilities.sampleRate)
        var cues: [Cue] = [], total: UInt64 = 0
        for index in value.plan.utterances.indices {
            let gap = index > 0 && value.plan.policy.usesStructuralPauses ? NarrationPausePolicy.seconds(after: value.plan.utterances[index - 1].boundaryAfter) : 0
            let frames = try samples(id, index: index, record: value), before = assembler.insertedFrames
            try assembler.append(samples: frames, gapBeforeSeconds: gap)
            let start = total + assembler.insertedFrames - before
            total = start + UInt64(frames.count)
            cues.append(.init(text: value.plan.utterances[index].text, startFrame: start, endFrame: total, sampleRate: value.plan.settings.model.capabilities.sampleRate))
        }
        try writer.publish(replaceExisting: false)
        return cues
    }
    public func remove(_ id: UUID) throws {
        _ = try load(id)
        try FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString))
    }
    private func save(_ record: Record) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= 16 * 1_024 * 1_024 else { throw SpeechFailure(.storage) }
        try data.write(to: file(record.id, "review.json"), options: .atomic)
    }
    private func file(_ id: UUID, _ name: String) throws -> URL {
        let directory = root.appendingPathComponent(id.uuidString)
        let result = directory.appendingPathComponent(name)
        guard root.resolvingSymlinksInPath().path == root.path, directory.resolvingSymlinksInPath().path == directory.path,
              result.resolvingSymlinksInPath().path == result.path else { throw SpeechFailure(.storage) }
        return result
    }
    private func read(_ file: URL, maximum: Int) throws -> Data {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SpeechFailure(.storage) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= maximum else { throw SpeechFailure(.storage) }
        let bytes = try handle.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count == info.st_size else { throw SpeechFailure(.storage) }
        return bytes
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
