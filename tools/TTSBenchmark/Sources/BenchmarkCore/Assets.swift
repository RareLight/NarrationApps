import Foundation
import CryptoKit

public struct AssetFile: Codable, Sendable {
    public var path: String
    public var bytes: Int64
    public var sha256: String
}
public struct Snapshot: Codable, Sendable {
    public var repository: String
    public var revision: String
    public var files: [AssetFile]
    public var source: String = "Hugging Face immutable revision; LFS SHA256 or computed Git blob SHA1 verified"
}

public enum Assets {
    public static func directory(_ root: URL, repository: String) throws -> URL {
        let components = repository.split(separator: "/")
        guard components.count == 2 else { throw BenchError("Invalid repository") }
        for component in components {
            guard component != ".", component != "..", component.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else { throw BenchError("Invalid repository component") }
        }
        return try Files.child(root, "cache/hub/mlx-audio/" + repository.replacingOccurrences(of: "/", with: "_"))
    }
    public static func verify(_ directory: URL) throws -> Snapshot {
        let manifest = try Files.read(Snapshot.self, directory.appendingPathComponent("benchmark-assets.json"))
        guard manifest.revision.count == 40, !manifest.files.isEmpty else { throw BenchError("Unpinned asset inventory") }
        let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
        if let entries = FileManager.default.enumerator(at: canonical, includingPropertiesForKeys: nil) {
            let tensors = Set(entries.compactMap { $0 as? URL }.filter { $0.pathExtension == "safetensors" }.map {
                $0.resolvingSymlinksInPath().standardizedFileURL.pathComponents.dropFirst(canonical.pathComponents.count).joined(separator: "/")
            })
            let expected = Set(manifest.files.filter { $0.path.hasSuffix(".safetensors") }.map(\.path))
            guard tensors == expected else { throw BenchError("Tensor inventory mismatch: actual=\(tensors.sorted()), expected=\(expected.sorted())") }
        }
        for file in manifest.files {
            let url = try Files.child(directory, file.path)
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                  (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(file.bytes),
                  try Files.hash(url) == file.sha256 else { throw BenchError("Asset verification failed: \(file.path)") }
        }
        return manifest
    }
    public static func prepare(_ root: URL, repository: String, revision: String? = nil) async throws -> Snapshot {
        let destination = try directory(root, repository: repository)
        if FileManager.default.fileExists(atPath: destination.appendingPathComponent("benchmark-assets.json").path) {
            let old = try verify(destination)
            guard revision == nil || revision == old.revision else { throw BenchError("Existing snapshot has a different revision; use a new benchmark workspace") }
            return old
        }
        let api = URL(string: "https://huggingface.co/api/models/\(repository)/revision/\(revision ?? "main")?blobs=true")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180; config.timeoutIntervalForResource = 7200
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: api)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let info = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = info["sha"] as? String, sha.count == 40,
              let siblings = info["siblings"] as? [[String: Any]] else { throw BenchError("Cannot resolve public model \(repository)") }
        let extensions: Set<String> = ["json", "safetensors", "txt", "model", "tiktoken", "wav", "md"]
        let selected = siblings.filter {
            guard let path = $0["rfilename"] as? String else { return false }
            return extensions.contains((path as NSString).pathExtension) || path.hasPrefix("LICENSE")
        }
        guard !selected.isEmpty else { throw BenchError("No supported model files") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var files: [AssetFile] = []
        for entry in selected {
            guard let path = entry["rfilename"] as? String else { continue }
            let target = try Files.child(destination, path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encodedPath = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! }.joined(separator: "/")
            let source = URL(string: "https://huggingface.co/\(repository)/resolve/\(sha)/\(encodedPath)?download=true")!
            print("Preparing \(repository): \(path)"); fflush(stdout)
            let lfs = entry["lfs"] as? [String: Any]
            let expectedSHA = lfs?["sha256"] as? String
            let expectedBytes = (lfs?["size"] as? NSNumber)?.int64Value ?? (entry["size"] as? NSNumber)?.int64Value
            let reusable = FileManager.default.fileExists(atPath: target.path) && expectedSHA != nil && (try? Files.hash(target)) == expectedSHA
            if !reusable {
                let (temporary, result) = try await session.download(from: source)
                guard (result as? HTTPURLResponse)?.statusCode == 200 else { throw BenchError("Download failed: \(repository)/\(path)") }
                let digest = try Files.hash(temporary)
                if let expectedSHA, digest != expectedSHA { throw BenchError("Published SHA256 mismatch: \(path)") }
                let bytes = Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                if let expectedBytes, bytes != expectedBytes { throw BenchError("Published size mismatch: \(path)") }
                if expectedSHA == nil, let oid = entry["blobId"] as? String {
                    let body = try Data(contentsOf: temporary)
                    let gitBlob = Data("blob \(body.count)\0".utf8) + body
                    guard Insecure.SHA1.hash(data: gitBlob).map({ String(format: "%02x", $0) }).joined() == oid else { throw BenchError("Git blob mismatch: \(path)") }
                }
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: temporary, to: target)
            }
            files.append(.init(path: path, bytes: Int64(try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0), sha256: try Files.hash(target)))
        }
        let snapshot = Snapshot(repository: repository, revision: sha, files: files)
        try Files.write(snapshot, destination.appendingPathComponent("benchmark-assets.json"))
        return try verify(destination)
    }
    public static func britishDirectory(_ root: URL) -> URL { root.appendingPathComponent("cache/british-g2p") }
    public static func prepareBritish(_ root: URL) async throws {
        let folder = britishDirectory(root)
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("benchmark-assets.json").path) { _ = try verify(folder); return }
        let revision = "b7477b15fc46cf8e20b32c008126611b38ec6b79"
        let hashes = ["gb_bart.safetensors": "4994f474bb6f4584076a4e98189caaec11aa3f773a0d82d5bc263a03dd07e703",
            "gb_bart_config.json": "e4f248e6af0cfb6cb54aea6ff0168d16b6f3cdabed438c487cde4ab0815d1bac",
            "gb_gold.json": "090cdecbe6bda9516a2cdc21563d62def0b91f5b55ea74fe6ef729eef682785f",
            "gb_silver.json": "cb8655f5e614e6306146e0da1bf93522ac542ebd39dcd9892afcf51c9aa52e1a"]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [AssetFile] = []
        for (path, hash) in hashes.sorted(by: { $0.key < $1.key }) {
            let url = URL(string: "https://raw.githubusercontent.com/mlalma/MisakiSwift/\(revision)/Sources/MisakiSwift/Resources/\(path)")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else { throw BenchError("British G2P hash mismatch") }
            try data.write(to: folder.appendingPathComponent(path), options: .atomic)
            files.append(AssetFile(path: path, bytes: Int64(data.count), sha256: hash))
        }
        try Files.write(Snapshot(repository: "mlalma/MisakiSwift", revision: revision, files: files,
            source: "Pinned GitHub resources; same published hashes as NativeSpeech/BritishG2P.swift"), folder.appendingPathComponent("benchmark-assets.json"))
    }
}
