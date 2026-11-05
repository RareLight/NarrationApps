import Foundation
import Darwin

public enum InferencePriority: Sendable {
    case interactive, background
}

/// Cooperative per-user exclusion with interactive admission ahead of background
/// work. Kernel locks identify live request tickets; crashed owners need no daemon.
public final class InferenceLease: @unchecked Sendable {
    private let descriptors: [Int32]
    private let ticket: InteractiveTicket?
    // Set before transferring a coordinated host lease to its caller. Retains
    // ranked demand until the platform operation releases kernel exclusion.
    var coordinatedRelease: (@Sendable () -> Void)?
    private init(descriptors: [Int32], ticket: InteractiveTicket?) {
        self.descriptors = descriptors; self.ticket = ticket
    }
    deinit { descriptors.forEach { close($0) }; coordinatedRelease?(); withExtendedLifetime(ticket) {} }

    @TaskLocal public static var currentPriority: InferencePriority = .background
    @TaskLocal public static var hostAdmission: SpeechHostAdmission?

    public static var defaultFile: URL {
        supportDirectory.appendingPathComponent("SwiftNarration/Locks/inference.lock")
    }
    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    // Persisted compatibility identifier: coordinate with already-running older
    // builds. Priority admission itself requires the updated shared implementation.
    private static var legacyDefaultFile: URL {
        supportDirectory.appendingPathComponent("NativeNarration/Locks/inference.lock")
    }

    /// Reserve interactive priority across a logical job, including gaps between
    /// its individual ML operations. Background work uses the same task context.
    public nonisolated(nonsending) static func withPriority<Value: Sendable>(_ priority: InferencePriority, at file: URL = defaultFile,
        operation: nonisolated(nonsending) () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let ticket = priority == .interactive && hostAdmission == nil ? try await registerInteractive(at: file) : nil
        defer { withExtendedLifetime(ticket) {} }
        return try await $currentPriority.withValue(priority, operation: operation)
    }

    public static func acquire(at file: URL = defaultFile, priority: InferencePriority = currentPriority) async throws -> InferenceLease {
        if let hostAdmission {
            guard file.standardizedFileURL == defaultFile.standardizedFileURL || file.standardizedFileURL == hostAdmission.inferenceFile.standardizedFileURL else { throw SpeechFailure(.invalidInput) }
            return try await hostAdmission.acquire()
        }
        let files = file.standardizedFileURL == defaultFile.standardizedFileURL ? [legacyDefaultFile, file] : [file]
        return try await acquire(files: files, priority: priority)
    }

    /// Nonblocking compatibility-lock handshake for the coordinated helper.
    /// Caller holds the shared work-registration gate and has rechecked rank.
    /// Never wait for another owner while retaining that registration gate.
    /// The helper retains the result from before load until after drain/unload.
    public static func tryAcquire(at file: URL = defaultFile, priority: InferencePriority = currentPriority) throws -> InferenceLease? {
        guard file.isFileURL else { throw SpeechFailure(.invalidInput) }
        let files = file.standardizedFileURL == defaultFile.standardizedFileURL ? [legacyDefaultFile, file] : [file]
        return try tryAcquire(files: files, priority: priority)
    }
    static func tryAcquire(files: [URL], priority: InferencePriority = currentPriority) throws -> InferenceLease? {
        guard !files.isEmpty, Set(files.map(\.standardizedFileURL)).count == files.count,
              files.allSatisfy(\.isFileURL), let file = files.last else { throw SpeechFailure(.invalidInput) }
        let gate = try openLock(gateFile(for: file)); defer { close(gate) }
        if flock(gate, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw SpeechFailure(.storage) }
            return nil
        }
        defer { _ = flock(gate, LOCK_UN) }
        if priority == .background, try hasInteractiveRequests(at: file) { return nil }
        var descriptors: [Int32] = [], owned = false
        defer { if !owned { descriptors.forEach { close($0) } } }
        for url in files { descriptors.append(try openLock(url)) }
        for descriptor in descriptors {
            if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EINTR else { throw SpeechFailure(.storage) }
                return nil
            }
        }
        owned = true
        return InferenceLease(descriptors: descriptors, ticket: nil)
    }

    /// A resident neural frontend yields at the next bounded preparation
    /// boundary when interactive work registers. Observe tickets under the same
    /// gate as acquire; this never revokes another process's lease.
    public static func shouldYield(at file: URL = defaultFile, priority: InferencePriority) throws -> Bool {
        guard file.isFileURL else { throw SpeechFailure(.invalidInput) }
        guard priority == .background else { return false }
        let gate = try openLock(gateFile(for: file)); defer { close(gate) }
        guard flock(gate, LOCK_EX | LOCK_NB) == 0 else {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw SpeechFailure(.storage) }
            return true
        }
        defer { _ = flock(gate, LOCK_UN) }
        return try hasInteractiveRequests(at: file)
    }

    static func acquire(files: [URL], priority: InferencePriority = currentPriority) async throws -> InferenceLease {
        try Task.checkCancellation()
        guard !files.isEmpty, Set(files.map(\.standardizedFileURL)).count == files.count,
              files.allSatisfy(\.isFileURL), let file = files.last else { throw SpeechFailure(.invalidInput) }
        let ticket = priority == .interactive ? try await registerInteractive(at: file) : nil
        let gate = try openLock(gateFile(for: file))
        defer { close(gate) }
        var descriptors: [Int32] = []
        var owned = false
        defer { if !owned { descriptors.forEach { close($0) } } }
        for url in files { descriptors.append(try openLock(url)) }
        while true {
            try await lockGate(gate)
            do {
                try Task.checkCancellation()
                var admitted = priority == .interactive
                if !admitted { admitted = !(try hasInteractiveRequests(at: file)) }
                if admitted {
                    // Acquire all compatibility locks without retaining partial
                    // ownership while waiting. Registration/admission share a gate.
                    for descriptor in descriptors where admitted {
                        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                            guard errno == EWOULDBLOCK || errno == EINTR else { throw SpeechFailure(.storage) }
                            admitted = false
                        }
                    }
                }
                if admitted {
                    try Task.checkCancellation()
                    _ = flock(gate, LOCK_UN)
                    owned = true
                    return InferenceLease(descriptors: descriptors, ticket: ticket)
                }
                descriptors.forEach { _ = flock($0, LOCK_UN) }
                _ = flock(gate, LOCK_UN)
            } catch {
                descriptors.forEach { _ = flock($0, LOCK_UN) }
                _ = flock(gate, LOCK_UN)
                throw error
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func gateFile(for file: URL) -> URL { file.appendingPathExtension("admission") }
    static func ticketDirectory(for file: URL) -> URL { file.appendingPathExtension("interactive") }

    private static func openLock(_ file: URL) throws -> Int32 {
        guard file.isFileURL else { throw SpeechFailure(.invalidInput) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SpeechFailure(.storage) }
        do { try validate(fd) } catch { close(fd); throw error }
        return fd
    }
    @discardableResult private static func validate(_ fd: Int32, acceptUnlinked: Bool = false) throws -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_nlink == 1 || (acceptUnlinked && info.st_nlink == 0)) else { throw SpeechFailure(.storage) }
        return info.st_nlink == 1
    }
    private static func lockGate(_ fd: Int32) async throws {
        while true {
            try Task.checkCancellation()
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return }
            guard errno == EWOULDBLOCK || errno == EINTR else { throw SpeechFailure(.storage) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    private static func registerInteractive(at file: URL) async throws -> InteractiveTicket {
        let gate = try openLock(gateFile(for: file))
        defer { close(gate) }
        try await lockGate(gate)
        defer { _ = flock(gate, LOCK_UN) }
        let directory = ticketDirectory(for: file)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString)
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SpeechFailure(.storage) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); _ = unlink(url.path); throw SpeechFailure(.storage)
        }
        return InteractiveTicket(descriptor: descriptor, url: url)
    }
    /// Called under the admission gate, so an incompletely registered ticket
    /// cannot be mistaken for a crashed owner. No PID reuse or stale timestamps.
    private static func hasInteractiveRequests(at file: URL) throws -> Bool {
        let directory = ticketDirectory(for: file)
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        var pending = false
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let descriptor = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0 {
                if errno == ENOENT { continue }
                throw SpeechFailure(.storage)
            }
            defer { close(descriptor) }
// A live owner may remove its ticket between our open and fstat.
            if !(try validate(descriptor, acceptUnlinked: true)) { continue }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                _ = unlink(url.path) // Unlocked ticket belongs to an exited owner.
            } else {
                guard errno == EWOULDBLOCK || errno == EINTR else { throw SpeechFailure(.storage) }
                pending = true
            }
        }
        return pending
    }

    private final class InteractiveTicket: @unchecked Sendable {
        let descriptor: Int32
        let url: URL
        init(descriptor: Int32, url: URL) { self.descriptor = descriptor; self.url = url }
        deinit { _ = unlink(url.path); close(descriptor) }
    }
}
