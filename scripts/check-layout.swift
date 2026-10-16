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
for app in ["Libro", "VoiceRelay"] {
    require(manager.fileExists(atPath: root.appendingPathComponent("\(app)/.git").path), "\(app) must retain independent Git history")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path, "check-ignore", "-q", app + "/"]
    try process.run(); process.waitUntilExit()
    require(process.terminationStatus == 0, "Root Git must ignore \(app)/")
}
if !failures.isEmpty { failures.forEach { print($0) }; exit(1) }
print("Workspace layout: both projects/scheme, local packages and independent ignored app repositories passed.")
