import Foundation
import CryptoKit

public enum NativeAssetError: Error, LocalizedError, Equatable {
    case outsideWorkspace, missing(String), invalid(String), changed(String)

    public var errorDescription: String? {
        switch self {
        case .outsideWorkspace: "Asset path escapes the selected Libro workspace."
        case .missing(let file): "Missing native asset: \(file). Prepare the model first."
        case .invalid(let file): "Invalid native asset: \(file). Prepare the model again."
        case .changed(let file): "Native asset inventory mismatch: \(file). Prepare the model again."
        }
    }
}

public struct NativeWorkspace: Sendable {
    public let root: URL
    public var nativeRoot: URL { root.appendingPathComponent("models/.native", isDirectory: true) }
    public var hubCache: URL { nativeRoot.appendingPathComponent("hub", isDirectory: true) }
    public var g2pDirectory: URL {
        nativeRoot.appendingPathComponent("assets/kitten-tts-g2p/\(NativeG2P.revision)", isDirectory: true)
    }

    public init(root: URL) throws {
        guard root.isFileURL else { throw NativeAssetError.outsideWorkspace }
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        guard !Self.isInsideApp(self.root) else { throw NativeAssetError.invalid("workspace inside an app bundle") }
        guard (try self.root.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw NativeAssetError.invalid("workspace directory")
        }
    }

    public func contained(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw NativeAssetError.outsideWorkspace }
        // Foundation does not resolve ancestor links when the leaf is absent.
        // Resolve the nearest existing ancestor before appending missing parts.
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) == nil,
                  ancestor.path != "/" else { throw NativeAssetError.outsideWorkspace }
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for part in missing.reversed() { resolved.appendPathComponent(part) }
        guard resolved.path.hasPrefix(root.path + "/"), !Self.isInsideApp(resolved) else {
            throw NativeAssetError.outsideWorkspace
        }
        return resolved
    }

    private static func isInsideApp(_ url: URL) -> Bool {
        url.pathComponents.contains { ($0 as NSString).pathExtension.lowercased() == "app" }
    }

    /// Writes must stay in the actual private namespace; an internal symlink
    /// must not redirect metadata/staging into a read-only Python snapshot.
    public func managed(_ url: URL) throws -> URL {
        let resolvedRoot = try contained(nativeRoot)
        let resolved = try contained(url)
        guard resolvedRoot.path == nativeRoot.path, resolved.path == url.standardizedFileURL.path,
              resolved.path.hasPrefix(nativeRoot.path + "/") else { throw NativeAssetError.outsideWorkspace }
        return resolved
    }

    public func primaryDirectory(for model: SpeechModel, voice: String = "af_aoede") throws -> URL {
        try NativePrimaryStore.directory(for: model, workspace: self, voice: voice)
    }

    public func validateFile(_ url: URL, json: Bool = false) throws {
        let file = try contained(url)
        guard FileManager.default.fileExists(atPath: file.path) else { throw NativeAssetError.missing(url.lastPathComponent) }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw NativeAssetError.invalid(url.lastPathComponent) }
        if json {
            guard (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) is [String: Any] else {
                throw NativeAssetError.invalid(url.lastPathComponent)
            }
        }
    }
}

public enum NativeG2P {
    public static let repository = "beshkenadze/kitten-tts-g2p"
    public static let revision = "9c692b92682d959d9013a9cfe6a49541997add18"
    public static let requiredFiles: [String: Int] = [
        "us_bart.safetensors": 3_011_692,
        "us_bart_config.json": 1_257,
        "us_gold.json": 3_001_196,
        "us_silver.json": 3_105_352
    ]
    public static let sha256ByFile = [
        "us_bart.safetensors": "dc4a02e62d4fcb4bb4097ecf00db89b8e1a12a549a52ab6adfbba220b80a55c5",
        "us_bart_config.json": "8deb3537fb29c63cd9f20d75515ae06e4c92f1b6db0703a2d45bca95b33a53a4",
        "us_gold.json": "8507f89840f0813b10cf584740942f58e9cc9ad3660e24088b442ab0a6b126be",
        "us_silver.json": "ea0e1abca0c9b18fb0d3402034633a337154a3153e9a9f49f97d668c908e140c"
    ]

    public static func validate(directory: URL, workspace: NativeWorkspace) throws {
        _ = try workspace.contained(directory)
        for (file, size) in requiredFiles.sorted(by: { $0.key < $1.key }) {
            let url = directory.appendingPathComponent(file)
            try workspace.validateFile(url, json: file.hasSuffix(".json"))
            guard (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize == size else {
                throw NativeAssetError.changed(file)
            }
        }
        let inventoryURL = directory.appendingPathComponent(".libro-native.json")
        try workspace.validateFile(inventoryURL, json: true)
        let inventory = try JSONDecoder().decode(AssetInventory.self, from: Data(contentsOf: inventoryURL))
        guard inventory.version == 1, inventory.repository == repository, inventory.revision == revision,
              inventory.sha256 == sha256ByFile else {
            throw NativeAssetError.invalid("native G2P inventory")
        }
        for (file, hash) in inventory.sha256 {
            guard try sha256(directory.appendingPathComponent(file)) == hash else { throw NativeAssetError.changed(file) }
        }
    }

    public static func record(directory: URL, workspace: NativeWorkspace) throws {
        var hashes: [String: String] = [:]
        for (file, size) in requiredFiles {
            let url = directory.appendingPathComponent(file)
            try workspace.validateFile(url, json: file.hasSuffix(".json"))
            guard (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize == size else { throw NativeAssetError.changed(file) }
            hashes[file] = try sha256(url)
        }
        // Digests were captured from the pinned Hub snapshot; the weight also
        // matches its published LFS digest. Do not trust mutable local metadata.
        guard hashes == sha256ByFile else {
            throw NativeAssetError.changed("native G2P snapshot")
        }
        let inventory = AssetInventory(version: 1, repository: repository, revision: revision, sha256: hashes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(inventory).write(to: workspace.managed(directory.appendingPathComponent(".libro-native.json")), options: [.atomic])
    }

    public static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct AssetInventory: Codable {
    let version: Int
    let repository: String
    let revision: String
    let sha256: [String: String]
}
