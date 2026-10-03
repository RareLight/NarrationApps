import Foundation
import CSQLite
import Darwin

final class NativeStore {
    private var db: OpaquePointer?
    private var lockFD: Int32 = -1
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static let applicationID = 0x56524c59
    static let schemaVersion = 1

    init(url: URL) throws {
        lockFD = Darwin.open(url.appendingPathExtension("writer.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else { throw RelayError.storage("Cannot open native writer lock.") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD); lockFD = -1
            throw RelayError.setup("Another native coordinator owns this fixture database.")
        }
        do {
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
                throw RelayError.storage("Cannot open native SQLite state.")
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
                    try execute("INSERT INTO feed_status VALUES(1,1,NULL)")
                    try execute("PRAGMA application_id=\(Self.applicationID)")
                    try execute("PRAGMA user_version=\(Self.schemaVersion)")
                    try execute("COMMIT")
                } catch { try? execute("ROLLBACK"); throw error }
            }
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA synchronous=FULL")
        } catch { release(); throw error }
    }
    deinit { release() }
    private func release() {
        if let db { sqlite3_close(db); self.db = nil }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }
    private func statement(_ sql: String, _ args: [String]) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else {
            throw RelayError.storage("Native SQLite statement failed.")
        }
        for (index, value) in args.enumerated() {
            guard sqlite3_bind_text(s, Int32(index + 1), value, -1, transient) == SQLITE_OK else {
                sqlite3_finalize(s); throw RelayError.storage("Native SQLite binding failed.")
            }
        }
        return s
    }
    func execute(_ sql: String, _ args: [String] = []) throws {
        let s = try statement(sql, args); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw RelayError.storage("Native SQLite write failed.") }
    }
    func query(_ sql: String, _ args: [String] = []) throws -> [[String]] {
        let s = try statement(sql, args); defer { sqlite3_finalize(s) }
        var result: [[String]] = []
        while true {
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw RelayError.storage("Native SQLite query failed.") }
            result.append((0..<sqlite3_column_count(s)).map { i in
                sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
            })
        }
    }
    func episode(sourceKey: String, settings: PrototypeProfile) throws -> Episode {
        if let record = try query("SELECT record FROM episodes WHERE source_key=?", [sourceKey]).first?.first {
            return try JSONDecoder().decode(Episode.self, from: Data(record.utf8))
        }
        let e = Episode(id: UUID().uuidString.lowercased(), title: "Saved fixture", stage: .discovered, settings: settings)
        try execute("INSERT INTO episodes VALUES(?,?,?)", [e.id, sourceKey, String(decoding: try Files.json(e), as: UTF8.self)])
        return e
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
        try query("SELECT record FROM episodes").map {
            try JSONDecoder().decode(Episode.self, from: Data($0[0].utf8))
        }.filter { $0.stage == .published }
    }
    func markFeed(_ hash: String) throws { try execute("UPDATE feed_status SET pending=0,local_hash=? WHERE singleton=1", [hash]) }
}
