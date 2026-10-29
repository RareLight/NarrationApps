import Foundation
import Darwin
import HuggingFace
import NarrationCore

public enum ModelStorageError: Error, LocalizedError {
    case inUse, unsafePath
    public var errorDescription: String? {
        switch self {
        case .inUse: "Models are in use. Stop speech and previews in both apps, then retry."
        case .unsafePath: "The model folder changed or contains an unsafe link. Nothing was deleted."
        }
    }
}

/// Shared readers cover complete sessions, including idle/waiting workers.
/// Removal takes an exclusive nonblocking lock. Other software does not honor it.
public final class ModelStorageLease: @unchecked Sendable {
    private let descriptor: Int32
    public init(workspace: NativeWorkspace, deleting: Bool = false) throws {
        let file = try workspace.managed(workspace.nativeRoot.appendingPathComponent("locks/model-storage.lock"))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ModelStorageError.unsafePath }
        guard flock(fd, (deleting ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            close(fd); throw ModelStorageError.inUse
        }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

public struct StoredSpeechModel: Identifiable, Sendable {
    public let model: SpeechModel
    public let bytes: Int64
    public let imported: Bool
    public var id: SpeechModel { model }
    public init(model: SpeechModel, bytes: Int64, imported: Bool = false) {
        self.model = model; self.bytes = bytes; self.imported = imported
    }
}

public enum NativeModelStorage {
    static let marker = ".narration-hub-cache-v1"
    /// Uses the pinned library's HF_HUB_CACHE / HF_HOME / platform resolution.
    /// Resolving the location performs no I/O or downloads.
    public static var defaultRoot: URL { HubCache.default.cacheDirectory.standardizedFileURL.resolvingSymlinksInPath() }

    /// Explicit installation or folder selection only. Existing workspaces keep
    /// their layout; new locations use the standard Python-compatible Hub layout.
    public static func prepareRoot(_ root: URL) throws {
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        guard root.isFileURL, canonical.path != "/", canonical.path != FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path,
              !canonical.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) else { throw ModelStorageError.unsafePath }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try NativeWorkspace(root: root)
        let legacy = FileManager.default.fileExists(atPath: workspace.nativeRoot.path)
        if root.standardizedFileURL.resolvingSymlinksInPath().path == defaultRoot.path || !legacy {
            let file = root.appendingPathComponent(marker)
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) == nil else { throw ModelStorageError.unsafePath }
            try Data("1\n".utf8).write(to: file, options: .atomic)
        }
    }

    public static func entries(at root: URL, models: [SpeechModel] = SpeechModel.allCases) throws -> [StoredSpeechModel] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let workspace = try NativeWorkspace(root: root)
        return try models.compactMap { model in
            let installed = try removablePaths(model, workspace: workspace).filter { FileManager.default.fileExists(atPath: $0.path) }
            let source = root.appendingPathComponent(model.primaryRelativePath)
            let imported = installed.isEmpty && FileManager.default.fileExists(atPath: source.path)
            let paths = imported ? [source] : installed
            guard !paths.isEmpty else { return nil }
            return StoredSpeechModel(model: model, bytes: try diskBytes(paths, workspace: workspace), imported: imported)
        }
    }

    /// Only known primary repositories and owned runtime copies. Shared codecs,
    /// unrelated repositories, references, source documents and audio stay intact.
    public static func remove(_ model: SpeechModel, at root: URL) throws {
        let workspace = try NativeWorkspace(root: root)
        let lease = try ModelStorageLease(workspace: workspace, deleting: true)
        defer { withExtendedLifetime(lease) {} }
        let paths = try removablePaths(model, workspace: workspace)
        // Validate the entire scope before the first mutation; never follow a
        // redirected repository or private primary directory on deletion.
        for path in paths {
            let resolved = try workspace.contained(path)
            guard resolved.path == path.standardizedFileURL.path else { throw ModelStorageError.unsafePath }
        }
        for path in paths where FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
        let spec = NativePrimaryCatalog.specification(for: model)
        let record = try NativePrimaryStore.reuseRecordURL(spec, workspace: workspace)
        if FileManager.default.fileExists(atPath: record.path) { try FileManager.default.removeItem(at: record) }
    }

    private static func removablePaths(_ model: SpeechModel, workspace: NativeWorkspace) throws -> [URL] {
        let spec = NativePrimaryCatalog.specification(for: model)
        let cache = HubCache(cacheDirectory: workspace.hubCache)
        guard let repo = Repo.ID(rawValue: spec.repository) else { throw ModelStorageError.unsafePath }
        let staging = try workspace.managed(workspace.nativeRoot.appendingPathComponent("staging"))
        let partials = ((try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("primary-\(model.rawValue)-") }
        return [try workspace.managed(workspace.nativeRoot.appendingPathComponent("primary/\(model.rawValue)")),
                cache.repoDirectory(repo: repo, kind: .model), cache.metadataDirectory(repo: repo, kind: .model)] + partials
    }

    private static func diskBytes(_ paths: [URL], workspace: NativeWorkspace) throws -> Int64 {
        var total: Int64 = 0, seen = Set<String>()
        for path in paths {
            let path = try workspace.contained(path)
            guard let entries = FileManager.default.enumerator(at: path, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey], options: []) else { continue }
            for case let file as URL in entries {
                try Task.checkCancellation()
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey])
                if values.isSymbolicLink == true { entries.skipDescendants(); continue }
                guard values.isRegularFile == true else { continue }
                _ = try workspace.contained(file)
                let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                let key = "\(attrs[.systemNumber] ?? ""):\(attrs[.systemFileNumber] ?? "")"
                if seen.insert(key).inserted { total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0) }
            }
        }
        return total
    }
}
