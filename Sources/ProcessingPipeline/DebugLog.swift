import NarrationCore
import DocumentProcessing
import NativeSpeech
import AudioOutput
import Foundation
import Darwin

/// Opt-in, local diagnostics. A lock owns the file/counters across worker
/// readers. Logging failures never change generation or worker cleanup.
public final class DebugLog: @unchecked Sendable {
    public static let maximumBytes = 1_048_576
    public let url: URL
    private let previous: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private var bytes: Int
    private var failed = false
    public var writeFailed: Bool { lock.withLock { failed } }

    public static func existingURL(workspace: URL) -> URL? {
        guard let store = try? NativeWorkspace(root: workspace),
              let url = try? store.managed(store.nativeRoot.appendingPathComponent("diagnostics/debug.log")),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }

    /// Bounded, private current-log export; never follows aliases or reads another file type.
    public static func read(workspace: URL) throws -> String {
        let store = try NativeWorkspace(root: workspace)
        let url = try store.managed(store.nativeRoot.appendingPathComponent("diagnostics/debug.log"))
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SpeechFailure(.storage) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= maximumBytes else { throw SpeechFailure(.storage) }
        let data = try handle.read(upToCount: maximumBytes) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Caller must have joined logging work. Validate both retained files before removing either.
    public static func clear(workspace: URL) throws {
        let store = try NativeWorkspace(root: workspace)
        let files = try ["debug.log", "debug.previous.log"].compactMap { name -> URL? in
            let url = try store.managed(store.nativeRoot.appendingPathComponent("diagnostics/" + name))
            var info = stat()
            if lstat(url.path, &info) != 0 {
                guard errno == ENOENT else { throw SpeechFailure(.storage) }
                return nil
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw SpeechFailure(.storage) }
            return url
        }
        for url in files { try FileManager.default.removeItem(at: url) }
    }

    public init(workspace: URL) throws {
        let store = try NativeWorkspace(root: workspace)
        let directory = try store.managed(store.nativeRoot.appendingPathComponent("diagnostics"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        url = try store.managed(directory.appendingPathComponent("debug.log"))
        previous = try store.managed(directory.appendingPathComponent("debug.previous.log"))
        let descriptor = open(url.path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SpeechFailure(.storage) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            close(descriptor); throw SpeechFailure(.storage)
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        bytes = Int(info.st_size)
    }

    deinit { try? handle?.close() }

    public func record(_ message: String) {
        // Callers pass metadata, never serialized commands or narration.
        // Upstream stderr is retained separately as an explicitly private tail.
        let data = Data(("\(Date().ISO8601Format()) \(String(message.prefix(16_384)))\n").utf8)
        lock.withLock {
            guard let current = handle, !failed else { return }
            do {
                if bytes + data.count > Self.maximumBytes {
                    try current.close(); handle = nil
                    if FileManager.default.fileExists(atPath: previous.path) {
                        var info = stat()
                        guard lstat(previous.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                            throw SpeechFailure(.storage)
                        }
                        try FileManager.default.removeItem(at: previous)
                    }
                    try FileManager.default.moveItem(at: url, to: previous)
                    let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
                    guard descriptor >= 0 else { throw SpeechFailure(.storage) }
                    handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    bytes = 0
                }
                try handle?.write(contentsOf: data)
                bytes += data.count
            } catch {
                failed = true; try? handle?.close(); handle = nil
            }
        }
    }
}
