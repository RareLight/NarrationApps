import NarrationCore
import Foundation
import CryptoKit

public struct NativePrimaryFile: Sendable {
    public let path: String
    public let bytes: Int
    public let sha256: String
    public let gitOID: String
    public let compatibleKokoroConfigSHA256: String?
    public let structuralJSONSHA256: String?

    init(path: String, bytes: Int, sha256: String, gitOID: String = "", compatibleKokoroConfigSHA256: String? = nil, structuralJSONSHA256: String? = nil) {
        self.path = path; self.bytes = bytes; self.sha256 = sha256; self.gitOID = gitOID
        self.compatibleKokoroConfigSHA256 = compatibleKokoroConfigSHA256
        self.structuralJSONSHA256 = structuralJSONSHA256
    }
}

public struct NativePrimarySpecification: Sendable {
    public let model: SpeechModel
    public let repository: String
    public let revision: String
    public let files: [NativePrimaryFile]
    public var voices: [String] {
        if model != .kokoro { return model.presetVoices }
        return files.filter { $0.path.hasPrefix("voices/") }.map { ($0.path as NSString).lastPathComponent.replacingOccurrences(of: ".safetensors", with: "") }
    }
}

/// Pinned inventories around explicit local loaders. This layer never downloads
/// or changes a Python snapshot/manifest. Preparation calls record explicitly.
public enum NativePrimaryStore {
    public static func directory(for model: SpeechModel, workspace: NativeWorkspace, voice: String) throws -> URL {
        let primary = try directory(specification: NativePrimaryCatalog.specification(for: model), workspace: workspace, voice: voice)
        for dependency in NativePrimaryCatalog.dependencies(for: model) {
            _ = try directory(specification: dependency, workspace: workspace, voice: voice)
        }
        return primary
    }

    public static func directory(specification: NativePrimarySpecification, workspace: NativeWorkspace, voice: String) throws -> URL {
        let shared = try workspace.contained(workspace.root.appendingPathComponent("models/\(specification.model.rawValue)/\(specification.repository.replacingOccurrences(of: "/", with: "__"))"))
        if let records = try? validate(directory: shared, specification: specification, workspace: workspace, sharedVoice: voice) {
            let metadata = try reuseRecordURL(specification, workspace: workspace)
            if FileManager.default.fileExists(atPath: metadata.path) {
                try validateRecord(metadata, records: records, source: shared, specification: specification, workspace: workspace)
            }
            return shared
        }
        let native = try nativeDirectory(specification, workspace: workspace)
        let records = try validate(directory: native, specification: specification, workspace: workspace)
        try validateRecord(native.appendingPathComponent(".libro-native.json"), records: records,
                           source: native, specification: specification, workspace: workspace)
        return native
    }

    public static func nativeDirectory(_ specification: NativePrimarySpecification, workspace: NativeWorkspace) throws -> URL {
        try workspace.managed(workspace.nativeRoot.appendingPathComponent("primary/\(specification.model.rawValue)/\(specification.revision)"))
    }

    public static func reuseRecordURL(_ specification: NativePrimarySpecification, workspace: NativeWorkspace) throws -> URL {
        try workspace.managed(workspace.nativeRoot.appendingPathComponent("reuse/\(specification.model.rawValue)-\(specification.revision).json"))
    }

    /// A shared snapshot may have fewer optional English voices. Every present
    /// supported voice is inventoried, and the requested voice is mandatory.
    public static func validate(directory: URL, specification: NativePrimarySpecification, workspace: NativeWorkspace,
                                sharedVoice: String? = nil) throws -> [NativePrimaryRecord] {
        // Enumerators do not consistently descend through a symlink supplied
        // as their root. Use the same contained canonical directory as loaders.
        let directory = try workspace.contained(directory)
        // Both loaders inspect top-level tensors; Kokoro even prefers an
        // unrequested model.safetensors over the named pinned weight. Do not
        // accept a directory whose extra tensors can alter the loaded model.
        if specification.model.isLarge {
            let generated = NativePrimaryCatalog.generatedFiles(for: specification)
            let expectedFiles = Set((specification.files + generated).map(\.path))
            let expectedTensors = Set(specification.files.filter { $0.path.hasSuffix(".safetensors") }.map(\.path))
            var actualTensors = Set<String>()
            // The path enumerator supplies relative names directly. URL-based
            // enumeration can return /private/var while its root uses /var.
            guard let entries = FileManager.default.enumerator(atPath: directory.path) else { throw NativeAssetError.missing("tensor inventory") }
            for case let relative as String in entries {
                let ext = (relative as NSString).pathExtension
                if ext == "safetensors" { actualTensors.insert(relative) }
                if ["json", "txt", "safetensors"].contains(ext) {
                    guard expectedFiles.contains(relative) || ["benchmark-assets.json", ".libro-native.json"].contains(relative) else { throw NativeAssetError.changed("unexpected model sidecar") }
                }
            }
            guard expectedTensors == actualTensors else { throw NativeAssetError.changed("tensor inventory") }
            try validateGenerated(directory: directory, specification: specification, requireAll: false)
        }
        let expectedWeights = Set(specification.files.filter { !$0.path.contains("/") && $0.path.hasSuffix(".safetensors") }.map(\.path))
        let actualWeights = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }.map(\.lastPathComponent))
        guard actualWeights == expectedWeights else { throw NativeAssetError.changed("primary tensor inventory") }
        if let sharedVoice, specification.model == .kokoro, !specification.voices.contains(sharedVoice) {
            throw NativeAssetError.invalid("English voice name")
        }
        var records: [NativePrimaryRecord] = []
        for file in specification.files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains(".."), file.bytes > 0 else {
                throw NativeAssetError.invalid("primary inventory path")
            }
            let url = try workspace.contained(directory.appendingPathComponent(file.path))
            if let sharedVoice, file.path.hasPrefix("voices/"), file.path != "voices/\(sharedVoice).safetensors",
               !FileManager.default.fileExists(atPath: url.path) { continue }
            try workspace.validateFile(url)
            let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let exactSize = bytes == file.bytes
            // Only the known CLI Kokoro metadata addition/JSON formatting is
            // compatible. No architecture relabeling or tensor conversion.
            let allowsCompatibleConfig = sharedVoice != nil && specification.model == .kokoro && file.path == "config.json" && file.compatibleKokoroConfigSHA256 != nil
            guard exactSize || (allowsCompatibleConfig && bytes > 0 && bytes <= 1_048_576) else { throw NativeAssetError.changed(file.path) }
            let sha256 = try NativeG2P.sha256(url)
            if sha256 != file.sha256 {
                guard allowsCompatibleConfig, try compatibleKokoroConfigHash(url) == file.compatibleKokoroConfigSHA256 else {
                    throw NativeAssetError.changed(file.path)
                }
            }
            records.append(.init(path: file.path, bytes: bytes, sha256: sha256))
        }
        return records
    }

    public static func recordReuse(directory: URL, specification: NativePrimarySpecification, workspace: NativeWorkspace,
                                   voice: String = SpeechSettings.defaultKokoroVoice) throws {
        let records = try validate(directory: directory, specification: specification, workspace: workspace, sharedVoice: voice)
        try record(try reuseRecordURL(specification, workspace: workspace), records: records, source: directory,
                   specification: specification, workspace: workspace)
    }

    public static func recordStaged(directory: URL, specification: NativePrimarySpecification, workspace: NativeWorkspace) throws {
        _ = try workspace.managed(directory)
        let records = try validate(directory: directory, specification: specification, workspace: workspace)
        try record(directory.appendingPathComponent(".libro-native.json"), records: records,
                   source: try nativeDirectory(specification, workspace: workspace), specification: specification, workspace: workspace)
    }

    public static func validateStaged(directory: URL, specification: NativePrimarySpecification, workspace: NativeWorkspace) throws {
        _ = try workspace.managed(directory)
        let records = try validate(directory: directory, specification: specification, workspace: workspace)
        try validateRecord(directory.appendingPathComponent(".libro-native.json"), records: records,
                           source: try nativeDirectory(specification, workspace: workspace), specification: specification, workspace: workspace)
    }

    public static func validateGenerated(directory: URL, specification: NativePrimarySpecification, requireAll: Bool = true) throws {
        for file in NativePrimaryCatalog.generatedFiles(for: specification) {
            let path = directory.appendingPathComponent(file.path)
            if !requireAll && !FileManager.default.fileExists(atPath: path.path) { continue }
            guard (try FileManager.default.attributesOfItem(atPath: path.path)[.type]) as? FileAttributeType == .typeRegular,
                  (try path.resourceValues(forKeys: [.fileSizeKey])).fileSize == file.bytes,
                  try (NativeG2P.sha256(path) == file.sha256 || file.structuralJSONSHA256.map { try NativeJSONDigest.sha256(path) == $0 } == true) else { throw NativeAssetError.changed("generated tokenizer") }
        }
    }

    private static func compatibleKokoroConfigHash(_ url: URL) throws -> String {
        guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw NativeAssetError.invalid("Kokoro configuration")
        }
        if let type = object["model_type"] {
            guard type as? String == "kokoro" else { throw NativeAssetError.invalid("model_type") }
            object.removeValue(forKey: "model_type")
        }
        let normalized = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return SHA256.hash(data: normalized).map { String(format: "%02x", $0) }.joined()
    }

    private static func relative(_ source: URL, workspace: NativeWorkspace) throws -> String {
        let source = try workspace.contained(source)
        return String(source.path.dropFirst(workspace.root.path.count + 1))
    }

    private static func record(_ url: URL, records: [NativePrimaryRecord], source: URL,
                               specification: NativePrimarySpecification, workspace: NativeWorkspace) throws {
        let url = try workspace.managed(url)
        try Task.checkCancellation()
        let inventory = PrimaryInventory(version: 1, repository: specification.repository, revision: specification.revision,
                                         relativeDirectory: try relative(source, workspace: workspace), files: records)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try NativeAtomicFile.write(encoder.encode(inventory), to: url, workspace: workspace)
    }

    private static func validateRecord(_ url: URL, records: [NativePrimaryRecord], source: URL,
                                      specification: NativePrimarySpecification, workspace: NativeWorkspace) throws {
        try workspace.validateFile(url)
        guard ((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) <= 131_072 else { throw NativeAssetError.invalid("primary inventory") }
        let inventory = try JSONDecoder().decode(PrimaryInventory.self, from: Data(contentsOf: url))
        guard inventory.version == 1, inventory.repository == specification.repository, inventory.revision == specification.revision,
              inventory.relativeDirectory == (try relative(source, workspace: workspace)), inventory.files == records else {
            throw NativeAssetError.changed("primary inventory")
        }
    }
}

public struct NativePrimaryRecord: Codable, Equatable, Sendable {
    public let path: String
    public let bytes: Int
    public let sha256: String
}

private struct PrimaryInventory: Codable {
    let version: Int
    let repository: String
    let revision: String
    let relativeDirectory: String
    let files: [NativePrimaryRecord]
}
