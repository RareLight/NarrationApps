import Foundation
import CoreFoundation

public struct ReadingListEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let safariID: String?
    public let url: URL
    public let title: String
    public let addedAt: Date?
    public init(id: String, safariID: String?, url: URL, title: String, addedAt: Date?) {
        self.id = id; self.safariID = safariID; self.url = url; self.title = title; self.addedAt = addedAt
    }
}

public struct ReadingListSnapshot: Sendable {
    public let entries: [ReadingListEntry]
    public let skippedEntries: Int
    public init(entries: [ReadingListEntry], skippedEntries: Int) {
        self.entries = entries; self.skippedEntries = skippedEntries
    }
}

/// Successful refreshes remove absent entries; failed reads preserve the inventory.
/// A failed parse cannot be reconciled and never empties this inventory.
public struct ReadingListCatalog: Codable, Sendable {
    public private(set) var entries: [ReadingListEntry] = []
    public private(set) var currentIDs: Set<String> = []
    /// Local presentation only; Safari's titles and source records remain untouched.
    private var resolvedTitles: [String: String]? = nil
    public func displayTitle(for entry: ReadingListEntry) -> String { resolvedTitles?[entry.id] ?? entry.title }
    public mutating func setResolvedTitle(_ title: String, for entryID: String) {
        guard currentIDs.contains(entryID) else { return }
        if resolvedTitles == nil { resolvedTitles = [:] }
        resolvedTitles?[entryID] = title
    }
    /// Legacy catalogs still decode this field; exclusion is no longer honored and each
    /// saved reconcile clears it.
    public var excludedIDs: Set<String> = []
    var duplicateEvidence: [String: ArticleDuplicateEvidence]? = nil
    /// All evaluated copies are consumed together at admission, including the losers.
    /// This survives refresh, restart, queue removal and audio retirement.
    var handledEntryIDs: Set<String>? = nil
    public var unreviewedDuplicateIDs: Set<String> {
        let handled = handledEntryIDs ?? []
        return Set(ArticleDuplicates.groups(entries, evidence: duplicateEvidence ?? [:]).flatMap { group -> [String] in
            group.count > 1 && group.contains { !handled.contains($0.id) } ? group.map(\.id) : []
        })
    }
    public var inactiveDuplicateIDs: Set<String> {
        let evidence = duplicateEvidence ?? [:]
        return Set(ArticleDuplicates.groups(entries, evidence: evidence).flatMap { group -> [String] in
            guard group.count > 1, let winner = ArticleDuplicates.winner(group, evidence: evidence) else { return [] }
            return group.filter { $0.id != winner.id }.map(\.id)
        })
    }
    public func hasHandled(_ entry: ReadingListEntry) -> Bool {
        entries.contains(entry) && handledEntryIDs?.contains(entry.id) == true
    }
    public init() {}
    /// Articles display saved dates newest first without changing durable discovery order.
    /// Equal dates and undated entries retain their inventory order; undated entries go last.
    public var newestFirstEntries: [ReadingListEntry] {
        entries.enumerated().sorted { left, right in
            switch (left.element.addedAt, right.element.addedAt) {
            case let (leftDate?, rightDate?) where leftDate != rightDate: return leftDate > rightDate
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.offset < right.offset
            }
        }.map(\.element)
    }
    /// Multi-selection retains durable inventory order for core clients.
    public func selectedEntries(_ ids: Set<String>) -> [ReadingListEntry] {
        entries.filter { ids.contains($0.id) }
    }
    public mutating func reconcile(_ snapshot: ReadingListSnapshot) {
        let previousEntries = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let unchanged = Set(snapshot.entries.filter {
            previousEntries[$0.id]?.url == $0.url && previousEntries[$0.id]?.addedAt == $0.addedAt
        }.map(\.id))
        duplicateEvidence = duplicateEvidence?.filter { unchanged.contains($0.key) }
        handledEntryIDs = handledEntryIDs?.intersection(unchanged)
        let previousURLs = Dictionary(entries.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })
        let updatedURLs = Dictionary(snapshot.entries.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })
        currentIDs = Set(snapshot.entries.map(\.id))
        resolvedTitles = resolvedTitles?.filter { currentIDs.contains($0.key) && previousURLs[$0.key] == updatedURLs[$0.key] }
        let updates = Dictionary(snapshot.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let known = Set(entries.map(\.id))
        entries = entries.compactMap { updates[$0.id] }
        var appended = known
        entries += snapshot.entries.filter { appended.insert($0.id).inserted }
    }
}

public enum ReadingList {
    public static let maximumBytes = 16 * 1024 * 1024
    public static func read(_ url: URL) throws -> ReadingListSnapshot {
        guard url.isFileURL else { throw RelayError.setup("Choose a local Reading List property-list file.") }
        do {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            var refreshed = url; refreshed.removeAllCachedResourceValues()
            let before = try refreshed.resourceValues(forKeys: keys)
            guard before.isRegularFile == true, let size = before.fileSize, size <= maximumBytes else {
                throw RelayError.setup("Reading List file is not a bounded regular file.")
            }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            refreshed.removeAllCachedResourceValues()
            let after = try refreshed.resourceValues(forKeys: keys)
            guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
                throw RelayError.setup("Reading List changed during refresh; retry. Previously discovered items are retained.")
            }
            return try parse(data)
        } catch let error as RelayError { throw error }
        catch {
            throw RelayError.setup("Cannot read the Reading List file. Check its path and the launching app's file access; existing items are retained.")
        }
    }
    public static func parse(_ data: Data) throws -> ReadingListSnapshot {
        guard !data.isEmpty, data.count <= maximumBytes,
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw RelayError.setup("Reading List is incomplete or invalid; existing items are retained.")
        }
        var entries: [ReadingListEntry] = []; var identities: Set<String> = []
        var found = false; var skipped = 0; var visited = 0
        func visit(_ node: [String: Any], inside: Bool, depth: Int) throws {
            visited += 1
            guard depth <= 64, visited <= 100_000 else { throw RelayError.setup("Reading List hierarchy exceeds inspection bounds.") }
            let reading = inside || node["Title"] as? String == "com.apple.ReadingList"
            if node["Title"] as? String == "com.apple.ReadingList" { found = true }
            if reading, let value = node["URLString"] {
                if let text = value as? String, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                   (try? ArticleURL.validate(url)) != nil {
                    let safariID = (node["WebBookmarkUUID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let uuid = safariID.flatMap { !$0.isEmpty && $0.count <= 512 ? $0 : nil }
                    let metadata = node["ReadingList"] as? [String: Any] ?? [:]
                    let added = date(metadata["DateAdded"]) ?? date(node["DateAdded"])
                    var normalized = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                    normalized.fragment = nil
                    let fallback = Files.hash(Data((normalized.url!.absoluteString + "\n" + (added.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "")).utf8))
                    let identity = uuid.map { "safari:\($0)" } ?? "fallback:\(fallback)"
                    let uri = node["URIDictionary"] as? [String: Any] ?? [:]
                    let title = ((uri["title"] as? String) ?? (node["Title"] as? String) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if identities.insert(identity).inserted {
                        entries.append(ReadingListEntry(id: identity, safariID: uuid, url: url,
                                                       title: title.isEmpty ? "Untitled article" : title, addedAt: added))
                    }
                } else { skipped += 1 }
            }
            if let children = node["Children"] {
                guard let children = children as? [Any] else {
                    throw RelayError.setup("Reading List hierarchy is incomplete; retry refresh. Existing items are retained.")
                }
                for child in children {
                    guard let dictionary = child as? [String: Any] else { skipped += 1; continue }
                    try visit(dictionary, inside: reading, depth: depth + 1)
                }
            }
        }
        try visit(root, inside: false, depth: 0)
        guard found else { throw RelayError.setup("No Reading List container found; existing items are retained.") }
        return ReadingListSnapshot(entries: entries, skippedEntries: skipped)
    }
    static func date(_ value: Any?) -> Date? {
        if let value = value as? Date { return value }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            let seconds = value.doubleValue
            return seconds.isFinite && abs(seconds) < 100_000_000_000 ? Date(timeIntervalSinceReferenceDate: seconds) : nil
        }
        if let value = value as? String {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: value)
        }
        return nil
    }
}
