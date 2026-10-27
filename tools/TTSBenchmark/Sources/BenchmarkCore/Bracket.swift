import Foundation

public struct Entrant: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var identity: String
    public var clips: [String: String]
    public var hashes: [String: String]
    public init(id: String, label: String, identity: String, clips: [String: String], hashes: [String: String]) {
        self.id = id; self.label = label; self.identity = identity; self.clips = clips; self.hashes = hashes
    }
}
public struct Vote: Codable, Sendable {
    public var match: String
    public var choice: String
    public var note: String
    public var at: String = ISO8601DateFormatter().string(from: Date())
    public init(match: String, choice: String, note: String = "") { self.match = match; self.choice = choice; self.note = note }
}
public struct Match: Codable, Equatable, Sendable {
    public var id: String
    public var stage: String
    public var a: String
    public var b: String
    public var passageOffset: Int
}
public struct BracketView: Codable, Sendable {
    public var pending: Match?
    public var matches: [Match]
    public var byes: [String]
    public var champion: String?
    public var runnerUp: String?
    public var eliminated: [String]
    public var rejected: [String]
    public var losses: [String: Int]
}
public struct Bracket: Codable, Sendable {
    public var version = 1
    public var seed: UInt64
    public var entrants: [Entrant]
    public var decisions: [Vote] = []
    public var history: [Vote] = []
    public var retained: [String] = []
    public init(entrants: [Entrant], seed: UInt64) throws {
        guard !entrants.isEmpty, Set(entrants.map(\.id)).count == entrants.count,
              Set(entrants.map(\.identity)).count == entrants.count else { throw BenchError("Duplicate/empty listening roster") }
        self.seed = seed; var rng = SplitMix(seed: seed); self.entrants = entrants.shuffled(using: &rng)
    }
    public func view() throws -> BracketView {
        guard version == 1 else { throw BenchError("Unknown bracket version") }
        var view = BracketView(pending: nil, matches: [], byes: [], champion: nil, runnerUp: nil,
                               eliminated: [], rejected: [], losses: Dictionary(uniqueKeysWithValues: entrants.map { ($0.id, 0) }))
        var number = 0
        // nil means a human choice is still needed; [] means both were rejected.
        func play(_ a: String, _ b: String, stage: String) throws -> [String]? {
            number += 1
            guard number < 10000 else { throw BenchError("Invalid bracket progression") }
            let id = String(format: "match-%03d", number)
            let votes = decisions.filter { $0.match == id }
            let match = Match(id: id, stage: stage, a: a, b: b, passageOffset: votes.filter { $0.choice == "tie" }.count)
            view.matches.append(match)
            guard let vote = votes.last, ["a", "b", "neither"].contains(vote.choice) else { view.pending = match; return nil }
            if vote.choice == "neither" { view.rejected += [a, b]; return [] }
            let winner = vote.choice == "a" ? a : b, loser = vote.choice == "a" ? b : a
            view.losses[loser, default: 0] += 1
            if view.losses[loser] == 2 { view.eliminated.append(loser) }
            return [winner, loser]
        }
        var winners = entrants.map(\.id), losers: [String] = []
        while winners.count > 1 {
            var next: [String] = []
            for offset in stride(from: 0, to: winners.count, by: 2) {
                if offset + 1 == winners.count { next.append(winners[offset]); view.byes.append(winners[offset]); continue }
                guard let outcome = try play(winners[offset], winners[offset + 1], stage: "winners") else { return view }
                if outcome.count == 2 { next.append(outcome[0]); losers.append(outcome[1]) }
            }
            winners = next
        }
        while losers.count > 1 {
            var next: [String] = []
            for offset in stride(from: 0, to: losers.count, by: 2) {
                if offset + 1 == losers.count { next.append(losers[offset]); view.byes.append(losers[offset]); continue }
                guard let outcome = try play(losers[offset], losers[offset + 1], stage: "consolation") else { return view }
                if outcome.count == 2 { next.append(outcome[0]) }
            }
            losers = next
        }
        if let w = winners.first, let l = losers.first {
            guard let final = try play(w, l, stage: "grand-final") else { return view }
            guard final.count == 2 else { return view }
            if final[0] == l {
                guard let reset = try play(w, l, stage: "final-reset") else { return view }
                if reset.count == 2 { view.champion = reset[0]; view.runnerUp = reset[1] }
            } else { view.champion = w; view.runnerUp = l }
        } else { view.champion = winners.first ?? losers.first }
        return view
    }
    public mutating func answer(match id: String, choice: String, note: String = "", revise: Bool = false) throws {
        guard ["a", "b", "tie", "neither", "defer"].contains(choice) else { throw BenchError("Choice must be a, b, tie, neither or defer") }
        let current = try view()
        if revise {
            guard let index = current.matches.firstIndex(where: { $0.id == id }) else { throw BenchError("Unknown match") }
            let invalidated = Set(current.matches[index...].map(\.id))
            decisions.removeAll { invalidated.contains($0.match) }
            history.append(Vote(match: id, choice: "revision", note: "Dependent decisions invalidated. " + note))
        }
        guard try view().pending?.id == id else { throw BenchError("Only the pending match can receive a choice") }
        let vote = Vote(match: id, choice: choice, note: note)
        decisions.append(vote); history.append(vote)
    }
    public func shortlist() throws -> [String] {
        let v = try view()
        guard v.pending == nil else { throw BenchError("Preference bracket is unfinished") }
        var ids: [String] = []
        for id in [v.champion, v.runnerUp].compactMap({ $0 }) + v.eliminated.reversed() {
            if !ids.contains(id) && !v.rejected.contains(id) { ids.append(id) }
            if ids.count == 4 { break }
        }
        for id in retained where !ids.contains(id) && !v.rejected.contains(id) { ids.append(id) }
        return ids
    }
}
