#!/usr/bin/swift
import Foundation

let base = CommandLine.arguments.dropFirst().first ?? ""
guard base.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
    base != String(repeating: "0", count: 40) else { print("release"); exit(0) }
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
process.arguments = ["diff", "--name-only", "-z", base, "HEAD", "--"]
let pipe = Pipe()
process.standardOutput = pipe
process.standardError = FileHandle.nullDevice
try process.run()
let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()
guard process.terminationStatus == 0 else { print("release"); exit(0) }
let paths = String(decoding: bytes, as: UTF8.self).split(separator: "\0").map(String.init)
let release = paths.contains {
    $0 == "DevelopmentBaseline.json" || $0.contains("Package.") || $0.contains("Patches/") ||
        $0.contains(".xcode") || $0.contains(".xcworkspace") || $0.contains("Worker") ||
        $0.contains("prepare-") || $0.contains("build-") || $0.hasPrefix("scripts/") ||
        $0.hasPrefix("swift-packages/Sources/") || $0.hasPrefix("swift-packages/AppPresentation/Sources/") ||
        $0.contains("ThirdPartyNotices/")
}
let full = paths.contains {
    $0.contains("Sources/") || $0.contains("Tests/") || $0.contains("Fixtures/") ||
        $0.hasPrefix("swift-packages/scripts/")
}
print(release ? "release" : (full ? "full" : "quick"))
