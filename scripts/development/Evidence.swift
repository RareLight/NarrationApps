import CryptoKit
import Foundation

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func fingerprints(_ root: URL) throws -> [String: String] {
    let manager = FileManager.default
    let files = [
        "DevelopmentBaseline.json", "swift-packages/Package.swift", "swift-packages/Package.resolved",
        "swift-packages/AppPresentation/Package.swift", "Libro/macos/LibroCore/Package.resolved",
        "VoiceRelay/Package.swift", "VoiceRelay/Package.resolved",
        "NarrationApps.xcworkspace/xcshareddata/swiftpm/Package.resolved",
        "Libro/macos/Libro/Libro.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
        "VoiceRelay/VoiceRelay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    ]
    var records: [String: String] = [:]
    for path in files {
        let url = root.appendingPathComponent(path)
        if manager.fileExists(atPath: url.path) { records[path] = sha256(try Data(contentsOf: url)) }
    }
    for path in [
        "swift-packages/Patches", "swift-packages/ThirdPartyNotices",
        "swift-packages/Sources/NativeSpeech/Resources/VoiceSamples",
    ] {
        guard
            let enumerator = manager.enumerator(
                at: root.appendingPathComponent(path),
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        else { continue }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true && values.isSymbolicLink != true {
                records[String(url.path.dropFirst(root.path.count + 1))] = sha256(try Data(contentsOf: url))
            }
        }
    }
    for name in [
        "ZIPFoundation", "mlx-audio-swift", "mlx-swift", "mlx-swift-lm", "swift-huggingface",
        "mlx-swift/Source/Cmlx/mlx", "mlx-swift/Source/Cmlx/mlx-c",
    ] {
        let directory = root.appendingPathComponent("swift-packages/.build/dependencies/\(name)")
        guard manager.fileExists(atPath: directory.appendingPathComponent(".git").path) else { continue }
        let revision = try git(directory, ["rev-parse", "HEAD"])
        let diff = try git(directory, ["diff", "--no-ext-diff", "--binary", "HEAD", "--"])
        if revision.status == 0 && diff.status == 0 {
            records["prepared/\(name)/revision"] = revision.output.trimmingCharacters(in: .whitespacesAndNewlines)
            records["prepared/\(name)/diff-sha256"] = sha256(Data(diff.output.utf8))
        }
    }
    return records
}

func nativePrerequisites(_ options: Options) -> Bool {
    guard let workspace = options.workspace, let libro = options.libroWorker,
        let relay = options.voiceRelayWorker
    else { return false }
    return FileManager.default.isExecutableFile(atPath: libro) && FileManager.default.isExecutableFile(atPath: relay)
        && FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: workspace).appendingPathComponent("models/.native").path)
}
