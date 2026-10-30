import Foundation
import Darwin

public struct PronunciationSnapshot: Sendable {
    public let dictionary: PronunciationDictionary
    public let revision: String?
}

/// One local dictionary shared by all SwiftNarration apps for this user.
/// Call file operations off the UI actor. Atomic writes and a compare-and-swap
/// revision protect edits from another process; corrupt files are never reset.
public struct PronunciationStore: Sendable {
    public let file: URL
    public init(file: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SwiftNarration/Pronunciation/overrides.json")) {
        self.file = file
    }
    private struct Document: Codable { let version: Int; let entries: [PronunciationEntry] }

    public func load() throws -> PronunciationSnapshot {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return .init(dictionary: .empty, revision: nil) }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw PronunciationError.invalidFile }
        do {
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard (1...2).contains(document.version) else { throw PronunciationError.invalidFile }
            return .init(dictionary: try PronunciationDictionary(entries: document.entries), revision: PronunciationDictionary.digest(data))
        } catch { throw PronunciationError.invalidFile }
    }

    public func save(entries: [PronunciationEntry], expectedRevision: String?) throws -> PronunciationSnapshot {
        let dictionary = try PronunciationDictionary(entries: entries)
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw PronunciationError.invalidFile }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw PronunciationError.invalidFile }
        guard try load().revision == expectedRevision else { throw PronunciationError.conflict }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let advanced = dictionary.entries.contains { $0.language != nil || $0.documentTitle != nil || $0.model != nil || $0.phonemes != nil }
        let data = try encoder.encode(Document(version: advanced ? 2 : 1, entries: dictionary.entries))
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return .init(dictionary: dictionary, revision: PronunciationDictionary.digest(data))
    }
}
