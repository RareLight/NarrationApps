import Foundation
import Pronunciation

enum SpokenWebAddresses {
    static let versionSuffix = "/web-addresses-2"
    static let rule = "web-address-2"
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let digits = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
    private static let hostCharacters = CharacterSet.alphanumerics.union(.nonBaseCharacters)
        .union(CharacterSet(charactersIn: ".-_:[]"))

    static func edits(in application: PronunciationApplicationResult, remaining: Int) throws -> [ProjectionEdit] {
        let text = application.text, ns = text as NSString
        guard let detector, text.range(of: "://") != nil || text.range(of: "www.", options: .caseInsensitive) != nil else { return [] }
        var edits: [ProjectionEdit] = [], failure: Error?
        var cursor = 0, inCode = false, userIndex = 0
        detector.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            if Task.isCancelled { stop.pointee = true; return }
            guard let match else { return }
            do { try NarrationWorkCheckpoint.check() }
            catch { failure = error; stop.pointee = true; return }
            let range = match.range
            let prefix = ns.substring(with: NSRange(location: range.location, length: min(8, range.length))).lowercased()
            guard prefix.hasPrefix("https://") || prefix.hasPrefix("http://") || prefix.hasPrefix("www.") else { return }
            while cursor < range.location {
                let tick = ns.range(of: "`", options: .literal, range: NSRange(location: cursor, length: range.location - cursor))
                guard tick.location != NSNotFound else { break }
                inCode.toggle(); cursor = NSMaxRange(tick)
            }
            cursor = range.location
            guard !inCode, let url = match.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let host = components.host, !host.isEmpty, host.utf8.count <= 512,
                  host.unicodeScalars.allSatisfy(hostCharacters.contains) else { return }
            while userIndex < application.applications.count && application.applications[userIndex].spokenLocation + application.applications[userIndex].spokenLength <= range.location { userIndex += 1 }
            if userIndex < application.applications.count && application.applications[userIndex].spokenLocation < NSMaxRange(range) { return }
            let spoken = render(host)
            guard !spoken.isEmpty else { return }
            guard edits.count < remaining else {
                failure = NarrationError.invalidInput("Too many spoken-form changes to prepare safely. No text was truncated.")
                stop.pointee = true; return
            }
            edits.append(.init(range: range, replacement: spoken, rule: rule))
        }
        if let failure { throw failure }
        try NarrationWorkCheckpoint.check()
        return edits
    }

    private static func render(_ host: String) -> String {
        var words: [String] = [], letters = ""
        func endWord() {
            guard !letters.isEmpty else { return }
            switch letters {
            case "a": words.append("ay")
            case "www" where words.isEmpty: words.append("double you double you double you")
            default: words.append(letters)
            }
            letters.removeAll(keepingCapacity: true)
        }
        for character in host.lowercased() {
            switch character {
            case ".": endWord(); words.append("dot")
            case "-": endWord(); words.append("dash")
            case "_": endWord(); words.append("underscore")
            case ":": endWord(); words.append("colon")
            case "[", "]": break // Brackets delimit an IPv6 literal in a URL.
            default:
                if let byte = character.asciiValue, (48...57).contains(byte) {
                    endWord(); words.append(digits[Int(byte - 48)])
                } else { letters.append(character) }
            }
        }
        endWord()
        return words.joined(separator: " ")
    }
}
