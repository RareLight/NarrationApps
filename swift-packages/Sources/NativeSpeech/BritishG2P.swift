import Foundation
import NarrationCore

/// Existing native MisakiSwift resources, pinned independently from US assets.
/// An installation without these remains valid for US voices.
public enum BritishG2P {
    public static let repository = "mlalma/MisakiSwift"
    public static let revision = "b7477b15fc46cf8e20b32c008126611b38ec6b79"
    public static let requiredFiles = [
        NativeAcquisitionFile(path: "gb_bart.safetensors", bytes: 3_011_692, hash: "4994f474bb6f4584076a4e98189caaec11aa3f773a0d82d5bc263a03dd07e703", gitOID: nil),
        NativeAcquisitionFile(path: "gb_bart_config.json", bytes: 1_246, hash: "e4f248e6af0cfb6cb54aea6ff0168d16b6f3cdabed438c487cde4ab0815d1bac", gitOID: nil),
        NativeAcquisitionFile(path: "gb_gold.json", bytes: 2_841_062, hash: "090cdecbe6bda9516a2cdc21563d62def0b91f5b55ea74fe6ef729eef682785f", gitOID: nil),
        NativeAcquisitionFile(path: "gb_silver.json", bytes: 3_677_750, hash: "cb8655f5e614e6306146e0da1bf93522ac542ebd39dcd9892afcf51c9aa52e1a", gitOID: nil)
    ]
    public static let totalBytes = requiredFiles.reduce(Int64(0)) { $0 + Int64($1.bytes) }

    public static func sourceURL(for file: NativeAcquisitionFile) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(repository)/\(revision)/Sources/MisakiSwift/Resources/\(file.path)")!
    }

    public static func directory(in workspace: NativeWorkspace) -> URL {
        workspace.nativeRoot.appendingPathComponent("assets/MisakiSwift/\(revision)", isDirectory: true)
    }

    public static func validate(directory: URL, workspace: NativeWorkspace) throws {
        _ = try workspace.contained(directory)
        for file in requiredFiles {
            try workspace.validateFile(directory.appendingPathComponent(file.path), json: file.path.hasSuffix(".json"))
            guard try file.matches(directory.appendingPathComponent(file.path)) else { throw NativeAssetError.changed(file.path) }
        }
        let url = directory.appendingPathComponent(".narration-regional.json")
        try workspace.validateFile(url, json: true)
        let manifest = try JSONDecoder().decode(Inventory.self, from: Data(contentsOf: url))
        guard manifest == Inventory() else { throw NativeAssetError.changed("British pronunciation inventory") }
    }

    public static func record(directory: URL, workspace: NativeWorkspace) throws {
        for file in requiredFiles {
            try workspace.validateFile(directory.appendingPathComponent(file.path), json: file.path.hasSuffix(".json"))
            guard try file.matches(directory.appendingPathComponent(file.path)) else { throw NativeAssetError.changed(file.path) }
        }
        try NativeAtomicFile.write(JSONEncoder().encode(Inventory()),
            to: directory.appendingPathComponent(".narration-regional.json"), workspace: workspace)
    }

    private struct Inventory: Codable, Equatable {
        var version = 1
        var repository = BritishG2P.repository
        var revision = BritishG2P.revision
        var hashes = Dictionary(uniqueKeysWithValues: BritishG2P.requiredFiles.map { ($0.path, $0.hash) })
    }
}

public extension NativeWorkspace {
    func pronunciationDirectory(for settings: SpeechSettings) throws -> URL {
        if settings.model == .kokoro && settings.voice.hasPrefix("b") {
            let directory = BritishG2P.directory(in: self)
            try BritishG2P.validate(directory: directory, workspace: self)
            return directory
        }
        try NativeG2P.validate(directory: g2pDirectory, workspace: self)
        return g2pDirectory
    }
}
