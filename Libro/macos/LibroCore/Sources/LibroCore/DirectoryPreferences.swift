import Foundation
import Darwin

public enum DirectoryRole: String, Sendable { case output, workspace }

public struct DirectorySelection: Sendable {
    public let displayPath: String
    public let url: URL?
    public let error: String?
    public init(displayPath: String, url: URL?, error: String?) {
        self.displayPath = displayPath; self.url = url; self.error = error
    }
}

/// Balance user-selected scopes over scans/batches, including async work.
public final class DirectoryAccess {
    private let url: URL
    private let started: Bool
    public init(_ url: URL) { self.url = url; started = url.startAccessingSecurityScopedResource() }
    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}

/// Store one bookmark record per role. An unavailable record keeps its identity.
/// The app owns this synchronous store on MainActor; fixtures use isolated defaults.
public final class DirectoryPreferences {
    static let modelStorageMigrationKey = "Libro.modelStorage.sharedCacheDefault.v1"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func clear(_ role: DirectoryRole) { defaults.removeObject(forKey: key(role)) }

    public func loadModelStorage(defaultRoot: URL, previousDefault: URL) -> DirectorySelection {
        let stored = load(.workspace)
        let migrating = !defaults.bool(forKey: Self.modelStorageMigrationKey)
        defaults.set(true, forKey: Self.modelStorageMigrationKey)
        let storedPath = stored.map { URL(fileURLWithPath: $0.displayPath).resolvingSymlinksInPath().path }
        if migrating && storedPath == previousDefault.resolvingSymlinksInPath().path { clear(.workspace) }
        else if let stored { return stored }
        return DirectorySelection(displayPath: defaultRoot.path, url: defaultRoot, error: nil)
    }

    public func load(_ role: DirectoryRole) -> DirectorySelection? {
        guard let data = defaults.data(forKey: key(role)) else { return nil }
        guard let stored = try? JSONDecoder().decode(StoredDirectory.self, from: data) else {
            return DirectorySelection(displayPath: "Remembered \(role.rawValue) folder", url: nil,
                                      error: "The remembered folder could not be restored. Browse to recover it.")
        }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: stored.bookmark, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            let scope = DirectoryAccess(url)
            defer { withExtendedLifetime(scope) {} }
            try validate(url, role: role)
            if stale || url.path != stored.path { try save(url, role: role) }
            return DirectorySelection(displayPath: url.path, url: url, error: nil)
        } catch {
            return DirectorySelection(displayPath: stored.path, url: nil,
                error: "\(role == .output ? "Output" : "Workspace") folder unavailable — Browse to recover it.")
        }
    }

    @discardableResult
    public func select(_ url: URL, role: DirectoryRole) throws -> DirectorySelection {
        let scope = DirectoryAccess(url)
        defer { withExtendedLifetime(scope) {} }
        try validate(url, role: role)
        try save(url, role: role)
        if role == .workspace { defaults.set(true, forKey: Self.modelStorageMigrationKey) }
        return DirectorySelection(displayPath: url.path, url: url, error: nil)
    }

    private func save(_ url: URL, role: DirectoryRole) throws {
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let data = try JSONEncoder().encode(StoredDirectory(path: url.path, bookmark: bookmark))
        defaults.set(data, forKey: key(role))
    }

    private func validate(_ url: URL, role: DirectoryRole) throws {
        guard url.isFileURL, (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
              access(url.path, R_OK | X_OK | W_OK) == 0 else { throw PlanningError.invalidDestination }
        if role == .workspace { _ = try NativeWorkspace(root: url) }
    }

    private func key(_ role: DirectoryRole) -> String { "Libro.directory.\(role.rawValue).v1" }
}

private struct StoredDirectory: Codable { let path: String; let bookmark: Data }
