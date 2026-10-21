#!/usr/bin/swift
import CryptoKit
import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, ["Libro", "VoiceRelay"].contains(arguments[1]) else {
    print("Usage: swift scripts/check-bundle.swift <generated-app-path> Libro|VoiceRelay")
    exit(2)
}
let app = URL(fileURLWithPath: arguments[0]).standardizedFileURL
let name = arguments[1]
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let manager = FileManager.default
func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "BundleCheck", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
    }
    return String(decoding: data, as: UTF8.self)
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "BundleCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func digest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func compareTree(_ source: URL, _ destination: URL) throws -> [String: String] {
    guard let enumerator = manager.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]) else {
        throw CocoaError(.fileReadNoSuchFile)
    }
    var records: [String: String] = [:]
    for case let file as URL in enumerator {
        if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let relative = String(file.path.dropFirst(source.path.count + 1))
            let expected = try digest(file)
            try require(try digest(destination.appendingPathComponent(relative)) == expected, "Resource differs: \(relative)")
            records[relative] = expected
        }
    }
    try require(!records.isEmpty, "Required resource tree is empty.")
    return records
}
do {
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
    guard let executable = info["CFBundleExecutable"] as? String,
        executable.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw CocoaError(.fileReadCorruptFile) }
    let gui = app.appendingPathComponent("Contents/MacOS/\(executable)")
    let worker = app.appendingPathComponent("Contents/Helpers/\(name)SpeechWorker")
    let metal = app.appendingPathComponent("Contents/Helpers/mlx.metallib")
    for binary in [gui, worker] {
        try require(try run("/usr/bin/lipo", ["-archs", binary.path]).trimmingCharacters(in: .whitespacesAndNewlines) == "arm64", "Expected arm64 binary.")
    }
    let symbols = try run("/usr/bin/nm", ["-j", gui.path])
    let libraries = try run("/usr/bin/otool", ["-L", gui.path])
    try require(!symbols.contains("$s3MLX") && !libraries.contains("MLX.framework"), "GUI links MLX.")
    try require(manager.fileExists(atPath: metal.path), "Missing embedded Metal library.")
    let notices = try compareTree(root.appendingPathComponent("swift-packages/ThirdPartyNotices"),
        app.appendingPathComponent("Contents/Resources/ThirdPartyNotices"))
    let samples = try compareTree(root.appendingPathComponent("swift-packages/Sources/NativeSpeech/Resources/VoiceSamples"),
        app.appendingPathComponent("Contents/Resources/SwiftNarration_NativeSpeech.bundle/Contents/Resources/VoiceSamples"))
    let helperNames = try manager.contentsOfDirectory(atPath: app.appendingPathComponent("Contents/Helpers").path)
    try require(Set(helperNames) == ["\(name)SpeechWorker", "mlx.metallib"], "Unexpected embedded helper/runtime.")
    var artifacts = ["gui": try digest(gui), "worker": try digest(worker), "metal": try digest(metal)]
    var codecSymbols: [String] = []
    if name == "VoiceRelay" {
        let original = root.appendingPathComponent("VoiceRelay/icon/VoiceRelay_Cover.png")
        let bundled = app.appendingPathComponent("Contents/Resources/VoiceRelay_Cover.png")
        let expected = try digest(original)
        try require(try digest(bundled) == expected, "Default podcast cover differs from the authored image.")
        artifacts["defaultPodcastCover"] = expected
    }
    if name == "Libro" {
        let codec = app.appendingPathComponent("Contents/Frameworks/libmp3lame.0.dylib")
        try require(try run("/usr/bin/lipo", ["-archs", codec.path]).trimmingCharacters(in: .whitespacesAndNewlines) == "arm64", "Expected arm64 codec.")
        _ = try run("/usr/bin/codesign", ["--verify", "--strict", codec.path])
        guard let library = dlopen(codec.path, RTLD_NOW | RTLD_LOCAL) else { throw CocoaError(.executableNotLoadable) }
        defer { dlclose(library) }
        codecSymbols = ["lame_init", "lame_close", "lame_set_num_channels", "lame_set_in_samplerate",
            "lame_set_out_samplerate", "lame_set_mode", "lame_set_brate", "lame_set_quality",
            "lame_set_findReplayGain", "lame_set_decode_on_the_fly", "lame_set_bWriteVbrTag",
            "lame_set_write_id3tag_automatic", "id3tag_set_albumart", "lame_set_scale", "lame_init_params",
            "lame_encode_buffer_ieee_float", "lame_encode_flush", "lame_get_lametag_frame", "lame_get_id3v2_tag"]
        for symbol in codecSymbols { try require(dlsym(library, symbol) != nil, "Missing packaged codec symbol: \(symbol)") }
        artifacts["codec"] = try digest(codec)
    }
    _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    _ = try run("/usr/bin/codesign", ["--verify", "--strict", worker.path])
    let signature = try run("/usr/bin/codesign", ["-d", "--verbose=2", app.path])
    let probe = try run("/usr/bin/sandbox-exec", ["-p", "(version 1)(allow default)(deny network*)", worker.path, "--probe"])
    let json = try JSONSerialization.jsonObject(with: Data(probe.utf8)) as? [String: Any]
    try require(json?["metal"] as? String == "ready", "Embedded helper Metal probe did not report ready.")
    let report: [String: Any] = ["app": name, "path": app.path, "artifacts": artifacts,
        "notices": notices, "samples": samples, "signatureVerified": true,
        "signingClass": signature.contains("Signature=adhoc") ? "ad-hoc-engineering" : "configured-signature",
        "metalProbe": json ?? [:], "codecSymbolsVerified": codecSymbols, "operatorAcceptance": "not-performed"]
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
} catch {
    print("Bundle verification failed: \(error)")
    exit(1)
}
