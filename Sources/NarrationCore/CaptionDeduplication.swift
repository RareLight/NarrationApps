import Foundation

/// Suppress a repeated description only when source association is reliable.
/// Distinct figures with equal wording and uncertain PDF caption matches remain.
public enum CaptionDeduplication {
    public static func suppressedIndices(in blocks: [ContentBlock]) -> Set<Int> {
        var suppressed = Set<Int>()
        var described: [URL: Set<String>] = [:]
        var previous: (index: Int, text: String)?
        for (index, block) in blocks.enumerated() {
            guard block.kind == .caption else { previous = nil; continue }
            let text = NarrationText.normalizeWhitespace(block.narrationText ?? block.text)
                .replacingOccurrences(of: #"^Image description:\s*"#, with: "", options: .regularExpression)
                .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            guard !text.isEmpty else { continue }
            if let url = block.imageURL {
                if !described[url, default: []].insert(text).inserted { suppressed.insert(index) }
            }
            if let previous {
                let prior = blocks[previous.index]
                let samePage = prior.pdfPageIndex == block.pdfPageIndex
                let distinctImages = prior.imageURL != nil && block.imageURL != nil && prior.imageURL != block.imageURL
                if previous.text == text, samePage, !distinctImages { suppressed.insert(index) }
            }
            previous = (index, text)
        }
        return suppressed
    }
}
