#!/usr/bin/swift
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "ArchitectureContracts", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func manifest(_ path: String) throws -> [String: Any] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = ["package", "--disable-sandbox", "--package-path", root.appendingPathComponent(path).path, "dump-package"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.standardError
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "Cannot inspect \(path) manifest.")
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}
func graph(_ manifest: [String: Any]) -> [String: [String]] {
    Dictionary(uniqueKeysWithValues: (manifest["targets"] as! [[String: Any]]).map { target in
        let dependencies = (target["dependencies"] as! [[String: Any]]).flatMap { entry in
            entry.values.compactMap { ($0 as? [Any])?.first as? String }
        }
        return (target["name"] as! String, dependencies)
    })
}
func reachesMLX(_ node: String, _ graph: [String: [String]], visited: Set<String> = []) -> Bool {
    if node.hasPrefix("MLX") || node == "NativeSpeechEngine" { return true }
    if visited.contains(node) { return false }
    return (graph[node] ?? []).contains { reachesMLX($0, graph, visited: visited.union([node])) }
}
do {
    try require(reachesMLX("GUI", ["GUI": ["Core"], "Core": ["MLX"]]), "Transitive MLX detector self-test.")
    try require(!reachesMLX("GUI", ["GUI": ["Core"], "Core": ["GUI"]]), "Cycle detector self-test.")
    let presentation = try manifest("swift-packages/AppPresentation")
    try require((presentation["dependencies"] as! [Any]).isEmpty, "AppPresentation must remain independent.")
    try require((graph(presentation)["AppPresentation"] ?? []).isEmpty, "AppPresentation may not link narration.")
    let shared = try manifest("swift-packages")
    let sharedGraph = graph(shared)
    let publicTargets = ["NarrationCore", "DocumentProcessing", "NativeSpeech", "AudioOutput",
        "ProcessingPipeline", "Pronunciation", "PronunciationUI", "NarrationUI"]
    for target in publicTargets {
        try require(sharedGraph[target] != nil && !reachesMLX(target, sharedGraph), "\(target) must not transitively link MLX.")
    }
    for (path, target) in [("Libro/macos/LibroCore", "LibroCore"), ("VoiceRelay", "VoiceRelayApp")] {
        let appGraph = graph(try manifest(path)).merging(sharedGraph) { first, _ in first }
        try require(appGraph[target] != nil && !reachesMLX(target, appGraph), "\(target) must remain helper-independent.")
    }
    for (project, app) in [("Libro/macos/Libro/Libro.xcodeproj", "Libro"), ("VoiceRelay/VoiceRelay.xcodeproj", "VoiceRelay")] {
        let data = try Data(contentsOf: root.appendingPathComponent("\(project)/project.pbxproj"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        let objects = plist["objects"] as! [String: [String: Any]]
        let target = objects.values.first { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == app }!
        let phases = (target["buildPhases"] as! [String]).compactMap { objects[$0] }
        let frameworks = phases.filter { $0["isa"] as? String == "PBXFrameworksBuildPhase" }
        for phase in frameworks {
            for file in phase["files"] as? [String] ?? [] {
                if let product = objects[file]?["productRef"] as? String,
                    let name = objects[product]?["productName"] as? String {
                    try require(!reachesMLX(name, sharedGraph), "\(app) GUI explicitly links \(name).")
                }
            }
        }
    }
    let locks = ["swift-packages/Package.resolved", "Libro/macos/LibroCore/Package.resolved",
        "VoiceRelay/Package.resolved", "NarrationApps.xcworkspace/xcshareddata/swiftpm/Package.resolved",
        "Libro/macos/Libro/Libro.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
        "VoiceRelay/VoiceRelay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"]
    var coordinatedPins: [String: String] = [:]
    for path in locks {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let pins = object["pins"] as! [[String: Any]]
        try require(Set(pins.compactMap { $0["identity"] as? String }).count == pins.count, "Duplicate lock identity: \(path)")
        for pin in pins {
            let identity = pin["identity"] as! String
            let revision = (pin["state"] as! [String: Any])["revision"] as! String
            try require(revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil, "Invalid locked revision: \(path)")
            if ["swiftsoup", "swift-readability", "swift-transformers"].contains(identity) {
                try require(coordinatedPins[identity] == nil || coordinatedPins[identity] == revision,
                    "Incompatible coordinated pin drift for \(identity) in \(path); review composition, never blindly copy locks.")
                coordinatedPins[identity] = revision
            }
        }
    }
    print("Architecture: independent presentation, transitive GUI/helper isolation and six owned locks passed.")
} catch {
    print("Architecture contract failed: \(error)")
    exit(1)
}
