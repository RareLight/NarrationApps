import Foundation

public struct BracketProgress: Codable, Sendable {
    public var version: Int = 1
    public var runID: String
    public var sourceRevision: String
    public var decisions: [Vote]
    public var history: [Vote]
    public var retained: [String]
}

/// The web page contains anonymous aliases only. Model identities stay in a
/// separate file, explicitly selected by the operator after the bracket finishes.
public enum WebBracket {
    struct Participant: Codable {
        var id: String
        var label: String
        var clips: [String: String]
    }
    struct Seed: Codable {
        var version = 1
        var runID: String
        var sourceRevision: String
        var participants: [Participant]
        var passages: [Passage]
        var progress: BracketProgress
    }
    struct Identities: Codable {
        var version = 1
        var runID: String
        var names: [String: String]
    }
    struct ImportReceipt: Codable {
        var runID: String
        var sourceRevision: String
        var currentHash: String
    }
    public static func resource(_ name: String, extension ext: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else { throw BenchError("Missing bracket web resource") }
        return try String(contentsOf: url, encoding: .utf8)
    }
    static func alias(_ index: Int) -> String { String(format: "voice-%03d", index + 1) }
    static func runID(_ bracket: Bracket, _ matrix: Matrix) throws -> String {
        Files.hash(String(decoding: try Files.encoder.encode(matrix), as: UTF8.self) + String(decoding: try Files.encoder.encode(bracket.entrants), as: UTF8.self))
    }
    public static func page(_ bracket: Bracket, matrix: Matrix, root: URL) throws {
        let identity = try runID(bracket, matrix)
        let source = try Files.hash(root.appendingPathComponent("bracket.json"))
        let passages = matrix.passages.filter { $0.role == "calibration" }
        guard !passages.isEmpty else { throw BenchError("No calibration passages") }
        var participants: [Participant] = [], names: [String: String] = [:], retained: [String] = []
        let rejected = try bracket.view().rejected
        let audio = root.appendingPathComponent("bracket-audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        for (index, entrant) in bracket.entrants.enumerated() {
            let id = alias(index)
            var clips: [String: String] = [:]
            for passage in passages {
                guard let path = entrant.clips[passage.id], let hash = entrant.hashes[passage.id],
                      try Files.hash(Files.child(root, path)) == hash else { throw BenchError("Missing/changed bracket audio") }
                let relative = "bracket-audio/\(hash).wav"
                let destination = try Files.child(root, relative)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: Files.child(root, path), to: destination)
                }
                guard try Files.hash(destination) == hash else { throw BenchError("Changed anonymous audio copy") }
                clips[passage.id] = relative
            }
            participants.append(Participant(id: id, label: String(format: "Voice %02d", index + 1), clips: clips))
            names[id] = entrant.label
            if bracket.retained.contains(entrant.id), !rejected.contains(entrant.id) { retained.append(id) }
        }
        let progress = BracketProgress(runID: identity, sourceRevision: source, decisions: bracket.decisions, history: bracket.history, retained: retained)
        let seed = Seed(runID: identity, sourceRevision: source, participants: participants, passages: passages, progress: progress)
        // Escaping '<' prevents a note/passage containing </script> from ending
        // the inert JSON element. UI rendering uses textContent, never innerHTML.
        let json = String(decoding: try Files.encoder.encode(seed), as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
        var html = try resource("bracket-template", extension: "html")
        html = html.replacingOccurrences(of: "/*__STYLE__*/", with: try resource("style", extension: "css"))
            .replacingOccurrences(of: "/*__ENGINE__*/", with: try resource("engine", extension: "js"))
            .replacingOccurrences(of: "/*__APP__*/", with: try resource("app", extension: "js"))
            .replacingOccurrences(of: "__SEED_JSON__", with: json)
        try Data(html.utf8).write(to: root.appendingPathComponent("bracket.html"), options: .atomic)
        try Files.write(Identities(runID: identity, names: names), root.appendingPathComponent("bracket-identities.json"))
    }
    /// Validate a browser export against the same Swift tournament engine before
    /// updating canonical state. Caller owns host.lock, like choose/revise.
    public static func importProgress(_ data: Data, root: URL, matrix: Matrix, bracket: Bracket) throws -> Bracket {
        guard data.count <= 4_000_000 else { throw BenchError("Progress file too large") }
        let input = try JSONDecoder().decode(BracketProgress.self, from: data)
        guard input.version == 1, input.runID == (try runID(bracket, matrix)), input.sourceRevision.count == 64,
              input.history.count <= 10000, input.decisions.count <= 10000 else { throw BenchError("Progress belongs to a different bracket or version") }
        var replay = bracket
        replay.decisions = []; replay.history = []; replay.retained = []
        var revision: Vote?
        for vote in input.history {
            guard vote.note.count <= (vote.choice == "revision" ? 4100 : 4000), vote.at.count <= 64 else { throw BenchError("Invalid progress note/date") }
            if vote.choice == "revision" {
                guard revision == nil else { throw BenchError("Unfinished revision") }
                revision = vote; continue
            }
            guard revision == nil || revision?.match == vote.match else { throw BenchError("Revision target changed") }
            try replay.answer(match: vote.match, choice: vote.choice, note: vote.note, revise: revision != nil)
            replay.decisions[replay.decisions.count - 1].at = vote.at
            replay.history[replay.history.count - 1].at = vote.at
            if let previous = revision {
                let index = replay.history.count - 2
                guard replay.history[index].note == previous.note else { throw BenchError("Invalid revision history") }
                replay.history[index].at = previous.at
            }
            revision = nil
        }
        guard revision == nil, try Files.encoder.encode(replay.decisions) == Files.encoder.encode(input.decisions) else { throw BenchError("Progress/history disagree") }
        guard Set(input.retained).count == input.retained.count else { throw BenchError("Duplicate retained voice") }
        for id in input.retained {
            guard let index = bracket.entrants.indices.first(where: { alias($0) == id }),
                  !(try replay.view().rejected).contains(bracket.entrants[index].id) else { throw BenchError("Invalid retained voice") }
            replay.retained.append(bracket.entrants[index].id)
        }
        let file = root.appendingPathComponent("bracket.json"), receiptFile = root.appendingPathComponent("bracket-web-import.json")
        let current = try Files.hash(file), next = Files.hash(String(decoding: try Files.encoder.encode(replay), as: UTF8.self))
        let receipt = try? Files.read(ImportReceipt.self, receiptFile)
        guard current == input.sourceRevision || current == next ||
              (receipt?.runID == input.runID && receipt?.sourceRevision == input.sourceRevision && receipt?.currentHash == current) else {
            throw BenchError("Canonical bracket changed since this page was generated; export a fresh page before replacing choices")
        }
        if current != next {
            let snapshot = try Files.child(root, "bracket-import-history/\(current).json")
            try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: snapshot.path) {
                guard try Files.hash(snapshot) == current else { throw BenchError("Changed import-history snapshot") }
            } else { try FileManager.default.copyItem(at: file, to: snapshot) }
        }
        try Files.write(replay, file)
        try Files.write(ImportReceipt(runID: input.runID, sourceRevision: input.sourceRevision, currentHash: next), receiptFile)
        return replay
    }
}
