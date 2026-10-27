import Foundation
import Darwin

public struct LibraryBackupSummary: Codable, Sendable, Equatable {
    public let createdAt: Date
    public let episodes: Int
    public let queuedArticles: Int
    public let retainedArticles: Int
}

private struct BackupManifest: Codable {
    struct File: Codable { let bytes: Int; let sha256: String }
    let version: Int
    let summary: LibraryBackupSummary
    let files: [String: File]
}

/// Private metadata only. No credentials, preferences, runtime, audio or scratch.
/// Operations require an idle coordinator; restore never performs network work.
enum LibraryBackup {
    private static let maximumBytes = 512 * 1024 * 1024
    private static let databaseName = "native.sqlite3"
    private static let ledgerName = "delivery.json"
    private static let manifestName = "manifest.json"
    private static let tables: Set<String> = ["episodes", "chunks", "feed_status", "snapshots", "reading_list_inventory", "speech_queue"]

    static func inspect(_ folder: URL) throws -> LibraryBackupSummary {
        try validated(folder).summary
    }
    private static func regular(_ url: URL, root: URL, limit: Int = maximumBytes) throws -> Int {
        var info = stat()
        guard Files.contains(root, url), !Files.hasSymlink(url, below: root),
              lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else {
            throw RelayError.artifact("The library backup contains an invalid file or exceeds its size limit.")
        }
        return Int(info.st_size)
    }
    private static func validated(_ folder: URL) throws -> BackupManifest {
        var info = stat()
        guard folder.isFileURL, lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw RelayError.artifact("Choose a VoiceRelay library backup folder.")
        }
        _ = try regular(folder.appendingPathComponent(manifestName), root: folder, limit: 64_000)
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: folder.appendingPathComponent(manifestName)))
        guard manifest.version == 1, manifest.files[databaseName] != nil,
              Set(manifest.files.keys).isSubset(of: [databaseName, ledgerName]),
              Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == Set(manifest.files.keys).union([manifestName]) else {
            throw RelayError.artifact("This library backup format is unsupported or incomplete.")
        }
        for (name, file) in manifest.files {
            let url = folder.appendingPathComponent(name)
            guard try regular(url, root: folder) == file.bytes, try Files.hash(url) == file.sha256 else {
                throw RelayError.artifact("The library backup failed its integrity check.")
            }
        }
        let store = try NativeStore(url: folder.appendingPathComponent(databaseName), readOnly: true)
        try validate(store)
        let summary = try summary(store, date: manifest.summary.createdAt)
        guard summary == manifest.summary else { throw RelayError.artifact("The library backup record counts do not match.") }
        if manifest.files[ledgerName] != nil {
            _ = try JSONDecoder().decode(DeliveryLedger.self, from: Data(contentsOf: folder.appendingPathComponent(ledgerName)))
        }
        return manifest
    }
    private static func summary(_ store: NativeStore, date: Date) throws -> LibraryBackupSummary {
        LibraryBackupSummary(createdAt: date, episodes: try store.episodes().count,
            queuedArticles: try store.queue().count,
            retainedArticles: Int(try store.query("SELECT COUNT(*) FROM snapshots").first?.first ?? "") ?? 0)
    }
    private static func validate(_ store: NativeStore) throws {
        guard try store.query("PRAGMA quick_check") == [["ok"]],
              try store.query("PRAGMA foreign_key_check").isEmpty,
              Set(try store.query("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND type='table'").compactMap(\.first)) == tables,
              try store.query("SELECT name FROM sqlite_master WHERE type IN ('trigger','view')").isEmpty else {
            throw RelayError.artifact("The library backup database is invalid.")
        }
        _ = try store.catalog(); _ = try store.queue()
        for episode in try store.episodes() {
            if let transcript = episode.transcript { _ = try transcript.data(for: episode.audioHash ?? episode.encodedHash) }
            for reference in episode.transcriptReferences ?? [] { try reference.validate() }
            guard UUID(uuidString: episode.id) != nil,
                  ["reviewed-article-speech", "speech-fixture"].contains(episode.settings.backendSelector),
                  episode.settings.webdavURL == nil, episode.settings.webdavUsername == nil else {
                throw RelayError.artifact("The library backup contains unsupported article records.")
            }
            if let bytes = try store.snapshot(articleID: episode.id) {
                _ = try JSONDecoder().decode(StoredExtraction.self, from: bytes).review()
            }
        }
    }
    static func create(storage: ManagedSpeechStorage, destination: URL, now: Date = Date()) throws -> LibraryBackupSummary {
        try storage.validateState()
        guard destination.isFileURL, !Files.contains(storage.stateRoot, destination),
              !Files.contains(destination, storage.stateRoot), !Files.contains(storage.audioDirectory, destination),
              !Files.contains(storage.temporaryRoot, destination), !FileManager.default.fileExists(atPath: destination.path) else {
            throw RelayError.setup("Choose a new private backup folder outside the library, audio and scratch folders.")
        }
        let lease = try PipelineLease(database: storage.profile.database)
        defer { lease.release() }
        let store = try NativeStore(url: storage.profile.database)
        try validate(store)
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".voicerelay-backup-\(UUID().uuidString)")
        try Files.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        try store.backup(to: stage.appendingPathComponent(databaseName))
        var files: [String: BackupManifest.File] = [:]
        let ledger = DeliveryLedger.fileURL(stateRoot: storage.stateRoot)
        if FileManager.default.fileExists(atPath: ledger.path) {
            _ = try regular(ledger, root: storage.stateRoot, limit: 10_000_000)
            let data = try Data(contentsOf: ledger)
            _ = try JSONDecoder().decode(DeliveryLedger.self, from: data)
            try Files.write(data, to: stage.appendingPathComponent(ledgerName))
        }
        for name in [databaseName, ledgerName] where FileManager.default.fileExists(atPath: stage.appendingPathComponent(name).path) {
            let url = stage.appendingPathComponent(name)
            files[name] = BackupManifest.File(bytes: try regular(url, root: stage), sha256: try Files.hash(url))
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw RelayError.storage("Cannot sync the library backup.") }
            let result = fsync(fd); close(fd)
            guard result == 0 else { throw RelayError.storage("Cannot sync the library backup.") }
        }
        let result = try summary(store, date: now)
        try Files.write(try Files.json(BackupManifest(version: 1, summary: result, files: files)), to: stage.appendingPathComponent(manifestName))
        _ = try validated(stage)
        try Task.checkCancellation()
        // Never replace an earlier backup, including one created while staging.
        guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw RelayError.storage("Cannot save the library backup at that destination.")
        }
        try Files.syncDirectory(destination.deletingLastPathComponent())
        return result
    }
    /// Atomically exchanges a validated replacement with the existing library.
    /// The old directory remains a private recovery copy; no audio files are touched.
    static func restore(backup: URL, storage: ManagedSpeechStorage) throws -> URL? {
        let manifest = try validated(backup)
        try storage.validate()
        guard !Files.contains(storage.stateRoot, backup), !Files.contains(backup, storage.stateRoot) else {
            throw RelayError.setup("Choose a backup outside the current library.")
        }
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: storage.stateRoot.path)
        if exists {
            var info = stat()
            guard lstat(storage.stateRoot.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                throw RelayError.setup("The current library must not be a symbolic link.")
            }
            try storage.validateState()
        }
        let lease = exists ? try PipelineLease(database: storage.profile.database) : nil
        defer { lease?.release() }
        let current = exists ? try NativeStore(url: storage.profile.database) : nil
        defer { withExtendedLifetime(current) {} }
        let parent = storage.stateRoot.deletingLastPathComponent()
        try Files.directory(parent)
        let stage = parent.appendingPathComponent("\(storage.stateRoot.lastPathComponent)-before-restore-\(UUID().uuidString)")
        try Files.directory(stage)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: stage) } }
        let target = try ManagedSpeechStorage.prepareLibrary(stateRoot: stage)
        // Re-copy through SQLite, after validation, into an owned destination.
        try NativeStore(url: backup.appendingPathComponent(databaseName), readOnly: true).backup(to: target)
        do {
            let store = try NativeStore(url: target)
            try validate(store)
            try store.execute("BEGIN IMMEDIATE")
            do {
                for var episode in try store.episodes() {
                    episode.settings.database = storage.profile.database
                    episode.settings.feed = storage.profile.feed
                    episode.settings.work = storage.profile.work
                    episode.settings.audio = storage.profile.audio
                    episode.settings.safariPlist = storage.profile.safariPlist
                    episode.settings.configurationURL = nil
                    episode.settings.temporaryAudio = true
                    episode.audioVolumeID = nil
                    try store.execute("UPDATE episodes SET record=? WHERE id=?", [String(decoding: try Files.json(episode), as: UTF8.self), episode.id])
                }
                for var item in try store.queue() where item.state == .running || item.state == .paused {
                    item.state = .queued; item.lastError = nil
                    try store.saveQueueItem(item)
                }
                try store.execute("DELETE FROM chunks") // Disposable chunk paths never survive relocation.
                try store.execute("UPDATE feed_status SET pending=1 WHERE singleton=1")
                try store.execute("COMMIT")
            } catch { try? store.execute("ROLLBACK"); throw error }
        }
        if manifest.files[ledgerName] != nil {
            try Files.write(try Data(contentsOf: backup.appendingPathComponent(ledgerName)),
                to: DeliveryLedger.fileURL(stateRoot: stage))
        }
        try Task.checkCancellation()
        try current?.closeDatabaseForReplacement()
        try Files.syncDirectory(parent)
        let flags = exists ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
        guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, storage.stateRoot.path, flags) == 0 else {
            throw RelayError.storage("Cannot commit the restored library. The current library is unchanged.")
        }
        committed = true
        do { try Files.syncDirectory(parent) }
        catch {
            throw RelayError.storage("The restored library is in place, but its directory could not be synced. Keep the backup and restart before reviewing recovery; processing and delivery must remain disabled.")
        }
        return exists ? stage : nil
    }
}

extension FixtureCoordinator {
    func requireIdleLibrary(_ storage: ManagedSpeechStorage) throws {
        let root = storage.stateRoot.resolvingSymlinksInPath().standardizedFileURL.path
        guard !activeDrainRoots.contains(root), !activeDeliveryRoots.contains(root) else {
            throw RelayError.setup("Stop processing and wait for delivery before managing library backups.")
        }
    }
    public func backupLibrary(storage: ManagedSpeechStorage, destination: URL) throws -> LibraryBackupSummary {
        try requireIdleLibrary(storage)
        return try LibraryBackup.create(storage: storage, destination: destination)
    }
    public func inspectLibraryBackup(_ backup: URL) throws -> LibraryBackupSummary { try LibraryBackup.inspect(backup) }
    public func restoreLibrary(backup: URL, storage: ManagedSpeechStorage) throws -> URL? {
        try requireIdleLibrary(storage)
        return try LibraryBackup.restore(backup: backup, storage: storage)
    }
}
