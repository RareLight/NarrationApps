#!/usr/bin/swift
import Foundation

// Local source-document links only: no network, credentials or application data.
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath).standardizedFileURL
let manager = FileManager.default
func matches(_ pattern: String, _ text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
        Range($0.range(at: 1), in: text).map { String(text[$0]) }
    }
}
func anchors(_ url: URL) -> Set<String> {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var counts: [String: Int] = [:], results: Set<String> = []
    for heading in matches("^#{1,6}\\s+(.+)$", text) {
        let cleaned = heading.replacingOccurrences(of: "[`*_]", with: "", options: .regularExpression).lowercased()
        let slug = cleaned.replacingOccurrences(of: "[^\\p{L}\\p{N}_ -]", with: "", options: .regularExpression).replacingOccurrences(of: " ", with: "-")
        let count = counts[slug, default: 0]; counts[slug] = count + 1
        results.insert(slug + (count == 0 ? "" : "-\(count)"))
    }
    return results
}
var files = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "md" } ?? []
for directory in ["docs", "Acknowledgements"] {
    if let enumerator = manager.enumerator(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil) {
        files += enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }
    }
}
var errors: [String] = [], count = 0
for source in files.sorted(by: { $0.path < $1.path }) {
    let text = try String(contentsOf: source, encoding: .utf8)
    for target in matches("(?<!!)\\[[^\\]\\n]+\\]\\(([^\\s)]+)\\)", text) {
        if target.range(of: "^[a-zA-Z]+:", options: .regularExpression) != nil { continue }
        let decoded = target.trimmingCharacters(in: CharacterSet(charactersIn: "<>")).removingPercentEncoding ?? target
        let parts = decoded.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        var base = source.deletingLastPathComponent()
        // This upstream notice retains its original relative references.
        if source.lastPathComponent == "SwiftReadability-THIRD-PARTY-NOTICES.md" {
            base = root.appendingPathComponent(".build/checkouts/swift-readability")
        }
        let resolved = parts[0].isEmpty ? source : base.appendingPathComponent(String(parts[0])).standardizedFileURL
        count += 1
        if !manager.fileExists(atPath: resolved.path) { errors.append("\(source.lastPathComponent): missing \(target)") }
        else if parts.count == 2 && !parts[1].isEmpty && resolved.pathExtension == "md" && !anchors(resolved).contains(String(parts[1])) {
            errors.append("\(source.lastPathComponent): missing anchor \(target)")
        }
    }
}
print("Checked \(files.count) Markdown files and \(count) local links/anchors.")
errors.forEach { print($0) }
exit(errors.isEmpty ? 0 : 1)
