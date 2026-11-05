import Foundation
import CryptoKit
import Darwin
import NarrationCore
import NativeSpeech
import AudioOutput

/// Private, explicit document recovery; independent of optional narration reviews.
/// The caller retains the job directory and captured input/destination consent.
/// It must revalidate those decisions before publishing reconstructed audio.
public final class SpeechRenderJournal: @unchecked Sendable {
    public struct Request: Codable, Equatable, Sendable {
        public let identity: AttemptIdentity
        public let plan: PreparedSpeechPlan
        public let destination: URL
        public let format: AudioOutputFormat
        public let replaceExisting: Bool
        public let sourceFingerprint: String
        public let documentOrder: [UUID]
        public let explicitGap: Double?
        public let artworkDigest: String?
        public init(identity: AttemptIdentity, plan: PreparedSpeechPlan, destination: URL, format: AudioOutputFormat,
                    replaceExisting: Bool, sourceFingerprint: String, documentOrder: [UUID],
                    explicitGap: Double? = nil, coverArtwork: CoverArtwork? = nil) {
            self.identity = identity; self.plan = plan; self.destination = destination; self.format = format
            self.replaceExisting = replaceExisting; self.sourceFingerprint = sourceFingerprint; self.documentOrder = documentOrder
            self.explicitGap = explicitGap; artworkDigest = coverArtwork?.digest
        }
    }
    public struct Recovery: Sendable {
        public let indices: Set<Int>
        public let lastEpoch: UInt64
    }
    public struct Staged: Sendable {
        fileprivate let journal: UUID
        fileprivate let descriptor: Descriptor
        fileprivate let metadata: URL
    }
    fileprivate struct Descriptor: Codable, Sendable {
        let version: Int, index: Int, frames: Int
        let token: SpeechAttemptToken
        let fingerprint: String, file: UUID, sha256: String
    }
    private struct Manifest: Codable { let version: Int; let request: Request }
    public let directory: URL
    public let request: Request
    private let id = UUID()
    private let lock = NSLock()
    private var descriptor: Int32
    private let maximumBytes: Int64
    private var bytes: Int64 = 0
    private var records: [Int: Descriptor] = [:]
    private var pending: UUID?
    public init(directory: URL, request: Request, maximumBytes: Int64 = 4 * 1_024 * 1_024 * 1_024) throws {
        guard directory.isFileURL, directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL,
              maximumBytes > 0, !request.sourceFingerprint.isEmpty, request.sourceFingerprint.utf8.count <= 512,
              !request.plan.utterances.isEmpty, request.plan.utterances.count <= SpeechAttemptFence.maximumChunks,
              request.documentOrder.count <= 10_000, Set(request.documentOrder).count == request.documentOrder.count,
              request.documentOrder.contains(request.identity.job), request.destination.isFileURL,
              request.explicitGap == nil || request.explicitGap!.isFinite && (0...10).contains(request.explicitGap!),
              request.artworkDigest == nil || request.artworkDigest!.count == 64 && request.artworkDigest!.allSatisfy({ $0.isASCII && ($0.isNumber || "abcdef".contains($0)) }) else { throw SpeechFailure(.invalidInput) }
        let plan = request.plan
        guard plan.version == 1, plan.settings.isValid,
              plan.policy == .selected(settings: plan.settings, requested: plan.policy),
              plan.acousticIdentity == SpeechAcousticIdentity.make(settings: plan.settings, policy: plan.policy) else { throw SpeechFailure(.invalidInput) }
        for utterance in plan.utterances { try utterance.validate(identity: plan.acousticIdentity, prepared: plan.policy.usesPreparedPhonemes) }
        self.directory = directory; self.request = request; self.maximumBytes = maximumBytes
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard descriptor >= 0, fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            if descriptor >= 0 { close(descriptor); descriptor = -1 }; throw SpeechFailure(.storage)
        }
        // A journal has one host writer. The lock also prevents an old process
        // from publishing into a newly reopened recovery context.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); descriptor = -1; throw SpeechFailure(.storage) }
        do {
            let manifest = directory.appendingPathComponent("job.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                let saved = try JSONDecoder().decode(Manifest.self, from: read("job.json", maximum: 16 * 1_024 * 1_024))
                guard saved.version == 1, saved.request == request else { throw SpeechFailure(.invalidInput) }
            } else {
                guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else { throw SpeechFailure(.storage) }
                let data = try JSONEncoder().encode(Manifest(version: 1, request: request))
                guard data.count <= 16 * 1_024 * 1_024 else { throw SpeechFailure(.storage) }
                try write(data, name: "job.json")
            }
            for index in plan.utterances.indices {
                let name = "\(index).json"
                var entry = stat()
                if fstatat(descriptor, name, &entry, AT_SYMLINK_NOFOLLOW) != 0 {
                    guard errno == ENOENT else { throw SpeechFailure(.storage) }; continue
                }
                let value = try JSONDecoder().decode(Descriptor.self, from: read(name, maximum: 4096))
                try validate(value, index: index)
                try autoreleasepool { _ = try samples(value) }
                bytes += Int64(value.frames) * 4
                guard bytes <= maximumBytes else { throw SpeechFailure(.storage) }
                records[index] = value
            }
        } catch { close(descriptor); descriptor = -1; throw error }
    }
    deinit { if descriptor >= 0 { close(descriptor) } }
    /// Reopen the captured plan after a host crash. Publication still requires
    /// the caller's fresh source/destination and replacement-consent checks.
    public convenience init(reopening directory: URL, maximumBytes: Int64 = 4 * 1_024 * 1_024 * 1_024) throws {
        let request = try Self.readRequest(directory)
        try self.init(directory: directory, request: request, maximumBytes: maximumBytes)
    }
    private static func readRequest(_ directory: URL) throws -> Request {
        guard directory.isFileURL, directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else { throw SpeechFailure(.storage) }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SpeechFailure(.storage) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              flock(fd, LOCK_SH | LOCK_NB) == 0 else { throw SpeechFailure(.storage) }
        let manifest = try JSONDecoder().decode(Manifest.self, from: read("job.json", descriptor: fd, maximum: 16 * 1_024 * 1_024))
        guard manifest.version == 1 else { throw SpeechFailure(.storage) }
        return manifest.request
    }
    public var recovery: Recovery {
        lock.withLock { .init(indices: Set(records.keys), lastEpoch: records.values.map(\.token.epoch).max() ?? 0) }
    }
    public func samples(index: Int) throws -> [Float]? {
        try lock.withLock { try records[index].map { try samples($0) } }
    }
    /// Expensive validation, hash and PCM fsync happen before the epoch fence.
    /// Scratch from revoked attempts is never a committed checkpoint.
    public func stage(index: Int, samples: [Float], token: SpeechAttemptToken) throws -> Staged {
        try lock.withLock {
            guard pending == nil, request.plan.utterances.indices.contains(index), records[index] == nil,
                  token.identity.batch == request.identity.batch, token.identity.job == request.identity.job,
                  token.epoch > 0, !samples.isEmpty,
                  samples.count <= request.plan.settings.model.capabilities.sampleRate * 120,
                  samples.allSatisfy(\.isFinite), bytes + Int64(samples.count) * 4 <= maximumBytes else { throw SpeechFailure(.invalidInput) }
            let data = samples.withUnsafeBytes { Data($0) }, file = UUID()
            let sha256 = try Self.digest(data)
            try write(data, name: "\(file).f32")
            let value = Descriptor(version: 1, index: index, frames: samples.count, token: token,
                fingerprint: request.plan.utterances[index].fingerprint, file: file, sha256: sha256)
            let metadata = directory.appendingPathComponent("\(file).pending")
            do { try write(JSONEncoder().encode(value), name: metadata.lastPathComponent) }
            catch { _ = unlinkat(descriptor, "\(file).f32", 0); throw error }
            pending = file
            return .init(journal: id, descriptor: value, metadata: metadata)
        }
    }
    /// Only this bounded metadata rename/fsync belongs inside SpeechWorkJob.commit.
    public func commit(_ staged: Staged) throws {
        try lock.withLock {
            let value = staged.descriptor
            guard staged.journal == id, pending == value.file, records[value.index] == nil,
                  bytes + Int64(value.frames) * 4 <= maximumBytes else { throw SpeechFailure(.invalidInput) }
            guard renameatx_np(descriptor, staged.metadata.lastPathComponent, descriptor, "\(value.index).json", UInt32(RENAME_EXCL)) == 0,
                  fsync(descriptor) == 0 else { throw SpeechFailure(.storage) }
            records[value.index] = value; bytes += Int64(value.frames) * 4; pending = nil
        }
    }
    public func discard(_ staged: Staged) {
        lock.withLock {
            guard staged.journal == id, records[staged.descriptor.index]?.file != staged.descriptor.file else { return }
            _ = unlinkat(descriptor, staged.metadata.lastPathComponent, 0)
            _ = unlinkat(descriptor, "\(staged.descriptor.file).f32", 0)
            if pending == staged.descriptor.file { pending = nil }
        }
    }
    private func validate(_ value: Descriptor, index: Int) throws {
        guard value.version == 1, value.index == index, value.fingerprint == request.plan.utterances[index].fingerprint,
              value.token.identity.batch == request.identity.batch, value.token.identity.job == request.identity.job,
              value.token.epoch > 0, (1...request.plan.settings.model.capabilities.sampleRate * 120).contains(value.frames),
              value.sha256.count == 64 else { throw SpeechFailure(.storage) }
    }
    private func samples(_ value: Descriptor) throws -> [Float] {
        let data = try read("\(value.file).f32", maximum: value.frames * 4)
        guard data.count == value.frames * 4, try Self.digest(data) == value.sha256 else { throw SpeechFailure(.storage) }
        let result = try data.withUnsafeBytes { buffer in
            var result: [Float] = []; result.reserveCapacity(value.frames)
            for start in stride(from: 0, to: value.frames, by: 16_384) {
                try AudioWorkCheckpoint.check()
                for index in start..<min(value.frames, start + 16_384) { result.append(buffer.loadUnaligned(fromByteOffset: index * 4, as: Float.self)) }
            }
            return result
        }
        guard result.allSatisfy(\.isFinite) else { throw SpeechFailure(.storage) }
        return result
    }
    private func read(_ name: String, maximum: Int) throws -> Data {
        try Self.read(name, descriptor: descriptor, maximum: maximum)
    }
    private static func read(_ name: String, descriptor: Int32, maximum: Int) throws -> Data {
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SpeechFailure(.storage) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= maximum else { throw SpeechFailure(.storage) }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count == info.st_size else { throw SpeechFailure(.storage) }
        return data
    }
    private func write(_ data: Data, name: String) throws {
        let fd = openat(descriptor, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SpeechFailure(.storage) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            for start in stride(from: 0, to: data.count, by: 1_024 * 1_024) {
                try AudioWorkCheckpoint.check()
                try handle.write(contentsOf: data.subdata(in: start..<min(data.count, start + 1_024 * 1_024)))
            }
            try handle.synchronize(); try handle.close()
            guard fsync(descriptor) == 0 else { throw SpeechFailure(.storage) }
        } catch { try? handle.close(); _ = unlinkat(descriptor, name, 0); throw error }
    }
    private static func digest(_ data: Data) throws -> String {
        var hash = SHA256()
        for start in stride(from: 0, to: data.count, by: 1_024 * 1_024) {
            try AudioWorkCheckpoint.check()
            autoreleasepool { hash.update(data: data.subdata(in: start..<min(data.count, start + 1_024 * 1_024))) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
