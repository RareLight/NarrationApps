import Foundation

/// Private extraction evidence, not an estimate of audio duration or model quality.
public struct ArticleDuplicateEvidence: Codable, Sendable {
    public let title: String
    public let readableCharacters: Int
    public let readable: Bool

    init(entry: ReadingListEntry, review: ReviewedSource?) {
        title = review?.document?.article.title ?? entry.title
        readable = review?.issue == nil && review?.narration?.chunks.isEmpty == false
        readableCharacters = review?.document?.article.blocks.filter {
            [.paragraph, .listItem, .quote].contains($0.kind) && $0.imageURL == nil
        }.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).joined(separator: " ").count } ?? 0
    }
}

/// Match exact normalized titles within the original website, or the same source URL.
/// Save/publication dates rank comparable copies; they never form part of a match.
enum ArticleDuplicates {
    static func title(_ text: String) -> String? {
        let value = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !value.isEmpty, !["untitled", "untitled article", "saved fixture"].contains(value) else { return nil }
        return value
    }
    static func host(_ host: String?) -> String? {
        guard var value = host?.lowercased(), !value.isEmpty else { return nil }
        while value.hasSuffix(".") { value.removeLast() }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        return value
    }
    static func source(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        return parts?.url?.absoluteString ?? url.absoluteString
    }
    static func matches(title a: String, host ah: String?, title b: String, host bh: String?) -> Bool {
        guard let a = title(a), let b = title(b), let ah = host(ah), let bh = host(bh) else { return false }
        return a == b && ah == bh
    }
    static func groups(_ entries: [ReadingListEntry], evidence: [String: ArticleDuplicateEvidence]) -> [[ReadingListEntry]] {
        // Union by either key; an extracted headline can bridge different Reading List titles.
        var parent = Array(entries.indices), owners: [String: Int] = [:]
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { i = parent[i] }; return i }
        for (i, entry) in entries.enumerated() {
            var keys = ["url:" + source(entry.url)]
            if let host = host(entry.url.host) {
                for text in [entry.title, evidence[entry.id]?.title].compactMap({ $0 }) {
                    if let title = title(text) { keys.append("title:" + host + "\n" + title) }
                }
            }
            for key in keys {
                if let owner = owners[key] { parent[root(i)] = root(owner) }
                else { owners[key] = i }
            }
        }
        var groups: [[ReadingListEntry]] = [], indexes: [Int: Int] = [:]
        for (i, entry) in entries.enumerated() {
            let key = root(i)
            if let index = indexes[key] { groups[index].append(entry) }
            else { indexes[key] = groups.count; groups.append([entry]) }
        }
        return groups
    }
    static func winner(_ entries: [ReadingListEntry], evidence: [String: ArticleDuplicateEvidence]) -> ReadingListEntry? {
        guard entries.allSatisfy({ evidence[$0.id] != nil }) else { return nil }
        let readable = entries.filter { evidence[$0.id]?.readable == true }
        let longest = readable.map { evidence[$0.id]!.readableCharacters }.max() ?? 0
        // Within 5% of the fullest text, recency wins. Tiny extraction differences
        // should not outweigh a newer save of substantially identical prose.
        return readable.filter { Double(evidence[$0.id]!.readableCharacters) >= Double(longest) * 0.95 }
            .sorted {
                if $0.addedAt != $1.addedAt { return ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
                return $0.id < $1.id
            }.first
    }
}
