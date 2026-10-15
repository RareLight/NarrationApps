import Foundation
import CryptoKit

// Developer evidence only. Consumes isolated native-check output; never reads
// model caches or changes app resources, recordings, playback level or PCM.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 else { fatalError("Usage: swift scripts/make-longform-report.swift EVIDENCE_ROOT") }
let root = URL(fileURLWithPath: arguments[0]).standardizedFileURL
let output = root.appendingPathComponent("listening")
let manager = FileManager.default
try manager.createDirectory(at: output, withIntermediateDirectories: true)
func object(_ file: URL) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
    return value
}
let directories = ["baseline/corpus", "verified-misaki-correctness-candidate-1", "verified-phoneme-200-candidate-1", "verified-phoneme-200-pauses-candidate-1"]
var manifests: [[String: Any]] = []
for directory in directories {
    let manifest = try object(root.appendingPathComponent(directory + "/manifest.json"))
    guard let results = manifest["results"] as? [[String: Any]], results.count == 12,
          manifest["offline"] as? Bool == true, manifest["normalization"] as? Bool == false else { throw CocoaError(.fileReadCorruptFile) }
    manifests.append(manifest)
}
struct Selection { let profile: Int; let voice: String; let speed: Double }
func record(_ selection: Selection) throws -> [String: Any] {
    let values = manifests[selection.profile]["results"] as! [[String: Any]]
    guard let value = values.first(where: { $0["voice"] as? String == selection.voice && abs(($0["speed"] as? Double ?? 0) - selection.speed) < 0.0001 && $0["repetition"] as? Int == 1 }) else { throw CocoaError(.fileReadCorruptFile) }
    return value
}
func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
var pairs: [[String: Any]] = []
var cards = "", ratings = "# Longform listening ratings\n\nKeep a comfortable playback volume. No clips were leveled or normalized. Record any manual playback-volume changes separately.\n\n"
func pair(_ title: String, first: Selection, second: Selection) throws {
    let number = pairs.count + 1
    let reverse = Array(SHA256.hash(data: Data("longform-neutral-1/\(number)".utf8)))[0] % 2 == 0
    let selections = reverse ? [second, first] : [first, second]
    var entries: [[String: Any]] = []
    var controls = ""
    for (offset, selection) in selections.enumerated() {
        let label = offset == 0 ? "A" : "B"
        let item = try record(selection)
        let sourceDirectory = root.appendingPathComponent(directories[selection.profile])
        let file = "pair-\(number)-\(label).m4a"
        let destination = output.appendingPathComponent(file)
        guard !manager.fileExists(atPath: destination.path), let audio = item["aac"] as? String else { throw CocoaError(.fileWriteFileExists) }
        try manager.copyItem(at: sourceDirectory.appendingPathComponent(audio), to: destination)
        controls += "<div><strong>\(label)</strong> <audio controls preload=\"none\" src=\"\(file)\"></audio></div>"
        entries.append(["label": label, "profileDirectory": directories[selection.profile], "sourceAAC": audio,
            "sourceWAV": item["wav"] as? String ?? "", "voice": selection.voice, "speed": selection.speed,
            "wavSHA256": item["wavSHA256"] as? String ?? "", "policy": item["policy"] as? String ?? "captured-baseline"])
    }
    pairs.append(["pair": number, "title": title, "choices": entries])
    cards += "<section><h2>Pair \(number): \(escape(title))</h2>\(controls)</section>"
    ratings += "## Pair \(number): \(title)\n\nPreferred: A / B / same / neither\n\nWrong words or pronunciation:\n\nOmitted/repeated speech:\n\nClause continuity, paragraph/section gaps, rushing:\n\nVoice consistency, fatigue and other notes:\n\nManual playback-volume change (if any):\n\n"
}
for (voice, name, speed) in [("af_heart", "Heart", 1.1), ("am_michael", "Michael", 1.0), ("bf_emma", "Emma", 1.0)] {
    for stage in 0..<3 {
        try pair("\(name), matched speed, comparison \(stage + 1)", first: .init(profile: stage, voice: voice, speed: speed), second: .init(profile: stage + 1, voice: voice, speed: speed))
    }
    try pair("\(name), speed comparison", first: .init(profile: 3, voice: voice, speed: 1), second: .init(profile: 3, voice: voice, speed: 1.1))
}
let corpus = try object(root.appendingPathComponent("../../Tests/Fixtures/Longform/corpus.json").standardizedFileURL)
let prose = (corpus["blocks"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n\n")
let html = """
<!doctype html><html lang="en"><meta charset="utf-8"><title>Longform listening comparison</title>
<meta name="viewport" content="width=device-width,initial-scale=1"><style>
:root{color-scheme:light dark}body{font:16px system-ui;max-width:850px;margin:32px auto;padding:0 20px;line-height:1.5}h1{font-size:28px}h2{font-size:19px}section{border-top:1px solid #8886;padding:14px 0}section div{display:flex;align-items:center;gap:16px;margin:10px 0}audio{width:min(100%,650px)}pre{white-space:pre-wrap;font:inherit}a{color:LinkText}
</style><h1>Longform listening comparison</h1>
<p>Start with Heart’s first three pairs. Each pair contains the same complete synthetic passage; speed comparisons are marked. A/B ordering is fixed and neutral. Clips use mono AAC-LC, 64 kbps at 24 kHz. No normalization, gain, leveling, trimming or crossfade was applied. Original Float32 WAVs and repeat renders remain in the evidence folders.</p>
<p>Use <a href="ratings.md">the rating sheet</a>. Choose A, B, same or neither for each pair you assess. Note wrong words, omissions, repeated speech, clause continuity, paragraph/section pacing, rushing and fatigue. Keep playback volume comfortable; record manual changes separately.</p>
<p>New-installation speed is a separate decision. Existing Libro 1.1× and VoiceRelay 1.0× preferences remain unchanged. The candidate is not activated in the apps.</p>
<details><summary>Passage text</summary><pre>\(escape(prose))</pre></details>
\(cards)
<details><summary>Unblind after listening</summary><a href="labels.json">Configuration and source mapping</a></details></html>
"""
try Data(html.utf8).write(to: output.appendingPathComponent("index.html"), options: .atomic)
try Data(ratings.utf8).write(to: output.appendingPathComponent("ratings.md"), options: .atomic)
try JSONSerialization.data(withJSONObject: ["version": 1, "normalization": false, "pairs": pairs], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("labels.json"), options: .atomic)
print("Created \(pairs.count) neutral A/B pairs in \(output.path)")
