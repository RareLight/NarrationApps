import Foundation
import CryptoKit
import Darwin

enum Files {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ url: URL) throws -> String {
        guard let stream = InputStream(url: url) else { throw RelayError.artifact("Cannot read artifact.") }
        stream.open(); defer { stream.close() }
        var hash = SHA256(); var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n < 0 { throw RelayError.artifact("Cannot read artifact.") }
            if n == 0 { break }
            hash.update(data: Data(buffer.prefix(n)))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let fd = Darwin.open(temporary.path, O_RDONLY)
        guard fd >= 0 else { throw RelayError.storage("Cannot open staged artifact.") }
        let synced = fsync(fd); close(fd)
        guard synced == 0, rename(temporary.path, url.path) == 0 else {
            throw RelayError.storage("Cannot commit staged artifact.")
        }
        try syncDirectory(url.deletingLastPathComponent())
    }
    static func syncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { throw RelayError.storage("Cannot open artifact directory.") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw RelayError.storage("Cannot sync artifact directory.") }
    }
    static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(value)
    }
    static func contains(_ parent: URL, _ child: URL) -> Bool {
        let p = canonicalPath(parent)
        let c = canonicalPath(child)
        return c == p || c.hasPrefix(p == "/" ? "/" : p + "/")
    }
    private static func canonicalPath(_ url: URL) -> String {
        // Resolve an existing ancestor, then append missing components. Foundation can
        // canonicalize /private/tmp differently depending on whether the leaf exists.
        var components: [String] = []
        for part in url.path.split(separator: "/").map(String.init) {
            if part == "." { continue }
            if part == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(part) }
        }
        var suffix: [String] = []
        while true {
            let candidate = "/" + components.joined(separator: "/")
            if let resolved = realpath(candidate, nil) {
                let base = String(cString: resolved); free(resolved)
                return suffix.isEmpty ? base : (base == "/" ? "" : base) + "/" + suffix.joined(separator: "/")
            }
            guard let last = components.popLast() else { return "/" + suffix.joined(separator: "/") }
            suffix.insert(last, at: 0)
        }
    }
    static func samePath(_ a: URL, _ b: URL) -> Bool { contains(a, b) && contains(b, a) }
    static func hasSymlink(_ path: URL, below root: URL) -> Bool {
        var current = path
        while !samePath(current, root) && current.path != "/" {
            var info = stat()
            if lstat(current.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK { return true }
            current.deleteLastPathComponent()
        }
        return false
    }
}
