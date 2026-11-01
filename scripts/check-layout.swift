#!/usr/bin/swift
import Foundation

// Validate the actual filesystem and project graph, without opening Xcode or apps.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let manager = FileManager.default
var failures: [String] = []
func require(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
func referencedPaths(_ file: URL, prefix: String) throws -> [String] {
    let text = try String(contentsOf: file, encoding: .utf8)
    let expression = try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: prefix) + "([^\"]+)")
    return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
        Range($0.range(at: 1), in: text).map { String(text[$0]) }
    }
}
require(manager.fileExists(atPath: root.appendingPathComponent(".git").path), "Root Git history is missing")
require(!manager.fileExists(atPath: root.appendingPathComponent("swift-packages/.git").path), "Packages must use the parent Git repository")
require(!manager.fileExists(atPath: root.appendingPathComponent("Package.swift").path), "Package manifest belongs under swift-packages")
let workspace = root.appendingPathComponent("NarrationApps.xcworkspace")
let projects = try referencedPaths(workspace.appendingPathComponent("contents.xcworkspacedata"), prefix: "group:")
require(Set(projects) == Set(["Libro/macos/Libro/Libro.xcodeproj", "VoiceRelay/VoiceRelay.xcodeproj"]), "Workspace must reference both current app paths")
let scheme = workspace.appendingPathComponent("xcshareddata/xcschemes/Build Both Apps.xcscheme")
require(Set(try referencedPaths(scheme, prefix: "container:")) == Set(projects), "Combined scheme and workspace project references differ")
for project in projects {
    let url = root.appendingPathComponent(project)
    require(manager.fileExists(atPath: url.path), "Missing project: \(project)")
    let data = try Data(contentsOf: url.appendingPathComponent("project.pbxproj"))
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    let objects = plist["objects"] as! [String: [String: Any]]
    let paths = objects.values.filter { $0["isa"] as? String == "XCLocalSwiftPackageReference" }.compactMap { $0["relativePath"] as? String }
    require(paths.count == 3, "Expected narration, presentation and app-core package references in \(project)")
    var sharedCount = 0
    for path in paths {
        let package = url.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
        require(manager.fileExists(atPath: package.appendingPathComponent("Package.swift").path), "Missing package manifest: \(package.path)")
        if package.path.hasPrefix(root.appendingPathComponent("swift-packages").path + "/") || package.path == root.appendingPathComponent("swift-packages").path {
            sharedCount += 1
        } else {
            let appCore = root.appendingPathComponent(project.hasPrefix("Libro/") ? "Libro/macos/LibroCore" : "VoiceRelay")
            require(package.path == appCore.path, "Unexpected app-core package reference")
        }
    }
    require(sharedCount == 2, "Both shared package references must resolve under swift-packages")
}
// Generate App Info sandbox input manifest: recursive inputs must be enabled,
// the whole repository root must not be a phase input, and every tracked
// immediate child of each GUI SRCROOT must be declared so git status can read
// the maintained worktree without build outputs entering the grant.
let phaseAppRoots: [String: String] = [
    "Libro/macos/Libro/Libro.xcodeproj": "Libro/macos/Libro",
    "VoiceRelay/VoiceRelay.xcodeproj": "VoiceRelay",
]
for (project, appRoot) in phaseAppRoots {
    let url = root.appendingPathComponent(project)
    let plist = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: url.appendingPathComponent("project.pbxproj")), format: nil) as! [String: Any]
    let objects = plist["objects"] as! [String: [String: Any]]
    let phases = objects.values.filter {
        $0["isa"] as? String == "PBXShellScriptBuildPhase" && ($0["name"] as? String) == "Generate App Info" }
    require(phases.count == 1, "expected one Generate App Info phase in \(project)")
    let inputs = (phases[0]["inputPaths"] as? [String] ?? [])
    require(!inputs.contains("$(NARRATION_REPOSITORY_ROOT)"), "repository root must not be a phase input")
    require(inputs.contains("$(NARRATION_REPOSITORY_ROOT)/.git"), "Git metadata input missing")
    let ls = Process()
    ls.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    ls.arguments = ["-C", root.path, "ls-files", "--", appRoot + "/"]
    let out = Pipe(); ls.standardOutput = out; ls.standardError = FileHandle.nullDevice
    try ls.run()
    let listing = out.fileHandleForReading.readDataToEndOfFile()
    ls.waitUntilExit()
    require(ls.terminationStatus == 0, "git ls-files failed for \(appRoot)")
    let children = Set(String(decoding: listing, as: UTF8.self)
        .split(separator: "\n").compactMap { line in
            let rest = line.dropFirst(appRoot.count + 1)
            return rest.contains("/") ? String(rest.prefix(while: { $0 != "/" })) : String(rest) })
    for child in children { require(inputs.contains("$(SRCROOT)/\(child)"), "undeclared source input \(appRoot)/\(child)") }
    let configs = objects.values.filter { $0["isa"] as? String == "XCBuildConfiguration" }
        .compactMap { $0["buildSettings"] as? [String: Any] }
        .filter { $0["MARKETING_VERSION"] != nil && $0["NARRATION_REPOSITORY_ROOT"] != nil }
    require(configs.count == 2, "expected Debug+Release versioned GUI configs in \(project)")
    for settings in configs {
        require(settings["USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES"] as? String == "YES",
                "recursive script inputs must be enabled")
        if let override = settings["ENABLE_USER_SCRIPT_SANDBOXING"] as? String {
            require(override == "YES", "script sandboxing must remain enabled")
        }
    }
}
for app in ["Libro", "VoiceRelay"] {
    require(!manager.fileExists(atPath: root.appendingPathComponent("\(app)/.git").path), "\(app) must use root Git history")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path, "ls-files", "--error-unmatch", "--", "\(app)/AGENTS.md"]
    process.standardOutput = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    require(process.terminationStatus == 0, "Root Git must track \(app) sources")
}
if !failures.isEmpty { failures.forEach { print($0) }; exit(1) }
print("Workspace layout: both projects/scheme, local packages and monorepo app sources passed.")
