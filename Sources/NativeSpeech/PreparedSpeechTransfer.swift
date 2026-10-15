import Foundation
import CryptoKit
import Darwin
import NarrationCore

/// Bounded, exclusively owned preparation payload. Control messages keep their
/// 64 KiB limit even for pathological expansion of a short source window.
package enum PreparedSpeechTransfer {
    package static let maximumBytes = 8 * 1_024 * 1_024
    package static func write(_ utterances: [PreparedUtterance], index: Int, spool: URL) throws -> PreparedSpeechFile {
        guard index >= 0, !utterances.isEmpty, utterances.count <= 1_000 else { throw SpeechFailure(.invalidInput) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(utterances)
        guard data.count <= maximumBytes else { throw SpeechFailure(.invalidInput) }
        let file = SpeechIPC.preparationFile(in: spool, index: index)
        let fd = open(file.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SpeechFailure(.storage) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        } catch { try? handle.close(); try? FileManager.default.removeItem(at: file); throw error }
        return .init(path: file.path, sha256: digest(data), count: utterances.count)
    }

    package static func read(_ reference: PreparedSpeechFile, index: Int, spool: URL) throws -> [PreparedUtterance] {
        let file = SpeechIPC.preparationFile(in: spool, index: index)
        guard reference.path == file.path, reference.sha256.count == 64,
              (1...1_000).contains(reference.count) else { throw SpeechFailure(.protocolViolation) }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SpeechFailure(.protocolViolation) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= maximumBytes else { throw SpeechFailure(.protocolViolation) }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count == info.st_size, digest(data) == reference.sha256 else { throw SpeechFailure(.protocolViolation) }
        let values: [PreparedUtterance]
        do { values = try JSONDecoder().decode([PreparedUtterance].self, from: data) }
        catch { throw SpeechFailure(.protocolViolation) }
        guard values.count == reference.count else { throw SpeechFailure(.protocolViolation) }
        return values
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
