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
        } catch { release(); throw error }
    }
    deinit { release() }
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
        let e = Episode(id: UUID().uuidString.lowercased(), title: "Saved fixture", stage: .discovered, settings: settings)
        try execute("INSERT INTO episodes VALUES(?,?,?)", [e.id, sourceKey, String(decoding: try Files.json(e), as: UTF8.self)])
        return e
    }
    func existingEpisode(sourceKey: String) throws -> Episode? {
        guard let record = try query("SELECT record FROM episodes WHERE source_key=?", [sourceKey]).first?.first else { return nil }
        return try JSONDecoder().decode(Episode.self, from: Data(record.utf8))
    }
    func save(_ e: Episode, pendingFeed: Bool = false) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("UPDATE episodes SET record=? WHERE id=?", [String(decoding: try Files.json(e), as: UTF8.self), e.id])
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
        try query("SELECT record FROM episodes ORDER BY rowid DESC").map {
            try JSONDecoder().decode(Episode.self, from: Data($0[0].utf8))
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
        return try query("SELECT article_id,record FROM speech_queue ORDER BY rowid").map {
            let item = try JSONDecoder().decode(SpeechQueueItem.self, from: Data($0[1].utf8))
            guard item.id == $0[0] else { throw RelayError.storage("The saved queue identity is invalid.") }
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
