import Foundation
import Darwin

public enum SpeechWorkRank: Int, Codable, Sendable { case api, libro, podcast }
public enum SpeechWorkOwner: String, Codable, Sendable { case libro, voiceRelay }
public enum SpeechWorkDelivery: String, Codable, Sendable { case streaming, file }
public enum SpeechWorkPurpose: String, Codable, Sendable { case speech, cpu }
public enum SpeechCoordinationFailure: Error, Equatable, Sendable { case invalidStorage, invalidDemand, capacity, timeout }

/// Coordination metadata only: no settings, text, paths, credentials or audio.
public struct SpeechWorkDemand: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let instance: UUID
    public let owner: SpeechWorkOwner
    public let rank: SpeechWorkRank
    public let delivery: SpeechWorkDelivery
    public let order: UInt64
    // Absent in earlier records. CPU demand ranks apps but never authorizes a
    // model host, nor serializes same-app speech behind its own finalizer.
    public let purpose: SpeechWorkPurpose?
    fileprivate var valid: Bool {
        version == 1 && order > 0 &&
        (rank == .libro ? owner == .libro && delivery == .file : owner == .voiceRelay) &&
        (rank == .api || delivery == .file) && !(rank == .api && purpose == .cpu)
    }
}

public enum SpeechWorkDecision: Equatable, Sendable {
    case run
    case waitForBoundary(SpeechWorkDemand)
    case cancelForStreamingAPI(SpeechWorkDemand)
    case withdrawn
}

/// Synchronous, short filesystem operations: call off UI/HTTP executors.
/// Tickets rank demand; they do not replace helper-owned compatibility locks.
/// This registry remains unused by normal app scheduling until coordinated
/// helper/session and durable checkpoint integration are complete.
public final class SpeechWorkAdmission: @unchecked Sendable {
    public static var defaultRoot: URL {
        InferenceLease.defaultFile.deletingLastPathComponent().appendingPathComponent("work-admission-v1")
    }
    public static let maximumTickets = 256
    public static let maximumRecordBytes = 4096
    private static let marker = Data("SwiftNarration/SpeechWorkAdmission/1\n".utf8)
    private var directory: Int32
    private let timeout: TimeInterval
    private let root: URL

    public init(root: URL = defaultRoot, timeout: TimeInterval = 3) throws {
        guard root.isFileURL, root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              timeout.isFinite, timeout > 0, timeout <= 30 else { throw SpeechCoordinationFailure.invalidStorage }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw SpeechCoordinationFailure.invalidStorage }
        directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        self.timeout = timeout
        self.root = root
        var info = stat()
        guard directory >= 0 else { throw SpeechCoordinationFailure.invalidStorage }
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else { close(directory); directory = -1; throw SpeechCoordinationFailure.invalidStorage }
        do {
            let names = try entries()
            guard names.contains("schema") || names.allSatisfy({ $0 == "gate" }) else { throw SpeechCoordinationFailure.invalidStorage }
            try gated {
                let names = try entries()
                if !names.contains("schema") {
                    guard names.allSatisfy({ $0 == "gate" }) else { throw SpeechCoordinationFailure.invalidStorage }
                    let marker = try file("schema", create: true)
                    defer { close(marker) }
                    try write(Self.marker, to: marker)
                    guard fsync(marker) == 0 else { throw SpeechCoordinationFailure.invalidStorage }
                }
                let marker = try file("schema"); defer { close(marker) }
                guard try read(marker) == Self.marker else { throw SpeechCoordinationFailure.invalidStorage }
            }
        } catch { close(directory); directory = -1; throw error }
    }
    deinit { if directory >= 0 { close(directory) } }

    public func register(owner: SpeechWorkOwner, instance: UUID, rank: SpeechWorkRank,
                         delivery: SpeechWorkDelivery, purpose: SpeechWorkPurpose = .speech) throws -> SpeechWorkTicket {
        let ticket = try gated {
            let live = try liveLocked()
            guard live.count < Self.maximumTickets else { throw SpeechCoordinationFailure.capacity }
            let greatest = live.map(\.order).max() ?? 0
            guard greatest < UInt64.max else { throw SpeechCoordinationFailure.capacity }
            let demand = SpeechWorkDemand(version: 1, id: UUID(), instance: instance, owner: owner,
                rank: rank, delivery: delivery, order: greatest + 1, purpose: purpose == .cpu ? .cpu : nil)
            guard demand.valid else { throw SpeechCoordinationFailure.invalidDemand }
            let name = filename(demand.id), descriptor = try file(filename(demand.id), create: true, exclusive: true)
            do {
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw SpeechCoordinationFailure.invalidStorage }
                try write(JSONEncoder().encode(demand), to: descriptor)
                return SpeechWorkTicket(demand: demand, descriptor: descriptor, registry: self)
            } catch { _ = unlinkat(directory, name, 0); close(descriptor); throw error }
        }
        SpeechWorkWakeup.post(root: root)
        return ticket
    }
    public func highest() throws -> SpeechWorkDemand? {
        try gated { try highestLocked() }
    }
    public func highest(for demand: SpeechWorkDemand) throws -> SpeechWorkDemand? {
        try gated { try highestLocked(for: demand) }
    }
    private func highestLocked(for demand: SpeechWorkDemand) throws -> SpeechWorkDemand? {
        try liveLocked().filter {
            !($0.purpose == .cpu && $0.instance == demand.instance && $0.rank == demand.rank && demand.rank != .api)
        }.min(by: precedes)
    }
    /// Final registration/rank fence. The operation must be short and nonblocking
    /// (for example a kernel try-lock), never a wait for cancellation/model load.
    public func withHighest<Value>(_ demand: SpeechWorkDemand, operation: () throws -> Value) throws -> Value? {
        try gated {
            guard try highestLocked(for: demand) == demand else { return nil }
            return try operation()
        }
    }
    /// Helper-only residency handshake. A positive rank snapshot alone cannot
    /// authorize loading; both rank and current/legacy exclusion must succeed.
    public func tryAcquireResidency(for demand: SpeechWorkDemand,
                                    inferenceFile: URL = InferenceLease.defaultFile) throws -> InferenceLease? {
        guard demand.purpose != .cpu else { throw SpeechCoordinationFailure.invalidDemand }
        let result = try withHighest(demand) {
            try InferenceLease.tryAcquire(at: inferenceFile, priority: demand.rank == .podcast ? .background : .interactive)
        }
        return result ?? nil
    }
    /// Advisory snapshot only. Use withHighest for launch or withDecision for a
    /// short fenced checkpoint transaction; do not launch from a stale snapshot.
    public func decision(for demand: SpeechWorkDemand) throws -> SpeechWorkDecision {
        try withDecision(for: demand) { $0 }
    }
    /// Linearize a short final commit/decision against accepted demand, allowing
    /// cooperative file-mode boundary commits while rejecting revoked streaming
    /// work. Do all hashing/validation and all asynchronous waits outside this gate.
    public func withDecision<Value>(for demand: SpeechWorkDemand,
                                   operation: (SpeechWorkDecision) throws -> Value) throws -> Value {
        try gated {
            let live = try liveLocked()
            guard live.contains(demand) else { return try operation(.withdrawn) }
            guard let highest = live.min(by: precedes), highest != demand else { return try operation(.run) }
            if highest.rank == .api && highest.delivery == .streaming && demand.rank != .api {
                return try operation(.cancelForStreamingAPI(highest))
            }
            return try operation(.waitForBoundary(highest))
        }
    }
    fileprivate func withdraw(_ demand: SpeechWorkDemand) throws {
        try gated {
            if unlinkat(directory, filename(demand.id), 0) != 0, errno != ENOENT { throw SpeechCoordinationFailure.invalidStorage }
        }
        SpeechWorkWakeup.post(root: root)
    }
    private func filename(_ id: UUID) -> String { "ticket-" + id.uuidString }
    private func precedes(_ a: SpeechWorkDemand, _ b: SpeechWorkDemand) -> Bool {
        a.rank.rawValue == b.rank.rawValue ? a.order < b.order : a.rank.rawValue < b.rank.rawValue
    }
    private func highestLocked() throws -> SpeechWorkDemand? { try liveLocked().min(by: precedes) }
    private func liveLocked() throws -> [SpeechWorkDemand] {
        var live: [SpeechWorkDemand] = []
        for name in try entries() where name != "gate" && name != "schema" {
            guard name.hasPrefix("ticket-"), let id = UUID(uuidString: String(name.dropFirst(7))), filename(id) == name else { throw SpeechCoordinationFailure.invalidStorage }
            let descriptor = try file(name); defer { close(descriptor) }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                guard unlinkat(directory, name, 0) == 0 else { throw SpeechCoordinationFailure.invalidStorage }
                continue // Kernel lock, never timestamps or a reused PID, is liveness.
            }
            guard errno == EWOULDBLOCK else { throw SpeechCoordinationFailure.invalidStorage }
            let demand: SpeechWorkDemand
            do { demand = try JSONDecoder().decode(SpeechWorkDemand.self, from: read(descriptor)) }
            catch { throw SpeechCoordinationFailure.invalidStorage }
            guard demand.valid, demand.id == id, !live.contains(where: { $0.order == demand.order }) else { throw SpeechCoordinationFailure.invalidStorage }
            live.append(demand)
        }
        return live
    }
    private func gated<Value>(_ operation: () throws -> Value) throws -> Value {
        let gate = try file("gate", create: true); defer { close(gate) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while flock(gate, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw SpeechCoordinationFailure.invalidStorage }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SpeechCoordinationFailure.timeout }
            Thread.sleep(forTimeInterval: 0.001)
        }
        defer { _ = flock(gate, LOCK_UN) }
        return try operation()
    }
    private func file(_ name: String, create: Bool = false, exclusive: Bool = false) throws -> Int32 {
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0) | (exclusive ? O_EXCL : 0)
        let descriptor = openat(directory, name, flags, 0o600)
        var info = stat()
        guard descriptor >= 0 else { throw SpeechCoordinationFailure.invalidStorage }
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size <= Self.maximumRecordBytes else {
            close(descriptor); throw SpeechCoordinationFailure.invalidStorage
        }
        return descriptor
    }
    private func read(_ descriptor: Int32) throws -> Data {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 0, info.st_size <= Self.maximumRecordBytes else { throw SpeechCoordinationFailure.invalidStorage }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = pread(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SpeechCoordinationFailure.invalidStorage }; offset += count
            }
        }
        return data
    }
    private func write(_ data: Data, to descriptor: Int32) throws {
        guard data.count <= Self.maximumRecordBytes else { throw SpeechCoordinationFailure.invalidStorage }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = pwrite(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SpeechCoordinationFailure.invalidStorage }; offset += count
            }
        }
        guard ftruncate(descriptor, off_t(data.count)) == 0 else { throw SpeechCoordinationFailure.invalidStorage }
    }
    private func entries() throws -> [String] {
        let copy = dup(directory)
        guard copy >= 0 else { throw SpeechCoordinationFailure.invalidStorage }
        guard let stream = fdopendir(copy) else { close(copy); throw SpeechCoordinationFailure.invalidStorage }
        defer { closedir(stream) }; rewinddir(stream)
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw SpeechCoordinationFailure.invalidStorage }; break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            if name == "." || name == ".." { continue }
            names.append(name)
            guard names.count <= Self.maximumTickets + 2 else { throw SpeechCoordinationFailure.capacity }
        }
        return names
    }
}

public final class SpeechWorkTicket: @unchecked Sendable {
    public let demand: SpeechWorkDemand
    private let registry: SpeechWorkAdmission
    private let lock = NSLock()
    private var descriptor: Int32?
    fileprivate init(demand: SpeechWorkDemand, descriptor: Int32, registry: SpeechWorkAdmission) {
        self.demand = demand; self.descriptor = descriptor; self.registry = registry
    }
    public func withdraw() throws {
        try lock.withLock {
            guard let descriptor else { return }
            defer { close(descriptor); self.descriptor = nil }
            try registry.withdraw(demand)
        }
    }
    deinit { try? withdraw() }
}

