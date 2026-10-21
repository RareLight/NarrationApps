import AppKit

/// Per-analysis, bounded use of the platform English spelling dictionary.
final class DocumentWordLexicon {
    private var checker: NSSpellChecker?
    private var cache: [String: Bool] = [:]
    func contains(_ value: String) -> Bool {
        let key = value.lowercased()
        if let result = cache[key] { return result }
        if checker == nil { checker = NSSpellChecker() }
        let result = checker!.checkSpelling(of: key, startingAt: 0, language: "en_US", wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        if cache.count < 10_000 { cache[key] = result }
        return result
    }
}
