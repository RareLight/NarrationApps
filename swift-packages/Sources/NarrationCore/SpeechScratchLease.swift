import Foundation
import Darwin

/// Host and helper hold shared directory locks until their actual writers/GPU
/// work are joined. Cleanup needs an exclusive lock and our versioned marker;
/// old/unknown directories are never inferred to be safe from a stale PID.
public final class SpeechScratchLease: @unchecked Sendable {
    private static let markerName = ".narration-owned-scratch"
    private static let marker = Data("narration-owned-scratch-1\n".utf8)
    private let lock = NSLock()
    private var descriptor: Int32
    public init(directory: URL, create: Bool, allowUnmarked: Bool = false) throws {
        let fd = try Self.openDirectory(directory)
        do {
            guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { throw SpeechFailure(.storage) }
            if create {
                let file = openat(fd, Self.markerName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard file >= 0 else { throw SpeechFailure(.storage) }
                let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
                do { try handle.write(contentsOf: Self.marker); try handle.synchronize(); try handle.close() }
                catch { try? handle.close(); throw error }
            } else if !allowUnmarked || Self.markerExists(fd) { try Self.validateMarker(fd) }
            descriptor = fd
        } catch { Darwin.close(fd); throw SpeechFailure(.storage) }
    }
    deinit { close() }
    public func close() {
        let fd = lock.withLock { let fd = descriptor; descriptor = -1; return fd }
        if fd >= 0 { Darwin.close(fd) }
    }
    private static func openDirectory(_ directory: URL, requirePrivate: Bool = true) throws -> Int32 {
        guard directory.isFileURL, directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else { throw SpeechFailure(.storage) }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SpeechFailure(.storage) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              !requirePrivate || info.st_mode & 0o077 == 0 else { Darwin.close(fd); throw SpeechFailure(.storage) }
        return fd
    }
    private static func markerExists(_ fd: Int32) -> Bool {
        var info = stat(); return fstatat(fd, markerName, &info, AT_SYMLINK_NOFOLLOW) == 0
    }
    private static func validateMarker(_ fd: Int32) throws {
        let file = openat(fd, markerName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw SpeechFailure(.storage) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_mode & 0o077 == 0,
              try handle.read(upToCount: 64) == marker else { throw SpeechFailure(.storage) }
    }
    @discardableResult public static func removeIfUnowned(_ directory: URL) throws -> Bool {
        let fd = try openDirectory(directory); defer { Darwin.close(fd) }
        guard markerExists(fd) else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { return false }
            throw SpeechFailure(.storage)
        }
        try validateMarker(fd)
        var opened = stat(), current = stat()
        guard fstat(fd, &opened) == 0, lstat(directory.path, &current) == 0,
              opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else { throw SpeechFailure(.storage) }
        try FileManager.default.removeItem(at: directory)
        return true
    }
    /// The owner chooses the namespace, never an HTTP field. Busy and unmarked
    /// work is retained. No source files, models or recovery journals are visited.
    public static func sweep(_ parent: URL, prefix: String) throws -> Int {
        guard !prefix.isEmpty, !prefix.contains("/"), parent.isFileURL else { throw SpeechFailure(.storage) }
        guard FileManager.default.fileExists(atPath: parent.path) else { return 0 }
        let fd = try openDirectory(parent, requirePrivate: false); defer { Darwin.close(fd) }
        var removed = 0
        for child in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
            try NarrationWorkCheckpoint.check()
            let name = child.lastPathComponent
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            if try removeIfUnowned(child) { removed += 1 }
        }
        return removed
    }
}
