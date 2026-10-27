import Foundation

public enum Reports {
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    public static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted(); guard !sorted.isEmpty else { return nil }
        let i = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[i - 1] + sorted[i]) / 2 : sorted[i]
    }
    public static func finalistTimeout(matrix: Matrix, attempts: [Attempt]) throws -> Double {
        var timeout = max(7200, matrix.timeoutSeconds)
        for profile in matrix.profiles {
            guard let attempt = attempts.last(where: { $0.profile.id == profile.id && $0.outcome == "completed" }) else { continue }
            let warm = attempt.measurements.filter { $0.state == "warm" }
            let perCharacter = warm.compactMap { value -> Double? in
                let length = value.chunks.joined().count
                return length > 0 ? value.requestSeconds / Double(length) : nil
            }.max() ?? 0
            let characters = matrix.passages.reduce(0) { $0 + $1.text.count }
            // A sizing estimate, not a performance promise: retain headroom for
            // long inputs and all warmups/repeats in the resident-model session.
            let estimate = (Double(characters) * perCharacter * Double(matrix.repetitions + 1) + (attempt.loadSeconds ?? 0)) * 1.5
            timeout = max(timeout, estimate.rounded(.up))
        }
        guard timeout <= 86400 else { throw BenchError("Estimated finalist session exceeds one day; reduce the matrix explicitly") }
        return timeout
    }
    public static func attempts(_ root: URL) throws -> [Attempt] {
        guard let files = FileManager.default.enumerator(at: root.appendingPathComponent("attempts"), includingPropertiesForKeys: nil) else { return [] }
        return try files.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "attempt.json" }.map { try Files.read(Attempt.self, $0) }.sorted { $0.started < $1.started }
    }
    public static func summary(root: URL, matrix: Matrix, attempts: [Attempt]) throws {
        var markdown = "# TTS model benchmark\n\nPerformance evidence only. Listening preferences are not inferred. RTF is elapsed generation time / audio duration; lower is faster. No gain or normalization.\n\n"
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("sources.json").path) {
            markdown += "Derived comparison: [source run receipts](sources.json) and per-source build/environment evidence in `provenance/`. All original attempts, including failures, remain in `results.json`. A corrected profile may supersede a failed configuration; no successful take is replaced. Session order is not counterbalanced.\n\n"
        }
        markdown += "| Model / voice | Outcome | Warm RTF median (range; n) | Load seconds | Peak worker tree GiB | Notes |\n| --- | --- | --- | --- | --- | --- |\n"
        for p in matrix.profiles {
            let rows = attempts.filter { $0.profile.id == p.id }
            guard let latest = rows.last else { markdown += "| \(p.label) | not-run | — | — | — | — |\n"; continue }
            let warm = latest.measurements.filter { $0.state == "warm" }.map(\.rtf)
            let stats = median(warm).map { String(format: "%.4f (%.4f–%.4f; %d)", $0, warm.min()!, warm.max()!, warm.count) } ?? "—"
            let load = latest.loadSeconds.map { String(format: "%.2f", $0) } ?? "—"
            let reason = (latest.reason ?? "").replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ")
            markdown += "| \(p.label) | \(latest.outcome) | \(stats) | \(load) | \(String(format: "%.2f", Double(latest.workerPeakBytes) / 1073741824)) | \(reason) |\n"
        }
        markdown += "\n## Warm throughput and delivery\n\nEach row is one model/voice and passage. Words/s and characters/s describe input processed per inference second; spoken words/minute uses input words divided by output duration, so omissions still require listening.\n\n| Model / voice | Passage | Audio seconds (median) | Input words/s | Input characters/s | Estimated spoken words/min | First PCM seconds (median) | Admission wait seconds (total) |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n"
        for p in matrix.profiles {
            guard let attempt = attempts.last(where: { $0.profile.id == p.id }) else { continue }
            for passage in matrix.passages {
                let values = attempt.measurements.filter { $0.state == "warm" && $0.passage == passage.id }
                guard let seconds = median(values.map(\.seconds)), seconds > 0, let duration = median(values.map(\.duration)) else { continue }
                let words = Double(passage.text.split(whereSeparator: \.isWhitespace).count)
                let first = median(values.compactMap(\.firstPCMSeconds)).map { String(format: "%.3f", $0) } ?? "unobserved"
                markdown += "| \(p.label) | \(passage.id) | \(String(format: "%.2f", duration)) | \(String(format: "%.2f", words / seconds)) | \(String(format: "%.2f", Double(passage.text.count) / seconds)) | \(String(format: "%.1f", words * 60 / duration)) | \(first) | \(String(format: "%.3f", values.reduce(0) { $0 + $1.admissionSeconds })) |\n"
            }
        }
        let unsuccessful = attempts.filter { $0.outcome != "completed" }
        if !unsuccessful.isEmpty {
            markdown += "\n## Retained unsuccessful attempts\n\n| Attempt | Model / voice | Outcome | Recorded language | Recordings | Reason |\n| --- | --- | --- | --- | --- | --- |\n"
            for attempt in unsuccessful {
                let reason = (attempt.reason ?? "").replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ")
                markdown += "| \(attempt.id) | \(attempt.profile.label) | \(attempt.outcome) | \(attempt.profile.language ?? "unspecified") | \(attempt.measurements.count) | \(reason) |\n"
            }
        }
        markdown += "\nCold means fresh process with unspecified filesystem-cache warmth. Worker physical footprint is sampled every 20 ms and includes descendants; MLX allocator peaks and host footprint are separate evidence fields. Admission wait and WAV writes are separate from model-call time. Incomplete and failed attempts retain diagnostics and are not quality successes. Repetitions are not independent model/voice listening entrants. Session order is seeded, not counterbalanced; power/thermal metadata is a starting snapshot, not continuous interference monitoring.\n"
        try Data(markdown.utf8).write(to: root.appendingPathComponent("summary.md"), options: .atomic)
        try Files.write(attempts, root.appendingPathComponent("results.json"))
    }
    public static func entrants(root: URL, matrix: Matrix, attempts: [Attempt]) throws -> [Entrant] {
        let calibration = Set(matrix.passages.filter { $0.role == "calibration" }.map(\.id))
        var result: [Entrant] = []
        for p in matrix.profiles where !p.productReference {
            guard let attempt = attempts.last(where: { $0.profile.id == p.id && $0.outcome == "completed" }) else { continue }
            let samples = attempt.measurements.filter { $0.state == "warm" && $0.repetition == 1 }
            guard calibration.isSubset(of: Set(samples.map(\.passage))), !result.contains(where: { $0.identity == p.listeningIdentity }) else { continue }
            var clips: [String: String] = [:], hashes: [String: String] = [:]
            for sample in samples {
                let path = "attempts/\(attempt.id)/\(sample.wav)"
                guard try Files.hash(Files.child(root, path)) == sample.sha256 else { throw BenchError("Listening sample changed") }
                clips[sample.passage] = path; hashes[sample.passage] = sample.sha256
            }
            result.append(Entrant(id: p.id, label: p.label, identity: p.listeningIdentity, clips: clips, hashes: hashes))
        }
        return result
    }
    private static let style = "body{font:17px system-ui;max-width:850px;margin:2em auto;padding:0 1em;line-height:1.5}audio{display:block;width:100%;margin:1em 0}section{padding:1em 0;border-top:1px solid #8885}pre{white-space:pre-wrap}button{font:inherit;margin:.3em;padding:.4em}textarea{width:100%}"
    public static func bracketPage(_ bracket: Bracket, matrix: Matrix, root: URL) throws {
        try WebBracket.page(bracket, matrix: matrix, root: root)
    }
    public static func blindPack(_ bracket: Bracket, matrix: Matrix, root: URL) throws {
        let ids = try bracket.shortlist()
        guard ids.count >= 2 else { throw BenchError("Blind confirmation requires two finalists") }
        let directory = root.appendingPathComponent("blind")
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw BenchError("Blind pack already exists; preserve it or use a new run") }
        let passages = matrix.passages.filter { $0.role == "heldout" || $0.role == "longform" }
        guard !passages.isEmpty else { throw BenchError("No held-out passages") }
        // Validate everything before creating a partial pack.
        for id in ids {
            guard let e = bracket.entrants.first(where: { $0.id == id }) else { throw BenchError("Unknown finalist") }
            for p in passages {
                guard let clip = e.clips[p.id], let hash = e.hashes[p.id], try Files.hash(Files.child(root, clip)) == hash else { throw BenchError("Missing/changed held-out audio for \(e.label)") }
            }
        }
        let staging = root.appendingPathComponent(".blind-staging-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var rng = SplitMix(seed: bracket.seed ^ 0xB11D), mapping: [[String: String]] = [], body = "<h1>Blind finalist comparison</h1><p>New passages; identities and bracket places hidden. No level adjustment. Choose A, B, same or neither, and note prosody, wrong/repeated words, pacing and fatigue.</p>", ratings = "# Blind finalist ratings\n\nRecord playback volume changes. No normalization or gain.\n\n"
        var pair = 0
        for i in ids.indices { for j in ids.indices where j > i { for passage in passages {
            pair += 1
            var sides = [ids[i], ids[j]]; if rng.next() & 1 == 1 { sides.reverse() }
            body += "<section><h2>Pair \(pair)</h2>"
            for (offset, id) in sides.enumerated() {
                let e = bracket.entrants.first { $0.id == id }!, label = offset == 0 ? "A" : "B"
                let name = "pair-\(pair)-\(label).wav"
                try FileManager.default.copyItem(at: Files.child(root, e.clips[passage.id]!), to: staging.appendingPathComponent(name))
                body += "<p>\(label)</p><audio controls preload=\"none\" src=\"\(name)\"></audio>"
                mapping.append(["pair": String(pair), "side": label, "entrant": id, "passage": passage.id, "sha256": e.hashes[passage.id]!])
            }
            body += "<details><summary>Text</summary><pre>\(escape(passage.text))</pre></details></section>"
            ratings += "## Pair \(pair)\n\nPreference: A / B / same / neither / unassessed\n\nNaturalness, phrasing, pronunciation, pacing, consistency, fatigue:\n\nVolume change:\n\n"
        } } }
        try Data("<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>Blind narration</title><style>\(style)</style>\(body)</html>".utf8).write(to: staging.appendingPathComponent("index.html"))
        try Data(ratings.utf8).write(to: staging.appendingPathComponent("ratings.md"))
        try Files.write(mapping, root.appendingPathComponent("unblind.json"))
        try FileManager.default.moveItem(at: staging, to: directory)
    }
}
