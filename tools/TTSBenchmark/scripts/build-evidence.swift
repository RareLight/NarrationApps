import Foundation
import CryptoKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2 else { fatalError("Usage: build-evidence.swift REPO_ROOT BIN_DIRECTORY") }
let root = URL(fileURLWithPath: args[0]), bin = URL(fileURLWithPath: args[1])
func command(_ path: String, _ arguments: [String]) throws -> Data {
    let p = Process(), output = Pipe()
    p.executableURL = URL(fileURLWithPath: path); p.arguments = arguments
    p.standardOutput = output; p.standardError = FileHandle.nullDevice
    try p.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }; return bytes
}
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
var pins: [String: Any] = [:]
for name in ["mlx-audio-swift", "mlx-swift", "mlx-swift-lm", "swift-huggingface"] {
    let directory = root.appendingPathComponent("swift-packages/.build/dependencies/" + name)
    pins[name] = ["revision": String(decoding: try command("/usr/bin/git", ["-C", directory.path, "rev-parse", "HEAD"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                  "patchSHA256": hash(try command("/usr/bin/git", ["-C", directory.path, "diff", "--binary", "--no-ext-diff"]))]
}
var resources: [String: String] = [:]
if let entries = FileManager.default.enumerator(at: bin, includingPropertiesForKeys: nil) {
    for case let url as URL in entries where url.pathExtension == "metallib" {
        resources[String(url.path.dropFirst(bin.path.count + 1))] = hash(try Data(contentsOf: url))
    }
}
guard !resources.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
let evidence: [String: Any] = ["schemaVersion": 1, "nativeDependencies": pins, "metalResources": resources,
    "swift": String(decoding: try command("/usr/bin/swift", ["--version"]), as: UTF8.self),
    "xcode": String(decoding: try command("/usr/bin/xcodebuild", ["-version"]), as: UTF8.self),
    "rootRevision": String(decoding: try command("/usr/bin/git", ["-C", root.path, "rev-parse", "HEAD"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
    "packageLockSHA256": hash(try Data(contentsOf: root.appendingPathComponent("tools/TTSBenchmark/Package.resolved")))]
try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: bin.appendingPathComponent("benchmark-build.json"), options: .atomic)
print("Recorded native pins, patches, Metal resources and toolchain evidence.")
