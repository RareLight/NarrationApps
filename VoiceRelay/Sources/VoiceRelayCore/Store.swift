import Foundation
import CSQLite
import Darwin

final class NativeStore {
    private var db: OpaquePointer?
    private var lockFD: Int32 = -1
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static let applicationID = 0x56524c59
    static let schemaVersion = 3

    init(url: URL, readOnly: Bool = false) throws {
        if readOnly {
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                release(); throw RelayError.storage("Cannot read the local article library.")
            }
            do {
                guard sqlite3_busy_timeout(db, 2_000) == SQLITE_OK else {
                    throw RelayError.storage("Cannot configure the local article library read deadline.")
                }
                guard try query("PRAGMA application_id").first?.first == String(Self.applicationID),
                      let version = try query("PRAGMA user_version").first?.first.flatMap(Int.init),
                      (1...Self.schemaVersion).contains(version) else {
                    throw RelayError.setup("This is not a supported native article library.")
                }
            } catch { release(); throw error }
            return
        }
        lockFD = Darwin.open(url.appendingPathExtension("writer.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else { throw RelayError.storage("Cannot open native writer lock.") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD); lockFD = -1
            throw RelayError.writerBusy
        }
        do {
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
                throw RelayError.storage("Cannot open native SQLite state.")
            }
            guard sqlite3_busy_timeout(db, 2_000) == SQLITE_OK else {
                throw RelayError.storage("Cannot configure the local article library write deadline.")
            }
            let appID = Int(try query("PRAGMA application_id").first?.first ?? "") ?? -1
            let version = Int(try query("PRAGMA user_version").first?.first ?? "") ?? -1
            let tables = try query("SELECT name FROM sqlite_master WHERE type='table'")
            guard appID == Self.applicationID || (appID == 0 && version == 0 && tables.isEmpty) else {
                throw RelayError.setup("This is not a native fixture database. Python/live state adoption requires a reviewed backup and import.")
            }
            guard version <= Self.schemaVersion else { throw RelayError.setup("Native state uses a newer unsupported schema.") }
            if version == 0 {
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute("CREATE TABLE episodes(id TEXT PRIMARY KEY, source_key TEXT NOT NULL UNIQUE, record TEXT NOT NULL)")
                    try execute("CREATE TABLE chunks(article_id TEXT NOT NULL REFERENCES episodes(id), chunk_index INTEGER NOT NULL, fingerprint TEXT NOT NULL, checkpoint TEXT NOT NULL, PRIMARY KEY(article_id,chunk_index))")
                    try execute("CREATE TABLE feed_status(singleton INTEGER PRIMARY KEY CHECK(singleton=1), pending INTEGER NOT NULL, local_hash TEXT)")
                    try execute("CREATE TABLE snapshots(article_id TEXT PRIMARY KEY REFERENCES episodes(id), record TEXT NOT NULL, hash TEXT NOT NULL)")
                    try createSourceTables()
                    try execute("INSERT INTO feed_status VALUES(1,1,NULL)")
                    try execute("PRAGMA application_id=\(Self.applicationID)")
                    try execute("PRAGMA user_version=\(Self.schemaVersion)")
                    try execute("COMMIT")
                } catch { try? execute("ROLLBACK"); throw error }
            }
            if version == 1 || version == 2 {
                try execute("BEGIN IMMEDIATE")
                do {
                    if version == 1 { try execute("CREATE TABLE snapshots(article_id TEXT PRIMARY KEY REFERENCES episodes(id), record TEXT NOT NULL, hash TEXT NOT NULL)") }
                    try createSourceTables()
                    try execute("PRAGMA user_version=\(Self.schemaVersion)")
                    try execute("COMMIT")
                } catch { try? execute("ROLLBACK"); throw error }
            }
            guard try query("PRAGMA journal_mode=WAL").first?.first?.lowercased() == "wal" else {
                throw RelayError.storage("The native article library could not enable concurrent reading and writing.")
            }
            var persistWAL: Int32 = 1
            guard sqlite3_file_control(db, "main", SQLITE_FCNTL_PERSIST_WAL, &persistWAL) == SQLITE_OK else {
                throw RelayError.storage("The native article library could not preserve its read-only recovery files.")
            }
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA synchronous=FULL")
            // Switching journal mode alone does not open the WAL sidecars. Start
            // a read transaction while this writable connection can create them,
            // including when initialization is the only work before it closes.
            _ = try query("SELECT COUNT(*) FROM sqlite_master")
        } catch { release(); throw error }
    }
    deinit { release() }
    /// Close SQLite before a directory exchange, while retaining the writer lease.
    func closeDatabaseForReplacement() throws {
        if let db {
            guard sqlite3_close(db) == SQLITE_OK else { throw RelayError.storage("Cannot close the current library for restore.") }
            self.db = nil
        }
    }
    /// SQLite copies committed WAL contents; copying the database file alone loses them.
    func backup(to destination: URL) throws {
        let fd = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RelayError.storage("Cannot create the library backup database.") }
        close(fd)
        var target: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let target { sqlite3_close(target) }
            throw RelayError.storage("Cannot open the library backup database.")
        }
        var targetClosed = false
        defer { if !targetClosed { sqlite3_close(target) } }
        guard let backup = sqlite3_backup_init(target, "main", db, "main") else {
            throw RelayError.storage("Cannot start the library backup.")
        }
        var finished = false
        defer { if !finished { sqlite3_backup_finish(backup) } }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while true {
            try Task.checkCancellation()
            let status = sqlite3_backup_step(backup, 128)
            if status == SQLITE_DONE { break }
            guard [SQLITE_OK, SQLITE_BUSY, SQLITE_LOCKED].contains(status),
                  ProcessInfo.processInfo.systemUptime < deadline else {
                throw RelayError.storage("The library backup could not finish. Existing state is unchanged.")
            }
            if status != SQLITE_OK { Thread.sleep(forTimeInterval: 0.02) }
        }
        let status = sqlite3_backup_finish(backup); finished = true
        guard status == SQLITE_OK else { throw RelayError.storage("The library backup could not be committed.") }
        // backup_step copies WAL-format header bytes without refreshing the target's
        // cached journal mode. Switch through WAL to force a standalone DELETE header.
        guard sqlite3_exec(target, "PRAGMA journal_mode=WAL; PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw RelayError.storage("The library backup could not finalize its standalone database.")
        }
        guard sqlite3_close(target) == SQLITE_OK else { throw RelayError.storage("Cannot close the library backup.") }
        targetClosed = true
        // Apple's SQLite can retain an unused -shm after switching to DELETE.
        // These belong to the exclusively created destination, never the source.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: destination.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
        }
    }
    private func createSourceTables() throws {
        try execute("CREATE TABLE IF NOT EXISTS reading_list_inventory(singleton INTEGER PRIMARY KEY CHECK(singleton=1), record TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS speech_queue(article_id TEXT PRIMARY KEY REFERENCES episodes(id), record TEXT NOT NULL)")
    }
    private func release() {
        if let db { sqlite3_close(db); self.db = nil }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }
    private func sqliteFailure(operation: String, code fallback: Int32? = nil) -> RelayError {
        var code = db.map { sqlite3_extended_errcode($0) } ?? -1
        if code == 0, let fallback { code = fallback }
        let system = db.map { sqlite3_system_errno($0) } ?? 0
        let primary = code & 0xFF
        if primary == SQLITE_BUSY || primary == SQLITE_LOCKED {
            return .storage("The local article library is busy (SQLite \(code), system \(system)). Saved progress is retained; retry when the current operation finishes.")
        }
        return .storage("Native SQLite \(operation) failed (SQLite \(code), system \(system)). Saved progress is retained.")
    }
    private func statement(_ sql: String, _ args: [String]) throws -> OpaquePointer {
        var s: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &s, nil)
        guard prepared == SQLITE_OK, let s else {
            throw sqliteFailure(operation: "statement", code: prepared)
        }
        for (index, value) in args.enumerated() {
            let bound = sqlite3_bind_text(s, Int32(index + 1), value, -1, transient)
            guard bound == SQLITE_OK else {
                let failure = sqliteFailure(operation: "binding", code: bound)
                sqlite3_finalize(s); throw failure
            }
        }
        return s
    }
    func execute(_ sql: String, _ args: [String] = []) throws {
        let s = try statement(sql, args); defer { sqlite3_finalize(s) }
        let stepped = sqlite3_step(s)
        guard stepped == SQLITE_DONE else { throw sqliteFailure(operation: "write", code: stepped) }
    }
    func query(_ sql: String, _ args: [String] = []) throws -> [[String]] {
        let s = try statement(sql, args); defer { sqlite3_finalize(s) }
        var result: [[String]] = []
        while true {
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw sqliteFailure(operation: "query", code: code) }
            result.append((0..<sqlite3_column_count(s)).map { i in
                sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
            })
        }
    }
    func episode(sourceKey: String, settings: PrototypeProfile) throws -> Episode {
        if let saved = try existingEpisode(sourceKey: sourceKey) { return saved }
        var e = Episode(id: UUID().uuidString.lowercased(), title: "Saved fixture", stage: .discovered, settings: settings)
        e.originalSourceIdentity = ServerRecoveryIdentity.validSource(sourceKey) ? sourceKey : nil
        try execute("INSERT INTO episodes VALUES(?,?,?)", [e.id, sourceKey, String(decoding: try Files.json(e), as: UTF8.self)])
        return e
    }
    func existingEpisode(sourceKey: String) throws -> Episode? {
        guard let record = try query("SELECT record FROM episodes WHERE source_key=?", [sourceKey]).first?.first else { return nil }
        var episode = try JSONDecoder().decode(Episode.self, from: Data(record.utf8))
        resolveArticleOrigin(&episode, sourceKey: sourceKey, entries: try readingListEntriesBySource())
        return episode
    }
    func save(_ e: Episode, pendingFeed: Bool = false) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            var saved = e
            // A stale worker/delivery record must not erase already captured origin metadata.
            if let record = try query("SELECT record FROM episodes WHERE id=?", [e.id]).first?.first,
               let current = try? JSONDecoder().decode(Episode.self, from: Data(record.utf8)) {
                saved.originalSourceHost = saved.originalSourceHost ?? current.originalSourceHost
                saved.readingListSavedAt = saved.readingListSavedAt ?? current.readingListSavedAt
                saved.originalSourceIdentity = saved.originalSourceIdentity ?? current.originalSourceIdentity
                if current.transcript?.audioHash == (saved.audioHash ?? saved.encodedHash) {
                    saved.transcript = saved.transcript ?? current.transcript
                    if saved.transcript?.sha256 == current.transcript?.sha256, saved.transcript?.delivery == nil {
                        saved.transcript?.delivery = current.transcript?.delivery
                    }
                }
                if current.audioHash != nil && current.audioHash == saved.audioHash {
                    saved.transcriptReferences = saved.transcriptReferences ?? current.transcriptReferences
                }
                // Source removal intent also survives results captured before the source refresh.
                if current.readingListRemoved == true {
                    saved.readingListRemoved = true
                    saved.articleCachePurged = current.articleCachePurged
                }
            }
            try execute("UPDATE episodes SET record=? WHERE id=?", [String(decoding: try Files.json(saved), as: UTF8.self), e.id])
            if pendingFeed { try execute("UPDATE feed_status SET pending=1 WHERE singleton=1") }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func chunk(articleID: String, index: Int, fingerprint: String) throws -> ChunkCheckpoint? {
        guard let row = try query("SELECT checkpoint FROM chunks WHERE article_id=? AND chunk_index=? AND fingerprint=?",
                                  [articleID, String(index), fingerprint]).first?.first else { return nil }
        return try? JSONDecoder().decode(ChunkCheckpoint.self, from: Data(row.utf8))
    }
    func saveChunk(articleID: String, index: Int, fingerprint: String, checkpoint: ChunkCheckpoint) throws {
        try execute("INSERT OR REPLACE INTO chunks VALUES(?,?,?,?)", [articleID, String(index), fingerprint,
                                                                     String(decoding: try Files.json(checkpoint), as: UTF8.self)])
    }
    func published() throws -> [Episode] {
        try episodes().filter { $0.stage == .published }
    }
    func episodes() throws -> [Episode] {
        let entries = try readingListEntriesBySource()
        return try query("SELECT record,source_key FROM episodes ORDER BY rowid DESC").map {
            var episode = try JSONDecoder().decode(Episode.self, from: Data($0[0].utf8))
            resolveArticleOrigin(&episode, sourceKey: $0[1], entries: entries)
            return episode
        }
    }
    /// Resolve legacy metadata read-only by original source identity, never the RSS link.
    private func readingListEntriesBySource() throws -> [String: ReadingListEntry] {
        let pairs = try catalog().entries.map { entry in
            ("reviewed-url-v1-" + Files.hash(Data(entry.url.absoluteString.utf8)), entry)
        }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }
    private func resolveArticleOrigin(_ episode: inout Episode, sourceKey: String,
                                      entries: [String: ReadingListEntry]) {
        if ServerRecoveryIdentity.validSource(sourceKey) { episode.originalSourceIdentity = sourceKey }
        let entry = entries[sourceKey]
        if episode.readingListSavedAt == nil { episode.readingListSavedAt = entry?.addedAt }
        guard episode.originalSourceHost == nil else { return }
        episode.originalSourceHost = entry?.url.host
        if episode.originalSourceHost == nil, let bytes = try? snapshot(articleID: episode.id),
           let review = try? JSONDecoder().decode(StoredExtraction.self, from: bytes).review() {
            let original = review.page.originalURL
            if sourceKey == "reviewed-url-v1-" + Files.hash(Data(original.absoluteString.utf8)) {
                episode.originalSourceHost = original.host
            }
        }
    }
    func markFeed(_ hash: String) throws { try execute("UPDATE feed_status SET pending=0,local_hash=? WHERE singleton=1", [hash]) }
    func saveSnapshot(articleID: String, data: Data) throws {
        try execute("INSERT OR REPLACE INTO snapshots VALUES(?,?,?)",
                    [articleID, data.base64EncodedString(), Files.hash(data)])
    }
    func snapshot(articleID: String) throws -> Data? {
        guard let row = try query("SELECT record,hash FROM snapshots WHERE article_id=?", [articleID]).first else { return nil }
        guard let data = Data(base64Encoded: row[0]), Files.hash(data) == row[1] else {
            throw RelayError.artifact("Saved article integrity failed. Existing audio is preserved.")
        }
        return data
    }
    func catalog() throws -> ReadingListCatalog {
        guard try query("SELECT name FROM sqlite_master WHERE type='table' AND name='reading_list_inventory'").first != nil,
              let row = try query("SELECT record FROM reading_list_inventory WHERE singleton=1").first?.first else { return ReadingListCatalog() }
        return try JSONDecoder().decode(ReadingListCatalog.self, from: Data(row.utf8))
    }
    func saveCatalog(_ catalog: ReadingListCatalog) throws {
        try execute("INSERT OR REPLACE INTO reading_list_inventory VALUES(1,?)", [String(decoding: try Files.json(catalog), as: UTF8.self)])
    }
    func queue() throws -> [SpeechQueueItem] {
        guard try query("SELECT name FROM sqlite_master WHERE type='table' AND name='speech_queue'").first != nil else { return [] }
        let entries = try catalog().entries
        return try query("SELECT article_id,record FROM speech_queue ORDER BY rowid").map {
            var item = try JSONDecoder().decode(SpeechQueueItem.self, from: Data($0[1].utf8))
            guard item.id == $0[0] else { throw RelayError.storage("The saved queue identity is invalid.") }
            if item.sourceHost == nil {
                item.sourceHost = entries.first { $0.id == item.sourceEntryID }?.url.host
                if item.sourceHost == nil, let bytes = try? snapshot(articleID: item.id),
                   let saved = try? JSONDecoder().decode(StoredExtraction.self, from: bytes).review() {
                    item.sourceHost = saved.page.originalURL.host
                }
            }
            return item
        }
    }
    func saveQueueItem(_ item: SpeechQueueItem) throws {
        let record = String(decoding: try Files.json(item), as: UTF8.self)
        // UPDATE preserves FIFO insertion order across retry and state transitions.
        try execute("INSERT INTO speech_queue VALUES(?,?) ON CONFLICT(article_id) DO UPDATE SET record=excluded.record", [item.id, record])
    }
}

final class PipelineStore: Sendable {
    private let databaseURL: URL
    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try writing { _ in () }
    }
    private func reading<T>(_ body: (NativeStore) throws -> T) throws -> T {
        try body(NativeStore(url: databaseURL, readOnly: true))
    }
    private func writing<T>(_ body: (NativeStore) throws -> T) throws -> T {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while true {
            do { return try body(NativeStore(url: databaseURL)) }
            catch RelayError.writerBusy {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw RelayError.writerBusy }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
    func episode(sourceKey: String, settings: PrototypeProfile) throws -> Episode {
        try writing { try $0.episode(sourceKey: sourceKey, settings: settings) }
    }
    func episode(id: String) throws -> Episode? {
        try reading { store in
            guard let raw = try store.query("SELECT record FROM episodes WHERE id=?", [id]).first?.first else { return nil }
            return try JSONDecoder().decode(Episode.self, from: Data(raw.utf8))
        }
    }
    func save(_ e: Episode, pendingFeed: Bool = false) throws {
        try writing { try $0.save(e, pendingFeed: pendingFeed) }
    }
    func saveSnapshot(articleID: String, data: Data) throws {
        try writing { try $0.saveSnapshot(articleID: articleID, data: data) }
    }
    func snapshot(articleID: String) throws -> Data? {
        try reading { try $0.snapshot(articleID: articleID) }
    }
    func chunk(articleID: String, index: Int, fingerprint: String) throws -> ChunkCheckpoint? {
        try reading { try $0.chunk(articleID: articleID, index: index, fingerprint: fingerprint) }
    }
    func saveChunk(articleID: String, index: Int, fingerprint: String, checkpoint: ChunkCheckpoint) throws {
        try writing { try $0.saveChunk(articleID: articleID, index: index, fingerprint: fingerprint, checkpoint: checkpoint) }
    }
    func published() throws -> [Episode] {
        try reading { try $0.published() }
    }
    func episodes() throws -> [Episode] {
        try reading { try $0.episodes() }
    }
    func markFeed(_ hash: String) throws {
        try writing { try $0.markFeed(hash) }
    }
}

final class PipelineLease {
    private var fd: Int32 = -1
    init(database: URL) throws {
        guard database.isFileURL else { throw RelayError.setup("The native library path is invalid.") }
        let folder = database.deletingLastPathComponent()
        var info = stat()
        guard lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(),
              !Files.hasSymlink(database, below: folder) else {
            throw RelayError.setup("The native library storage is invalid.")
        }
        fd = Darwin.open(database.appendingPathExtension("speech.lock").path,
                         O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RelayError.storage("Cannot open the speech worker lease.") }
        do {
            var created = stat()
            guard fstat(fd, &created) == 0, (created.st_mode & S_IFMT) == S_IFREG, created.st_uid == geteuid(),
                  created.st_mode & 0o077 == 0 else {
                throw RelayError.setup("The speech worker lease is invalid.")
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                throw RelayError.setup("Another speech worker is processing this library.")
            }
        } catch { close(fd); fd = -1; throw error }
    }
    func release() {
        if fd >= 0 { flock(fd, LOCK_UN); close(fd); fd = -1 }
    }
    deinit { release() }
}
