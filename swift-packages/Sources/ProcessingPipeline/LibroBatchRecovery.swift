import Foundation
import CryptoKit
import Darwin
import NarrationCore
import DocumentProcessing
import NativeSpeech
import AudioOutput
import Pronunciation

/// Explicit private batch recovery. Opening a record never starts work. The app
/// must restore file access and obtain an explicit Resume before running it.
public final class LibroBatchRecovery: @unchecked Sendable {
    private struct FileProof: Codable, Equatable { let bytes: Int64; let device: UInt64; let inode: UInt64; let sha256: String }
    private struct Document: Codable {
        let id: UUID, source: URL, canonicalSource: URL, destination: URL
        let kind: DocumentKind, encoding: TextFileEncoding
        let relativeInput: String, relativeOutput: String
        let replacesExisting: Bool
        let sourceProof: FileProof, destinationProof: FileProof?
    }
    private struct Manifest: Codable {
        let version: Int, id: UUID, documents: [Document], output: URL, workspace: URL
        let settings: SpeechSettings, describeImages: Bool, format: AudioOutputFormat
        let entries: [PronunciationEntry], pronunciationFingerprint: String, options: NarrationOptions
        let covers: [UUID: Data], approved: Set<UUID>
        let textPreparationWorkers: Int?
    }
    private struct QueueRecord: Codable { let current: UUID?; let pending: [UUID]; let paused: Bool }
    private struct Completion: Codable { let version: Int; let id: UUID; let skipped: Bool; let proof: FileProof? }
    public let directory: URL
    public var id: UUID { saved.id }
    public struct Summary: Sendable {
        public let id: UUID
        public let documentCount: Int
        public let completedCount: Int
        public let firstSource: String
        public let output: URL
    }
    /// Discovery reads receipts only. Hashing source/audio belongs to the
    /// explicitly requested, CPU-admitted Resume operation.
    public func summary() throws -> Summary {
        let completed = try saved.documents.filter { try completion($0, verifyOutput: false) != nil }.count
        return .init(id: saved.id, documentCount: saved.documents.count, completedCount: completed,
                     firstSource: saved.documents[0].source.lastPathComponent, output: saved.output)
    }
    public var requiredAccess: [URL] { Array(Set(saved.documents.map(\.source) + [saved.output, saved.workspace])).sorted { $0.path < $1.path } }
    public var capturedSettings: SpeechSettings { saved.settings }
    public var capturedWorkspace: URL { saved.workspace }
    /// Explicit discard or verified-complete cleanup only. Journals are private
    /// checkpoints; removing them never visits sources or completed output.
    public func discard() throws {
        try lock.withLock {
            var opened = stat(), current = stat()
            guard fstat(descriptor, &opened) == 0, lstat(directory.path, &current) == 0,
                  opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else { throw SpeechFailure(.storage) }
            try FileManager.default.removeItem(at: directory)
        }
    }
    public var wasManuallyPaused: Bool { get throws { try queueRecord()?.paused ?? false } }
    private let saved: Manifest
    private let descriptor: Int32
    private let lock = NSLock()
    private let io = DispatchQueue(label: "org.libro.batch-recovery")
    private var lastSequence = -1
    private var queueWriteFailed = false

    public convenience init(directory: URL, request: BatchRequest, pronunciations: PronunciationDictionary? = nil) throws {
        _ = try BatchPlanner.ValidationContext(request)
        let dictionary = pronunciations ?? request.pronunciations
        var settings = request.settings; settings.savedChoices = nil
        let documents = try request.documents.map { doc in
            Document(id: doc.id, source: doc.input.source, canonicalSource: try OutputPaths.resolved(doc.input.source), destination: doc.destination,
                kind: doc.input.kind, encoding: doc.input.textEncoding, relativeInput: doc.input.relativePath, relativeOutput: doc.relativeOutput,
                replacesExisting: doc.replacesExisting, sourceProof: try Self.proof(doc.input.source),
                destinationProof: doc.replacesExisting ? try Self.proof(doc.destination) : nil)
        }
        let capture = Manifest(version: 1, id: request.id, documents: documents, output: request.outputDirectory, workspace: request.workspace,
            settings: settings, describeImages: request.describeImages, format: request.outputFormat, entries: dictionary.entries,
            pronunciationFingerprint: dictionary.fingerprint, options: request.narrationOptions, covers: request.coverArtwork.mapValues(\.data),
            approved: request.approvedReplacements, textPreparationWorkers: request.textPreparationWorkers)
        try self.init(directory: directory, capture: capture)
    }
    public convenience init(reopening directory: URL) throws { try self.init(directory: directory, capture: nil) }
    private init(directory: URL, capture: Manifest?) throws {
        guard directory.isFileURL, directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else { throw SpeechFailure(.storage) }
        if capture != nil { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SpeechFailure(.storage) }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0,
                  flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw SpeechFailure(.storage) }
            let manifest: Manifest
            if let capture {
                guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else { throw SpeechFailure(.storage) }
                manifest = capture
            } else { manifest = try JSONDecoder().decode(Manifest.self, from: Self.read("batch.json", fd: fd, maximum: 16 * 1_024 * 1_024)) }
            guard CPUTextPreparation.validates(manifest.textPreparationWorkers ?? 1),
                  manifest.version == 1, !manifest.documents.isEmpty, manifest.documents.count <= 1_000,
                  Set(manifest.documents.map(\.id)).count == manifest.documents.count, manifest.settings.isValid,
                  manifest.output.isFileURL, manifest.workspace.isFileURL,
                  manifest.approved.isSubset(of: Set(manifest.documents.map(\.id))),
                  manifest.covers.keys.allSatisfy({ id in manifest.documents.contains { $0.id == id } }),
                  try PronunciationDictionary(entries: manifest.entries).fingerprint == manifest.pronunciationFingerprint else { throw SpeechFailure(.invalidInput) }
            for doc in manifest.documents {
                guard doc.source.isFileURL, doc.canonicalSource.isFileURL, doc.destination.isFileURL,
                      doc.sourceProof.sha256.count == 64, doc.sourceProof.bytes >= 0 else { throw SpeechFailure(.invalidInput) }
            }
            for data in manifest.covers.values { _ = try CoverArtwork(preparedData: data) }
            if capture != nil { try Self.write(JSONEncoder().encode(manifest), name: "batch.json", fd: fd, replacing: false) }
            self.directory = directory; saved = manifest; descriptor = fd
        } catch { close(fd); throw error }
    }
    deinit { close(descriptor) }

    /// Completed/skipped documents are excluded, preserving their output bytes
    /// and the captured ordering of remaining work. No new consent is inferred.
    public func resumeRequest() throws -> BatchRequest {
        let remaining = try saved.documents.filter { try completion($0) == nil }
        let order = try queueRecord().map { record in (record.current.map { [$0] } ?? []) + record.pending } ?? saved.documents.map(\.id)
        let all = order + saved.documents.map(\.id).filter { !order.contains($0) }
        let rank = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1, $0) })
        let sorted = remaining.sorted { rank[$0.id, default: Int.max] < rank[$1.id, default: Int.max] }
        let documents = sorted.map { doc in
            PlannedDocument(input: .init(source: doc.source, kind: doc.kind, relativePath: doc.relativeInput, id: doc.id, textEncoding: doc.encoding),
                destination: doc.destination, relativeOutput: doc.relativeOutput, replacesExisting: doc.replacesExisting)
        }
        let covers = try saved.covers.filter { key, _ in remaining.contains { $0.id == key } }.mapValues { try CoverArtwork(preparedData: $0) }
        return BatchRequest(documents: documents, outputDirectory: saved.output, workspace: saved.workspace, settings: saved.settings,
            describeImages: saved.describeImages, outputFormat: saved.format, pronunciations: try .init(entries: saved.entries),
            coverArtwork: covers, narrationOptions: saved.options, id: saved.id,
            approvedReplacements: saved.approved.intersection(Set(documents.map(\.id))), textPreparationWorkers: saved.textPreparationWorkers ?? 1)
    }
    public func validateBinding(_ request: BatchRequest) throws {
        let expected = try resumeRequest()
        var settings = request.settings; settings.savedChoices = nil
        guard request.id == saved.id, settings == saved.settings, request.outputDirectory == saved.output, request.workspace == saved.workspace,
              request.textPreparationWorkers == (saved.textPreparationWorkers ?? 1),
              request.outputFormat == saved.format, request.describeImages == saved.describeImages, request.narrationOptions == saved.options,
              request.approvedReplacements == expected.approvedReplacements, request.pronunciations.fingerprint == saved.pronunciationFingerprint,
              request.coverArtwork.mapValues(\.digest) == expected.coverArtwork.mapValues(\.digest),
              request.documents.map(\.id) == expected.documents.map(\.id) else { throw SpeechFailure(.invalidInput) }
        for (actual, wanted) in zip(request.documents, expected.documents) {
            guard actual.input == wanted.input, actual.destination == wanted.destination, actual.relativeOutput == wanted.relativeOutput,
                  actual.replacesExisting == wanted.replacesExisting else { throw SpeechFailure(.invalidInput) }
            try validateSourceAndDestination(document: actual.id)
        }
    }
    public func validateSourceAndDestination(document id: UUID) throws {
        guard let doc = saved.documents.first(where: { $0.id == id }),
              try OutputPaths.resolved(doc.source) == doc.canonicalSource,
              try Self.proof(doc.source) == doc.sourceProof else { throw SpeechFailure(.invalidInput) }
        if let destination = doc.destinationProof {
            guard try Self.proof(doc.destination) == destination else { throw SpeechFailure(.storage) }
        } else if FileManager.default.fileExists(atPath: doc.destination.path) { throw SpeechFailure(.storage) }
    }
    public func journal(document id: UUID, plan: PreparedSpeechPlan? = nil) throws -> SpeechRenderJournal? {
        guard let doc = saved.documents.first(where: { $0.id == id }) else { throw SpeechFailure(.invalidInput) }
        if let plan { guard plan.settings == saved.settings else { throw SpeechFailure(.invalidInput) } }
        let path = directory.appendingPathComponent(id.uuidString)
        let journal: SpeechRenderJournal
        if FileManager.default.fileExists(atPath: path.appendingPathComponent("job.json").path) {
            journal = try SpeechRenderJournal(reopening: path)
            guard plan == nil || journal.request.plan == plan else { throw SpeechFailure(.invalidInput) }
        } else {
            guard let plan else { return nil }
            let cover = try saved.covers[id].map { try CoverArtwork(preparedData: $0) }
            journal = try SpeechRenderJournal(directory: path, request: .init(identity: .init(batch: saved.id, job: id), plan: plan,
                destination: doc.destination, format: saved.format, replaceExisting: saved.approved.contains(id),
                sourceFingerprint: doc.sourceProof.sha256, documentOrder: saved.documents.map(\.id), coverArtwork: cover))
        }
        guard journal.request.identity.batch == saved.id, journal.request.identity.job == id,
              journal.request.plan.settings == saved.settings, journal.request.sourceFingerprint == doc.sourceProof.sha256,
              journal.request.destination == doc.destination, journal.request.format == saved.format,
              journal.request.replaceExisting == saved.approved.contains(id), journal.request.documentOrder == saved.documents.map(\.id),
              journal.request.artworkDigest == saved.covers[id].map({ SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }),
              journal.request.explicitGap == nil else { throw SpeechFailure(.invalidInput) }
        return journal
    }
    public func markPublished(_ id: UUID) throws {
        guard let doc = saved.documents.first(where: { $0.id == id }) else { throw SpeechFailure(.invalidInput) }
        let record = Completion(version: 1, id: id, skipped: false, proof: try Self.proof(doc.destination, cancellable: false))
        try lock.withLock { try Self.write(JSONEncoder().encode(record), name: "done-\(id).json", fd: descriptor, replacing: false) }
    }
    public func markSkipped(_ id: UUID) throws {
        guard saved.documents.contains(where: { $0.id == id }) else { throw SpeechFailure(.invalidInput) }
        try lock.withLock { try Self.write(JSONEncoder().encode(Completion(version: 1, id: id, skipped: true, proof: nil)), name: "done-\(id).json", fd: descriptor, replacing: false) }
    }
    private func completion(_ doc: Document, verifyOutput: Bool = true) throws -> Completion? {
        try lock.withLock {
            let name = "done-\(doc.id).json"
            var info = stat()
            if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw SpeechFailure(.storage) }; return nil
            }
            let record = try JSONDecoder().decode(Completion.self, from: Self.read(name, fd: descriptor, maximum: 4096))
            guard record.version == 1, record.id == doc.id, record.skipped ? record.proof == nil : record.proof != nil else { throw SpeechFailure(.storage) }
            if verifyOutput, let proof = record.proof { guard try Self.proof(doc.destination) == proof else { throw SpeechFailure(.storage) } }
            return record
        }
    }
    public func beginRun() { io.sync { lock.withLock { lastSequence = -1; queueWriteFailed = false } } }
    /// Control callbacks may arrive on MainActor. Coalesce/order their small
    /// records on the owned I/O queue; never hash or write a ledger in the UI.
    public func recordQueue(_ state: BatchQueueState) {
        guard state.batch == saved.id else { return }
        let record = QueueRecord(current: state.current, pending: state.pending, paused: state.pauseRequested)
        io.async { [self] in
            lock.withLock {
                guard state.sequence > lastSequence else { return }
                do { try Self.write(JSONEncoder().encode(record), name: "queue.json", fd: descriptor, replacing: true); lastSequence = state.sequence }
                catch { queueWriteFailed = true }
            }
        }
    }
    public func flush() async throws {
        await withCheckedContinuation { continuation in io.async { continuation.resume() } }
        guard !lock.withLock({ queueWriteFailed }) else { throw SpeechFailure(.storage) }
    }
    private func queueRecord() throws -> QueueRecord? {
        try lock.withLock {
            var info = stat()
            if fstatat(descriptor, "queue.json", &info, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw SpeechFailure(.storage) }; return nil
            }
            let value = try JSONDecoder().decode(QueueRecord.self, from: Self.read("queue.json", fd: descriptor, maximum: 128 * 1024))
            let order = (value.current.map { [$0] } ?? []) + value.pending
            guard Set(order).count == order.count, Set(order).isSubset(of: Set(saved.documents.map(\.id))) else { throw SpeechFailure(.storage) }
            return value
        }
    }
    private static func proof(_ file: URL, cancellable: Bool = true) throws -> FileProof {
        let canonical = try OutputPaths.resolved(file), fd = open(canonical.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SpeechFailure(.storage) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var before = stat(); guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw SpeechFailure(.storage) }
        var hash = SHA256(), total: Int64 = 0
        while true {
            if cancellable { try AudioWorkCheckpoint.check() }
            else { try AudioWorkCheckpoint.current?() }
            let count = try autoreleasepool { () throws -> Int in
                let block = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
                hash.update(data: block); return block.count
            }
            total += Int64(count); if count == 0 { break }
        }
        var after = stat(), pathInfo = stat()
        guard fstat(fd, &after) == 0, lstat(canonical.path, &pathInfo) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              after.st_dev == pathInfo.st_dev, after.st_ino == pathInfo.st_ino,
              before.st_size == after.st_size, total == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw SpeechFailure(.storage) }
        return .init(bytes: total, device: UInt64(UInt32(bitPattern: after.st_dev)), inode: UInt64(after.st_ino),
                     sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private static func read(_ name: String, fd: Int32, maximum: Int) throws -> Data {
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw SpeechFailure(.storage) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= maximum else { throw SpeechFailure(.storage) }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count == info.st_size else { throw SpeechFailure(.storage) }; return data
    }
    private static func write(_ data: Data, name: String, fd: Int32, replacing: Bool) throws {
        guard data.count <= 16 * 1_024 * 1_024 else { throw SpeechFailure(.storage) }
        var info = stat()
        if replacing, fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { _ = try read(name, fd: fd, maximum: 16 * 1_024 * 1_024) }
        let temporary = "\(UUID()).tmp", file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw SpeechFailure(.storage) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close(); _ = unlinkat(fd, temporary, 0) }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard renameatx_np(fd, temporary, fd, name, replacing ? 0 : UInt32(RENAME_EXCL)) == 0, fsync(fd) == 0 else { throw SpeechFailure(.storage) }
    }
}
